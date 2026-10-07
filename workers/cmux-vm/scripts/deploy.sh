#!/usr/bin/env bash
# Deploys the Worker to $TARGET (preview, staging or production) and installs
# its secrets. CI only: the values come from the GitHub environment and travel
# to wrangler on stdin, so they never appear in argv or logs.
set -euo pipefail

case "${TARGET:-}" in
  preview | staging | production) ;;
  *) echo "::error::TARGET must be preview, staging or production"; exit 1 ;;
esac

missing=()
for name in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID CMUX_VM_UPSTREAM_API_KEY CMUX_VM_STACK_PROJECT_ID CMUX_VM_STACK_SECRET_SERVER_KEY; do
  [ -n "${!name:-}" ] || missing+=("$name")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "::error::cmux VM $TARGET deploy is missing secrets: ${missing[*]}"
  exit 1
fi

bunx wrangler deploy --env "$TARGET"
printf '%s' "$CMUX_VM_UPSTREAM_API_KEY" | bunx wrangler secret put UPSTREAM_API_KEY --env "$TARGET"
printf '%s' "$CMUX_VM_STACK_PROJECT_ID" | bunx wrangler secret put STACK_PROJECT_ID --env "$TARGET"
printf '%s' "$CMUX_VM_STACK_SECRET_SERVER_KEY" | bunx wrangler secret put STACK_SECRET_SERVER_KEY --env "$TARGET"
