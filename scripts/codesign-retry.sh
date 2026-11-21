#!/usr/bin/env bash
# codesign-retry.sh ARGS...: codesign ARGS, run again when only Apple's timestamp service failed.
#
# A Developer ID signature with --timestamp asks Apple's timestamp server for a secure timestamp. When that
# server does not answer, codesign exits 1 with "The timestamp service is not available." or "A timestamp
# was expected but was not found." and the whole signing step fails: nightly-next runs 43587666320 (the
# app), 43595656749 (WebRTC.framework) and 43649298848 (libvk_swiftshader.dylib, sign-cef.sh), 2026-11-14,
# each a red nightly and up to 63 min more until the next one published. Every caller passes --force, so
# signing again is the same signature; any other failure exits at once with codesign's own status.
#
# Env: CMUX_CODESIGN_TOOL (default /usr/bin/codesign; tests), CMUX_CODESIGN_TIMESTAMP_TRIES (default 4),
# CMUX_CODESIGN_RETRY_DELAY seconds before the first retry, doubled each time (default 15).
set -uo pipefail

tool="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"
tries="${CMUX_CODESIGN_TIMESTAMP_TRIES:-4}"
delay="${CMUX_CODESIGN_RETRY_DELAY:-15}"
err="$(mktemp "${TMPDIR:-/tmp}/codesign-retry.XXXXXX")" || exit 1
trap 'rm -f "$err"' EXIT

for ((attempt = 1; ; attempt++)); do
  "$tool" "$@" 2>"$err"
  status=$?
  cat "$err" >&2
  [[ $status -ne 0 ]] || exit 0
  if (( attempt < tries )) \
    && grep -qE 'The timestamp service is not available|A timestamp was expected but was not found' "$err"; then
    echo "warning: codesign: Apple's timestamp service failed (try $attempt of $tries); signing again in ${delay}s" >&2
    sleep "$delay"
    delay=$((delay * 2))
    continue
  fi
  exit "$status"
done
