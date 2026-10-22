#!/usr/bin/env bash
# check-dev-env-files.sh <dev secrets file> <web dir>
#
# Refuses local dev when a web env file that Next.js loads carries production
# markers. Prints file names and KEY NAMES only, never a value. Called by
# load-dev-env.sh; bypass for one run (humans only): CMUX_ALLOW_NONDEV_ENV_FILES=1.
#
# A file is refused when:
#   - VERCEL_ENV or VERCEL_TARGET_ENV is production or preview;
#   - NEXT_PUBLIC_STACK_PROJECT_ID or STACK_PROJECT_ID differs from the dev id
#     in the dev secrets file (an allowlist; no dev id means refuse);
#   - PGHOST, DATABASE_URL, DIRECT_DATABASE_URL or POSTGRES_URL* has a host
#     other than a local or Docker host.
# Why: local web/.env.local files once held non-development values, and a sync
# then copied them to a shared build machine.

set -uo pipefail

dev_secrets="${1:?dev secrets file}"
web_dir="${2:?web dir}"

dev_id="$(awk '
  { sub(/^[[:space:]]*export[[:space:]]+/, "") }
  /^(NEXT_PUBLIC_STACK_PROJECT_ID|STACK_PROJECT_ID)[[:space:]]*=/ {
    v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
    if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
    if (v != "") { print v; exit }
  }' "$dev_secrets" 2>/dev/null)"

status=0
for name in .env .env.local .env.development .env.development.local .env.production.local; do
  file="$web_dir/$name"
  [[ -f "$file" ]] || continue
  if ! report="$(DEV_ID="$dev_id" awk -v file="$name" '
    function unquote(v) {
      sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
      return v
    }
    function local_host(h) {
      h = tolower(h)
      return h == "" || h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]" || \
             h == "0.0.0.0" || h == "postgres" || h == "db" || h == "database" || h == "host.docker.internal"
    }
    function url_host(u,   rest) {
      rest = u
      sub(/^[A-Za-z][A-Za-z0-9+.-]*:\/\//, "", rest)
      sub(/[\/?#].*$/, "", rest)
      sub(/^.*@/, "", rest)
      if (rest ~ /^\[/) { sub(/\].*$/, "]", rest); return rest }
      sub(/:.*$/, "", rest)
      return rest
    }
    function flag(key, why) { printf "  %s: %s (%s)\n", file, key, why; bad = 1 }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      if (line !~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) next
      key = line; sub(/[[:space:]]*=.*$/, "", key)
      value = line; sub(/^[^=]*=/, "", value); value = unquote(value)
      if (value == "") next
      if (key == "VERCEL_ENV" || key == "VERCEL_TARGET_ENV") {
        if (tolower(value) == "production" || tolower(value) == "preview") flag(key, "non-development Vercel environment")
      } else if (key == "NEXT_PUBLIC_STACK_PROJECT_ID" || key == "STACK_PROJECT_ID") {
        if (ENVIRON["DEV_ID"] == "") flag(key, "no dev Stack id to compare against")
        else if (value != ENVIRON["DEV_ID"]) flag(key, "not the dev Stack project")
      } else if (key == "PGHOST") {
        if (!local_host(value)) flag(key, "non-local database host")
      } else if (key == "DATABASE_URL" || key == "DIRECT_DATABASE_URL" || key ~ /^POSTGRES_(URL|PRISMA_URL)/) {
        if (!local_host(url_host(value))) flag(key, "non-local database host")
      }
    }
    END { exit bad ? 1 : 0 }' "$file")"; then
    [[ "$status" == 0 ]] && echo "Refusing to start local dev: web env files carry non-development values:" >&2
    printf '%s\n' "$report" >&2
    status=1
  fi
done

if [[ "$status" != 0 ]]; then
  {
    echo "Local dev reads Stack and web secrets from ~/.secrets/cmuxterm-dev.env; these files override it."
    echo "Move the listed files out of web/ (they may hold production credentials; report them), then rerun."
    echo "Pull development-only env with cmuxterm-hq scripts/dev-env-pull.sh. Values were not printed."
  } >&2
fi
exit "$status"
