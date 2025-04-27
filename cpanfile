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

# For testing
on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'Test::Exception';
    requires 'Test::Pod';
    requires 'HTTP::Server::Simple';
    requires 'HTTP::Server::Simple::CGI';
    requires 'Digest::MD5';
    requires 'FindBin';
    requires 'IO::Capture';
};

# For development only
on 'develop' => sub {
    requires 'Test::More';
    requires 'Test::Exception';
    requires 'Test::Pod';
    requires 'Test::Pod::Coverage';
    requires 'Test::Perl::Critic';
    requires 'Pod::Coverage::TrustPod';
    requires 'Perl::Critic';
    requires 'Devel::Cover';
    requires 'Module::Install';
};

# For distribution building
on 'configure' => sub {
    requires 'ExtUtils::MakeMaker';
};

# For creating standalone executable
on 'build' => sub {
    requires 'App::FatPacker';
    requires 'Carton';
};

