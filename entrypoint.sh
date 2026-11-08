#!/bin/bash
set -e

# ============================================================
# VIRGOZKI ENTRYPOINT SCRIPT (ENVOY + OPENRESTY)
# ============================================================

PORT="${PORT:-8080}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"

echo "[ENTRYPOINT] Initializing VIRGOZKI Envoy + OpenResty service..."
echo "[ENTRYPOINT] Target PORT: ${PORT}"
echo "[ENTRYPOINT] Target BIND_ADDR: ${BIND_ADDR}"

# Ensure runtime directories exist
mkdir -p /var/log/xray \
         /var/log/nginx \
         /tmp/virgozki \
         /tmp/virgozki-logs

# Safely update Envoy port and address using Python YAML/Text parsing
if [ -f /etc/envoy/envoy.yaml ]; then
    python3 -c "
import re
with open('/etc/envoy/envoy.yaml', 'r') as f:
    content = f.read()
# Palitan ang port at bind address sa main_listener
content = re.sub(r'(address:\s+address:\s+)[0-9\.]+', r'\1' + '${BIND_ADDR}', content)
content = re.sub(r'(port_value:\s+)[0-9]+', r'\1' + '${PORT}', content, count=1)
with open('/etc/envoy/envoy.yaml', 'w') as f:
    f.write(content)
"
    echo "[ENTRYPOINT] Successfully configured Envoy port to ${PORT} and address to ${BIND_ADDR}"
fi

# Validate core configurations at runtime
echo "[ENTRYPOINT] Validating configurations..."

/usr/local/bin/xray run -test -c /etc/xray/config.json >/dev/null 2>&1 || {
    echo "[ENTRYPOINT ERROR] Xray configuration test failed!"
    exit 1
}

/usr/local/bin/envoy --mode validate -c /etc/envoy/envoy.yaml >/dev/null 2>&1 || {
    echo "[ENTRYPOINT ERROR] Envoy configuration test failed!"
    exit 1
}

/usr/local/openresty/bin/openresty -t -c /etc/openresty/nginx.conf >/dev/null 2>&1 || {
    echo "[ENTRYPOINT ERROR] OpenResty configuration test failed!"
    exit 1
}

echo "[ENTRYPOINT] All service configurations validated successfully!"

# Hand off execution to Tini / Supervisord
exec "$@"
