# HAProxy - L4 Load Balancer
# Golden Stack - Non-Root, Baked Config
FROM haproxy:3.3.6-alpine

# Create non-root user
USER root
RUN addgroup -g 1000 haproxy-user && \
    adduser -D -u 1000 -G haproxy-user haproxy-user && \
    mkdir -p /var/lib/haproxy && \
    chown -R haproxy-user:haproxy-user /var/lib/haproxy

# Bake configuration into image (NEVER bind-mount)
COPY config/haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
RUN chown haproxy-user:haproxy-user /usr/local/etc/haproxy/haproxy.cfg

# Switch to non-root
USER 1000

# Expose ports
EXPOSE 80 443 8405

# Healthcheck
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost:8405/stats > /dev/null || exit 1

CMD ["haproxy", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
