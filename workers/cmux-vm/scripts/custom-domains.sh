#!/usr/bin/env bash
# Attaches the Worker's custom domains (custom-domains.generated.txt, written by
# wrangler-config.mjs) through the account Workers domains API. Idempotent: a
# PUT for a hostname already bound to this Worker changes nothing. Refuses a
# hostname bound to another Worker instead of moving it.
#
#   custom-domains.sh <worker name>
#
# Needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID. Never prints the token
# or response bodies.
set -euo pipefail
cd "$(dirname "$0")/.."

worker="${1:?worker name required}"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is required}"
list="custom-domains.generated.txt"
[ -s "$list" ] || { echo "no custom domains for $worker"; exit 0; }

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'Authorization: Bearer %s\n' "$CLOUDFLARE_API_TOKEN" > "$work/auth"
api="https://api.cloudflare.com/client/v4"
call() {
  local args=(-sS -o "$work/body" -w '%{http_code}' -X "$1" -H @"$work/auth")
  if [ -n "${3:-}" ]; then args+=(-H 'Content-Type: application/json' --data-binary @"$3"); fi
  curl "${args[@]}" "$2" || echo 000
}
fail() {
  local codes
  codes="$(jq -r '[.errors[]?.code] | map(tostring) | join(",")' "$work/body" 2>/dev/null || true)"
  echo "::error::$1: HTTP $2 cloudflare error codes [${codes}]" >&2
  exit 1
}

while IFS= read -r host; do
  [ -n "$host" ] || continue
  # cmux VM publishes only under cmux.dev (CMUX-VM-API amendment 2).
  case "$host" in
    *.cmux.dev) zone_name="cmux.dev" ;;
    *) echo "::error::custom domain $host is outside cmux.dev" >&2; exit 1 ;;
  esac
  code="$(call GET "$api/zones?name=$zone_name")"
  [ "$code" = 200 ] || fail "zone lookup $zone_name" "$code"
  zone_id="$(jq -r '.result[0].id // empty' "$work/body")"
  [ -n "$zone_id" ] || { echo "::error::zone $zone_name not found" >&2; exit 1; }

  code="$(call GET "$api/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/domains?hostname=$host")"
  [ "$code" = 200 ] || fail "custom domain lookup $host" "$code"
  bound="$(jq -r --arg h "$host" '[.result[]? | select(.hostname == $h) | .service] | first // empty' "$work/body")"
  if [ -n "$bound" ] && [ "$bound" != "$worker" ]; then
    echo "::error::$host is bound to another Worker; refusing to move it" >&2
    exit 1
  fi

  jq -n --arg hostname "$host" --arg service "$worker" --arg zone_id "$zone_id" \
    '{hostname: $hostname, service: $service, zone_id: $zone_id, environment: "production"}' > "$work/req"
  code="$(call PUT "$api/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/domains" "$work/req")"
  [ "$code" = 200 ] || fail "attach $host" "$code"
  echo "custom domain $host -> $worker"
done < "$list"
