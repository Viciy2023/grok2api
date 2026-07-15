FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai \
    VIRTUAL_ENV=/app/.venv \
    PATH=/app/.venv/bin:/root/.local/bin:$PATH \
    SERVER_HOST=0.0.0.0 \
    SERVER_PORT=7860 \
    SERVER_WORKERS=1 \
    DATA_DIR=/data \
    LOG_DIR=/data/logs \
    ACCOUNT_STORAGE=local

WORKDIR /app

EXPOSE 7860

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        curl \
        ca-certificates \
        git \
        libffi-dev \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Pin uv minor line for reproducible builds (aligned with upstream).
COPY --from=ghcr.io/astral-sh/uv:0.6 /uv /uvx /bin/

# Always build from the official upstream source, not the local fork tree.
ARG GROK2API_REPO=https://github.com/chenyme/grok2api.git
ARG GROK2API_REF=main

RUN git clone --depth 1 --branch "${GROK2API_REF}" "${GROK2API_REPO}" /tmp/src \
    && cp /tmp/src/pyproject.toml /app/pyproject.toml \
    && cp /tmp/src/uv.lock /app/uv.lock \
    && uv sync --frozen --no-dev --no-install-project \
    && cp -r /tmp/src/app /app/app \
    && cp -r /tmp/src/scripts /app/scripts \
    && cp /tmp/src/config.defaults.toml /app/config.defaults.toml \
    && chmod +x /app/scripts/*.sh \
    && rm -rf /tmp/src /root/.cache /tmp/uv-cache

COPY start.sh /app/start.sh

RUN chmod +x /app/start.sh \
    && mkdir -p /data /data/logs

ENTRYPOINT ["/app/start.sh"]
CMD ["sh", "-c", "exec granian --interface asgi --host ${SERVER_HOST} --port ${SERVER_PORT} --workers ${SERVER_WORKERS} app.main:app"]
