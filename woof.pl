#!/usr/bin/env perl
# -*- encoding: utf-8 -*-
#
#  woof.pl -- an ad-hoc single file webserver
#  Perl port of woof by Simon Budig  <simon@budig.de>
#
#  Copyright 2025(C), Francesco P Lovergine <pobox@lovergine.com>
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

use Archive::Tar;
use Archive::Zip;
use IO::Compress::Gzip qw(gzip $GzipError);
use IO::Compress::Bzip2 qw(bzip2 $Bzip2Error);

use File::Find;
use File::Copy;
use Fcntl qw(:flock :DEFAULT O_WRONLY O_CREAT O_EXCL);
use Errno qw(EEXIST);
use Cwd qw(abs_path);

# Global variables
our $maxdownloads = 2;
our $compressed = 'gz';
our $upload = 0;
our $filename;
our $archive_ext = '';
our $server_running = 1;
our $downloads_count = 0;
our $actual_download = 0;  # Flag to differentiate between redirects and actual downloads

# Set up signal handling for parent/child communication
$SIG{CHLD} = \&sig_child_handler;
$SIG{USR1} = \&sig_download_complete;
$SIG{INT} = \&sig_interrupt_handler;
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
    if ($actual_download) {
        $downloads_count++;
        warn "Download completed. Count: $downloads_count/$maxdownloads\n";
        
        if ($downloads_count >= $maxdownloads) {
            warn "Maximum downloads reached. Shutting down server...\n";
            $server_running = 0;
        }
    } else {
        warn "Redirect request processed (not counted towards download limit)\n";
    }
    
    # Reset the actual_download flag for the next request
    $actual_download = 0;
    
    $SIG{USR1} = \&sig_download_complete;  # Reset handler
}

sub sig_interrupt_handler {
    warn "\nReceived interrupt signal. Shutting down server...\n";
    $server_running = 0;
}

sub sig_terminate_handler {
    warn "\nReceived termination signal. Shutting down server...\n";
    $server_running = 0;
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

# Send HTTP response header
sub send_http_header {
    my ($client, $code, $message, $content_type, $content_length, $headers) = @_;
    $headers ||= {};
    
    print $client "HTTP/1.0 $code $message\r\n";
    print $client "Content-Type: $content_type\r\n";
    print $client "Content-Length: $content_length\r\n" if defined $content_length;
    
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
            my $bytes_read = read($client, $buffer, $remaining);
            
            if (!defined $bytes_read || $bytes_read == 0) {
                last;
            }
            
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
        my $filename;
        
        if ($headers_hash->{'content-disposition'} =~ /form-data; name="([^"]+)"/) {
            $name = $1;
        }
        
        if ($headers_hash->{'content-disposition'} =~ /filename="([^"]+)"/) {
            $filename = $1;
            
            # Handle file uploads
            $form_data->{$name} = {
                filename => $filename,
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
    
    if (!$upload) {
        return (501, "Not Implemented", "text/plain", "Uploads are disabled");
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
    
    # Extract filename from path
    if ($upfilename =~ /\\/) {
        $upfilename = (split(/\\/, $upfilename))[-1];
    }
    $upfilename = basename($upfilename);
    
    my $destfile;
    my $destfilename;
    
    # Try multiple filenames
    for my $suffix ('', '.1', '.2', '.3', '.4', '.5', '.6', '.7', '.8', '.9') {
        # Handle absolute and relative paths correctly
        $destfilename = ($upfilename =~ m{^/} ? $upfilename : "./$upfilename") . $suffix;
        if (sysopen($destfile, $destfilename, O_WRONLY | O_CREAT | O_EXCL, 0644)) {
            last;
        } elsif ($! != EEXIST) {
            return (500, "Internal Server Error", "text/plain", "Failed to open $destfilename: $!");
        }
    }
    
    # If all failed, use tempfile
    if (!defined $destfile) {
        $upfilename .= '.';
        ($destfile, $destfilename) = tempfile($upfilename . "XXXXXX", DIR => ".");
    }
    
    warn "accepting uploaded file: $upfilename -> $destfilename\n";
    
    # Write file content
    print $destfile $upfile->{content};
    close($destfile);
    
    my $html = <<HTML;
<html>
  <head><title>Woof Upload</title></head>
  <body>
    <h1>Woof Upload complete</h1>
    <p>Thanks a lot!</p>
  </body>
</html>
HTML
    
    return (200, "OK", "text/html", $html);
}

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
        send_http_header($client, 400, "Bad Request", "text/plain", 11);
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
    } 
    elsif ($request->{method} eq 'GET') {
        if ($upload) {
            # Serve upload form
            my $html = <<HTML;
<html>
  <head><title>Woof Upload</title></head>
  <body>
    <h1>Woof Upload</h1>
    <form name="upload" method="POST" enctype="multipart/form-data">
      <p><input type="file" name="upfile" /></p>
      <p><input type="submit" value="Upload!" /></p>
    </form>
  </body>
</html>
HTML
            send_http_header($client, 200, "OK", "text/html", length($html));
            print $client $html;
        }
        else {
            # Redirect any request to the filename of the file to serve
            my $path = $request->{uri};
            my $location = "/";
            
            if ($filename) {
                $location .= uri_escape(basename($filename));
                if (-d $filename) {
                    if ($compressed eq 'gz') {
                        $location .= ".tar.gz";
                    } elsif ($compressed eq 'bz2') {
                        $location .= ".tar.bz2";
                    } elsif ($compressed eq 'zip') {
                        $location .= ".zip";
                    } else {
                        $location .= ".tar";
                    }
                }
            }
            
            if ($path ne $location) {
                # Send redirect
                my $html = <<HTML;
<html>
  <head><title>302 Found</title></head>
  <body>302 Found <a href="$location">here</a>.</body>
</html>
HTML
                send_http_header($client, 302, "Found", "text/html", length($html), {
                    'Location' => $location
                });
                print $client $html;
            }
            else {
                # Decrement the download counter
                $downloads_count++;
                warn "Download started. Count: $downloads_count/$maxdownloads\n";
                
                # Check if we've reached the limit
                if ($downloads_count >= $maxdownloads) {
                    warn "Maximum downloads reached. Shutting down server...\n";
                    $server_running = 0;
                }
                
                # Fork a child process to serve the file
                my $pid = fork();
                
                if ($pid == 0) {
                    # Child process - serve the file
                    eval {
                        serve_file($client);
                    };
                    warn "Error serving file: $@" if $@;
                    
                    # Exit child process
                    close($client);
                    exit(0);
                }
                else {
                    # Parent process - close client socket and continue
                    close($client);
                }
            }
        }
    }
    else {
        # Method not implemented
        send_http_header($client, 501, "Not Implemented", "text/plain", 22);
        print $client "Method not implemented";
    }
    
    close($client);
}

# Serve a file or directory
sub serve_file {
    my ($client) = @_;
    my $type = undef;
    
    if (-f $filename) {
        $type = "file";
    } elsif (-d $filename) {
        $type = "dir";
    }
    
    die "can only serve files or directories. Aborting.\n" if !$type;
    
    my $download_filename = basename($filename);
    $download_filename .= $archive_ext if defined $archive_ext;
    
    my $headers = {
        'Content-Disposition' => 'attachment;filename=' . uri_escape($download_filename)
    };
    
    if (-f $filename) {
        my $filesize = -s $filename;
        $headers->{'Content-Length'} = $filesize if defined $filesize;
    }
    
    send_http_header($client, 200, "OK", "application/octet-stream", 
                    ($type eq "file" ? (-s $filename) : undef), $headers);
    
    if ($type eq "file") {
        open(my $datafile, "<", $filename) or die "Can't open $filename: $!";
        binmode($datafile);
        binmode($client);
        
        my $buffer;
        while (read($datafile, $buffer, 8192)) {
            print $client $buffer;
        }
        close($datafile);
    } 
    elsif ($type eq "dir") {
        binmode($client);
        
        if ($compressed eq 'zip') {
            my $zip = Archive::Zip->new();
            
            my $stripoff = dirname($filename) . '/';
            $stripoff =~ s/\/$// if $stripoff eq './';
            
            find(sub {
                return if -d $File::Find::name;
                my $file = $File::Find::name;
                my $arcname = $file;
                $arcname =~ s/^\Q$stripoff\E//;
                $zip->addFile($file, $arcname);
            }, $filename);
            
            $zip->writeToFileHandle($client);
        } 
        else {
            my $tar = Archive::Tar->new();
            $tar->add_files($filename);
            
            if ($compressed eq 'gz') {
                my $tar_data = $tar->write();
                gzip \$tar_data => $client or die "gzip failed: $GzipError\n";
            } 
            elsif ($compressed eq 'bz2') {
                my $tar_data = $tar->write();
                bzip2 \$tar_data => $client or die "bzip2 failed: $Bzip2Error\n";
            } 
            else {
                $tar->write($client);
            }
        }
    }
}

# Main server function
sub serve_files {
    my ($filename_to_serve, $maxdown, $ip_addr, $port) = @_;
    
    $maxdownloads = $maxdown;
    $filename = $filename_to_serve;
    $downloads_count = 0;
    $server_running = 1;
    
    $archive_ext = "";
    if ($filename && -d $filename) {
        if ($compressed eq 'gz') {
            $archive_ext = ".tar.gz";
        } elsif ($compressed eq 'bz2') {
            $archive_ext = ".tar.bz2";
        } elsif ($compressed eq 'zip') {
            $archive_ext = ".zip";
        } else {
            $archive_ext = ".tar";
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
        
        if ($filename) {
            $location = "http://$ip_addr:$port/" . 
                uri_escape(basename($filename) . $archive_ext);
        } else {
            $location = "http://$ip_addr:$port/";
        }
        
        print "Now serving on $location\n";
        print "Server will exit after $maxdownloads download(s)\n";
    }
    
    # Set up non-blocking mode for server socket
    my $flags = fcntl($server, F_GETFL, 0)
        or die "Can't get flags for socket: $!\n";
    fcntl($server, F_SETFL, $flags | O_NONBLOCK)
        or die "Can't set socket to non-blocking mode: $!\n";
    
    # Main server loop
    while ($server_running && $downloads_count < $maxdownloads) {
        # Accept new connections (non-blocking)
        my $client = $server->accept();
        
        if ($client) {
            handle_request($client);
        }
        
        # Give other processes a chance to run
        select(undef, undef, undef, 0.1);
    }
    
    close($server);
    print "Server stopped after serving $downloads_count download(s)\n";
}

sub woof_client {
    my ($url) = @_;
    
    # Check if URL is valid
    if ($url !~ m{^(http|https)://}) {
        return undef;
    }
    
    # Create a user agent that automatically follows redirects
    my $ua = LWP::UserAgent->new();
    
    # Make the GET request, which will automatically follow redirects
    my $response = $ua->get($url);
    
    if (!$response->is_success) {
        die "Failed to download from $url: " . $response->status_line . "\n";
    }
    
    # Get filename from Content-Disposition header or from URL
    my $fname;
    my $disposition = $response->header('Content-Disposition');
    
    if ($disposition && $disposition =~ /^attachment;\s*filename="?([^"]+)"?/i) {
        $fname = $1;
    } else {
        $fname = basename($url);
    }
    
    $fname = "woof-out.bin" if !$fname;
    
    $fname = uri_unescape($fname);
    $fname = basename($fname);
    
    # Ask user for the target filename
    my $term = Term::ReadLine->new('woof');
    $term->ornaments(0);
    $term->add_history($fname);
    my $input = $term->readline("Enter target filename: ", $fname);
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
    
    print "downloading file: $fname -> $destfilename\n";
    
    # Get the content and write to file
    my $content = $response->content;
    
    if (defined $fh) {
        binmode($fh);  # Ensure binary mode for files
        print $fh $content;
        close($fh);
    } else {
        die "No valid filehandle to write content to\n";
    }
    
    return 1;
}

sub usage {
    my ($defport, $defmaxdown, $errmsg) = @_;
    
    my $name = basename($0);
    print STDERR <<USAGE;

    Usage: $name [-i <ip_addr>] [-p <port>] [-c <count>] <file>
           $name [-i <ip_addr>] [-p <port>] [-c <count>] [-z|-j|-Z|-u] <dir>
           $name [-i <ip_addr>] [-p <port>] [-c <count>] -s
           $name [-i <ip_addr>] [-p <port>] [-c <count>] -U

           $name <url>

    Serves a single file <count> times via http on port <port> on IP
    address <ip_addr>.
    When a directory is specified, an tar archive gets served. By default
    it is gzip compressed. You can specify -z for gzip compression,
    -j for bzip2 compression, -Z for ZIP compression or -u for no compression.
    You can configure your default compression method in the configuration
    file described below.

    When -s is specified instead of a filename, $name distributes itself.

    When -U is specified, woof provides an upload form, allowing file uploads.

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

USAGE
    
    print STDERR "$errmsg\n\n" if $errmsg;
    
    exit 1;
}

sub main {
    my $maxdown = 1;
    my $port = 8080;
    my $ip_addr = '';
    my $do_usage = 0;
    my $want_to_serve_self = 0;
    
    # Read config files
    my $config;
    if (-f '/etc/woofrc') {
        $config = Config::IniFiles->new(-file => '/etc/woofrc');
    }
    
    my $home_config_file = $ENV{HOME} ? "$ENV{HOME}/.woofrc" : undef;
    if ($home_config_file && -f $home_config_file) {
        $config = Config::IniFiles->new(-file => $home_config_file);
    }
    
    if ($config) {
        if ($config->val('main', 'port')) {
            $port = $config->val('main', 'port');
        }
        
        if ($config->val('main', 'count')) {
            $maxdown = $config->val('main', 'count');
        }
        
        if ($config->val('main', 'ip')) {
            $ip_addr = $config->val('main', 'ip');
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
            $compressed = $formats{$value} if exists $formats{$value};
        }
    }
    
    my $defaultport = $port;
    my $defaultmaxdown = $maxdown;
    
    # Parse command line options
    GetOptions(
        'h|help'      => \$do_usage,
        'U|upload'    => \$upload,
        's|self'      => \$want_to_serve_self,
        'z|gzip'      => sub { $compressed = 'gz'; },
        'j|bzip2'     => sub { $compressed = 'bz2'; },
        'Z|zip'       => sub { $compressed = 'zip'; },
        'u|uncompress'=> sub { $compressed = ''; },
        'i|ip=s'      => \$ip_addr,
        'c|count=i'   => \$maxdown,
        'p|port=i'    => \$port,
    ) or usage($defaultport, $defaultmaxdown, "Invalid options");
    
    if ($do_usage) {
        usage($defaultport, $defaultmaxdown);
    }
    
    if ($maxdown <= 0) {
        usage($defaultport, $defaultmaxdown, "invalid download count: $maxdown. Please specify an integer >= 0.");
    }
    
    if ($want_to_serve_self) {
        # When serving self, we should serve the script with the complete header
        # and all comments intact, so we use the exact script path
        $filename = abs_path($0);
    } else {
        $filename = shift @ARGV;
    }
    
    if ($upload) {
        if ($filename) {
            usage($defaultport, $defaultmaxdown, "Conflicting usage: simultaneous up- and download not supported.");
        }
        $filename = undef;
    } elsif (!$filename) {
        usage($defaultport, $defaultmaxdown, "Can only serve single files/directories.");
    } elsif ($filename =~ m{^(http|https)://}) {
        woof_client($filename);
        exit 0;
    } else {
        $filename = abs_path($filename);
        
        if (!-e $filename) {
            usage($defaultport, $defaultmaxdown, "$filename: No such file or directory");
        }
        
        if (!(-f $filename || -d $filename)) {
            usage($defaultport, $defaultmaxdown, "$filename: Neither file nor directory");
        }
    }
    
    serve_files($filename, $maxdown, $ip_addr, $port);
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
