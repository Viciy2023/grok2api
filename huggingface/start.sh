#!/usr/bin/env sh
set -eu

DATA_DIR="${DATA_DIR:-/data}"
LOG_DIR="${LOG_DIR:-/data/logs}"
ENV_FILE="$DATA_DIR/.env"
CONFIG_FILE="$DATA_DIR/config.toml"
DEFAULT_CONFIG="/app/config.defaults.toml"

mkdir -p "$DATA_DIR" "$LOG_DIR"

if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

if [ ! -f "$CONFIG_FILE" ]; then
  cp "$DEFAULT_CONFIG" "$CONFIG_FILE"
  echo "Initialized runtime config at $CONFIG_FILE"
fi

SPACE_HOST="${SPACE_HOST:-}"
SPACE_ID="${SPACE_ID:-}"

if [ -n "$SPACE_HOST" ]; then
  sed -i "s|^app_url = .*|app_url = \"https://$SPACE_HOST\"|" "$CONFIG_FILE"
elif [ -n "$SPACE_ID" ]; then
  sed -i "s|^app_url = .*|app_url = \"https://${SPACE_ID}.hf.space\"|" "$CONFIG_FILE"
fi

chmod 600 "$CONFIG_FILE" || true

exec "$@"
