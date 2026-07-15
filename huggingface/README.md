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

This Space runs the official [chenyme/grok2api](https://github.com/chenyme/grok2api) FastAPI gateway in Docker mode.

## How it builds

- Space repository only contains the HF adapter (`Dockerfile`, `start.sh`, this README, `.env.example`)
- During image build, the Dockerfile **clones the official upstream** `https://github.com/chenyme/grok2api` and installs from that source
- Local fork application code is **not** copied into the image

## Persistent storage

Mount HF Storage (example: `DanielleNguyen/Grok2Api-storage`) to **`/data`**.

| Path | Purpose |
| --- | --- |
| `/data` | `DATA_DIR` root (accounts DB, media cache, config) |
| `/data/.env` | Optional runtime environment file (loaded on start) |
| `/data/config.toml` | Runtime config (seeded from `config.defaults.toml` on first boot) |
| `/data/logs` | Log directory |

## Required runtime settings

Set either in `/data/.env` or Space Variables/Secrets:

| Variable | Notes |
| --- | --- |
| `DATA_DIR` | Must be `/data` when using the storage mount |
| `LOG_DIR` | Prefer `/data/logs` |
| `SERVER_PORT` | Must stay `7860` for Spaces |
| `ACCOUNT_STORAGE` | Prefer `local` with `/data` |
| `GROK_APP_APP_KEY` | Admin password (override default) |
| `GROK_APP_API_KEY` | API key for `/v1/*` |
| `GROK_APP_APP_URL` | Public Space URL, e.g. `https://daniellenguyen-grok2api.hf.space` |

`SPACE_HOST` / `SPACE_ID` are optional fallbacks used by `start.sh` to write `app.app_url` when `GROK_APP_APP_URL` is empty.

## Service

- Port: `7860`
- Entrypoint: `start.sh` → `granian` ASGI on `app.main:app`
- Admin: `/admin/login`
- Health: `/health`

## Deploy from GitHub

GitHub Actions workflow `.github/workflows/deploy-hf.yml` syncs only the `huggingface/` adapter files to this Space on `main` push or manual dispatch.

Required GitHub secrets:

- `HF_TOKEN` — write access to the Space
- `HF_SPACE_ID` — e.g. `DanielleNguyen/Grok2Api`
