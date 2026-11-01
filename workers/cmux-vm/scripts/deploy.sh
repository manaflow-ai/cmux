#!/usr/bin/env bash
# Deploys the Worker to $TARGET (preview, staging or production) and installs its secrets.
# CI only. First it ensures the Hyperdrive config cmux-vm-$TARGET from
# CMUX_VM_DATABASE_URL (create if missing, else rewrite its origin: idempotent),
# then resolves its id by name, so no id is committed. Secret values travel to
# wrangler in a 0600 file that is removed afterwards; they never appear in
# argv or logs.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${TARGET:-}" in
  preview | staging | production) ;;
  *) echo "::error::TARGET must be preview, staging or production"; exit 1 ;;
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

# CMUX_VM_SERVICE_KEYS_EXTRA and CMUX_VM_SERVICE_KEYS_CLOUD_PLATFORM (both optional) hold more
# service key entries, appended to CMUX_VM_SERVICE_KEYS, so a key is added without reading back or
# rewriting a write-only secret (each one is its own environment secret; CLOUD_PLATFORM holds
# cmux-platform's Cloud driver key). Checked here, before anything deploys: each must be a JSON
# array, ids and hashes unique across all of them (the Worker turns every service key off on a
# duplicate). Values never reach the log.
service_keys="${CMUX_VM_SERVICE_KEYS:-}"
extras=()
for name in CMUX_VM_SERVICE_KEYS_EXTRA CMUX_VM_SERVICE_KEYS_CLOUD_PLATFORM; do
  if [ -n "${!name:-}" ]; then extras+=("$name"); fi
done
if [ "${#extras[@]}" -gt 0 ]; then
  if [ -z "$service_keys" ]; then
    echo "::error::${extras[0]} is set without CMUX_VM_SERVICE_KEYS; refusing to replace the Worker's service keys with the extra entries alone"
    exit 1
  fi
  for name in CMUX_VM_SERVICE_KEYS "${extras[@]}"; do
    if ! printf '%s' "${!name}" | jq -e 'type == "array"' >/dev/null 2>&1; then
      echo "::error::$name is not a JSON array"
      exit 1
    fi
  done
  for name in "${extras[@]}"; do
    service_keys="$(jq -cn --arg a "$service_keys" --arg b "${!name}" '($a | fromjson) + ($b | fromjson)' 2>/dev/null)"
  done
  if ! printf '%s' "$service_keys" | jq -e '([.[].id] | length == (unique | length)) and ([.[].sha256] | length == (unique | length))' >/dev/null 2>&1; then
    echo "::error::CMUX_VM_SERVICE_KEYS and ${extras[*]} share a service key id or hash"
    exit 1
  fi
fi

umask 077
secrets="$(mktemp)"
trap 'rm -f "$secrets"' EXIT
jq -n \
  --arg upstream "$CMUX_VM_UPSTREAM_API_KEY" \
  --arg project "$CMUX_VM_STACK_PROJECT_ID" \
  --arg server "$CMUX_VM_STACK_SECRET_SERVER_KEY" \
  --arg service_keys "$service_keys" \
  '{UPSTREAM_API_KEY: $upstream, STACK_PROJECT_ID: $project, STACK_SECRET_SERVER_KEY: $server}
   + (if $service_keys == "" then {} else {CMUX_VM_SERVICE_KEYS: $service_keys} end)' > "$secrets"

# Until the secrets land the Worker answers 503 "not configured" (src/index.ts).
bunx wrangler deploy --config wrangler.generated.json --env "$TARGET"
bunx wrangler secret bulk "$secrets" --config wrangler.generated.json --env "$TARGET"
worker="$(jq -r --arg t "$TARGET" '.env[$t].name' wrangler.generated.json)"
bash scripts/custom-domains.sh "$worker"
