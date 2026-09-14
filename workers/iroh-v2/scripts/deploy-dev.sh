#!/usr/bin/env bash
set -euo pipefail

# Deploy one isolated development Worker. A named Worker gets its own Durable
# Object namespaces, so a branch cannot change the shared development data.
# The shared baseline remains cmux-iroh-v2-development.

cd "$(dirname "$0")/.."

read_value() {
  local key="$1" value line
  value="${!key:-}"
  if [[ -n "$value" ]]; then printf '%s' "$value"; return; fi
  [[ -f .dev.vars ]] || return 0
  line="$(grep -E "^${key}=" .dev.vars | tail -1 || true)"
  [[ -n "$line" ]] || return 0
  value="${line#*=}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  printf '%s' "$value"
}

raw="${1:-${CMUX_IROH_V2_DEV_SLUG:-$(git config user.email 2>/dev/null | cut -d@ -f1 || true)}}"
raw="${raw:-${USER:-}}"
slug="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/--*/-/g; s/^-//; s/-*$//')"
[[ -n "$slug" ]] || { echo "error: pass a development slug" >&2; exit 1; }
case "$slug" in
  development|staging|production|prod|shared|local)
    echo "error: '$slug' is reserved; choose a branch or developer slug" >&2; exit 1 ;;
esac

name="cmux-iroh-v2-dev-${slug}"
workers_subdomain="${CMUX_IROH_V2_WORKERS_SUBDOMAIN:-debussy}"
required=(STACK_PROJECT_ID STACK_PUBLISHABLE_KEY STACK_SERVER_KEY API_TICKET_KEYS
  API_TICKET_CURRENT_KEY_ID RELAY_SIGNING_KEY RELAY_KEY_ID RELAY_URLS)
for key in "${required[@]}"; do
  value="$(read_value "$key")"
  [[ -n "$value" ]] || { echo "error: missing $key in environment or .dev.vars" >&2; exit 1; }
done

echo "Deploying isolated Worker: $name"
secret_file="$(mktemp "${TMPDIR:-/tmp}/cmux-iroh-v2-dev-secrets.XXXXXX.json")"
trap 'rm -f "$secret_file"' EXIT
chmod 600 "$secret_file"
secret_pairs=()
for key in "${required[@]}"; do
  secret_pairs+=("$key" "$(read_value "$key")")
done
printf '%s\0' "${secret_pairs[@]}" | python3 -c '
import json, pathlib, sys
values = sys.stdin.buffer.read().split(b"\0")
values = dict(zip(values[0::2], values[1::2]))
if any(not key or not value for key, value in values.items()):
    raise SystemExit("missing deployment secret")
pathlib.Path(sys.argv[1]).write_text(json.dumps({key.decode(): value.decode() for key, value in values.items()}))
' "$secret_file"
bunx wrangler deploy --config wrangler.jsonc --env development --name "$name" --secrets-file "$secret_file"

echo
echo "Isolated IROH v2 development Worker: https://${name}.${workers_subdomain}.workers.dev"
echo "Use this origin for the matching Mac and iOS dev build:"
echo "  CMUX_IROH_V2_BASE_URL=https://${name}.${workers_subdomain}.workers.dev"
echo "The shared development Worker remains unchanged."
