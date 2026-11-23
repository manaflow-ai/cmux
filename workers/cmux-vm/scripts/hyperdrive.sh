#!/usr/bin/env bash
# Hyperdrive configs for the cmux VM Worker, by name, through the Cloudflare API.
#
#   hyperdrive.sh resolve <name>   prints the config id (only the id) or fails
#   hyperdrive.sh ensure  <name>   creates <name> from CMUX_VM_DATABASE_URL, or
#                                  updates its origin; prints name and id only
#   hyperdrive.sh show    <name>   prints the id, origin port and origin_connection_limit
#   hyperdrive.sh restart <name>   drains the config's connection pool (its origin connections, all the
#                                  Worker role's) and starts a new one; the config itself is unchanged
#   hyperdrive.sh limit   <name>   sets only origin_connection_limit (PATCH, no origin check, so it works
#                                  while the database is full); ensure runs it before its PUT
#
# ensure sets origin_connection_limit, the most connections Hyperdrive opens to the database. Unset, Cloudflare's
# paid default is 60, and the staging branch has max_connections 25 (3 reserved): on 2026-11-09 the Worker's pool
# took every slot from 21:49Z and every deploy stopped at the ordering gate with 53300 (cmux#39920 measured it:
# 12 of 13 backends were Hyperdrive's). So staging gets 10 and preview 5, which leaves room for the gate,
# migrate-staging, the preview pool and an admin. Hyperdrive's limit is soft, so it stays well under the slots.
# Production keeps its current limit. HYPERDRIVE_ORIGIN_CONNECTION_LIMIT (5..100) overrides it.
#
# Needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID (and CMUX_VM_DATABASE_URL
# for ensure). Never prints the token, the database URL or response bodies.
set -euo pipefail

command="${1:-}"
config_name="${2:-}"
case "$config_name" in
  cmux-vm-staging) default_limit=10 ;;
  cmux-vm-preview) default_limit=5 ;;
  cmux-vm-production) default_limit="" ;;
  *) echo "::error::config name must be cmux-vm-preview, cmux-vm-staging or cmux-vm-production" >&2; exit 2 ;;
esac
export HYPERDRIVE_ORIGIN_CONNECTION_LIMIT="${HYPERDRIVE_ORIGIN_CONNECTION_LIMIT:-$default_limit}"
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
  local codes messages
  codes="$(jq -r '[.errors[]?.code] | map(tostring) | join(",")' "$work/body" 2>/dev/null || true)"
  # The messages say why (2015 is Cloudflare's catch-all "could not connect"); anything shaped like a URL's
  # credentials is cut out first, and GitHub masks the secret values themselves.
  messages="$(jq -r '[.errors[]?.message] | join("; ")' "$work/body" 2>/dev/null | sed -E 's#[a-zA-Z][a-zA-Z0-9+.-]*://[^[:space:]]*@#<redacted>@#g' | cut -c1-300 || true)"
  echo "::error::$1: HTTP $2 cloudflare error codes [${codes}]: ${messages}" >&2
  exit 1
}

# patch_limit ID: PATCH only origin_connection_limit. Cloudflare checks the origin on a PUT (error 2015 while the
# database is full, which is when the limit matters most), so the limit goes first and alone.
patch_limit() {
  [ -n "$HYPERDRIVE_ORIGIN_CONNECTION_LIMIT" ] || return 0
  if ! [[ "$HYPERDRIVE_ORIGIN_CONNECTION_LIMIT" =~ ^[0-9]+$ ]] || [ "$HYPERDRIVE_ORIGIN_CONNECTION_LIMIT" -lt 5 ] || [ "$HYPERDRIVE_ORIGIN_CONNECTION_LIMIT" -gt 100 ]; then
    echo "::error::HYPERDRIVE_ORIGIN_CONNECTION_LIMIT must be a whole number from 5 to 100" >&2
    exit 1
  fi
  printf '{"origin_connection_limit":%s}' "$HYPERDRIVE_ORIGIN_CONNECTION_LIMIT" > "$work/limit.json"
  local code
  code="$(call PATCH "$api/$1" "$work/limit.json")"
  [ "$code" = 200 ] || fail "setting origin_connection_limit on Hyperdrive config $config_name" "$code"
  echo "Hyperdrive config $config_name: origin_connection_limit $(jq -r '.result.origin_connection_limit // "?"' "$work/body")"
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
      const limit = process.env.HYPERDRIVE_ORIGIN_CONNECTION_LIMIT || "";
      if (limit && !(/^[0-9]+$/.test(limit) && Number(limit) >= 5 && Number(limit) <= 100)) { console.error("::error::HYPERDRIVE_ORIGIN_CONNECTION_LIMIT must be a whole number from 5 to 100"); process.exit(1); }
      const body = {
        name: process.env.CONFIG_NAME,
        ...(limit ? { origin_connection_limit: Number(limit) } : {}),
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
      patch_limit "$id"
      # Cloudflare connects to the origin before it takes an update, and refuses with error 2015 while the
      # database is out of connection slots (cmux-vm.yml staging, 2026-11-09): try again twice, 20 s apart.
      for attempt in 1 2 3; do
        code="$(call PUT "$api/$id" "$work/request.json")"
        [ "$code" != 200 ] && [ "$attempt" -lt 3 ] && jq -e '[.errors[]?.code] | index(2015)' "$work/body" >/dev/null 2>&1 || break
        echo "::warning::updating Hyperdrive config $config_name: Cloudflare could not reach the database (2015); trying again in 20 s" >&2
        sleep 20
      done
      [ "$code" = 200 ] || fail "updating Hyperdrive config $config_name" "$code"
      action=updated
    fi
    id="$(jq -r '.result.id' "$work/body")"
    limit="$(jq -r '.result.origin_connection_limit // "default"' "$work/body")"
    echo "Hyperdrive config $config_name $action: id $id, origin_connection_limit $limit"
    ;;
  show)
    id="$(find_id)"
    [ -n "$id" ] || { echo "::error::Hyperdrive config $config_name does not exist" >&2; exit 1; }
    code="$(call GET "$api/$id")"
    [ "$code" = 200 ] || fail "reading Hyperdrive config $config_name" "$code"
    jq -r --arg name "$config_name" '"Hyperdrive config \($name): id \(.result.id), origin port \(.result.origin.port // "?"), origin_connection_limit \(.result.origin_connection_limit // "default (60 on paid plans)"), caching \(if .result.caching.disabled then "off" else "on" end)"' "$work/body"
    ;;
  restart)
    id="$(find_id)"
    [ -n "$id" ] || { echo "::error::Hyperdrive config $config_name does not exist" >&2; exit 1; }
    code="$(call POST "$api/$id/restart")"
    [ "$code" = 200 ] || fail "restarting Hyperdrive config $config_name" "$code"
    echo "Hyperdrive config $config_name: pool restarted ($(jq -r '.result.restarted_on // "?"' "$work/body"))"
    ;;
  limit)
    id="$(find_id)"
    [ -n "$id" ] || { echo "::error::Hyperdrive config $config_name does not exist" >&2; exit 1; }
    [ -n "$HYPERDRIVE_ORIGIN_CONNECTION_LIMIT" ] || { echo "::error::no origin_connection_limit for $config_name" >&2; exit 1; }
    patch_limit "$id"
    ;;
  *)
    echo "usage: hyperdrive.sh resolve|ensure|show|restart|limit <cmux-vm-preview|cmux-vm-staging|cmux-vm-production>" >&2
    exit 2
    ;;
esac
