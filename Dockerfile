# ============================================================
# VIRGOZKI 2-PROXY (ENVOY + OPENRESTY) + gRPC | CLOUD RUN
# DEBIAN BOOKWORM
# ============================================================

# STAGE 1 — ENVOY
FROM envoyproxy/envoy:v1.39.1 AS envoy

# STAGE 2 — XRAY
FROM ghcr.io/xtls/xray-core:25.12.8 AS xray

# STAGE 3 — FINAL IMAGE
FROM openresty/openresty:1.31.1.1-bookworm-fat AS final

ENV DEBIAN_FRONTEND=noninteractive

# CLOUD RUN DEFAULT ENVIRONMENT
ENV PORT=8080
ENV BIND_ADDR=0.0.0.0

# XRAY ENVIRONMENT
ENV XRAY_LOCATION_ASSET=/usr/local/share/xray
ENV XRAY_LOCATION_CONFIG=/etc/xray

# INTERNAL PORTS
ENV ENVOY_PORT=8080
ENV OPENRESTY_PORT=8084

WORKDIR /opt/virgozki

# INSTALL REQUIRED PACKAGES
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      supervisor \
      ca-certificates \
      curl \
      wget \
      unzip \
      tini \
      procps \
      iproute2 \
      net-tools \
      openssl \
      python3 \
      python3-pip \
      netcat-openbsd && \
    mkdir -p \
      /etc/xray \
      /etc/envoy \
      /tmp/virgozki \
      /tmp/virgozki-logs \
      /usr/share/nginx/html \
      /usr/local/share/xray \
      /var/log/xray \
      /var/log/nginx && \
    rm -rf /var/lib/apt/lists/*

# COPY BINARIES & ASSETS
COPY --from=envoy /usr/local/bin/envoy /usr/local/bin/envoy
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY --from=xray /usr/local/share/xray/ /usr/local/share/xray/

# COPY CONFIGURATION & SCRIPT FILES
COPY supervisord.conf /etc/supervisord.conf
COPY config.json /etc/xray/config.json
COPY nginx.conf /etc/openresty/nginx.conf
COPY envoy.yaml /etc/envoy/envoy.yaml
COPY index.html /usr/share/nginx/html/index.html
COPY anti_ddos.py /usr/local/bin/anti_ddos.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# BASIC FILE SETUP & PERMISSIONS
RUN printf 'ok\n' > /usr/share/nginx/html/health && \
    chmod +x /usr/local/bin/anti_ddos.py /usr/local/bin/entrypoint.sh && \
    chmod 644 /etc/xray/config.json \
              /etc/openresty/nginx.conf \
              /etc/envoy/envoy.yaml \
              /usr/share/nginx/html/index.html

# BUILD-TIME CONFIGURATION VALIDATION
RUN /usr/local/bin/xray run -test -c /etc/xray/config.json && \
    /usr/local/bin/envoy --mode validate -c /etc/envoy/envoy.yaml && \
    /usr/local/openresty/bin/openresty -t -c /etc/openresty/nginx.conf

EXPOSE 8080

STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisord.conf"]
