# Traefik - L7 Reverse Proxy
# Golden Stack - Non-Root, Baked Config
FROM traefik:v3.6.12

# Create non-root user and directories
USER root
RUN addgroup -g 1000 traefik-user && \
    adduser -D -u 1000 -G traefik-user traefik-user && \
    mkdir -p /etc/traefik/dynamic /acme && \
    chown -R traefik-user:traefik-user /etc/traefik /acme

# Copy dynamic configuration (Middlewares)
COPY config/dynamic.yml /etc/traefik/dynamic/default.yml
RUN chown traefik-user:traefik-user /etc/traefik/dynamic/default.yml

# Set default Static Configuration via Environment Variables
# This allows downstream users to override them easily.

# Global
ENV TRAEFIK_GLOBAL_CHECKNEWVERSION=false \
    TRAEFIK_GLOBAL_SENDANONYMOUSUSAGE=false

# API
ENV TRAEFIK_API_DASHBOARD=false \
    TRAEFIK_API_INSECURE=false

# Ping & Metrics
ENV TRAEFIK_PING_ENTRYPOINT=ping \
    TRAEFIK_METRICS_PROMETHEUS_ENTRYPOINT=metrics \
    TRAEFIK_METRICS_PROMETHEUS_ADDENTRYPOINTSLABELS=true \
    TRAEFIK_METRICS_PROMETHEUS_ADDROUTERSLABELS=true \
    TRAEFIK_METRICS_PROMETHEUS_ADDSERVICESLABELS=true

# Logs
ENV TRAEFIK_LOG_LEVEL=INFO \
    TRAEFIK_LOG_FORMAT=json \
    TRAEFIK_ACCESSLOG_FORMAT=json \
    TRAEFIK_ACCESSLOG_BUFFERINGSIZE=100

# EntryPoints
ENV TRAEFIK_ENTRYPOINTS_WEB_ADDRESS=:80 \
    TRAEFIK_ENTRYPOINTS_WEB_HTTP_REDIRECTIONS_ENTRYPOINT_TO=websecure \
    TRAEFIK_ENTRYPOINTS_WEB_HTTP_REDIRECTIONS_ENTRYPOINT_SCHEME=https \
    TRAEFIK_ENTRYPOINTS_WEB_HTTP_REDIRECTIONS_ENTRYPOINT_PERMANENT=true \
    TRAEFIK_ENTRYPOINTS_WEBSECURE_ADDRESS=:443 \
    TRAEFIK_ENTRYPOINTS_WEBSECURE_HTTP_TLS_CERTRESOLVER=letsencrypt \
    TRAEFIK_ENTRYPOINTS_WEBSECURE_HTTP_TLS_OPTIONS=default@file \
    TRAEFIK_ENTRYPOINTS_WEBSECURE_HTTP_MIDDLEWARES=secure-headers@file,rate-limit@file \
    TRAEFIK_ENTRYPOINTS_WEBSECURE_TRANSPORT_RESPONDINGTIMEOUTS_READTIMEOUT=30s \
    TRAEFIK_ENTRYPOINTS_WEBSECURE_TRANSPORT_RESPONDINGTIMEOUTS_WRITETIMEOUT=30s \
    TRAEFIK_ENTRYPOINTS_WEBSECURE_TRANSPORT_RESPONDINGTIMEOUTS_IDLETIMEOUT=180s \
    TRAEFIK_ENTRYPOINTS_PING_ADDRESS=:8082 \
    TRAEFIK_ENTRYPOINTS_METRICS_ADDRESS=:8083

# Providers
ENV TRAEFIK_PROVIDERS_DOCKER_ENDPOINT=unix:///var/run/docker.sock \
    TRAEFIK_PROVIDERS_DOCKER_EXPOSEDBYDEFAULT=false \
    TRAEFIK_PROVIDERS_DOCKER_NETWORK=edge-router_default \
    TRAEFIK_PROVIDERS_DOCKER_WATCH=true \
    TRAEFIK_PROVIDERS_FILE_DIRECTORY=/etc/traefik/dynamic \
    TRAEFIK_PROVIDERS_FILE_WATCH=true

# Certificates Resolvers (Default: HTTP Challenge)
ENV TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL=admin@example.com \
    TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_STORAGE=/acme/acme.json \
    TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_HTTPCHALLENGE_ENTRYPOINT=web

# Switch to non-root
USER 1000

# Expose ports: HTTP, HTTPS, Ping, Metrics
EXPOSE 80 443 8082 8083

# Healthcheck via ping endpoint
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8082/ping || exit 1

ENTRYPOINT ["traefik"]
