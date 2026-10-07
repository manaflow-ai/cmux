#!/usr/bin/env bash
# Deploys the Worker to $TARGET (preview or staging) and installs its secrets.
# CI only. First it ensures the Hyperdrive config cmux-vm-$TARGET from
# CMUX_VM_DATABASE_URL (create if missing, else rewrite its origin: idempotent),
# then resolves its id by name, so no id is committed. Secret values travel to
# wrangler in a 0600 file that is removed afterwards; they never appear in
# argv or logs.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${TARGET:-}" in
  preview | staging) ;;
  *) echo "::error::TARGET must be preview or staging"; exit 1 ;;
esac

missing=()
for name in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID CMUX_VM_DATABASE_URL CMUX_VM_UPSTREAM_API_KEY CMUX_VM_STACK_PROJECT_ID CMUX_VM_STACK_SECRET_SERVER_KEY; do
  [ -n "${!name:-}" ] || missing+=("$name")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "::error::cmux VM $TARGET deploy is missing secrets: ${missing[*]}"
  exit 1
fi

bash scripts/hyperdrive.sh ensure "cmux-vm-$TARGET"
hyperdrive_id="$(bash scripts/hyperdrive.sh resolve "cmux-vm-$TARGET")"
# Each lane branch (feat-cmux-vm-<lane>) gets its own preview Worker,
# cmux-vm-preview-<lane>; all previews share the cmux-vm-preview Hyperdrive config.
lane=""
if [ "$TARGET" = preview ]; then
  lane="$(printf '%s' "${GITHUB_REF_NAME:-}" | sed -e 's/^feat-cmux-vm-//' | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | cut -c1-31 | sed -e 's/^-*//' -e 's/-*$//')"
  if [ -z "$lane" ]; then
    echo "::error::preview deploys need a feat-cmux-vm-<lane> branch (GITHUB_REF_NAME)"
    exit 1
  fi
fi
node scripts/wrangler-config.mjs "$TARGET" "$hyperdrive_id" $lane

umask 077
secrets="$(mktemp)"
trap 'rm -f "$secrets"' EXIT
jq -n \
  --arg upstream "$CMUX_VM_UPSTREAM_API_KEY" \
  --arg project "$CMUX_VM_STACK_PROJECT_ID" \
  --arg server "$CMUX_VM_STACK_SECRET_SERVER_KEY" \
  '{UPSTREAM_API_KEY: $upstream, STACK_PROJECT_ID: $project, STACK_SECRET_SERVER_KEY: $server}' > "$secrets"

# Until the secrets land the Worker answers 503 "not configured" (src/index.ts).
bunx wrangler deploy --config wrangler.generated.json --env "$TARGET"
bunx wrangler secret bulk "$secrets" --config wrangler.generated.json --env "$TARGET"
worker="$(jq -r --arg t "$TARGET" '.env[$t].name' wrangler.generated.json)"
bash scripts/custom-domains.sh "$worker"
