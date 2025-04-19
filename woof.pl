#!/usr/bin/env perl
# -*- encoding: utf-8 -*-
#
#  woof.pl -- an ad-hoc single file webserver
#  Perl port of woof by Simon Budig  <simon@budig.de>
#
#  Copyright (C) 2025, Francesco P Lovergine <pobox@lovergine.com>
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  A copy of the GNU General Public License is available at
#  http://www.fsf.org/licenses/gpl.txt, you can also write to the
#  Free Software Foundation, Inc., 59 Temple Place - Suite 330,
#  Boston, MA 02111-1307, USA.

use strict;
use warnings;

use File::Basename;
use File::Temp qw(tempfile);
use Config::IniFiles;
use POSIX qw(:sys_wait_h :signal_h);
use Getopt::Long qw(:config gnu_getopt);
use Term::ReadLine;

use IO::Socket::INET;
use Socket qw(inet_ntoa sockaddr_in);
use URI::Escape;
use LWP::UserAgent;
use HTTP::Status qw(:constants status_message);

use Archive::Tar;
use Archive::Zip;
use IO::Compress::Gzip qw(gzip $GzipError);
use IO::Compress::Bzip2 qw(bzip2 $Bzip2Error);

use File::Find;
use File::Copy;
use File::Spec;
use Fcntl qw(:flock :DEFAULT O_WRONLY O_CREAT O_EXCL);
use Errno qw(EEXIST);
use Cwd qw(abs_path getcwd);

# Global variables
our %GLOBS = (
    maxdownloads => 1,
    compressed => 'gz',
    upload => 0,
    upload_dir => '.',
    show_progress => 1,
    filename => '',
    archive_ext => '',
    server_running => 1,
    downloads_count => 0,
    redirect_count => 0,
);

# Set up signal handling for parent/child communication
$SIG{CHLD} = \&sig_child_handler;
$SIG{USR1} = \&sig_download_complete;
$SIG{INT}  = \&sig_interrupt_handler;
$SIG{TERM} = \&sig_terminate_handler;

# Signal handlers
sub sig_child_handler {
    # Reap dead child processes
    while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
        # Child process terminated
    }
    $SIG{CHLD} = \&sig_child_handler;  # Reset handler
}

sub sig_download_complete {
    $GLOBS{downloads_count}++;
    warn "Download completed. Count: $GLOBS{downloads_count}/$GLOBS{maxdownloads}\n";

    if ($GLOBS{downloads_count} >= $GLOBS{maxdownloads}) {
        warn "Maximum downloads reached. Shutting down server...\n";
        $GLOBS{server_running} = 0;
    }

    $SIG{USR1} = \&sig_download_complete;  # Reset handler
}

sub sig_interrupt_handler {
    warn "\nReceived interrupt signal. Shutting down server...\n";
    $GLOBS{server_running} = 0;
}

sub sig_terminate_handler {
    warn "\nReceived termination signal. Shutting down server...\n";
    $GLOBS{server_running} = 0;
}

# Utility function to guess the IP (as a string) where the server can be
# reached from the outside. Quite nasty problem actually.
sub find_ip {
    # We get a UDP-socket for the TEST-networks reserved by IANA.
    # It is highly unlikely, that there is special routing used
    # for these networks, hence the socket later should give us
    # the ip address of the default route.
    # We're doing multiple tests, to guard against the computer being
    # part of a test installation.

    my @candidates = ();

    for my $test_ip ("192.0.2.0", "198.51.100.0", "203.0.113.0") {
        my $sock = IO::Socket::INET->new(
            Proto    => 'udp',
            PeerAddr => $test_ip,
            PeerPort => 80,
        );

        if ($sock) {
            my $ip_addr = $sock->sockhost;
            $sock->close();

            if (grep { $_ eq $ip_addr } @candidates) {
                return $ip_addr;
            }

            push @candidates, $ip_addr;
        }
    }

    return $candidates[0] if @candidates;
    return "127.0.0.1"; # Fallback
}

# Determine MIME type of a file
sub get_mime_type {
    my ($file_name) = @_;

    my $mime_type;

    # Try to use File::MimeInfo::Magic if available
    if (eval { require File::MimeInfo::Magic; 1 }) {
        $mime_type = File::MimeInfo::Magic::mimetype($file_name);
    }

    # Fallback to basic extension mapping
    if (!$mime_type) {
        my %mime_map = (
            'txt'  => 'text/plain',
            'html' => 'text/html',
            'htm'  => 'text/html',
            'css'  => 'text/css',
            'js'   => 'application/javascript',
            'json' => 'application/json',
            'png'  => 'image/png',
            'jpg'  => 'image/jpeg',
            'jpeg' => 'image/jpeg',
            'gif'  => 'image/gif',
            'svg'  => 'image/svg+xml',
            'pdf'  => 'application/pdf',
            'zip'  => 'application/zip',
            'gz'   => 'application/gzip',
            'tar'  => 'application/x-tar',
            'mp3'  => 'audio/mpeg',
            'mp4'  => 'video/mp4',
        );

        if ($file_name =~ /\.([^.]+)$/) {
            my $ext = lc($1);
            $mime_type = $mime_map{$ext} if exists $mime_map{$ext};
        }
    }

    # Fallback to binary type
    return $mime_type || 'application/octet-stream';
}

# Send HTTP response header
sub send_http_header {
    my ($client, $code, $message, $content_type, $content_length, $headers) = @_;
    $headers ||= {};

    print $client "HTTP/1.0 $code $message\r\n";
    print $client "Content-Type: $content_type\r\n";
    print $client "Content-Length: $content_length\r\n" if defined $content_length;
    print $client "Server: woof-perl/1.0\r\n";

    foreach my $key (keys %$headers) {
        print $client "$key: $headers->{$key}\r\n";
    }

    print $client "\r\n";
}

# Parse HTTP request
sub parse_http_request {
    my ($client) = @_;
    my $request = {};

    # Read request line
    my $request_line = <$client>;
    return undef unless defined $request_line;

    chomp $request_line;
    $request_line =~ s/\r$//;

    if ($request_line =~ /^(GET|POST|HEAD) ([^ ]+) HTTP\/(\d\.\d)$/) {
        $request->{method} = $1;
        $request->{uri} = $2;
        $request->{http_version} = $3;
    } else {
        return undef;
    }

    # Read headers
    $request->{headers} = {};
    my $content_length = 0;

    while (my $line = <$client>) {
        chomp $line;
        $line =~ s/\r$//;
        last if $line eq '';

        if ($line =~ /^([^:]+):\s*(.*)$/) {
            my ($key, $value) = (lc($1), $2);
            $request->{headers}{$key} = $value;

            $content_length = $value if $key eq 'content-length';
        }
    }

    # Read POST data if applicable
    if ($request->{method} eq 'POST' && $content_length > 0) {
        $request->{content} = '';
        my $remaining = $content_length;

        while ($remaining > 0) {
            my $buffer;
            my $bytes_read = read($client, $buffer, $remaining > 8192 ? 8192 : $remaining);

            last if !defined $bytes_read || $bytes_read == 0;

            $request->{content} .= $buffer;
            $remaining -= $bytes_read;
        }
    }

    return $request;
}

# Parse multipart form data
sub parse_multipart_form {
    my ($content, $boundary) = @_;
    my $form_data = {};

    # Split content by boundary
    my @parts = split(/--\Q$boundary\E(?:--)?\r?\n/, $content);

    # Process each part (skip first empty part)
    for my $part (@parts[1..$#parts]) {
        next if $part =~ /^\s*$/;

        my ($headers, $body) = split(/\r?\n\r?\n/, $part, 2);
        my $headers_hash = {};

        # Parse headers
        foreach my $header (split(/\r?\n/, $headers)) {
            if ($header =~ /^([^:]+):\s*(.*)$/) {
                $headers_hash->{lc($1)} = $2;
            }
        }

        # Extract Content-Disposition info
        my $name;
        my $file_name;

        if ($headers_hash->{'content-disposition'} =~ /form-data; name="([^"]+)"/) {
            $name = $1;
        }

        if ($headers_hash->{'content-disposition'} =~ /filename="([^"]+)"/) {
            $file_name = $1;

            # Handle file uploads
            $form_data->{$name} = {
                filename => $file_name,
                content => $body,
                type => $headers_hash->{'content-type'} || 'application/octet-stream',
            };
        } else {
            # Handle regular form fields
            $form_data->{$name} = $body;
        }
    }

    return $form_data;
}

# Handle file upload
sub handle_upload {
    my ($request) = @_;

    if (!$GLOBS{upload}) {
        return (HTTP_NOT_IMPLEMENTED, status_message(HTTP_NOT_IMPLEMENTED), "text/plain", "Uploads are disabled");
    }

    # Parse Content-Type to get boundary
    my $boundary;
    if ($request->{headers}{'content-type'} =~ /boundary=(.+)$/) {
        $boundary = $1;
    } else {
        return (400, "Bad Request", "text/plain", "No boundary found in multipart/form-data");
    }

    # Parse form data
    my $form_data = parse_multipart_form($request->{content}, $boundary);

    # Check for uploaded file
    if (!exists $form_data->{upfile}) {
        return (403, "Forbidden", "text/plain", "No upload provided");
    }

    my $upfile = $form_data->{upfile};
    my $upfilename = $upfile->{filename};

    # Extract filename from path and sanitize
    if ($upfilename =~ /[\\\/]/) {
        $upfilename = basename($upfilename);
    }

    # Basic security: Prevent directory traversal
    $upfilename =~ s/[^a-zA-Z0-9_\-\.]/_/g;
    $upfilename =~ s/\.\./_/g;

    my $destfile;
    my $destfilename;

    # Try multiple filenames
    for my $suffix ('', '.1', '.2', '.3', '.4', '.5', '.6', '.7', '.8', '.9') {
        $destfilename = File::Spec->catfile($GLOBS{upload_dir}, $upfilename . $suffix);

        if (sysopen($destfile, $destfilename, O_WRONLY | O_CREAT | O_EXCL, 0644)) {
            last;
        } elsif ($! != EEXIST) {
            return (HTTP_INTERNAL_SERVER_ERROR, status_message(HTTP_INTERNAL_SERVER_ERROR), "text/plain", "Failed to open $destfilename: $!");
        }
    }

    # If all failed, use tempfile
    if (!defined $destfile) {
        ($destfile, $destfilename) = tempfile($upfilename . ".XXXXXX", DIR => $GLOBS{upload_dir});
    }

    warn "Accepting uploaded file: $upfilename -> $destfilename\n";

    # Write file content
    print $destfile $upfile->{content};
    close($destfile);

    my $html = <<HTML;
<!DOCTYPE html>
<html>
  <head>
    <title>Woof Upload</title>
    <style>
      body { font-family: Arial, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }
      h1 { color: #4CAF50; }
      .success { background-color: #e8f5e9; border-left: 5px solid #4CAF50; padding: 10px; }
    </style>
  </head>
  <body>
    <h1>Woof Upload Complete</h1>
    <div class="success">
      <p>File successfully uploaded as: <strong>$destfilename</strong></p>
      <p>File size: <strong>@{[length($upfile->{content})]} bytes</strong></p>
    </div>
    <p><a href="/">Upload another file</a></p>
  </body>
</html>
HTML

    return (HTTP_OK, status_message(HTTP_OK), "text/html", $html);
}

# Handle HTTP requests
# Handle HTTP requests
sub handle_request {
    my ($client) = @_;
    
    # Get peer address
    my $peeraddr = getpeername($client);
    my ($port, $addr) = sockaddr_in($peeraddr);
    my $client_ip = inet_ntoa($addr);
    my $client_port = $port;
    
    warn "Connection from $client_ip:$client_port\n";
    
    # Parse HTTP request
    my $request = parse_http_request($client);
    
    if (!defined $request) {
        send_http_header($client, HTTP_BAD_REQUEST, status_message(HTTP_BAD_REQUEST), "text/plain", 11);
        print $client "Bad Request";
        close($client);
        return;
    }
    
    warn "Request: $request->{method} $request->{uri}\n";
    
    # Handle different HTTP methods
    if ($request->{method} eq 'POST') {
        my ($code, $message, $content_type, $content) = handle_upload($request);
        send_http_header($client, $code, $message, $content_type, length($content));
        print $client $content;
        close($client);
    } 
    elsif ($request->{method} eq 'GET' || $request->{method} eq 'HEAD') {
        if ($GLOBS{upload}) {
            # Serve upload form
            my $html = <<HTML;
<!DOCTYPE html>
<html>
  <head>
    <title>Woof Upload</title>
    <style>
      body { font-family: Arial, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }
      h1 { color: #2196F3; }
      .upload-form { background-color: #e3f2fd; padding: 20px; border-radius: 5px; }
      .upload-form input[type="file"] { margin: 10px 0; }
      .upload-form input[type="submit"] { 
        background-color: #2196F3; color: white; padding: 10px 15px; 
        border: none; border-radius: 4px; cursor: pointer;
      }
      .upload-form input[type="submit"]:hover { background-color: #0b7dda; }
    </style>
  </head>
  <body>
    <h1>Woof Upload</h1>
    <div class="upload-form">
      <form name="upload" method="POST" enctype="multipart/form-data">
        <p>Select file to share:</p>
        <input type="file" name="upfile" />
        <p><input type="submit" value="Upload!" /></p>
      </form>
    </div>
  </body>
</html>
HTML
            send_http_header($client, HTTP_OK, status_message(HTTP_OK), "text/html", length($html));
            print $client $html if $request->{method} eq 'GET';
            close($client);
        }
        else {
            # Redirect any request to the filename of the file to serve
            my $path = $request->{uri};
            my $location = "/";
            
            if ($GLOBS{filename}) {
                $location .= uri_escape(basename($GLOBS{filename}));
                if (-d $GLOBS{filename}) {
                    if ($GLOBS{compressed} eq 'gz') {
                        $location .= ".tar.gz";
                    } elsif ($GLOBS{compressed} eq 'bz2') {
                        $location .= ".tar.bz2";
                    } elsif ($GLOBS{compressed} eq 'zip') {
                        $location .= ".zip";
                    } else {
                        $location .= ".tar";
                    }
                }
            }
            
            if ($path ne $location) {
                # Send redirect
                my $code = HTTP_FOUND;
                my $msg = status_message($code);
                my $html = <<HTML;
<!DOCTYPE html>
<html>
  <head><title>$code $msg</title></head>
  <body>$code $msg <a href="$location">here</a>.</body>
</html>
HTML
                send_http_header($client, $code, $msg, "text/html", length($html), {
                    'Location' => $location
                });
                print $client $html if $request->{method} eq 'GET';
                close($client);
                $GLOBS{redirect_count}++;
            }
            else {
                # Serve the file
                warn "$request->{method} request received for: " . basename($GLOBS{filename}) . "\n";
                
                # For HEAD requests, serve headers only and don't fork or count
                if ($request->{method} eq 'HEAD') {
                    handle_head_request($client);
                    close($client);
                }
                else {
                    # Create a child process to handle GET downloads
                    my $pid = fork();
                    
                    if (!defined $pid) {
                        # Fork failed
                        warn "Fork failed: $!\n";
                        send_http_header($client, HTTP_INTERNAL_SERVER_ERROR, status_message(HTTP_INTERNAL_SERVER_ERROR), "text/plain", 22);
                        print $client "Internal Server Error";
                        close($client);
                    }
                    elsif ($pid == 0) {
                        # Child process - handle the download
                        eval {
                            serve_file($client, $request->{method});
                        };
                        warn "Error serving file: $@" if $@;
                        
                        # Only signal completion for GET requests (actual downloads)
                        kill USR1 => getppid();
                        
                        # Exit child process
                        exit(0);
                    }
                    else {
                        # Parent process - close our copy of the client socket and continue
                        close($client);
                    }
                }
            }
        }
    }
    else {
        # Method not implemented
        send_http_header($client, HTTP_NOT_IMPLEMENTED, status_message(HTTP_NOT_IMPLEMENTED), "text/plain", 22);
        print $client "Method not implemented";
        close($client);
    }
}

# Handle HEAD requests - just send headers without counting as a download
sub handle_head_request {
    my ($client) = @_;
    my $type = undef;
    
    $type = "file" if -f $GLOBS{filename};
    $type = "dir" if  -d $GLOBS{filename};
    
    return unless $type;
    
    my $download_filename = basename($GLOBS{filename});
    $download_filename .= $GLOBS{archive_ext} if defined $GLOBS{archive_ext} && $GLOBS{archive_ext} ne '';
    
    my $content_type;
    my $headers = {
        'Content-Disposition' => 'attachment; filename="' . uri_escape($download_filename) . '"'
    };
    
    if ($type eq "file") {
        $content_type = get_mime_type($GLOBS{filename});
        my $filesize = -s $GLOBS{filename};
        $headers->{'Content-Length'} = $filesize if defined $filesize;
    } else {
        # For directories, use appropriate type based on compression
        if ($GLOBS{compressed} eq 'zip') {
            $content_type = 'application/zip';
        } elsif ($GLOBS{compressed} eq 'gz') {
            $content_type = 'application/gzip';
        } elsif ($GLOBS{compressed} eq 'bz2') {
            $content_type = 'application/x-bzip2';
        } else {
            $content_type = 'application/x-tar';
        }
    }
    
    # Send headers only for HEAD request
    send_http_header($client, HTTP_OK, status_message(HTTP_OK), $content_type, 
                    ($type eq "file" ? (-s $GLOBS{filename}) : undef), $headers);
    
    warn "HEAD request handled without download count increment\n";
}

# Serve a file or directory
sub serve_file {
    my ($client, $method) = @_;
    my $type = undef;

    $type = "file" if -f $GLOBS{filename};
    $type = "dir" if -d $GLOBS{filename};

    die "can only serve files or directories. Aborting.\n" if !$type;

    my $download_filename = basename($GLOBS{filename});
    $download_filename .= $GLOBS{archive_ext} if defined $GLOBS{archive_ext} && $GLOBS{archive_ext} ne '';

    my $content_type;
    my $headers = {
        'Content-Disposition' => 'attachment; filename="' . uri_escape($download_filename) . '"'
    };

    if ($type eq "file") {
        $content_type = get_mime_type($GLOBS{filename});
        my $filesize = -s $GLOBS{filename};
        $headers->{'Content-Length'} = $filesize if defined $filesize;
    } else {
        # For directories, use appropriate type based on compression
        if ($GLOBS{compressed} eq 'zip') {
            $content_type = 'application/zip';
        } elsif ($GLOBS{compressed} eq 'gz') {
            $content_type = 'application/gzip';
        } elsif ($GLOBS{compressed} eq 'bz2') {
            $content_type = 'application/x-bzip2';
        } else {
            $content_type = 'application/x-tar';
        }
    }

    send_http_header($client, HTTP_OK, status_message(HTTP_OK), $content_type,
                    ($type eq "file" ? (-s $GLOBS{filename}) : undef), $headers);

    # Only send content for GET requests
    return if $method eq 'HEAD';

    warn "Serving content: " . basename($GLOBS{filename}) .
         ($GLOBS{archive_ext} ? $GLOBS{archive_ext} : '') . "\n";

    if ($type eq "file") {
        open(my $datafile, "<", $GLOBS{filename}) or die "Can't open $GLOBS{filename} $!";
        binmode($datafile);
        binmode($client);

        my $filesize = -s $GLOBS{filename};
        my $bytes_sent = 0;
        my $last_percent = 0;

        my $buffer;
        while (my $bytes_read = read($datafile, $buffer, 8192)) {
            print $client $buffer;

            # Update progress if enabled
            if ($GLOBS{show_progress} && $filesize > 0) {
                $bytes_sent += $bytes_read;
                my $percent = int($bytes_sent * 100 / $filesize);

                if ($percent >= $last_percent + 10) {
                    warn "Transfer progress: $percent%\n";
                    $last_percent = $percent;
                }
            }
        }
        close($datafile);
    }
    elsif ($type eq "dir") {
        binmode($client);
        warn "Creating archive for directory: $GLOBS{filename}\n";

        # Determine the base directory path for proper path handling
        my $dir_path = $GLOBS{filename};
        my $base_name = basename($dir_path);
        my $parent_dir = dirname($dir_path);

        if ($GLOBS{compressed} eq 'zip') {
            my $zip = Archive::Zip->new();

            warn "Creating ZIP archive...\n";

            my $file_count = 0;

            # Change to parent directory to handle relative paths
            my $cwd = getcwd();
            chdir($parent_dir) or die "Cannot change to directory $parent_dir: $!";

            # Use a relative path for Find to preserve proper structure
            find(sub {
                return if -d $File::Find::name;
                $file_count++;

                # Use a path relative to parent directory
                my $rel_path = $File::Find::name;
                $rel_path =~ s!^\Q$parent_dir\E/!!;

                # Add with relative path
                $zip->addFile($File::Find::name, $rel_path);

                # Occasionally report progress
                warn "Added $file_count files to archive...\n" if $file_count % 100 == 0;
            }, $base_name);

            # Restore original directory
            chdir($cwd) or die "Cannot change back to directory $cwd: $!";

            warn "Writing ZIP archive with $file_count files...\n";
            $zip->writeToFileHandle($client);
        }
        else {
            warn "Creating TAR archive...\n";

            # Create a tar archive with proper relative paths
            my $tar = Archive::Tar->new();

            # Change to parent directory to handle relative paths
            my $cwd = getcwd();
            chdir($parent_dir) or die "Cannot change to directory $parent_dir: $!";

            # Add files with relative paths
            my @files_to_add = ();
            find(sub {
                # Get path relative to parent dir
                my $rel_path = $File::Find::name;
                $rel_path =~ s!^\Q$parent_dir\E/!!;

                push @files_to_add, $rel_path;
            }, $base_name);

            # Add files with proper relative paths
            $tar->add_files(@files_to_add);

            # Restore original directory
            chdir($cwd) or die "Cannot change back to directory $cwd: $!";

            if ($GLOBS{compressed} eq 'gz') {
                warn "Compressing with gzip...\n";
                my $tar_data = $tar->write();
                gzip \$tar_data => $client or die "gzip failed: $GzipError\n";
            }
            elsif ($GLOBS{compressed} eq 'bz2') {
                warn "Compressing with bzip2...\n";
                my $tar_data = $tar->write();
                bzip2 \$tar_data => $client or die "bzip2 failed: $Bzip2Error\n";
            }
            else {
                warn "Writing uncompressed tar...\n";
                $tar->write($client);
            }
        }
    }

    warn "Download complete for: " . basename($GLOBS{filename}) .
         ($GLOBS{archive_ext} ? $GLOBS{archive_ext} : '') . "\n";

    # Close the client connection after serving the file
    close($client);
}

# Main server function
sub serve_files {
    my ($filename_to_serve, $maxdown, $ip_addr, $port) = @_;

    $GLOBS{maxdownloads} = $maxdown;
    $GLOBS{filename}= $filename_to_serve;
    $GLOBS{downloads_count} = 0;
    $GLOBS{redirect_count} = 0;
    $GLOBS{server_running} = 1;

    $GLOBS{archive_ext} = "";
    if ($GLOBS{filename} && -d $GLOBS{filename}) {
        if ($GLOBS{compressed} eq 'gz') {
            $GLOBS{archive_ext} = ".tar.gz";
        } elsif ($GLOBS{compressed} eq 'bz2') {
            $GLOBS{archive_ext} = ".tar.bz2";
        } elsif ($GLOBS{compressed} eq 'zip') {
            $GLOBS{archive_ext} = ".zip";
        } else {
            $GLOBS{archive_ext} = ".tar";
        }
    }

    # Create listening socket
    my $server = IO::Socket::INET->new(
        LocalAddr => $ip_addr || '0.0.0.0',
        LocalPort => $port,
        Proto     => 'tcp',
        ReuseAddr => 1,
        Listen    => 5,
    ) or die "Cannot create socket: $!\n";

    # Get real IP address if not specified
    $ip_addr = find_ip() if !$ip_addr;

    if ($ip_addr) {
        my $location;

        if ($GLOBS{filename}) {
            $location = "http://$ip_addr:$port/" .
                uri_escape(basename($GLOBS{filename}) . $GLOBS{archive_ext});
        } else {
            $location = "http://$ip_addr:$port/";
        }

        print "Now serving on $location\n";
        print "Server will exit after $GLOBS{maxdownloads} download(s). Press CTRL-C to abort.\n";
    }

    # Set up non-blocking mode for server socket
    my $flags = fcntl($server, F_GETFL, 0)
        or die "Can't get flags for socket: $!\n";
    fcntl($server, F_SETFL, $flags | O_NONBLOCK)
        or die "Can't set socket to non-blocking mode: $!\n";

    # Main server loop
    my $start_time = time();

    while ($GLOBS{server_running} && $GLOBS{downloads_count} < $GLOBS{maxdownloads}) {
        # Accept new connections (non-blocking)
        my $client = $server->accept();

        handle_request($client) if $client;

        # Give other processes a chance to run
        select(undef, undef, undef, 0.1);

        # Periodically show server status if running for a while
        if (time() - $start_time > 300 && (time() - $start_time) % 300 < 1) {
            my $runtime = time() - $start_time;
            my $hours = int($runtime / 3600);
            my $minutes = int(($runtime % 3600) / 60);
            warn sprintf("Server status: running for %d:%02d, served %d/%d downloads\n",
                $hours, $minutes, $GLOBS{downloads_count}, $GLOBS{maxdownloads});
        }
    }

    my $runtime = time() - $start_time;
    my $hours = int($runtime / 3600);
    my $minutes = int(($runtime % 3600) / 60);
    my $seconds = $runtime % 60;

    print "\nServer stopped after serving $GLOBS{downloads_count} of $GLOBS{maxdownloads} download(s)\n";
    printf "Total runtime: %d:%02d:%02d\n", $hours, $minutes, $seconds;
    print "Received $GLOBS{redirect_count} connection(s) total\n";
    close($server);
}

sub woof_client {
    my ($url) = @_;
    
    # Check if URL is valid
    if ($url !~ m{^(http|https)://}) {
        return undef;
    }
    
    print "Connecting to $url...\n";
    
    # Set up signal handling for clean interruption
    local $SIG{INT} = sub {
        print "\nDownload interrupted by user.\n";
        exit 1;
    };
    
    # Create a user agent with minimal configuration
    my $ua = LWP::UserAgent->new(
        timeout => 60,
        keep_alive => 1,
    );
    
    # First make a HEAD request to get headers without downloading content
    my $head_response = $ua->head($url);
    
    if (!$head_response->is_success) {
        die "Failed to connect to $url: " . $head_response->status_line . "\n";
    }
    
    # Get filename from Content-Disposition header or from URL
    my $fname;
    my $disposition = $head_response->header('Content-Disposition');
    
    if ($disposition && $disposition =~ /^attachment;\s*filename="?([^"]+)"?/i) {
        $fname = $1;
    } else {
        $fname = basename($url);
        $fname =~ s/\?.*$//; # Remove query parameters
    }
    
    $fname = "woof-out.bin" if !$fname;
    
    $fname = uri_unescape($fname);
    $fname = basename($fname);
    
    # Get content type and size - ensure we have a clean numeric value
    my $content_type = $head_response->header('Content-Type') || 'application/octet-stream';
    my $content_length = $head_response->header('Content-Length');
    $content_length = 0 + $content_length if defined $content_length; # Force numeric context
    
    # Ask user for the target filename
    my $term = Term::ReadLine->new('woof');
    $term->ornaments(0);
    $term->add_history($fname);
    my $input = $term->readline("Enter target filename [$fname]: ");
    $fname = $input || $fname;
    
    my $destfilename = $fname =~ m{^/} ? $fname : "./$fname";
    my $fh; # File handle declaration moved outside of blocks for wider scope
    
    # Try to create a new file
    my $create_new = eval {
        sysopen($fh, $destfilename, O_WRONLY | O_CREAT | O_EXCL, 0644);
    };
    
    # Handle file exists case
    if (!$create_new && $! == EEXIST) {
        $input = $term->readline("File exists. Overwrite (y/n)? ");
        my $override = ($input =~ /^y(es)?$/i);
        
        if ($override) {
            # Create a new file, truncating if it exists
            unless (open($fh, ">", $destfilename)) {
                die "Failed to open $destfilename for overwriting: $!\n";
            }
        } else {
            # Try alternative filenames
            my $found = 0;
            for my $suffix (".1", ".2", ".3", ".4", ".5", ".6", ".7", ".8", ".9") {
                my $alt_name = $destfilename . $suffix;
                if (sysopen($fh, $alt_name, O_WRONLY | O_CREAT | O_EXCL, 0644)) {
                    $destfilename = $alt_name;
                    $found = 1;
                    last;
                } elsif ($! != EEXIST) {
                    die "Failed to open $alt_name: $!\n";
                }
            }
            
            # If still not found, use tempfile
            if (!$found) {
                ($fh, $destfilename) = tempfile("$fname.XXXXXX", DIR => ".");
            }
            
            print "alternate filename is: $destfilename\n";
        }
    } elsif (!$create_new) {
        die "Failed to open $destfilename: $!\n";
    }
    
    binmode($fh);  # Ensure binary mode for files
    
    print "downloading file: $fname -> $destfilename\n";
    if ($content_length) {
        printf "File size: %d bytes (%s)\n", $content_length, format_size($content_length);
    }
    
    # Now make a request for the actual content, with streaming download
    my $request = HTTP::Request->new(GET => $url);
    my $total_bytes = 0;
    my $last_percent = 0;
    my $start_time = time();
    
    # Use a callback to process chunks of data as they arrive
    my $response = $ua->request(
        $request,
        sub {
            my ($data, $response, $protocol) = @_;
            
            # Write chunk to file
            print $fh $data;
            
            my $chunk_size = length($data);
            $total_bytes += $chunk_size;
            
            # Update progress display if needed
            if ($GLOBS{show_progress} && $content_length && $content_length > 0) {
                my $percent = int(($total_bytes * 100) / $content_length);
                
                # Only update display when percent changes significantly
                if ($percent >= $last_percent + 5) {
                    my $elapsed = time() - $start_time;
                    my $rate = $elapsed > 0 ? $total_bytes / $elapsed : 0;
                    
                    printf("\rProgress: %d%% (%s / %s) - %s/sec ",
                        $percent,
                        format_size($total_bytes),
                        format_size($content_length),
                        format_size($rate));
                    $last_percent = $percent;
                }
            } elsif ($GLOBS{show_progress} && ($total_bytes % (1024 * 1024) < 8192)) {
                # If we don't know the size, show progress by megabyte
                printf("\rDownloaded: %s ", format_size($total_bytes));
            }
        }
    );
    
    close($fh);
    
    # If download was successful, show summary
    if ($response->is_success) {
        my $elapsed = time() - $start_time;
        my $rate = $elapsed > 0 ? $total_bytes / $elapsed : 0;
        
        print "\nDownload complete: $destfilename\n";
        printf "Size: %s\n", format_size($total_bytes);
        printf "Time: %d seconds\n", $elapsed;
        printf "Average speed: %s/sec\n", format_size($rate);
    } else {
        print "\nDownload failed: " . $response->status_line . "\n";
        # Remove incomplete file
        unlink($destfilename);
        return 0;
    }
    
    return 1;
}

# Helper function to format file sizes
sub format_size {
    my ($bytes) = @_;
    
    # Ensure we have a clean numeric value
    $bytes = 0 + $bytes;
    
    my @units = ('B', 'KB', 'MB', 'GB', 'TB');
    my $i = 0;
    
    while ($bytes >= 1024 && $i < $#units) {
        $bytes /= 1024;
        $i++;
    }
    
    return sprintf("%.2f %s", $bytes, $units[$i]);
}

sub usage {
    my ($defport, $defmaxdown, $errmsg) = @_;

    my $name = basename($0);
    print STDERR <<USAGE;

    Usage: $name [-i <ip_addr>] [-p <port>] [-c <count>] <file>
           $name [-i <ip_addr>] [-p <port>] [-c <count>] [-z|-j|-Z|-u] <dir>
           $name [-i <ip_addr>] [-p <port>] [-c <count>] -s
           $name [-i <ip_addr>] [-p <port>] [-c <count>] [-d <upload_dir>] -U
           $name [-q] <url>

    Serves a single file <count> times via http on port <port> on IP
    address <ip_addr>.
    When a directory is specified, an tar archive gets served. By default
    it is gzip compressed. You can specify -z for gzip compression,
    -j for bzip2 compression, -Z for ZIP compression or -u for no compression.
    You can configure your default compression method in the configuration
    file described below.

    When -s is specified instead of a filename, $name distributes itself.

    When -U is specified, woof provides an upload form, allowing file uploads.
    Optional -d <upload_dir> specifies where to save uploaded files.

    Option -q disables progress indicators.

    defaults: count = $defmaxdown, port = $defport

    If started with an url as an argument, woof acts as a client,
    downloading the file and saving it in the current directory.

    You can specify different defaults in two locations: /etc/woofrc
    and ~/.woofrc can be INI-style config files containing the default
    port and the default count. The file in the home directory takes
    precedence. The compression methods are "off", "gz", "bz2" or "zip".

    Sample file:

        [main]
        port = 8008
        count = 2
        ip = 127.0.0.1
        compressed = gz
        upload_dir = /tmp/woof-uploads
        show_progress = 1

USAGE

    print STDERR "$errmsg\n\n" if $errmsg;

    exit 1;
}

sub main {
    # Set default configuration
    $GLOBS{maxdownloads} = 1;
    my $port = 8080;
    my $ip_addr = '';
    $GLOBS{upload_dir} = '.';
    $GLOBS{show_progress} = 1;

    # Read config files
    my $config;
    $config = Config::IniFiles->new(-file => '/etc/woofrc') if -f '/etc/woofrc';

    my $home_config_file = $ENV{HOME} ? "$ENV{HOME}/.woofrc" : undef;
    if ($home_config_file && -f $home_config_file) {
        $config = Config::IniFiles->new(-file => $home_config_file);
    }

    if ($config) {
        if ($config->val('main', 'port')) {
            $port = $config->val('main', 'port');
        }

        if ($config->val('main', 'count')) {
            $GLOBS{maxdownloads} = $config->val('main', 'count');
        }

        if ($config->val('main', 'ip')) {
            $ip_addr = $config->val('main', 'ip');
        }

        if ($config->val('main', 'upload_dir')) {
            $GLOBS{upload_dir} = $config->val('main', 'upload_dir');
        }

        if (defined $config->val('main', 'show_progress')) {
            $GLOBS{show_progress} = $config->val('main', 'show_progress');
        }

        if ($config->val('main', 'compressed')) {
            my %formats = (
                'gz'    => 'gz',
                'true'  => 'gz',
                'bz'    => 'bz2',
                'bz2'   => 'bz2',
                'zip'   => 'zip',
                'off'   => '',
                'false' => ''
            );

            my $value = $config->val('main', 'compressed');
            $GLOBS{compressed} = $formats{$value} if exists $formats{$value};
        }
    }

    my $defaultport = $port;
    my $defaultmaxdown = $GLOBS{maxdownloads};
    my $do_usage = 0;
    my $want_to_serve_self = 0;

    # Parse command line options
    GetOptions(
        'h|help'      => \$do_usage,
        'U|upload'    => sub { $GLOBS{upload} = 1; },
        's|self'      => \$want_to_serve_self,
        'z|gzip'      => sub { $GLOBS{compressed} = 'gz'; },
        'j|bzip2'     => sub { $GLOBS{compressed} = 'bz2'; },
        'Z|zip'       => sub { $GLOBS{compressed} = 'zip'; },
        'u|uncompress'=> sub { $GLOBS{compressed} = ''; },
        'i|ip=s'      => \$ip_addr,
        'c|count=i'   => \$GLOBS{maxdownloads},
        'p|port=i'    => \$port,
        'd|upload-dir=s' => \$GLOBS{upload_dir},
        'q|quiet'     => sub { $GLOBS{show_progress} = 0; },
    ) or usage($defaultport, $defaultmaxdown, "Invalid options");

    if ($do_usage) {
        usage($defaultport, $defaultmaxdown);
    }

    if ($GLOBS{maxdownloads} <= 0) {
        usage($defaultport, $defaultmaxdown, "invalid download count: $GLOBS{maxdownloads}. Please specify an integer >= 0.");
    }

    # Validate upload directory
    if ($GLOBS{upload} && ! -d $GLOBS{upload_dir}) {
        usage($defaultport, $defaultmaxdown, "Upload directory $GLOBS{upload_dir} does not exist");
    }

    if ($want_to_serve_self) {
        # When serving self, we should serve the script with the complete header
        # and all comments intact, so we use the exact script path
        $GLOBS{filename} = abs_path($0);
    } else {
        $GLOBS{filename} = shift @ARGV;
    }

    if ($GLOBS{upload}) {
        if ($GLOBS{filename}) {
            usage($defaultport, $defaultmaxdown, "Conflicting usage: simultaneous up- and download not supported.");
        }
    } elsif (!$GLOBS{filename}) {
        usage($defaultport, $defaultmaxdown, "Can only serve single files/directories.");
    } elsif ($GLOBS{filename} =~ m{^(http|https)://}) {
        woof_client($GLOBS{filename});
        exit 0;
    } else {
        $GLOBS{filename} = abs_path($GLOBS{filename});

        if (!-e $GLOBS{filename}) {
            usage($defaultport, $defaultmaxdown, "$GLOBS{filename}: No such file or directory");
        }

        if (!(-f $GLOBS{filename} || -d $GLOBS{filename})) {
            usage($defaultport, $defaultmaxdown, "$GLOBS{filename}: Neither file nor directory");
        }
    }

    serve_files($GLOBS{filename}, $GLOBS{maxdownloads}, $ip_addr, $port);
}

# Run main program
eval {
    main();
};

if ($@) {
    if ($@ =~ /Interrupted/) {
        print "\n"; # Clean up terminal on ctrl-c
    } else {
        die $@;
    }
}

exit 0;

__END__

=pod

=head1 NAME

woof.pl - Web Offer One File - an ad-hoc single file HTTP server

=head1 SYNOPSIS

  # Serve a single file
  woof.pl [-i <ip_addr>] [-p <port>] [-c <count>] <file>

  # Serve a directory as an archive
  woof.pl [-i <ip_addr>] [-p <port>] [-c <count>] [-z|-j|-Z|-u] <dir>

  # Serve the woof.pl script itself
  woof.pl [-i <ip_addr>] [-p <port>] [-c <count>] -s

  # Provide an upload form
  woof.pl [-i <ip_addr>] [-p <port>] [-c <count>] [-d <upload_dir>] -U

  # Act as a client and download a file
  woof.pl [-q] <url>

=head1 DESCRIPTION

B<woof.pl> is a Perl port of Simon Budig's "woof" tool designed to quickly share
files over a network. It starts a lightweight HTTP server that makes a file or
directory available for download on your local network or the internet. After
the specified number of downloads, the server automatically shuts down.

When sharing a directory, woof.pl automatically creates an archive (tar.gz by
default) on-the-fly. By default, all files are offered with Content-Disposition:
attachment, prompting browsers to download rather than display them.

In client mode, woof.pl can also download files from other woof instances or any
HTTP server.

=head1 OPTIONS

=over 4

=item B<-i>, B<--ip>=I<ip_address>

Specify the IP address to bind to. If not provided, woof will attempt to
determine your machine's IP address automatically.

=item B<-p>, B<--port>=I<port>

Specify the TCP port to listen on (default: 8080).

=item B<-c>, B<--count>=I<number>

Number of times the file may be downloaded before the server exits
(default: 1).

=item B<-s>, B<--self>

Serve the woof.pl script itself instead of a file.

=item B<-U>, B<--upload>

Instead of serving a file, provide a form allowing others to upload files
to your computer.

=item B<-d>, B<--upload-dir>=I<directory>

Specify a directory to store uploaded files (default: current directory).

=item B<-z>, B<--gzip>

When serving a directory, compress it as a tar.gz archive (default).

=item B<-j>, B<--bzip2>

When serving a directory, compress it as a tar.bz2 archive.

=item B<-Z>, B<--zip>

When serving a directory, compress it as a ZIP archive.

=item B<-u>, B<--uncompress>

When serving a directory, create an uncompressed tar archive.

=item B<-q>, B<--quiet>

Disable progress indicators during uploads and downloads.

=item B<-h>, B<--help>

Display help message and exit.

=back

=head1 CONFIGURATION FILES

woof.pl can read configuration from two INI-style configuration files:

=over 4

=item * Global configuration: F</etc/woofrc>

=item * User configuration: F<~/.woofrc>

=back

The user's configuration takes precedence over the global one. These files
can specify the default port, download count, IP address, and compression
method.

Sample configuration file:

  [main]
  port = 8008
  count = 2
  ip = 127.0.0.1
  compressed = gz
  upload_dir = /tmp/woof-uploads
  show_progress = 1

Valid compression methods in the config file are: "gz", "bz2", "zip", "off".

=head1 EXAMPLES

=over 4

=item Share a file once, using the default port (8080):

  woof.pl /path/to/file.pdf

=item Share an image five times on port 9090:

  woof.pl -c 5 -p 9090 image.jpg

=item Share a directory as a ZIP archive:

  woof.pl -Z /path/to/directory

=item Share a directory as an uncompressed tar archive:

  woof.pl -u /path/to/directory

=item Provide an upload form for others to send you files:

  woof.pl -U

=item Provide an upload form storing files in a specific directory:

  woof.pl -U -d /path/to/uploads

=item Download a file being shared by another woof instance:

  woof.pl http://192.168.1.101:8080/file.zip

=back

=head1 SECURITY CONSIDERATIONS

woof.pl is designed for convenient ad-hoc file sharing and not as a
permanent server solution. Consider these security implications:

=over 4

=item * There is minimal access control - anyone with the URL can access your file

=item * The server provides minimal logging and request filtering

=item * When using the upload feature, anyone with the URL can upload files to your system

=item * By default, the tool binds to all interfaces, potentially exposing the service to the internet

=back

For more security, consider using the B<-i> option to bind to a specific interface
(like 127.0.0.1 for local-only access) or restrict uploads to a specific directory
with B<-d>.

=head1 AUTHOR

Perl port of woof by Francesco P Lovergine <pobox@lovergine.com>

Original woof by Simon Budig <simon@budig.de>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2025, Francesco P Lovergine

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3 of the License, or
(at your option) any later version.

=head1 SEE ALSO

The original Python woof: L<https://github.com/simon-budig/woof>

=cut
