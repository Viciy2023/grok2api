#!/usr/bin/env bash
#
# Render, publish and verify the Hugging Face Space adapter for grok2api.
#
# Why a script instead of inline workflow YAML: the same logic has to run for a
# normal deploy, for a drift-triggered deploy and for an automatic rollback, and
# it must be testable locally without touching GitHub or Hugging Face.
#
# Subcommands
#   hash             print the adapter payload fingerprint and exit
#   render [outdir]  render the Space payload locally (no network) and exit
#   deploy           deploy if the Space does not already match, then verify
#   rollback         re-deploy the previous recorded deployment
#
# Environment
#   HF_TOKEN               Hugging Face write token              (deploy/rollback)
#   HF_SPACE_ID            e.g. DanielleNguyen/Grok2Api          (deploy/rollback)
#   HF_BUILD_MODE          image | source                        (default: image)
#   HF_UPSTREAM_REF        upstream commit SHA / tag / branch     (default: main)
#   HF_UPSTREAM_VERSION    informational, e.g. v3.1.6
#   HF_IMAGE_REPOSITORY    default: ghcr.io/chenyme/grok2api
#   HF_IMAGE_TAG           GHCR tag when no digest is pinned      (default: main)
#   HF_IMAGE_DIGEST        immutable sha256:... pin (preferred)
#   HF_FORCE               true = deploy even if state matches    (default: false)
#   HF_ADAPTER_DIR         default: huggingface
#   HF_SOURCE_SHA          adapter commit being deployed (informational)
#   HF_VERIFY              1 = poll the Space until healthy       (default: 1)
#   HF_VERIFY_TIMEOUT      seconds to wait for RUNNING            (default: 1500)
#   HF_ALLOW_ROLLBACK      1 = mark a failed build rollback-able  (default: 1)
#   HF_DRY_RUN             1 = render only, never talk to HF
#   HF_STATE_DIR           shared state between deploy/rollback
#
# Exit codes
#   0 success (or nothing to do)
#   1 configuration / infrastructure error
#   2 the Space build or runtime failed  (rollback-eligible)
#   3 the Space built but never became healthy
#
set -euo pipefail

SUBCOMMAND="${1:-deploy}"

HF_ADAPTER_DIR="${HF_ADAPTER_DIR:-huggingface}"
HF_BUILD_MODE="${HF_BUILD_MODE:-image}"
HF_UPSTREAM_REF="${HF_UPSTREAM_REF:-main}"
HF_UPSTREAM_VERSION="${HF_UPSTREAM_VERSION:-}"
HF_IMAGE_REPOSITORY="${HF_IMAGE_REPOSITORY:-ghcr.io/chenyme/grok2api}"
HF_IMAGE_TAG="${HF_IMAGE_TAG:-main}"
HF_IMAGE_DIGEST="${HF_IMAGE_DIGEST:-}"
HF_FORCE="${HF_FORCE:-false}"
HF_VERIFY="${HF_VERIFY:-1}"
HF_VERIFY_TIMEOUT="${HF_VERIFY_TIMEOUT:-1500}"
HF_ALLOW_ROLLBACK="${HF_ALLOW_ROLLBACK:-1}"
HF_DRY_RUN="${HF_DRY_RUN:-0}"
HF_SOURCE_SHA="${HF_SOURCE_SHA:-}"
HF_STATE_DIR="${HF_STATE_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/hf-publish}"
UPSTREAM_REPO_SLUG="${HF_UPSTREAM_REPOSITORY:-chenyme/grok2api}"

ADAPTER_FILES=(Dockerfile Dockerfile.image start.sh README.md .env.example)

# All logging goes to stderr so stdout carries only machine-readable data.
log()  { printf '[hf-publish] %s\n' "$*" >&2; }
warn() { printf '[hf-publish] WARN: %s\n' "$*" >&2; }
die()  { printf '[hf-publish] ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

mkdir -p "$HF_STATE_DIR"

PREV_SYNC_FILE="$HF_STATE_DIR/deployed-sync.prev"
ROLLBACK_FLAG="$HF_STATE_DIR/rollback-eligible"

# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #

# Fingerprint of the adapter payload that actually lands in the Space. Used to
# detect "someone edited huggingface/ but the Space was never updated" and to
# let the situation self-heal on the next watchdog run.
compute_adapter_hash() {
  local dir="$1" f digest
  for f in "${ADAPTER_FILES[@]}"; do
    if [ -f "$dir/$f" ]; then
      digest="$(sha256sum "$dir/$f" | cut -d' ' -f1)"
      printf '%s  %s\n' "$digest" "$f"
    else
      printf 'MISSING  %s\n' "$f"
    fi
  done | sha256sum | cut -d' ' -f1
}

sync_field() {
  local file="$1" key="$2"
  if [ -f "$file" ]; then
    sed -n "s/^${key}=//p" "$file" | head -n 1
  fi
}

image_ref() {
  if [ -n "$HF_IMAGE_DIGEST" ]; then
    printf '%s@%s' "$HF_IMAGE_REPOSITORY" "$HF_IMAGE_DIGEST"
  else
    printf '%s:%s' "$HF_IMAGE_REPOSITORY" "$HF_IMAGE_TAG"
  fi
}

space_repo_url() {
  printf 'https://oauth2:%s@huggingface.co/spaces/%s' "$HF_TOKEN" "$HF_SPACE_ID"
}

# Anonymous (or token-authenticated) call against the public Spaces API.
space_api() {
  if [ -n "${HF_TOKEN:-}" ]; then
    curl -fsS --max-time 30 -H "Authorization: Bearer ${HF_TOKEN}" "$1"
  else
    curl -fsS --max-time 30 "$1"
  fi
}

fetch_deployed_sync() {
  local out="$1"
  rm -f "$out"
  space_api "https://huggingface.co/spaces/${HF_SPACE_ID}/raw/main/.hf-sync" > "$out" 2>/dev/null || rm -f "$out"
  return 0
}

# --------------------------------------------------------------------------- #
# render
# --------------------------------------------------------------------------- #

write_sync_record() {
  local out="$1" mode="$2" ref="$3" ref_image="$4" adapter_hash="$5"
  cat > "$out/.hf-sync" <<EOF
adapter_repo=${GITHUB_REPOSITORY:-Viciy2023/grok2api}
adapter_commit=${HF_SOURCE_SHA:-unknown}
adapter_hash=${adapter_hash}
build_mode=${mode}
upstream_repo=${UPSTREAM_REPO_SLUG}
upstream_ref=${ref}
upstream_version=${HF_UPSTREAM_VERSION:-unknown}
image_ref=${ref_image}
image_digest=${HF_IMAGE_DIGEST:-}
deployed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
deployed_by=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-0}
EOF
}

render_payload() {
  local out="$1" adapter_hash
  adapter_hash="$(compute_adapter_hash "$HF_ADAPTER_DIR")"

  case "$HF_BUILD_MODE" in
    image)  [ -f "$HF_ADAPTER_DIR/Dockerfile.image" ] || die "missing $HF_ADAPTER_DIR/Dockerfile.image" ;;
    source) [ -f "$HF_ADAPTER_DIR/Dockerfile" ]       || die "missing $HF_ADAPTER_DIR/Dockerfile" ;;
    *)      die "unknown HF_BUILD_MODE '$HF_BUILD_MODE' (expected image or source)" ;;
  esac

  rm -rf "$out"
  mkdir -p "$out"
  if [ "$HF_BUILD_MODE" = image ]; then
    cp "$HF_ADAPTER_DIR/Dockerfile.image" "$out/Dockerfile"
  else
    cp "$HF_ADAPTER_DIR/Dockerfile" "$out/Dockerfile"
  fi
  cp "$HF_ADAPTER_DIR/start.sh"     "$out/start.sh"
  cp "$HF_ADAPTER_DIR/README.md"    "$out/README.md"
  cp "$HF_ADAPTER_DIR/.env.example" "$out/.env.example"
  chmod 0755 "$out/start.sh"

  # Pin the upstream revision so the build is reproducible. The sed patterns
  # must match, otherwise the Space would silently build `main` (drifting again
  # without anyone noticing), so every patch is asserted.
  local ref_image
  ref_image="$(image_ref)"
  if [ "$HF_BUILD_MODE" = image ]; then
    sed -i "s|^ARG GROK2API_IMAGE=.*|ARG GROK2API_IMAGE=${ref_image}|" "$out/Dockerfile"
    grep -qF "ARG GROK2API_IMAGE=${ref_image}" "$out/Dockerfile" \
      || die "could not pin GROK2API_IMAGE in Dockerfile.image"
    sed -i "s|^ARG GROK2API_CONFIG_REF=.*|ARG GROK2API_CONFIG_REF=${HF_UPSTREAM_REF}|" "$out/Dockerfile"
    grep -qF "ARG GROK2API_CONFIG_REF=${HF_UPSTREAM_REF}" "$out/Dockerfile" \
      || die "could not pin GROK2API_CONFIG_REF in Dockerfile.image"
  else
    sed -i "s|^ARG GROK2API_REF=.*|ARG GROK2API_REF=${HF_UPSTREAM_REF}|" "$out/Dockerfile"
    grep -qF "ARG GROK2API_REF=${HF_UPSTREAM_REF}" "$out/Dockerfile" \
      || die "could not pin GROK2API_REF in Dockerfile"
  fi

  write_sync_record "$out" "$HF_BUILD_MODE" "$HF_UPSTREAM_REF" "$ref_image" "$adapter_hash"
  log "rendered payload: mode=${HF_BUILD_MODE} ref=${HF_UPSTREAM_REF} image=${ref_image}"
  log "adapter fingerprint: ${adapter_hash}"
}

# --------------------------------------------------------------------------- #
# publish
# --------------------------------------------------------------------------- #

publish_payload() {
  local payload="$1" space_dir msg sha
  space_dir="$(mktemp -d)"
  msg="chore(hf): deploy ${HF_BUILD_MODE} mode @ ${HF_UPSTREAM_REF} (${HF_UPSTREAM_VERSION:-unknown})"

  log "cloning Space ${HF_SPACE_ID}"
  if ! git clone --quiet "$(space_repo_url)" "$space_dir" 2>/dev/null; then
    # Never echo the tokenised URL: it would leak HF_TOKEN into the build log.
    warn "could not clone Space '${HF_SPACE_ID}' — verify the repository id and that HF_TOKEN has write access"
    rm -rf "$space_dir"
    return 1
  fi

  # The Space is a pure artifact: it holds exactly the adapter payload.
  find "$space_dir" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
  cp -a "$payload"/. "$space_dir"/

  sha="$(
    cd "$space_dir"
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git add --all
    if git diff --cached --quiet; then
      log "Space files already identical"
    else
      git commit --quiet -m "$msg"
    fi
    git push --quiet origin HEAD:main || {
      log "push rejected, rebasing onto the Space head"
      git pull --quiet --rebase --autostash origin main
      git push --quiet origin HEAD:main
    } || exit 1
    git rev-parse HEAD
  )" || { rm -rf "$space_dir"; return 1; }

  rm -rf "$space_dir"
  printf '%s' "$sha"
}

verify_space() {
  local expected="$1" deadline=$((SECONDS + HF_VERIFY_TIMEOUT)) info stage sha
  log "waiting for the Space to run ${expected:0:12} (timeout ${HF_VERIFY_TIMEOUT}s)"

  while :; do
    info="$(space_api "https://huggingface.co/api/spaces/${HF_SPACE_ID}" 2>/dev/null || true)"
    if [ -z "$info" ]; then
      log "Space API not reachable yet"
    else
      stage="$(printf '%s' "$info" | jq -r '.runtime.stage // "UNKNOWN"')"
      sha="$(printf '%s' "$info" | jq -r '.sha // ""')"
      case "$stage" in
        BUILD_ERROR|RUNTIME_ERROR|CONFIG_ERROR|NO_APP_FILE|BUILD_FAILED)
          printf '%s\n' "$info" > "$HF_STATE_DIR/space-error.json"
          log "Space stage=${stage} sha=${sha:0:12}"
          log "Space error detail: $(printf '%s' "$info" | jq -c '.runtime // {}' 2>/dev/null | head -c 600)"
          return 2
          ;;
        RUNNING)
          if [ "$sha" = "$expected" ]; then
            log "Space is RUNNING ${sha:0:12}"
            break
          fi
          log "still running the previous revision ${sha:0:12}, waiting"
          ;;
        *)
          log "stage=${stage} sha=${sha:0:12}"
          ;;
      esac
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      warn "timed out waiting for ${expected:0:12}"
      return 3
    fi
    sleep 15
  done

  if [ "$HF_VERIFY" != "1" ]; then
    log "health verification disabled"
    return 0
  fi

  local host attempt
  host="$(printf '%s' "$info" | jq -r '.host // empty')"
  if [ -z "$host" ]; then
    host="https://$(printf '%s' "$info" | jq -r '.subdomain').hf.space"
  fi
  for attempt in $(seq 1 24); do
    if curl -fsS --max-time 15 "${host}/healthz" 2>/dev/null | grep -q '"ok"'; then
      log "health check passed: ${host}/healthz"
      return 0
    fi
    log "health check attempt ${attempt} failed, retrying"
    sleep 10
  done
  warn "Space is RUNNING but ${host}/healthz never returned {\"ok\":true}"
  return 3
}

# --------------------------------------------------------------------------- #
# deploy
# --------------------------------------------------------------------------- #

do_deploy() {
  [ "$HF_DRY_RUN" = "1" ] || [ -n "${HF_TOKEN:-}" ] || die "HF_TOKEN is required"
  [ "$HF_DRY_RUN" = "1" ] || [ -n "${HF_SPACE_ID:-}" ] || die "HF_SPACE_ID is required"

  local desired_hash payload
  desired_hash="$(compute_adapter_hash "$HF_ADAPTER_DIR")"
  payload="$HF_STATE_DIR/payload"

  if [ "$HF_DRY_RUN" != "1" ]; then
    fetch_deployed_sync "$PREV_SYNC_FILE"
    local have_mode have_ref have_digest have_hash
    have_mode="$(sync_field "$PREV_SYNC_FILE" build_mode)"
    have_ref="$(sync_field "$PREV_SYNC_FILE" upstream_ref)"
    have_digest="$(sync_field "$PREV_SYNC_FILE" image_digest)"
    have_hash="$(sync_field "$PREV_SYNC_FILE" adapter_hash)"

    if [ "$HF_FORCE" != "true" ] \
      && [ "$HF_BUILD_MODE" = "$have_mode" ] \
      && [ "$HF_UPSTREAM_REF" = "$have_ref" ] \
      && [ "$HF_IMAGE_DIGEST" = "$have_digest" ] \
      && [ "$desired_hash" = "$have_hash" ]; then
      log "Space already matches (mode=${have_mode} ref=${have_ref} digest=${have_digest:0:19} adapter=${have_hash:0:12}); nothing to do"
      return 0
    fi
    log "drift detected:"
    log "  mode    deployed=${have_mode:-<none>} desired=${HF_BUILD_MODE}"
    log "  ref     deployed=${have_ref:-<none>} desired=${HF_UPSTREAM_REF}"
    log "  digest  deployed=${have_digest:-<none>} desired=${HF_IMAGE_DIGEST:-<none>}"
    log "  adapter deployed=${have_hash:-<none>} desired=${desired_hash}"
  fi

  render_payload "$payload"

  if [ "$HF_DRY_RUN" = "1" ]; then
    log "dry run: payload rendered at ${payload}"
    ls -la "$payload" >&2
    return 0
  fi

  rm -f "$ROLLBACK_FLAG"

  local sha rc
  sha="$(publish_payload "$payload")" || die "failed to publish the payload to the Space"
  log "pushed Space commit ${sha}"

  rc=0
  verify_space "$sha" || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$rc" -eq 2 ] && [ "$HF_ALLOW_ROLLBACK" = "1" ] && [ -s "$PREV_SYNC_FILE" ]; then
    : > "$ROLLBACK_FLAG"
    log "marked the deployment as rollback-eligible"
  fi
  return "$rc"
}

do_rollback() {
  if [ ! -f "$ROLLBACK_FLAG" ]; then
    log "nothing to roll back"
    return 0
  fi
  if [ ! -s "$PREV_SYNC_FILE" ]; then
    warn "no previous deployment record to roll back to"
    return 1
  fi

  local mode ref digest version
  mode="$(sync_field "$PREV_SYNC_FILE" build_mode)"
  ref="$(sync_field "$PREV_SYNC_FILE" upstream_ref)"
  digest="$(sync_field "$PREV_SYNC_FILE" image_digest)"
  version="$(sync_field "$PREV_SYNC_FILE" upstream_version)"

  if [ -z "$ref" ]; then
    warn "previous deployment record has no upstream_ref; cannot roll back"
    return 1
  fi

  log "rolling back to mode=${mode} ref=${ref} digest=${digest:-<none>}"
  HF_BUILD_MODE="${mode:-image}"
  HF_UPSTREAM_REF="$ref"
  HF_IMAGE_DIGEST="$digest"
  HF_UPSTREAM_VERSION="$version"
  HF_FORCE="true"
  HF_ALLOW_ROLLBACK="0"
  rm -f "$ROLLBACK_FLAG"

  local payload
  payload="$HF_STATE_DIR/payload-rollback"
  render_payload "$payload"
  local sha
  sha="$(publish_payload "$payload")" || die "rollback publish failed"
  log "rolled back with Space commit ${sha}"
  verify_space "$sha" || die "rolled-back deployment is not healthy either" 1
  return 0
}

# --------------------------------------------------------------------------- #

case "$SUBCOMMAND" in
  hash)
    compute_adapter_hash "$HF_ADAPTER_DIR"
    printf '\n'
    ;;
  render)
    out="${2:-$HF_STATE_DIR/payload}"
    render_payload "$out"
    log "rendered to ${out}"
    ;;
  deploy)
    do_deploy
    ;;
  rollback)
    do_rollback
    ;;
  *)
    die "unknown subcommand '$SUBCOMMAND' (expected hash, render, deploy or rollback)"
    ;;
esac
