#!/usr/bin/env bash
# Builds the web app and deploys the mux-staging Worker.
# `cf deploy` 0.13 sends no Authorization header in its deploy step, so this
# runs wrangler with the cf CLI's OAuth token (refreshed by `cf auth whoami`).
# Secrets come from ~/.secrets; MUX_DEV_AUTH is always 0 here.
set -euo pipefail
cd "$(dirname "$0")/.."
(cd ../../apps/web && ../../node_modules/.bin/vp build >/dev/null)
cf auth whoami >/dev/null
CLOUDFLARE_API_TOKEN="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Preferences/cloudflare/config/default.json')))['oauth_token'])")"
export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID=0c1675e0def6de1ab3a50a4e17dc5656
umask 077
secrets="$(mktemp /tmp/mux-secrets.XXXXXX)"
trap 'rm -f "$secrets"' EXIT
(
  set -a
  . ~/.secrets/coderouter-chatmux2.env
  . ~/.secrets/cmuxterm-dev.env
  . ~/.secrets/cmux-dev-backend-providers.env
  printf 'CODEROUTER_API_KEY=%s\nMUX_STACK_PUBLISHABLE_CLIENT_KEY=%s\nFREESTYLE_API_KEY=%s\nMUX_DEV_AUTH=0\n' \
    "$CODEROUTER_API_KEY" "$NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY" "$FREESTYLE_API_KEY" > "$secrets"
)
./node_modules/.bin/wrangler deploy --experimental-new-config --secrets-file "$secrets"
