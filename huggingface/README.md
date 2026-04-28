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

This Space runs the Grok2Api FastAPI service in Docker mode.

## Runtime Notes

- Persistent data is stored in the mounted bucket at `/data`
- Runtime environment file: `/data/.env`
- Runtime config file: `/data/config.toml`
- Logs directory: `/data/logs`
- Service port: `7860`

## Runtime Variables

Runtime variables are expected to come from `/data/.env` in the mounted bucket.

Optional HF Space variables only used as fallback:

- `SPACE_HOST`
- `SPACE_ID`

## Build Mode

This deployment does not pull a prebuilt image.

The GitHub workflow only syncs the local `huggingface` directory to the Hugging Face Space repository root. During Docker build, the Space clones the latest upstream source from `https://github.com/chenyme/grok2api` and builds from that source.
