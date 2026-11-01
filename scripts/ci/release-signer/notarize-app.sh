#!/usr/bin/env bash
# Notarize and staple a signed .app bundle with the release signer.
#
#   scripts/ci/release-signer/notarize-app.sh <app-path> <log-file>
#
# Submits the bundle to Apple's notary service, waits up to
# NOTARY_MAX_WAIT_SECONDS (default 1200), fails unless Apple accepts it, then
# staples the ticket into the bundle. The submission id goes to stdout as
# submission_id=<uuid> (for $GITHUB_OUTPUT), and a run without one fails; the signer's output goes to
# <log-file> and stderr. Not used by any workflow yet.
#
# Env: ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64 (the notary API
# key), CMUX_SIGNER (the signer binary, from install.sh). The key exists only in
# a mktemp -d directory (umask 077) that the EXIT trap removes, never on a
# command line or in a signer process's environment.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 <app-path> <log-file>" >&2; exit 2; }
APP="${1%/}" LOG="$2"
R="${CMUX_SIGNER:?CMUX_SIGNER names the signer binary}"
[[ -d "$APP/Contents" ]] || { echo "error: app bundle not found at $APP" >&2; exit 1; }
command -v "$R" >/dev/null || { echo "error: signer binary not found ($R)" >&2; exit 1; }
: "${ASC_API_KEY_ID:?}" "${ASC_API_ISSUER_ID:?}" "${ASC_API_KEY_P8_BASE64:?}"
[[ "$ASC_API_KEY_ID" =~ ^[A-Za-z0-9]+$ ]] || { echo "error: ASC_API_KEY_ID is not a key id" >&2; exit 1; }
# shellcheck source=signer-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/signer-env.sh"

secrets=""
trap 'rm -rf ${secrets:+"$secrets"}' EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
secrets="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/cmux-app-notary.XXXXXX")"
(umask 077 && printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 -d > "$secrets/AuthKey_${ASC_API_KEY_ID}.p8") 2>/dev/null ||
  { echo "error: ASC_API_KEY_P8_BASE64 is not valid base64" >&2; exit 1; }
[[ -s "$secrets/AuthKey_${ASC_API_KEY_ID}.p8" ]] || { echo "error: ASC_API_KEY_P8_BASE64 decoded to nothing" >&2; exit 1; }
unset ASC_API_KEY_P8_BASE64
(umask 077 && run_signer "$R" encode-app-store-connect-api-key --config-file /dev/null -o "$secrets/api-key.json" \
  "$ASC_API_ISSUER_ID" "$ASC_API_KEY_ID" "$secrets/AuthKey_${ASC_API_KEY_ID}.p8" >/dev/null)
rm -f "$secrets/AuthKey_${ASC_API_KEY_ID}.p8"

# --staple waits for Apple's answer and fails unless it is Accepted (printing
# the notary log), then staples the ticket into the bundle.
echo "==> notarizing and stapling ${APP##*/}" >&2
rc=0
run_signer "$R" notary-submit --config-file /dev/null --api-key-file "$secrets/api-key.json" \
  --max-wait-seconds "${NOTARY_MAX_WAIT_SECONDS:-1200}" --staple "$APP" > "$LOG" 2>&1 || rc=$?
cat "$LOG" >&2
id="$(grep -oiE 'submission id:? *[0-9a-f-]{36}' "$LOG" | grep -oE '[0-9a-f-]{36}' | head -n 1 || true)"
[[ -z "$id" ]] || echo "submission_id=$id"
[[ "$rc" -eq 0 ]] || { echo "error: ${APP##*/} was not notarized and stapled (exit $rc, submission ${id:-none})" >&2; exit 1; }
[[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
  { echo "error: the notary log names no submission id" >&2; exit 1; }
[[ -f "$APP/Contents/CodeResources" ]] || { echo "error: no stapled ticket in ${APP##*/}" >&2; exit 1; }
echo "==> ${APP##*/} is notarized and stapled (submission $id)" >&2
