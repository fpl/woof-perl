FROM perl:5.40-slim

LABEL maintainer="Francesco P. Lovergine <fpl@cpan.org>"
LABEL description="woof-perl - A file sharing utility"

# Create a non-privileged user to run the application
RUN groupadd -r woof && useradd -r -g woof -m -d /home/woof woof

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Carton
RUN cpanm Carton

# Set up directory structure
WORKDIR /app

# Copy application files
COPY woof.pl ./
COPY cpanfile ./
COPY README.md ./

# Install dependencies with Carton
RUN carton install

# Create a wrapper script
RUN echo '#!/bin/bash\n\
# Always run from /data for file operations\n\
cd /data\n\
# Use system perl with the environment variable to find local libraries\n\
PERL5LIB=/app/local/lib/perl5 exec perl /app/woof.pl "$@"\n\
' > /usr/local/bin/woof && \
chmod +x /usr/local/bin/woof

# Set proper permissions
RUN chown -R woof:woof /app

# Add volume for data
VOLUME ["/data"]

# Expose the default port
EXPOSE 8080

# Switch to non-privileged user
USER woof

# Setup the entrypoint
ENTRYPOINT ["/usr/local/bin/woof"]

# Usage instructions
LABEL usage="# To run:\n\
  docker run -p 8080:8080 -v $(pwd):/data -u $(id -u):$(id -g) woof-perl [options] <file>\n\
\n\
# Examples:\n\
  # Serve a file\n\
  docker run -p 8080:8080 -v $(pwd):/data -u $(id -u):$(id -g) woof-perl myfile.txt\n\
\n\
  # Enable uploads\n\
  docker run -p 8080:8080 -v $(pwd):/data -u $(id -u):$(id -g) woof-perl -U\n"
