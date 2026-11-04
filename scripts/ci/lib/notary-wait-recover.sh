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
