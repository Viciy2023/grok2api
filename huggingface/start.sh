#!/bin/sh
set -eu

umask 077

DATA_DIR="${DATA_DIR:-/data}"
CONFIG_SOURCE="${GROK2API_CONFIG_SOURCE:-$DATA_DIR/config.yaml}"
EXAMPLE_CONFIG="/app/config.example.yaml"
APP_CONFIG="/app/config.yaml"
LISTEN_ADDR="0.0.0.0:${SERVER_PORT:-7860}"

mkdir -p "$DATA_DIR" "$DATA_DIR/media" /run/grok2api

# Load optional env file first so secrets are available for seed/override.
if [ -f "$DATA_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$DATA_DIR/.env"
  set +a
fi

apply_secret_overrides() {
  target="$1"
  [ -f "$target" ] || return 0

  if [ -n "${GROK2API_JWT_SECRET:-}" ]; then
    sed -i "s|jwtSecret: \".*\"|jwtSecret: \"${GROK2API_JWT_SECRET}\"|" "$target"
  fi
  if [ -n "${GROK2API_CREDENTIAL_ENCRYPTION_KEY:-}" ]; then
    sed -i "s|credentialEncryptionKey: \".*\"|credentialEncryptionKey: \"${GROK2API_CREDENTIAL_ENCRYPTION_KEY}\"|" "$target"
  fi
  if [ -n "${GROK2API_ADMIN_USERNAME:-}" ]; then
    sed -i "s|username: \".*\"|username: \"${GROK2API_ADMIN_USERNAME}\"|" "$target"
  fi
  if [ -n "${GROK2API_ADMIN_PASSWORD:-}" ]; then
    sed -i "s|password: \".*\"|password: \"${GROK2API_ADMIN_PASSWORD}\"|" "$target"
  fi
  if [ -n "${GROK2API_SECURE_COOKIES:-}" ]; then
    sed -i "s|secureCookies: .*|secureCookies: ${GROK2API_SECURE_COOKIES}|" "$target"
  fi
}

seed_config() {
  cp "$EXAMPLE_CONFIG" "$CONFIG_SOURCE"

  sed -i \
    -e 's|listen: "127.0.0.1:8000"|listen: "0.0.0.0:7860"|' \
    -e 's|staticPath: "./frontend/dist"|staticPath: "/app/frontend/dist"|' \
    -e 's|path: "./data/backend.db"|path: "'"$DATA_DIR"'/backend.db"|' \
    -e 's|path: "./data/media"|path: "'"$DATA_DIR"'/media"|' \
    "$CONFIG_SOURCE"

  apply_secret_overrides "$CONFIG_SOURCE"
  echo "Initialized HF runtime config at $CONFIG_SOURCE"
}

if [ ! -f "$CONFIG_SOURCE" ]; then
  if [ ! -f "$EXAMPLE_CONFIG" ]; then
    echo "missing example config: $EXAMPLE_CONFIG" >&2
    exit 1
  fi
  seed_config
else
  # Re-apply Space secrets every boot so placeholder configs can be fixed without rebuild.
  apply_secret_overrides "$CONFIG_SOURCE"
fi

# Fail fast with clear guidance if placeholders remain.
if grep -q 'replace-with-at-least-32-characters' "$CONFIG_SOURCE" \
  || grep -q 'replace-with-base64-key' "$CONFIG_SOURCE" \
  || grep -q 'replace-with-a-strong-password' "$CONFIG_SOURCE"; then
  cat >&2 <<'EOF'
ERROR: /data/config.yaml still contains example secrets.

Fix one of:
1) Edit HF Storage file: /data/config.yaml
   - secrets.jwtSecret
   - secrets.credentialEncryptionKey
   - bootstrapAdmin.password
2) Or set Space Secrets, then restart:
   - GROK2API_JWT_SECRET          (openssl rand -hex 32)
   - GROK2API_CREDENTIAL_ENCRYPTION_KEY  (openssl rand -base64 32)
   - GROK2API_ADMIN_PASSWORD
EOF
  exit 1
fi

cp "$CONFIG_SOURCE" "$APP_CONFIG"
chown grok2api:grok2api "$APP_CONFIG" 2>/dev/null || true
chmod 0600 "$APP_CONFIG" || true
chown -R grok2api:grok2api "$DATA_DIR" 2>/dev/null || true

if ! printf '%s' "$*" | grep -q -- '--listen'; then
  set -- "$@" --listen "$LISTEN_ADDR"
fi

if command -v su-exec >/dev/null 2>&1 && id grok2api >/dev/null 2>&1; then
  exec su-exec grok2api:grok2api "$@"
fi

exec "$@"
