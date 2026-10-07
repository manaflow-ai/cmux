#!/usr/bin/env bash
# Deploys the Worker to $TARGET (preview or staging) and installs its secrets.
# CI only. The Hyperdrive id is resolved by name (cmux-vm-$TARGET) at deploy
# time, and secret values travel to wrangler in a 0600 file that is removed
# afterwards; they never appear in argv or logs.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${TARGET:-}" in
  preview | staging) ;;
  *) echo "::error::TARGET must be preview or staging"; exit 1 ;;
esac

missing=()
for name in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID CMUX_VM_UPSTREAM_API_KEY CMUX_VM_STACK_PROJECT_ID CMUX_VM_STACK_SECRET_SERVER_KEY; do
  [ -n "${!name:-}" ] || missing+=("$name")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "::error::cmux VM $TARGET deploy is missing secrets: ${missing[*]}"
  exit 1
fi

hyperdrive_id="$(bash scripts/hyperdrive.sh resolve "cmux-vm-$TARGET")"
node scripts/wrangler-config.mjs "$TARGET" "$hyperdrive_id"

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
