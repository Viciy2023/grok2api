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

Runs the official [chenyme/grok2api](https://github.com/chenyme/grok2api) (Go +
React) gateway on Hugging Face.

This Space repository is a **build artifact**. Never edit it by hand — it is
overwritten on every deployment by
[`.github/scripts/hf-publish.sh`](https://github.com/Viciy2023/grok2api/blob/main/.github/scripts/hf-publish.sh)
in the source repository.

## Build model

| Mode | Base | Build cost | When to use |
| --- | --- | --- | --- |
| `image` (default) | `ghcr.io/chenyme/grok2api@sha256:…` | seconds | normal operation |
| `source` | compiles upstream Go + React | ~5–15 min | fallback if upstream stops publishing images |

In `image` mode the adapter re-bases the exact image upstream publishes to GHCR
on every push to `main`. That image is produced by upstream's own CI (which runs
`go test`, `go vet`, `pnpm lint` first) and is labelled with the upstream commit
it was built from, so the Space runs a tested, reproducible artifact.

The deployed revision is pinned by **digest**, not by a moving tag.

## Auto-update pipeline

```text
chenyme/grok2api push to main
        |
        v
upstream CI publishes ghcr.io/chenyme/grok2api:main (a few minutes later)
        |
        v
Viciy2023/grok2api -> "Watch upstream and rebuild HF Space" (every 10 min)
   resolves the newest published image digest + revision
   compares with the .hf-sync record inside this Space
        |
        v  drift detected
"Deploy Hugging Face Space" -> fetch upstream revision, re-render the adapter,
   pin image digest + config ref, push to this Space
        |
        v
Hugging Face rebuilds -> the workflow waits for RUNNING and /healthz = {"ok":true}
        |
        v  on build/runtime failure
automatic rollback to the previous recorded deployment
```

Drift is detected on **any** of these changing: upstream image digest, upstream
revision, build mode, or the adapter payload fingerprint. That last one means a
failed deployment also self-heals instead of being silently forgotten.

No manual step is required to stay current.

## Persistent storage

Mount HF Storage (e.g. `DanielleNguyen/Grok2Api-storage`) to **`/data`**.

| Path | Purpose |
| --- | --- |
| `/data/config.yaml` | Runtime config (seeded once from upstream `config.example.yaml`) |
| `/data/backend.db` | SQLite database |
| `/data/media` | Local media files |
| `/data/.env` | Optional env file loaded at start |

## First boot secrets

Edit `/data/config.yaml` (or set the env vars before the first seed):

| Field / env | Notes |
| --- | --- |
| `secrets.jwtSecret` / `GROK2API_JWT_SECRET` | `openssl rand -hex 32` |
| `secrets.credentialEncryptionKey` / `GROK2API_CREDENTIAL_ENCRYPTION_KEY` | `openssl rand -base64 32` (keep forever) |
| `bootstrapAdmin.password` / `GROK2API_ADMIN_PASSWORD` | Strong admin password |
| `auth.secureCookies` / `GROK2API_SECURE_COOKIES` | Prefer `true` on HTTPS |

Secrets are re-applied on every boot. The service refuses to start while
placeholder secrets are still present.

## Service

- Port `7860` (Spaces requirement)
- Health: `/healthz`
- Admin UI: `/` (same origin as the API)
- API: `/v1/*` with `Authorization: Bearer g2a_...`

## Operating it

```bash
# is the Space current?
curl -s https://huggingface.co/spaces/DanielleNguyen/Grok2Api/raw/main/.hf-sync

# force a drift check + deploy now
gh workflow run "Watch upstream and rebuild HF Space" -R Viciy2023/grok2api

# manual deploy pinned to a specific upstream commit
gh workflow run "Deploy Hugging Face Space" -R Viciy2023/grok2api \
  -f upstream_ref=<40-char-sha> -f build_mode=image

# switch to the source-build fallback
gh variable set HF_BUILD_MODE --body source -R Viciy2023/grok2api
```

Repository configuration required by the workflows:

| Name | Kind | Value |
| --- | --- | --- |
| `HF_TOKEN` | secret | Hugging Face **write** token |
| `HF_SPACE_ID` | secret or variable | `DanielleNguyen/Grok2Api` |
| `HF_BUILD_MODE` | variable (optional) | `image` (default) or `source` |
| `HF_FAILURE_BACKOFF_SECONDS` | variable (optional) | default `21600` |
| `HF_KEEPALIVE` | variable (optional) | `true` pings `/healthz` to defeat idle sleep |

> `HF_TOKEN` must have **write** access to this Space. A read-only or expired
> token makes every deployment fail at the publish step.

## 自动更新说明

- 上游 `chenyme/grok2api` 每次推送 `main`，其 CI 会自动构建并发布镜像到
  `ghcr.io/chenyme/grok2api`。
- 本仓库的 `Watch upstream and rebuild HF Space` 工作流每 10 分钟检查一次上游已发布的
  镜像摘要（digest）与 commit；一旦发现与 Space 内记录的版本不一致，立即触发本
  Space 重新构建，拉取最新镜像。
- 重建完成后工作流会等待 Space 进入 `RUNNING` 并校验 `/healthz` 返回
  `{"ok":true}`；若构建或运行失败，会自动回滚到上一个可用版本。
- Space 内 `.hf-sync` 文件记录了当前部署的上游 commit、镜像摘要、构建模式与
  适配层指纹，是判断是否需要更新的依据。
