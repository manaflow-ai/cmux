#!/usr/bin/env bash
# Copy the TURN and APNs secrets from 1Password (vault Shared) into a cmux-next iOS API Worker.
# Values are piped straight from `op` into `wrangler secret put` and never printed. An empty value
# (a failed or timed-out `op` call) aborts before wrangler sees it.
#
# usage: cnx-ios/backend/scripts/put-secrets.sh dev|prod
set -euo pipefail
env=${1:?usage: put-secrets.sh dev|prod}
[[ "$env" == dev || "$env" == prod ]] || { echo "env must be dev or prod" >&2; exit 2; }
cd "$(dirname "$0")/.."

turn_item=lqvg75d4awzbveq7ny5gyfeyd4   # "Cloudflare TURN Server API Key"
apns_item=hid2ap53ult7b5gpllt3pqtyca   # "cmux-next iOS APNs Auth Key (dev.cmux.app.internal)"

put() { # name, then the value on stdin
  local value; value=$(cat)
  [[ -n "$value" ]] || { echo "error: empty value for $1 (is op signed in?)" >&2; exit 1; }
  printf '%s' "$value" | bunx wrangler@4 secret put "$1" --env "$env" >/dev/null
  echo "set $1 on env $env"
}

op item get "$turn_item" --fields notesPlain | grep -oE '[0-9a-f]{32}' | head -1 | tr -d '\n' | put TURN_KEY_ID
op read "op://Shared/$turn_item/credential" | tr -d '\n' | put TURN_KEY_API_TOKEN
op read "op://Shared/$apns_item/key_id" | tr -d '\n' | put APNS_KEY_ID
op read "op://Shared/$apns_item/team_id" | tr -d '\n' | put APNS_TEAM_ID
op document get "$apns_item" | put APNS_KEY_P8
