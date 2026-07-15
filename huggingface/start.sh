#!/bin/sh
set -eu

umask 077

DATA_DIR="${DATA_DIR:-/data}"
CONFIG_SOURCE="${GROK2API_CONFIG_SOURCE:-$DATA_DIR/config.yaml}"
EXAMPLE_CONFIG="/app/config.example.yaml"
APP_CONFIG="/app/config.yaml"
LISTEN_ADDR="0.0.0.0:${SERVER_PORT:-7860}"

mkdir -p "$DATA_DIR" "$DATA_DIR/media" /run/grok2api

seed_config() {
  cp "$EXAMPLE_CONFIG" "$CONFIG_SOURCE"

  # Absolute paths under HF Storage mount.
  sed -i \
    -e 's|listen: "127.0.0.1:8000"|listen: "0.0.0.0:7860"|' \
    -e 's|staticPath: "./frontend/dist"|staticPath: "/app/frontend/dist"|' \
    -e 's|path: "./data/backend.db"|path: "'"$DATA_DIR"'/backend.db"|' \
    -e 's|path: "./data/media"|path: "'"$DATA_DIR"'/media"|' \
    "$CONFIG_SOURCE"

  # Optional bootstrap overrides from Space secrets / /data/.env style env.
  if [ -n "${GROK2API_JWT_SECRET:-}" ]; then
    sed -i "s|jwtSecret: \".*\"|jwtSecret: \"${GROK2API_JWT_SECRET}\"|" "$CONFIG_SOURCE"
  fi
  if [ -n "${GROK2API_CREDENTIAL_ENCRYPTION_KEY:-}" ]; then
    sed -i "s|credentialEncryptionKey: \".*\"|credentialEncryptionKey: \"${GROK2API_CREDENTIAL_ENCRYPTION_KEY}\"|" "$CONFIG_SOURCE"
  fi
  if [ -n "${GROK2API_ADMIN_USERNAME:-}" ]; then
    sed -i "s|username: \".*\"|username: \"${GROK2API_ADMIN_USERNAME}\"|" "$CONFIG_SOURCE"
  fi
  if [ -n "${GROK2API_ADMIN_PASSWORD:-}" ]; then
    sed -i "s|password: \".*\"|password: \"${GROK2API_ADMIN_PASSWORD}\"|" "$CONFIG_SOURCE"
  fi
  if [ -n "${GROK2API_SECURE_COOKIES:-}" ]; then
    sed -i "s|secureCookies: .*|secureCookies: ${GROK2API_SECURE_COOKIES}|" "$CONFIG_SOURCE"
  fi

  echo "Initialized HF runtime config at $CONFIG_SOURCE"
  echo "IMPORTANT: set secrets.jwtSecret / secrets.credentialEncryptionKey / bootstrapAdmin.password before production use."
}

if [ ! -f "$CONFIG_SOURCE" ]; then
  if [ ! -f "$EXAMPLE_CONFIG" ]; then
    echo "missing example config: $EXAMPLE_CONFIG" >&2
    exit 1
  fi
  seed_config
fi

# Load optional env file from storage (KEY=VALUE lines only).
if [ -f "$DATA_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$DATA_DIR/.env"
  set +a
fi

cp "$CONFIG_SOURCE" "$APP_CONFIG"
chown grok2api:grok2api "$APP_CONFIG" 2>/dev/null || true
chmod 0600 "$APP_CONFIG" || true
chown -R grok2api:grok2api "$DATA_DIR" 2>/dev/null || true

# Ensure listen stays on Spaces port even if user config still has 8000.
if ! printf '%s' "$*" | grep -q -- '--listen'; then
  set -- "$@" --listen "$LISTEN_ADDR"
fi

if command -v su-exec >/dev/null 2>&1 && id grok2api >/dev/null 2>&1; then
  exec su-exec grok2api:grok2api "$@"
fi

exec "$@"
