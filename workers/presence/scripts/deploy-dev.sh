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
# .dev.vars: STACK_PROJECT_ID, STACK_PUBLISHABLE_CLIENT_KEY, and
# CONNECTIVITY_INVALIDATION_SECRET. STACK_API_URL is optional and defaults in
# code to https://api.stack-auth.com. The TURN key id and key secret
# are resolved from the shell/.dev.vars first, then from the standard private
# Cloudflare config files. They are uploaded as Worker secrets and never enter
# the app bundle.
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

read_private_env_value() {
  local key="$1"
  local file="${2:-${CLOUDFLARE_ENV_FILE:-$HOME/.config/manaflow/cloudflare.env}}"
  if [ ! -f "$file" ]; then
    return
  fi
  local line
  line="$(grep -E "^${key}=" "$file" | tail -1 || true)"
  if [ -z "$line" ]; then
    return
  fi
  local value="${line#*=}"
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
connectivity_invalidation_secret="$(read_dev_value CONNECTIVITY_INVALIDATION_SECRET)"
turn_key_id="$(read_dev_value CLOUDFLARE_TURN_KEY_ID)"
turn_key_secret="$(read_dev_value CLOUDFLARE_TURN_KEY_SECRET)"

# Reuse the private dev Stack config used by the web and mobile launchers when
# the caller has not supplied a .dev.vars file. Only the two publishable values
# are read; the server key is never needed by this Worker.
stack_env_file="${CMUX_STACK_ENV_FILE:-$HOME/.secrets/cmux.env}"
if [ -z "$stack_project_id" ]; then
  stack_project_id="$(read_private_env_value NEXT_PUBLIC_STACK_PROJECT_ID "$stack_env_file")"
fi
if [ -z "$stack_client_key" ]; then
  stack_client_key="$(read_private_env_value NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY "$stack_env_file")"
fi
if [ -z "$connectivity_invalidation_secret" ]; then
  connectivity_invalidation_secret="$(read_private_env_value CMUX_CONNECTIVITY_INVALIDATION_SECRET "$stack_env_file")"
fi
if [ -z "$connectivity_invalidation_secret" ]; then
  connectivity_invalidation_secret="$(openssl rand -hex 32)"
fi

# The local TURN key file is provisioned by the Cloudflare account setup. Its
# uid and secret are used only to provision the encrypted Worker secrets. The
# account API token is used only for this deploy; it is never sent to the TURN
# credential endpoint.
turn_key_file="${CLOUDFLARE_TURN_KEY_FILE:-$HOME/.config/cmux/webrtc/wrtca-turn-key.json}"
if [ -z "$turn_key_id" ] && [ -f "$turn_key_file" ]; then
  turn_key_id="$(jq -er '.uid // empty' "$turn_key_file" 2>/dev/null || true)"
fi
if [ -z "$turn_key_secret" ] && [ -f "$turn_key_file" ]; then
  turn_key_secret="$(jq -er '.secret // empty' "$turn_key_file" 2>/dev/null || true)"
fi

# Allow a fresh checkout to deploy without exporting the Cloudflare CLI
# credentials in the interactive shell. The values remain process-local and
# are never printed.
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  cloudflare_api_token="$(read_private_env_value CLOUDFLARE_API_TOKEN)"
  if [ -n "$cloudflare_api_token" ]; then
    export CLOUDFLARE_API_TOKEN="$cloudflare_api_token"
  fi
fi
if [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  cloudflare_account_id="$(read_private_env_value CLOUDFLARE_ACCOUNT_ID)"
  if [ -n "$cloudflare_account_id" ]; then
    export CLOUDFLARE_ACCOUNT_ID="$cloudflare_account_id"
  fi
fi

if [ -z "$stack_project_id" ] || [ -z "$stack_client_key" ] \
  || [ "${#connectivity_invalidation_secret}" -lt 32 ] \
  || [ -z "$turn_key_id" ] || [ -z "$turn_key_secret" ]; then
  cat >&2 <<'EOF'
error: missing isolated-worker configuration.

Set these in your shell or workers/presence/.dev.vars before deploying:
  STACK_PROJECT_ID=...
  STACK_PUBLISHABLE_CLIENT_KEY=...
  CONNECTIVITY_INVALIDATION_SECRET=... # optional; generated when omitted

TURN is resolved automatically from:
  $HOME/.config/cmux/webrtc/wrtca-turn-key.json (key uid)
  $HOME/.config/manaflow/cloudflare.env (CLOUDFLARE_API_TOKEN)
or from CLOUDFLARE_TURN_KEY_ID / CLOUDFLARE_TURN_KEY_SECRET.

Without the Stack values or TURN values, authenticated /v1 presence and the
WebRTC credential route fail closed.
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
put_worker_secret CONNECTIVITY_INVALIDATION_SECRET "$connectivity_invalidation_secret"
put_worker_secret CLOUDFLARE_TURN_KEY_ID "$turn_key_id"
put_worker_secret CLOUDFLARE_TURN_KEY_SECRET "$turn_key_secret"
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

Configure the web backend with the same publisher capability:

  export CMUX_CONNECTIVITY_INVALIDATION_SECRET=<matching value>

The reload scripts inject it into the tagged build, so a normally-tapped dev app
uses your worker, not the shared one. Unset it to go back to the shared
cmux-presence-dev baseline.
================================================================
EOF
