#!/usr/bin/env bash
# notary_wait_recover <output file> <timeout>: after `notarytool submit --wait`
# exited nonzero, finish the wait on the submission it already made.
#
# notarytool uploads, then polls Apple; a transport error while polling (run
# 41801811362: "A TLS error caused the secure connection to fail", NSURLErrorDomain
# -1200) ends it nonzero with no JSON, so the build failed although Apple had the
# submission. The error still names it (.../notary/v2/submissions/<id>), so this
# waits on that id with `notarytool wait`, up to NOTARY_RECOVER_ATTEMPTS times,
# and appends each wait's JSON to the output file, where extract_notary_value
# reads the newest id and status. It returns the last wait's exit, or 1 when the
# output names no submission or already holds one (a real failure or timeout,
# which the caller handles as before). Needs XCRUN_TOOL and NOTARY_AUTH_ARGS.
notary_wait_recover() {
  local output="$1" timeout="$2" id attempt rc=1
  if grep -Eq '"id"[[:space:]]*:' "$output"; then
    return 1
  fi
  id="$(grep -Eo 'notary/v2/submissions/[A-Za-z0-9-]+' "$output" | tail -n 1 | sed 's|.*/||')"
  if [ -z "$id" ]; then
    return 1
  fi
  for attempt in $(seq 1 "${NOTARY_RECOVER_ATTEMPTS:-3}"); do
    echo "notarytool lost its connection to Apple after submitting $id; waiting on that submission (try $attempt)" >&2
    set +e
    "$XCRUN_TOOL" notarytool wait "$id" ${NOTARY_AUTH_ARGS[@]+"${NOTARY_AUTH_ARGS[@]}"} \
      --output-format json --timeout "$timeout" >>"$output" 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] || grep -Eiq 'timeout|timed out' "$output"; then
      break
    fi
    sleep "${NOTARY_RECOVER_SLEEP_SECONDS:-20}"
  done
  return "$rc"
}

# notary_submit_retry <output file> <submit command...>: after a submit exited
# nonzero, run it again when it never reached Apple.
#
# Run 42289209031 failed the NEXT nightly 11 s into its DMG submit on
# "Error: HTTPClientError.connectTimeout": notarytool never connected, so Apple had
# no submission and nothing was left to wait on. When the output names no
# submission (no "id" and no .../submissions/<id>) and shows a connect-phase
# failure, this runs the same command up to NOTARY_SUBMIT_RETRIES more times. Each
# run replaces the output file, so the caller and the next check read only the
# newest attempt (an earlier attempt's connectTimeout would read as a wait
# timeout); earlier attempts go to stderr, the job log. It returns the last run's exit,
# or 1 when there was nothing to retry (a named submission, Apple's answer or a
# refused upload, which the caller handles as before).
notary_submit_retry() {
  local output="$1" attempt rc=1
  shift
  for attempt in $(seq 1 "${NOTARY_SUBMIT_RETRIES:-2}"); do
    if grep -Eq '"id"[[:space:]]*:|notary/v2/submissions/[A-Za-z0-9-]+' "$output" \
      || ! grep -Eiq 'connectTimeout|cannotConnectToHost|Could not connect|network connection was lost|NSURLErrorDomain Code=-10(01|03|04|05|09)([^0-9]|$)' "$output"; then
      return "$rc"
    fi
    sleep "${NOTARY_SUBMIT_RETRY_SLEEP_SECONDS:-30}"
    {
      echo "notarytool did not reach Apple; submitting again (try $attempt). The attempt before it said:"
      cat "$output"
    } >&2
    set +e
    "$@" >"$output" 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
  done
  return "$rc"
}
