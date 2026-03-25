# Use a specific version for stability
FROM valkey/valkey:9.1-alpine

# Use root to setup configuration files and permissions
USER root

# Create configuration directory
RUN mkdir -p /etc/valkey

# Copy configuration files
COPY config/valkey.conf /etc/valkey/valkey.conf
COPY config/sentinel.conf /etc/valkey/sentinel.conf

# Copy entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Set working directory to /data (default volume)
WORKDIR /data

# Expose ports (6379 for Valkey, 26379 for Sentinel)
EXPOSE 6379 26379

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["valkey-server"]
