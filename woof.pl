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
#  the Free Software Foundation; either version 2 of the License, or
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
use POSIX qw(:sys_wait_h);
use Getopt::Long qw(:config gnu_getopt);
use Term::ReadLine;

use HTTP::Server::Simple::CGI;
use HTTP::Status qw(:constants);
use IO::Socket::INET;
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
our $maxdownloads = 1;
our $cpid = -1;
our $compressed = 'gz';
our $upload = 0;
our $filename;
our $archive_ext = '';

# My HTTP server class that inherits from HTTP::Server::Simple::CGI
package WoofServer;
use base qw(HTTP::Server::Simple::CGI);
use HTTP::Status qw(:constants);
use URI::Escape;
use File::Basename;
use POSIX qw(:sys_wait_h);
use File::Copy;
use Archive::Tar;
use Archive::Zip;
use IO::Compress::Gzip qw(gzip $GzipError);
use IO::Compress::Bzip2 qw(bzip2 $Bzip2Error);
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use Errno qw(EEXIST);

sub handle_request {
    my ($self, $cgi) = @_;
    
    my $method = $ENV{REQUEST_METHOD};
    
    if ($method eq 'POST') {
        $self->handle_post($cgi);
    } elsif ($method eq 'GET') {
        $self->handle_get($cgi);
    } else {
        print "HTTP/1.0 501 Not Implemented\r\n";
        print "Content-Type: text/plain\r\n\r\n";
        print "Method $method not implemented\r\n";
    }
}

sub handle_post {
    my ($self, $cgi) = @_;
    
    # Handle file uploads
    if (!$main::upload) {
        print "HTTP/1.0 501 Not Implemented\r\n";
        print "Content-Type: text/plain\r\n\r\n";
        print "Uploads are disabled\r\n";
        return;
    }
    
    my $upfile = $cgi->param('upfile');
    
    if (!$upfile) {
        print "HTTP/1.0 403 Forbidden\r\n";
        print "Content-Type: text/plain\r\n\r\n";
        print "No upload provided\r\n";
        return;
    }
    
    my $upfilename = $upfile;
    
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
            die "Failed to open $destfilename: $!";
        }
    }
    
    # If all failed, use tempfile
    if (!defined $destfile) {
        $upfilename .= '.';
        ($destfile, $destfilename) = tempfile($upfilename . "XXXXXX", DIR => ".");
    }
    
    warn "accepting uploaded file: $upfilename -> $destfilename\n";
    
    # Copy uploaded file to destination
    my $fh = $cgi->upload('upfile');
    if (!$fh) {
        print "HTTP/1.0 408 Request Timeout\r\n";
        print "Content-Type: text/plain\r\n\r\n";
        print "Upload interrupted\r\n";
        return;
    }
    
    copy($fh, $destfile);
    close($destfile);
    
    my $txt = <<HTML;
<html>
  <head><title>Woof Upload</title></head>
  <body>
    <h1>Woof Upload complete</h1>
    <p>Thanks a lot!</p>
  </body>
</html>
HTML
    
    print "HTTP/1.0 200 OK\r\n";
    print "Content-Type: text/html\r\n";
    print "Content-Length: " . length($txt) . "\r\n";
    print "\r\n";
    print $txt;
    
    $main::maxdownloads--;
}

sub handle_get {
    my ($self, $cgi) = @_;
    
    # Form for uploading a file
    if ($main::upload) {
        my $txt = <<HTML;
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
        print "HTTP/1.0 200 OK\r\n";
        print "Content-Type: text/html\r\n";
        print "Content-Length: " . length($txt) . "\r\n";
        print "\r\n";
        print $txt;
        return;
    }
    
    # Get path from request
    my $path = $ENV{PATH_INFO} || "/";
    $path = uri_unescape($path);
    
    # Redirect any request to the filename of the file to serve
    my $location = "/";
    if ($main::filename) {
        $location .= uri_escape(basename($main::filename));
        if (-d $main::filename) {
            if ($main::compressed eq 'gz') {
                $location .= ".tar.gz";
            } elsif ($main::compressed eq 'bz2') {
                $location .= ".tar.bz2";
            } elsif ($main::compressed eq 'zip') {
                $location .= ".zip";
            } else {
                $location .= ".tar";
            }
        }
    }
    
    if ($path ne $location) {
        my $txt = <<HTML;
<html>
  <head><title>302 Found</title></head>
  <body>302 Found <a href="$location">here</a>.</body>
</html>
HTML
        
        print "HTTP/1.0 302 Found\r\n";
        print "Location: $location\r\n";
        print "Content-Type: text/html\r\n";
        print "Content-Length: " . length($txt) . "\r\n";
        print "\r\n";
        print $txt;
        return;
    }
    
    $main::maxdownloads--;
    
    # Fork to handle the actual download
    $main::cpid = fork();
    
    if ($main::cpid == 0) {
        # Child process
        my $type = undef;
        
        if (-f $main::filename) {
            $type = "file";
        } elsif (-d $main::filename) {
            $type = "dir";
        }
        
       die "can only serve files or directories. Aborting.\n" if ! $type;
        
        print "HTTP/1.0 200 OK\r\n";
        print "Content-Type: application/octet-stream\r\n";
        my $download_filename = basename($main::filename);
        $download_filename .= $main::archive_ext if defined $main::archive_ext;
        print "Content-Disposition: attachment;filename=" . uri_escape($download_filename) . "\r\n";
        
        if (-f $main::filename) {
            my $filesize = -s $main::filename;
            print "Content-Length: $filesize\r\n" if defined $filesize;
        }
        
        print "\r\n";
        
        eval {
            if ($type eq "file") {
                open(my $datafile, "<", $main::filename) or die "Can't open $main::filename: $!";
                binmode($datafile);
                binmode(STDOUT);
                
                my $buffer;
                while (read($datafile, $buffer, 8192)) {
                    print $buffer;
                }
                close($datafile);
            } elsif ($type eq "dir") {
                if ($main::compressed eq 'zip') {
                    my $zip = Archive::Zip->new();
                    
                    my $stripoff = dirname($main::filename) . '/';
                    $stripoff =~ s/\/$// if $stripoff eq './';
                    
                    find(sub {
                        return if -d $File::Find::name;
                        my $filename = $File::Find::name;
                        my $arcname = $filename;
                        $arcname =~ s/^\Q$stripoff\E//;
                        $zip->addFile($filename, $arcname);
                    }, $main::filename);
                    
                    binmode(STDOUT);
                    $zip->writeToFileHandle(\*STDOUT);
                } else {
                    my $tar = Archive::Tar->new();
                    $tar->add_files($main::filename);
                    
                    if ($main::compressed eq 'gz') {
                        my $tar_data = $tar->write();
                        binmode(STDOUT);
                        gzip \$tar_data => \*STDOUT or die "gzip failed: $GzipError\n";
                    } elsif ($main::compressed eq 'bz2') {
                        my $tar_data = $tar->write();
                        binmode(STDOUT);
                        bzip2 \$tar_data => \*STDOUT or die "bzip2 failed: $Bzip2Error\n";
                    } else {
                        binmode(STDOUT);
                        $tar->write(\*STDOUT);
                    }
                }
            }
        };
        
        warn "Connection broke. Aborting: $@\n" if $@;
        
        exit 0;
    }
}

package main;

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

sub serve_files {
    my ($filename, $maxdown, $ip_addr, $port) = @_;
    
    $maxdownloads = $maxdown;
    
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
    
    my $server = WoofServer->new($port);
    $server->{ip_addr} = $ip_addr;
    
    # Try to bind to the specified IP address and port
    eval { $server->run(); };
    
    if ($@) {
        die "cannot bind to IP address '$ip_addr' port $port: $@\n";
    }
    
    # Get real IP address if not specified
    $ip_addr = find_ip() if ! $ip_addr;
    
    if ($ip_addr) {
        my $location;
        
        if ($filename) {
            $location = "http://$ip_addr:" . $server->port . "/" . 
                uri_escape(basename($filename . $archive_ext));
        } else {
            $location = "http://$ip_addr:" . $server->port . "/";
        }
        
        print "Now serving on $location\n";
    }
    
    # Process requests until max downloads reached
    while ($cpid != 0 && $maxdownloads > 0) {
        sleep 1;
        
        # Check for child process termination
        while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
            # Child process terminated
        }
    }
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

sub woof_client {
    my ($url) = @_;
    
    # Check if URL is valid
    if ($url !~ m{^(http|https)://}) {
        return undef;
    }
    
    my $ua = LWP::UserAgent->new;
    my $response = $ua->get($url, ':content_cb' => sub { });
    
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
    
    $fname = "woof-out.bin" if ! $fname;
    
    $fname = uri_unescape($fname);
    $fname = basename($fname);
    
    # Ask user for the target filename
    my $term = Term::ReadLine->new('woof');
    $term->ornaments(0);
    $term->add_history($fname);
    my $input = $term->readline("Enter target filename: ", $fname);
    $fname = $input || $fname;
    
    my $override = 0;
    my $destfile;
    my $destfilename = $fname =~ m{^/} ? $fname : "./$fname";
    
    # Try to open file
    if (!sysopen($destfile, $destfilename, O_WRONLY | O_CREAT | O_EXCL, 0644)) {
        if ($! == EEXIST) {
            $input = $term->readline("File exists. Overwrite (y/n)? ");
            $override = ($input =~ /^y(es)?$/i);
            
            # If not overriding, don't proceed with the current filename
            if (!$override) {
                undef $destfile;
            }
        } else {
            die "Failed to open $destfilename: $!\n";
        }
    }
    
    # Find an alternative filename if necessary
    if (!defined $destfile) {
        if ($override) {
            sysopen($destfile, $destfilename, O_WRONLY | O_CREAT, 0644) or
                die "Failed to open $destfilename: $!\n";
        } else {
            for my $suffix (".1", ".2", ".3", ".4", ".5", ".6", ".7", ".8", ".9") {
                $destfilename = ($fname =~ m{^/} ? $fname : "./$fname") . $suffix;
                if (sysopen($destfile, $destfilename, O_WRONLY | O_CREAT | O_EXCL, 0644)) {
                    last;
                } elsif ($! != EEXIST) {
                    die "Failed to open $destfilename: $!\n";
                }
            }
            
            # If still not found, use tempfile
            if (!defined $destfile) {
                ($destfile, $destfilename) = tempfile("$fname.XXXXXX", DIR => ".");
            }
            
            print "alternate filename is: $destfilename\n";
        }
    }
    
    print "downloading file: $fname -> $destfilename\n";
    
    # Download the file
    my $response2 = $ua->get($url, ':content_cb' => sub {
        my ($data, $response, $protocol) = @_;
        # Make sure filehandle is still open
        if (defined $destfile && fileno($destfile)) {
            print $destfile $data;
        }
    });
    
    close($destfile) if defined $destfile && fileno($destfile);
    
    if (!$response2->is_success) {
        unlink($destfilename);
        die "Download failed: " . $response2->status_line . "\n";
    }
    
    return 1;
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
    
    # Wait for child processes to terminate
    if ($cpid != 0) {
        while (waitpid(-1, 0) > 0) {
            # Just wait for all children
        }
    }
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
