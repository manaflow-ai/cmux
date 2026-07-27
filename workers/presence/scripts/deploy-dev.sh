#!/usr/bin/env bash
set -euo pipefail

# Deploy an ISOLATED dev presence worker for one developer (or feature), so
# several people can work on / dogfood the presence + paired-Mac-backup worker at
# the same time WITHOUT clobbering the shared `cmux-presence-dev` or each other.
#
# Each named worker `cmux-presence-dev-<slug>` gets:
#   - its own `*.workers.dev` URL, and
#   - its own Durable Object namespace (presence + backup state fully isolated).
#
# Point your dev builds (Mac heartbeat + iOS presence/backup) at the printed URL
# via CMUX_PRESENCE_BASE_URL; the reload scripts bake it into the tagged build.
#
# Usage:
#   ./scripts/deploy-dev.sh            # slug = your git email prefix (one per dev)
#   ./scripts/deploy-dev.sh <slug>     # explicit slug (e.g. a feature name)
#
# Required Stack config is read from the shell environment first, then from
# .dev.vars: STACK_PROJECT_ID and STACK_PUBLISHABLE_CLIENT_KEY. STACK_API_URL is
# optional and defaults in code to https://api.stack-auth.com.
#
# Do NOT deploy the shared `cmux-presence-dev` from a feature branch: that single
# instance is the integration baseline, and `wrangler deploy --name cmux-presence`
# / `--name cmux-presence-dev` inherits the PRODUCTION presence.cmux.dev custom
# domain (see README + wrangler.dev.toml). This script refuses those names.

cd "$(dirname "$0")/.."

read_dev_value() {
  local key="$1"
  local value="${!key:-}"
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return
  fi
  if [ ! -f .dev.vars ]; then
    return
  fi
  local line
  line="$(grep -E "^${key}=" .dev.vars | tail -1 || true)"
  if [ -z "$line" ]; then
    return
  fi
  value="${line#*=}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

put_worker_secret() {
  local key="$1"
  local value="$2"
  printf '%s' "$value" | bunx wrangler secret put "$key" --config wrangler.dev.toml --name "$name" >/dev/null
}

raw="${1:-${CMUX_PRESENCE_DEV_SLUG:-$(git config user.email 2>/dev/null | cut -d@ -f1 || true)}}"
raw="${raw:-${USER:-}}"
slug="$(printf '%s' "$raw" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | sed 's/--*/-/g; s/^-//; s/-*$//')"

if [ -z "$slug" ]; then
  echo "error: could not derive a slug; pass one: ./scripts/deploy-dev.sh <slug>" >&2
  exit 1
fi
case "$slug" in
  dev|prod|presence|cmux-presence|cmux-presence-dev)
    echo "error: '$slug' is reserved (shared/prod). Pick a personal slug." >&2
    exit 1
    ;;
esac

name="cmux-presence-dev-${slug}"
stack_project_id="$(read_dev_value STACK_PROJECT_ID)"
stack_client_key="$(read_dev_value STACK_PUBLISHABLE_CLIENT_KEY)"
stack_api_url="$(read_dev_value STACK_API_URL)"

if [ -z "$stack_project_id" ] || [ -z "$stack_client_key" ]; then
  cat >&2 <<'EOF'
error: missing Stack Auth config for the isolated worker.

Set these in your shell or workers/presence/.dev.vars before deploying:
  STACK_PROJECT_ID=...
  STACK_PUBLISHABLE_CLIENT_KEY=...

Without these Worker secrets, authenticated /v1 presence and paired-Mac backup
routes fail closed with 401.
EOF
  exit 1
fi

echo "→ Deploying isolated dev worker: ${name}"
out="$(bunx wrangler deploy --config wrangler.dev.toml --name "$name" 2>&1)"
echo "$out"

url="$(printf '%s\n' "$out" | grep -oE 'https://[a-z0-9.-]+\.workers\.dev' | head -1)"
if [ -z "$url" ]; then
  echo "error: deployed, but could not parse the worker URL from wrangler output." >&2
  exit 1
fi

echo "→ Provisioning Stack Auth secrets on ${name}"
put_worker_secret STACK_PROJECT_ID "$stack_project_id"
put_worker_secret STACK_PUBLISHABLE_CLIENT_KEY "$stack_client_key"
if [ -n "$stack_api_url" ]; then
  put_worker_secret STACK_API_URL "$stack_api_url"
fi

cat <<EOF

================================================================
Isolated dev presence + paired-Mac-backup worker:
  ${url}

Point ALL your dev builds at it (Mac that heartbeats + the iPhone that
subscribes/backs up must use the SAME worker), then reload:

  export CMUX_PRESENCE_BASE_URL=${url}

The reload scripts inject it into the tagged build, so a normally-tapped dev app
uses your worker, not the shared one. Unset it to go back to the shared
cmux-presence-dev baseline.
================================================================
EOF
