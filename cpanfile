requires 'perl', '5.010';

# Core dependencies
requires 'File::Basename';
requires 'File::Temp';
requires 'File::Find';
requires 'File::Copy';
requires 'Fcntl';
requires 'Errno';
requires 'Cwd';
requires 'POSIX';
requires 'Getopt::Long';
requires 'Term::ReadLine';

# External dependencies
requires 'Config::IniFiles';
requires 'HTTP::Server::Simple::CGI';
requires 'HTTP::Status';
requires 'IO::Socket::INET';
requires 'URI::Escape'; 
requires 'LWP::UserAgent';
requires 'Any::URI::Escape';

# Compression modules
requires 'Archive::Tar';
requires 'Archive::Zip';
requires 'IO::Compress::Gzip';
requires 'IO::Compress::Bzip2';

# For development only
on 'develop' => sub {
    requires 'Test::More';
    requires 'Test::Exception';
    requires 'Test::Pod';
};
