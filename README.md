# woof-perl

## Web Offer One File 

This is woof-perl, the Perl edition of [Simon Buding's woof](https://github.com/simon-budig/woof). 
It is a complete rewriting of the tool in Perl 5, with strict dependencies on standard packages
and a few well-maintained main others. 
It mimics the behavior of the original tool, but for a few details.
As in the case of the original tool it is thought to work under *nix systems, but could work 
also under Windows.

This version should be stable enough for use and forever, due to longevity and stability
of Perl 5 and its APIs.

```
    Usage: woof.pl [-i <ip_addr>] [-p <port>] [-c <count>] <file>
           woof.pl [-i <ip_addr>] [-p <port>] [-c <count>] [-z|-j|-Z|-u] <dir>
           woof.pl [-i <ip_addr>] [-p <port>] [-c <count>] -s
           woof.pl [-i <ip_addr>] [-p <port>] [-c <count>] -U
  
           woof.pl <url>

    Serves a single file <count> times via http on port <port> on IP
    address <ip_addr>.
    When a directory is specified, an tar archive gets served. By default
    it is gzip compressed. You can specify -z for gzip compression,
    -j for bzip2 compression, -Z for ZIP compression or -u for no compression.
    You can configure your default compression method in the configuration
    file described below.

    When -s is specified instead of a filename, woof.pl distributes itself.

    When -U is specified, woof provides an upload form, allowing file uploads.
  
    defaults: count = 1, port = 8080
  
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

    Can only serve single files/directories.

```

## System packages dependencies

On a Debian/Ubuntu GNU/Linux system the minimal dependecies currently 
required are the following packages, but for core Perl packages:

```
    libany-uri-escape-perl
    libarchive-zip-perl
    libconfig-inifiles-perl
    libhttp-message-perl
    liburi-perl
    libwww-perl
```

Several methods can be used to install and distribute woof-perl using standard 
Perl distribution tools as alternative.

## Prerequisites

All methods require Perl 5.10 or higher, plus some basic tools:

```bash
# Debian/Ubuntu
sudo apt-get install build-essential cpanminus

# RHEL/CentOS/Fedora
sudo dnf install perl-core cpanminus gcc make

# macOS (with Homebrew)
brew install perl cpanminus
```

## Method 1: Carton Installation (Recommended)

This method uses Carton to manage dependencies locally:

1. Install Carton if you don't have it:
   ```bash
   cpanm Carton
   ```

2. Run the installation script:
   ```bash
   ./install.sh
   ```
   
   This will:
   - Install all dependencies locally in a `local` directory
   - Create wrapper scripts to properly set the environment
   - Make the command available as `woof`

3. Add the installation bin directory to your PATH:
   ```bash
   echo 'export PATH="$HOME/.local/woof-perl/bin:$PATH"' >> ~/.bashrc
   source ~/.bashrc
   ```

4. Test your installation:
   ```bash
   woof --help
   ```

## Method 2: Create a Standalone Executable with App::FatPacker

This creates a single-file executable that includes all dependencies:

1. Install required tools:
   ```bash
   cpanm App::FatPacker Carton
   ```

2. Run the fatpacking script:
   ```bash
   ./fatpack.pl
   ```

3. The standalone executable will be created as `woof-packed.pl`

4. Distribute this single file to users who can run it directly:
   ```bash
   chmod +x woof-packed.pl
   ./woof-packed.pl --help
   ```

## Method 3: Private CPAN Repository with Pinto

For enterprise environments where you need a private CPAN mirror:

1. Install Pinto:
   ```bash
   cpanm Pinto
   ```

2. Set up your Pinto repository:
   ```bash
   ./pinto-setup.sh
   ```

3. Install woof-perl from your repository:
   ```bash
   cpanm --mirror file://$HOME/.local/woof-perl-repo/stacks/woof-perl --mirror-only woof-perl
   ```

## Method 4: Docker Container

For completely isolated deployment:

1. Build the Docker image:
   ```bash
   docker build -t woof-perl .
   ```

2. Run woof-perl in a container:
   ```bash
   # To serve a file:
   docker run -p 8080:8080 -u $(id -u):$(id -g) -v $(pwd):/data woof-perl myfile.txt
   
   # To enable uploads:
   docker run -p 8080:8080 -u $(id -u):$(id -g) -v $(pwd):/data woof-perl -U
   ```

## Troubleshooting

### Missing Dependencies

If you encounter missing dependencies:

```bash
# For Carton installation
cd ~/.local/woof-perl
carton install

# For standalone installations
cpanm --installdeps .
```

### Permission Issues

```bash
# Fix permissions on the executable
chmod +x ~/.local/woof-perl/bin/woof.pl
```

### Path Issues

```bash
# Run directly with the full path
~/.local/woof-perl/bin/woof

# Or check your PATH configuration
echo $PATH
```


