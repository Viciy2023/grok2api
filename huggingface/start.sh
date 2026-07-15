#!/usr/bin/env sh
set -eu

DATA_DIR="${DATA_DIR:-/data}"
LOG_DIR="${LOG_DIR:-/data/logs}"
ENV_FILE="$DATA_DIR/.env"
DEFAULT_CONFIG="/app/config.defaults.toml"

mkdir -p "$DATA_DIR" "$LOG_DIR"

# Runtime env lives on the mounted HF Storage bucket.
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

# Re-resolve after sourcing /data/.env (it may override paths).
DATA_DIR="${DATA_DIR:-/data}"
LOG_DIR="${LOG_DIR:-/data/logs}"
CONFIG_FILE="${CONFIG_LOCAL_PATH:-$DATA_DIR/config.toml}"
mkdir -p "$DATA_DIR" "$LOG_DIR"

if [ ! -f "$CONFIG_FILE" ] && [ -f "$DEFAULT_CONFIG" ]; then
  cp "$DEFAULT_CONFIG" "$CONFIG_FILE"
  echo "Initialized runtime config at $CONFIG_FILE"
fi

# Prefer explicit GROK_APP_APP_URL; otherwise derive from HF Space metadata.
if [ -z "${GROK_APP_APP_URL:-}" ] && [ -f "$CONFIG_FILE" ]; then
  SPACE_HOST="${SPACE_HOST:-}"
  SPACE_ID="${SPACE_ID:-}"

  if [ -n "$SPACE_HOST" ]; then
    sed -i "s|^app_url = .*|app_url = \"https://${SPACE_HOST}\"|" "$CONFIG_FILE"
  elif [ -n "$SPACE_ID" ]; then
    # DanielleNguyen/Grok2Api -> daniellenguyen-grok2api.hf.space
    space_slug=$(printf '%s' "$SPACE_ID" | tr '[:upper:]' '[:lower:]' | tr '/' '-')
    sed -i "s|^app_url = .*|app_url = \"https://${space_slug}.hf.space\"|" "$CONFIG_FILE"
  fi
fi

if [ -f "$CONFIG_FILE" ]; then
  chmod 600 "$CONFIG_FILE" || true
fi

exec "$@"
