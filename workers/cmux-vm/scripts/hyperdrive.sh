#!/usr/bin/env bash
# Hyperdrive configs for the cmux VM Worker, by name, through the Cloudflare API.
#
#   hyperdrive.sh resolve <name>   prints the config id (only the id) or fails
#   hyperdrive.sh ensure  <name>   creates <name> from CMUX_VM_DATABASE_URL, or
#                                  updates its origin; prints name and id only
#
# Needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID (and CMUX_VM_DATABASE_URL
# for ensure). Never prints the token, the database URL or response bodies.
set -euo pipefail

command="${1:-}"
config_name="${2:-}"
case "$config_name" in
  cmux-vm-preview | cmux-vm-staging | cmux-vm-production) ;;
  *) echo "::error::config name must be cmux-vm-preview, cmux-vm-staging or cmux-vm-production" >&2; exit 2 ;;
esac
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is required}"

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'Authorization: Bearer %s\n' "$CLOUDFLARE_API_TOKEN" > "$work/auth"
api="https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/hyperdrive/configs"

# call METHOD URL [BODY_FILE] -> HTTP code; response body in $work/body.
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

find_id() {
  local code
  code="$(call GET "$api?per_page=100")"
  [ "$code" = 200 ] || fail "listing Hyperdrive configs" "$code"
  jq -r --arg name "$config_name" '[.result[] | select(.name == $name) | .id] | if length > 1 then error("duplicate") else (.[0] // "") end' "$work/body"
}

case "$command" in
  resolve)
    id="$(find_id)"
    [ -n "$id" ] || { echo "::error::Hyperdrive config $config_name does not exist; run the hyperdrive ensure job" >&2; exit 1; }
    printf '%s\n' "$id"
    ;;
  ensure)
    : "${CMUX_VM_DATABASE_URL:?CMUX_VM_DATABASE_URL is required}"
    # Builds the request body from the URL without echoing it.
    CONFIG_NAME="$config_name" node --input-type=module -e '
      import { writeFileSync } from "node:fs";
      const url = new URL(process.env.CMUX_VM_DATABASE_URL);
      if (!/^postgres(ql)?:$/.test(url.protocol)) { console.error("::error::CMUX_VM_DATABASE_URL must be a postgres URL"); process.exit(1); }
      const database = decodeURIComponent(url.pathname.replace(/^\//, ""));
      if (!url.hostname || !url.username || !url.password || !database) { console.error("::error::CMUX_VM_DATABASE_URL needs host, user, password and database"); process.exit(1); }
      const body = {
        name: process.env.CONFIG_NAME,
        origin: {
          scheme: "postgres",
          host: url.hostname,
          port: url.port ? Number(url.port) : 5432,
          database,
          user: decodeURIComponent(url.username),
          password: decodeURIComponent(url.password),
        },
      };
      writeFileSync(process.argv[1], JSON.stringify(body));
    ' "$work/request.json"
    id="$(find_id)"
    if [ -z "$id" ]; then
      code="$(call POST "$api" "$work/request.json")"
      [ "$code" = 200 ] || fail "creating Hyperdrive config $config_name" "$code"
      action=created
    else
      code="$(call PUT "$api/$id" "$work/request.json")"
      [ "$code" = 200 ] || fail "updating Hyperdrive config $config_name" "$code"
      action=updated
    fi
    id="$(jq -r '.result.id' "$work/body")"
    echo "Hyperdrive config $config_name $action: id $id"
    ;;
  *)
    echo "usage: hyperdrive.sh resolve|ensure <cmux-vm-preview|cmux-vm-staging|cmux-vm-production>" >&2
    exit 2
    ;;
esac
