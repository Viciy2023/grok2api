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
    LOG_DIR=/data/logs

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

COPY --from=ghcr.io/astral-sh/uv:0.6.17 /uv /uvx /bin/

RUN git clone --depth 1 https://github.com/chenyme/grok2api.git /tmp/src \
    && cp /tmp/src/pyproject.toml /app/pyproject.toml \
    && cp /tmp/src/uv.lock /app/uv.lock \
    && uv sync --frozen --no-dev --no-install-project \
    && cp -r /tmp/src/app /app/app \
    && cp /tmp/src/config.defaults.toml /app/config.defaults.toml \
    && rm -rf /tmp/src

COPY start.sh /app/start.sh

RUN chmod +x /app/start.sh \
    && mkdir -p /data /data/logs

ENTRYPOINT ["/app/start.sh"]
CMD ["granian", "--interface", "asgi", "--host", "0.0.0.0", "--port", "7860", "--workers", "1", "app.main:app"]
