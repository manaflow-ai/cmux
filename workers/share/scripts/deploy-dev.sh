#!/usr/bin/env bash
set -euo pipefail

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
  [ -n "$line" ] || return
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

raw="${1:-${CMUX_SHARE_DEV_SLUG:-$(git config user.email 2>/dev/null | cut -d@ -f1 || true)}}"
raw="${raw:-${USER:-}}"
slug="$(printf '%s' "$raw" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | sed 's/--*/-/g; s/^-//; s/-*$//')"
if [ -z "$slug" ]; then
  echo "error: pass an isolated slug: ./scripts/deploy-dev.sh <slug>" >&2
  exit 1
fi
case "$slug" in
  dev|prod|share|cmux-share|cmux-share-dev)
    echo "error: '$slug' is reserved; choose a personal feature slug" >&2
    exit 1
    ;;
esac

name="cmux-share-dev-${slug}"
stack_project_id="$(read_dev_value STACK_PROJECT_ID)"
stack_client_key="$(read_dev_value STACK_PUBLISHABLE_CLIENT_KEY)"
public_keys="$(read_dev_value SHARE_TICKET_PUBLIC_KEYS_JSON)"
stack_api_url="$(read_dev_value STACK_API_URL)"
web_origin="${SHARE_WEB_ORIGIN:-http://localhost:${CMUX_PORT:-3000}}"
if [ -z "$stack_project_id" ] || [ -z "$stack_client_key" ] || [ -z "$public_keys" ]; then
  echo "error: STACK_PROJECT_ID, STACK_PUBLISHABLE_CLIENT_KEY, and SHARE_TICKET_PUBLIC_KEYS_JSON are required" >&2
  exit 1
fi

echo "Deploying isolated worker: ${name}"
out="$(bunx wrangler deploy \
  --config wrangler.dev.toml \
  --name "$name" \
  --var "SHARE_WEB_ORIGIN:${web_origin}" \
  --var "SHARE_ALLOWED_ORIGINS:${web_origin}" 2>&1)"
echo "$out"
url="$(printf '%s\n' "$out" | grep -oE 'https://[a-z0-9.-]+\.workers\.dev' | head -1)"
if [ -z "$url" ]; then
  echo "error: deployed, but could not parse the workers.dev URL" >&2
  exit 1
fi

put_worker_secret STACK_PROJECT_ID "$stack_project_id"
put_worker_secret STACK_PUBLISHABLE_CLIENT_KEY "$stack_client_key"
put_worker_secret SHARE_TICKET_PUBLIC_KEYS_JSON "$public_keys"
if [ -n "$stack_api_url" ]; then
  put_worker_secret STACK_API_URL "$stack_api_url"
fi

printf '\nWorker: %s\nMac: export CMUX_SHARE_SERVICE_URL=%s\nWeb: export CMUX_SHARE_WORKER_URL=%s\n' "$url" "$url" "$url"
