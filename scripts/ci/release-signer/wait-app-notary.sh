#!/usr/bin/env bash
# Wait for Apple's answer on an app submission submit-app.sh made, and fail unless
# Apple accepted it (nightly.yml signer-dmg, before the DMG is signed).
#
#   scripts/ci/release-signer/wait-app-notary.sh <submission-id>
#
# The Mac DMG job has already stapled the ticket Apple publishes only for an accepted
# submission, so this normally answers at once; it keeps the explicit Accepted check
# in front of the DMG, as signer-app-notary's --wait did. Waits up to
# NOTARY_MAX_WAIT_SECONDS (default 1200), then reads the notary log and checks its
# status is Accepted.
#
# Env: ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64 (the notary API key),
# CMUX_SIGNER (the signer binary, from install.sh). The key exists only in a mktemp -d
# directory (umask 077) that the EXIT trap removes.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <submission-id>" >&2; exit 2; }
ID="$1"
R="${CMUX_SIGNER:?CMUX_SIGNER names the signer binary}"
[[ "$ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
  { echo "error: '$ID' is not a submission id" >&2; exit 1; }
command -v "$R" >/dev/null || { echo "error: signer binary not found ($R)" >&2; exit 1; }
: "${ASC_API_KEY_ID:?}" "${ASC_API_ISSUER_ID:?}" "${ASC_API_KEY_P8_BASE64:?}"
[[ "$ASC_API_KEY_ID" =~ ^[A-Za-z0-9]+$ ]] || { echo "error: ASC_API_KEY_ID is not a key id" >&2; exit 1; }
# shellcheck source=signer-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/signer-env.sh"

secrets=""
trap 'rm -rf ${secrets:+"$secrets"}' EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
secrets="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/cmux-app-wait.XXXXXX")"
(umask 077 && printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 -d > "$secrets/AuthKey_${ASC_API_KEY_ID}.p8") 2>/dev/null ||
  { echo "error: ASC_API_KEY_P8_BASE64 is not valid base64" >&2; exit 1; }
[[ -s "$secrets/AuthKey_${ASC_API_KEY_ID}.p8" ]] || { echo "error: ASC_API_KEY_P8_BASE64 decoded to nothing" >&2; exit 1; }
unset ASC_API_KEY_P8_BASE64
(umask 077 && run_signer "$R" encode-app-store-connect-api-key --config-file /dev/null -o "$secrets/api-key.json" \
  "$ASC_API_ISSUER_ID" "$ASC_API_KEY_ID" "$secrets/AuthKey_${ASC_API_KEY_ID}.p8" >/dev/null)
rm -f "$secrets/AuthKey_${ASC_API_KEY_ID}.p8"

echo "==> waiting for Apple's answer on submission $ID"
run_signer "$R" notary-wait --config-file /dev/null --api-key-file "$secrets/api-key.json" \
  --max-wait-seconds "${NOTARY_MAX_WAIT_SECONDS:-1200}" "$ID" > "$secrets/wait.log" 2>&1 || true
cat "$secrets/wait.log"
# notary-wait fetches the log once and can fail when it is not ready yet, so the log is
# read here (a few bounded tries) and its status decides.
for attempt in 1 2 3 4; do
  run_signer "$R" notary-log --config-file /dev/null --api-key-file "$secrets/api-key.json" "$ID" \
    > "$secrets/notary-log.json" 2> "$secrets/log" &&
    python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "$secrets/notary-log.json" 2>/dev/null && break
  tail -5 "$secrets/log" >&2
  (( attempt < 4 )) || { echo "error: the notary log of submission $ID is not readable" >&2; exit 1; }
  sleep "${CMUX_NOTARY_LOG_RETRY_SECONDS:-15}"
done
status="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$secrets/notary-log.json")"
[[ "$status" == Accepted ]] || { cat "$secrets/notary-log.json" >&2; echo "error: Apple answered '$status' for submission $ID" >&2; exit 1; }
echo "==> Apple accepted submission $ID" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
