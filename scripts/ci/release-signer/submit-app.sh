#!/usr/bin/env bash
# Submit a signed .app bundle to Apple's notary service in the background, without
# waiting for Apple's answer (nightly.yml signer-app).
#
#   scripts/ci/release-signer/submit-app.sh start <app-path>
#   scripts/ci/release-signer/submit-app.sh finish
#
# `start` begins the upload (notary_submit, without --wait) in the background and
# returns at once, so the job's artifact upload runs beside Apple's. `finish` waits
# for it, prints its log, and writes submission_id=<uuid> to stdout (for
# $GITHUB_OUTPUT); it fails when the upload failed or named no submission. The
# caller must not change the bundle between the two. wait-app-notary.sh later waits
# for Apple's answer on that id, and the Mac DMG job staples the ticket it publishes.
#
# Env: ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64 (the notary API
# key, read by `start` only), CMUX_SIGNER (the signer binary, from install.sh). The key
# exists only in a mktemp -d directory (umask 077) that the background process's EXIT
# trap removes once the upload ends, never on a command line or in a signer process's
# environment.
set -euo pipefail

state_dir="${RUNNER_TEMP:?}/submit-app"
fifo="$state_dir/status.fifo"
log="$state_dir/submit.log"

case "${1:-}" in
  start)
    [[ $# -eq 2 ]] || { echo "usage: $0 start <app-path>" >&2; exit 2; }
    APP="${2%/}"
    R="${CMUX_SIGNER:?CMUX_SIGNER names the signer binary}"
    [[ -d "$APP/Contents" ]] || { echo "error: app bundle not found at $APP" >&2; exit 1; }
    command -v "$R" >/dev/null || { echo "error: signer binary not found ($R)" >&2; exit 1; }
    : "${ASC_API_KEY_ID:?}" "${ASC_API_ISSUER_ID:?}" "${ASC_API_KEY_P8_BASE64:?}"
    [[ "$ASC_API_KEY_ID" =~ ^[A-Za-z0-9]+$ ]] || { echo "error: ASC_API_KEY_ID is not a key id" >&2; exit 1; }
    rm -rf "$state_dir"
    mkdir -p "$state_dir"
    mkfifo "$fifo"
    # The subshell writes its status into the FIFO; that write blocks until `finish`
    # opens the FIFO, so the status is never lost and nothing polls.
    (
      status=0
      bash "$0" run "$APP" || status=$?
      echo "$status" >"$fifo"
    ) >"$log" 2>&1 </dev/null &
    echo "notarization upload of ${APP##*/} started (PID $!); submit-app.sh finish waits for it"
    ;;
  run)
    APP="$2"
    R="$CMUX_SIGNER"
    # shellcheck source=signer-env.sh
    source "$(dirname "${BASH_SOURCE[0]}")/signer-env.sh"
    secrets=""
    trap 'rm -rf ${secrets:+"$secrets"}' EXIT
    trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
    secrets="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/cmux-app-submit.XXXXXX")"
    (umask 077 && printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 -d > "$secrets/AuthKey_${ASC_API_KEY_ID}.p8") 2>/dev/null ||
      { echo "error: ASC_API_KEY_P8_BASE64 is not valid base64" >&2; exit 1; }
    [[ -s "$secrets/AuthKey_${ASC_API_KEY_ID}.p8" ]] || { echo "error: ASC_API_KEY_P8_BASE64 decoded to nothing" >&2; exit 1; }
    unset ASC_API_KEY_P8_BASE64
    (umask 077 && run_signer "$R" encode-app-store-connect-api-key --config-file /dev/null -o "$secrets/api-key.json" \
      "$ASC_API_ISSUER_ID" "$ASC_API_KEY_ID" "$secrets/AuthKey_${ASC_API_KEY_ID}.p8" >/dev/null)
    rm -f "$secrets/AuthKey_${ASC_API_KEY_ID}.p8"
    echo "==> submitting ${APP##*/} for notarization"
    notary_submit "$R" --config-file /dev/null --api-key-file "$secrets/api-key.json" "$APP"
    ;;
  finish)
    [[ -p "$fifo" ]] || { echo "error: submit-app.sh start did not run" >&2; exit 1; }
    status=""
    read -r status <"$fifo" || true
    cat "$log" >&2
    id="$(grep -oiE 'submission id:? *[0-9a-f-]{36}' "$log" | grep -oE '[0-9a-f-]{36}' | head -n 1 || true)"
    [[ "$status" == 0 ]] || { echo "error: the notarization upload failed (status ${status:-none}, submission ${id:-none})" >&2; exit 1; }
    [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
      { echo "error: the notary output names no submission id" >&2; exit 1; }
    echo "submission_id=$id"
    echo "==> uploaded for notarization (submission $id); Apple's answer is awaited later" >&2
    ;;
  *)
    echo "usage: $0 start <app-path> | finish" >&2
    exit 2
    ;;
esac
