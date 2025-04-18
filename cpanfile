requires 'perl', '5.010';

# Core dependencies
requires 'File::Basename';
requires 'File::Temp';
requires 'File::Find';
requires 'File::Copy';
requires 'File::Spec';
requires 'Fcntl';
requires 'Errno';
requires 'Cwd';
requires 'POSIX';
requires 'Getopt::Long';
requires 'Term::ReadLine';
requires 'Socket';

# External dependencies
requires 'Config::IniFiles';
requires 'HTTP::Message';
requires 'IO::Socket::INET';
requires 'URI';
requires 'URI::Escape'; 
requires 'LWP::UserAgent';

# Compression modules
requires 'Archive::Tar';
requires 'Archive::Zip';
requires 'IO::Compress::Gzip';
requires 'IO::Compress::Bzip2';

# Optional modules
recommends 'File::MimeInfo::Magic';

# For development only
on 'develop' => sub {
    requires 'Test::More';
    requires 'Test::Exception';
    requires 'Test::Pod';
};
