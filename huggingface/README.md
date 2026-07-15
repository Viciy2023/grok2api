---
title: Grok2Api
emoji: 🚀
colorFrom: indigo
colorTo: blue
sdk: docker
app_port: 7860
pinned: false
---

# Grok2Api on Hugging Face Spaces

Runs the official [chenyme/grok2api](https://github.com/chenyme/grok2api) **Go + React** gateway.

## Build model

- This Space repository only contains the HF adapter (`Dockerfile`, `start.sh`, this README, `.env.example`)
- Docker build **clones upstream** `https://github.com/chenyme/grok2api` (`main`) and builds frontend + backend from that source
- Local Python-era fork code is **not** used

## Persistent storage

Mount HF Storage (e.g. `DanielleNguyen/Grok2Api-storage`) to **`/data`**.

| Path | Purpose |
| --- | --- |
| `/data/config.yaml` | Runtime config (seeded from upstream `config.example.yaml` on first boot) |
| `/data/backend.db` | SQLite database |
| `/data/media` | Local media files |
| `/data/.env` | Optional env file loaded at start |

## First boot secrets

Edit `/data/config.yaml` (or set env vars **before** first seed):

| Field / env | Notes |
| --- | --- |
| `secrets.jwtSecret` / `GROK2API_JWT_SECRET` | `openssl rand -hex 32` |
| `secrets.credentialEncryptionKey` / `GROK2API_CREDENTIAL_ENCRYPTION_KEY` | `openssl rand -base64 32` (keep forever) |
| `bootstrapAdmin.password` / `GROK2API_ADMIN_PASSWORD` | Strong admin password |
| `auth.secureCookies` / `GROK2API_SECURE_COOKIES` | Prefer `true` on HTTPS Space |

Service refuses insecure defaults if secrets are not replaced.

## Service

- Port: `7860` (Spaces requirement)
- Health: `/healthz`
- Admin UI: `/` (same origin as API)
- API: `/v1/*` with `Authorization: Bearer g2a_...`

## Deploy from GitHub

Workflow `.github/workflows/deploy-hf.yml` syncs only `huggingface/*` to this Space.

GitHub secrets:

- `HF_TOKEN`
- `HF_SPACE_ID` (e.g. `DanielleNguyen/Grok2Api`)
