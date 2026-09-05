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
# Required config is read from the shell environment first, then from
# .dev.vars: STACK_PROJECT_ID, STACK_PUBLISHABLE_CLIENT_KEY, and
# CONNECTIVITY_INVALIDATION_SECRET. STACK_API_URL is optional and defaults in
# code to https://api.stack-auth.com. IROH_SESSION_SIGNING_KEY must be supplied
# in the shell or .dev.vars so the same value can be installed in the matching
# web compatibility deployment.
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
connectivity_invalidation_secret="$(read_dev_value CONNECTIVITY_INVALIDATION_SECRET)"
iroh_session_signing_key="$(read_dev_value IROH_SESSION_SIGNING_KEY)"
if [ "${#iroh_session_signing_key}" -lt 32 ]; then
  echo "error: IROH_SESSION_SIGNING_KEY must contain at least 32 characters." >&2
  echo "Set it in the shell or workers/presence/.dev.vars, then set the same" >&2
  echo "value as CMUX_IROH_SESSION_SIGNING_KEY in the web deployment." >&2
  exit 1
fi

if [ -z "$stack_project_id" ] || [ -z "$stack_client_key" ] \
  || [ "${#connectivity_invalidation_secret}" -lt 32 ]; then
  cat >&2 <<'EOF'
error: missing Stack Auth config for the isolated worker.

Set these in your shell or workers/presence/.dev.vars before deploying:
  STACK_PROJECT_ID=...
  STACK_PUBLISHABLE_CLIENT_KEY=...
  CONNECTIVITY_INVALIDATION_SECRET=... # at least 32 random characters
  IROH_SESSION_SIGNING_KEY=...       # at least 32 random characters

Without these Worker secrets, authenticated /v1 presence and paired-Mac backup
routes or backend-only connectivity publication fail closed.
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
put_worker_secret IROH_SESSION_SIGNING_KEY "$iroh_session_signing_key"
if [ -n "$stack_api_url" ]; then
  put_worker_secret STACK_API_URL "$stack_api_url"
fi

# Optional direct-backend and observability secrets. Provisioning them here
# keeps an isolated Worker faithful to the production shape without requiring
# every developer to paste sensitive values into a command line.
for key in \
  SENTRY_DSN \
  CMUX_IROH_LAN_DISCOVERY_SECRET_B64 \
  CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64 \
  CMUX_IROH_GRANT_SIGNING_KEY_P8 \
  CMUX_IROH_GRANT_SIGNING_KID \
  CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON \
  CMUX_IROH_MINT_URL \
  CMUX_IROH_MINT_HMAC_SECRET_B64 \
  CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER \
  CMUX_RELAY_POLICY_KEY_ID \
  CMUX_RELAY_POLICY_PRIVATE_KEY_PEM \
  CMUX_RELAY_JWT_PRIVATE_KEY_PEM; do
  value="$(read_dev_value "$key")"
  if [ -n "$value" ]; then
    put_worker_secret "$key" "$value"
  fi
done

cat <<EOF

================================================================
Isolated dev presence + paired-Mac-backup worker:
  ${url}

Point ALL your dev builds at it (Mac that heartbeats + the iPhone that
subscribes/backs up must use the SAME worker), then reload:

  export CMUX_PRESENCE_BASE_URL=${url}

Configure the web backend with the same publisher capability:

  export CMUX_CONNECTIVITY_INVALIDATION_SECRET=<matching value>

The web compatibility route must also use the exact session-signing key that
was provisioned on this Worker. Keep it in the web deployment's secret store,
never in source control or a shell transcript.

The reload scripts inject it into the tagged build, so a normally-tapped dev app
uses your worker, not the shared one. Unset it to go back to the shared
cmux-presence-dev baseline.
================================================================
EOF
