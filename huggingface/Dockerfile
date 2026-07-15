# Hugging Face Space adapter for official chenyme/grok2api (Go + React rewrite).
# Build always clones upstream; this Space repo only ships the adapter layer.

ARG NODE_VERSION=22
ARG GO_VERSION=1.26
ARG ALPINE_VERSION=3.23
ARG GROK2API_REPO=https://github.com/chenyme/grok2api.git
ARG GROK2API_REF=main

FROM alpine:${ALPINE_VERSION} AS src
ARG GROK2API_REPO
ARG GROK2API_REF
RUN apk add --no-cache git ca-certificates \
    && git clone --depth 1 --branch "${GROK2API_REF}" "${GROK2API_REPO}" /src \
    && test -f /src/backend/go.mod \
    && test -f /src/frontend/package.json \
    && test -f /src/config.example.yaml \
    && test -f /src/docker/entrypoint.sh

FROM --platform=$BUILDPLATFORM node:${NODE_VERSION}-alpine AS frontend-builder
WORKDIR /src/frontend
RUN corepack enable
COPY --from=src /src/frontend/package.json /src/frontend/pnpm-lock.yaml ./
RUN pnpm config set store-dir /pnpm/store \
    && pnpm fetch --frozen-lockfile \
    && pnpm install --offline --frozen-lockfile
COPY --from=src /src/frontend/index.html /src/frontend/vite.config.ts /src/frontend/tsconfig.json /src/frontend/tsconfig.app.json /src/frontend/tsconfig.node.json ./
COPY --from=src /src/frontend/public ./public
COPY --from=src /src/frontend/src ./src
RUN pnpm build

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS backend-builder
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src/backend
RUN apk add --no-cache ca-certificates git
COPY --from=src /src/backend/go.mod /src/backend/go.sum ./
RUN go mod download
COPY --from=src /src/backend/cmd ./cmd
COPY --from=src /src/backend/internal ./internal
COPY --from=src /src/backend/docs/docs.go ./docs/docs.go
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} \
    go build -buildvcs=false -trimpath -ldflags="-s -w" -o /out/grok2api ./cmd/grok2api

FROM alpine:${ALPINE_VERSION}

ENV TZ=Asia/Shanghai \
    GROK2API_CONFIG_SOURCE=/data/config.yaml \
    SERVER_PORT=7860

RUN apk add --no-cache ca-certificates su-exec tzdata wget \
    && addgroup -S -g 10001 grok2api \
    && adduser -S -D -H -u 10001 -G grok2api grok2api \
    && mkdir -p /app/data /app/frontend/dist /data /data/media /run/grok2api \
    && chown -R grok2api:grok2api /app/data /data /run/grok2api

WORKDIR /app

COPY --from=backend-builder --chmod=0755 /out/grok2api /app/grok2api
COPY --from=frontend-builder /src/frontend/dist /app/frontend/dist
COPY --from=src /src/config.example.yaml /app/config.example.yaml
COPY --chmod=0755 start.sh /usr/local/bin/hf-start.sh

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD wget -qO- "http://127.0.0.1:${SERVER_PORT}/healthz" >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/hf-start.sh"]
CMD ["/app/grok2api", "--config", "/app/config.yaml", "--listen", "0.0.0.0:7860"]
