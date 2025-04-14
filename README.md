# woof-perl

## Web Offer One File 

This is woof-perl, the Perl edition of [Simon Buding's woof](https://github.com/simon-budig/woof). 
It is a complete rewriting of the tool in Perl 5, with strict dependencies on standard packages. It mimics the behavior of the original tool but for a few details. 
As in the case of the original tool it is thought to work under *nix.

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
