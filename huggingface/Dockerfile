# Hugging Face Space adapter for official chenyme/grok2api (source mode).
#
# This is the FALLBACK build strategy. The default is ./Dockerfile.image, which
# re-bases the image upstream already publishes to GHCR and is far faster and
# more robust. Keep this file for the case where upstream stops publishing
# images, or when a local patch of upstream source is required.
#
# The auto-update workflow pins GROK2API_REF to an immutable upstream commit
# SHA, so every deployment is reproducible.

ARG NODE_VERSION=22
ARG GO_VERSION=1.26
ARG ALPINE_VERSION=3.23
ARG GROK2API_REPO=https://github.com/chenyme/grok2api.git
ARG GROK2API_REF=main

# Fetch upstream at an exact commit. `git clone --branch` accepts only branches
# and tags, so fetch explicitly: this accepts a branch, a tag OR a full commit
# SHA, which is what makes SHA-pinned deploys possible.
FROM alpine:${ALPINE_VERSION} AS src
ARG GROK2API_REPO
ARG GROK2API_REF
RUN apk add --no-cache git ca-certificates \
    && git init -q /src \
    && cd /src \
    && git remote add origin "${GROK2API_REPO}" \
    && git fetch -q --depth 1 origin "${GROK2API_REF}" \
    && git checkout -q FETCH_HEAD \
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
# Copy the whole frontend tree instead of an explicit file list: upstream keeps
# adding root-level build inputs (components.json, tsconfig.test.json, ...) and
# an enumerated list silently breaks the build when it does.
COPY --from=src /src/frontend/ ./
RUN pnpm build

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS backend-builder
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src/backend
RUN apk add --no-cache ca-certificates git
COPY --from=src /src/backend/go.mod /src/backend/go.sum ./
RUN go mod download
# Same reasoning as the frontend: copy the whole module.
COPY --from=src /src/backend/ ./
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} \
    go build -buildvcs=false -trimpath -ldflags="-s -w" -o /out/grok2api ./cmd/grok2api

FROM alpine:${ALPINE_VERSION}

ARG GROK2API_REF

ENV TZ=Asia/Shanghai \
    SERVER_PORT=7860 \
    DATA_DIR=/data \
    GROK2API_CONFIG_SOURCE=/data/config.yaml

RUN apk add --no-cache ca-certificates su-exec tzdata wget \
    && addgroup -S -g 10001 grok2api \
    && adduser -S -D -H -u 10001 -G grok2api grok2api \
    && mkdir -p /app/data /app/frontend/dist /data /data/media /run/grok2api \
    && chown -R grok2api:grok2api /app/data /data /run/grok2api

WORKDIR /app

COPY --from=backend-builder --chmod=0755 /out/grok2api /app/grok2api
COPY --from=frontend-builder /src/frontend/dist /app/frontend/dist
COPY --from=src /src/VERSION /app/VERSION
COPY --from=src /src/config.example.yaml /app/config.example.yaml
COPY --chmod=0755 start.sh /usr/local/bin/hf-start.sh

LABEL org.opencontainers.image.source="https://github.com/chenyme/grok2api" \
      io.viciy.adapter="huggingface/Dockerfile" \
      io.viciy.upstream.ref="${GROK2API_REF}"

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD wget -qO- "http://127.0.0.1:${SERVER_PORT}/healthz" >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/hf-start.sh"]
CMD ["/app/grok2api", "--config", "/app/config.yaml", "--listen", "0.0.0.0:7860"]
