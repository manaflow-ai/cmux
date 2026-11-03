#!/usr/bin/env bash
# The release-ring switch NIGHTLY_NEXT_DEV_RING read live, for the nightly-next publish path.
#
# `vars.*` is fixed when a run starts and a re-run keeps that snapshot: on 2026-10-27 run
# 40454745365 (created 05:20Z with the ring on) published at 08:39Z on attempt 2, after the ring
# was turned off at 08:28Z, and tagged both feeds cmux-next-dev again, so the shipped cmux NIGHTLY
# app was offered nothing new. Every publish step that tags items reads the switch here instead.
#
# RING_TOKEN is a release App token (the App has Variables: read; GITHUB_TOKEN cannot read
# variables). Prints `on` only when the variable reads exactly `on`; unset (404) is off, as the
# vars expression treated it. A missing token or a refused or failed read is off, said loudly:
# off is every item on cmux-next, what every build followed before rings.
#
# usage: RING_TOKEN=... GITHUB_REPOSITORY=o/r nightly_next_dev_ring.sh [--github-output FILE]
set -uo pipefail
out=""
if [ "${1:-}" = --github-output ]; then out="${2:?--github-output needs a file}"; fi
emit() {
  echo "DEV ring: $2"
  [ -z "$out" ] || echo "mode=$1" >> "$out"
  [ -n "$out" ] || echo "$1"
}
if [ -z "${RING_TOKEN:-}" ]; then
  echo "::warning title=DEV ring::DEV ring: live read refused (no release App token), using off"
  emit off "no token; off"
  exit 0
fi
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
if value="$(GH_TOKEN="$RING_TOKEN" gh api "repos/${GITHUB_REPOSITORY:?}/actions/variables/NIGHTLY_NEXT_DEV_RING" --jq .value 2>"$err")"; then
  value="$(tr -d '[:space:]' <<<"$value")"
  if [ "$value" = on ]; then
    emit on "NIGHTLY_NEXT_DEV_RING read live is 'on'"
  else
    emit off "NIGHTLY_NEXT_DEV_RING read live is '${value}'; off"
  fi
elif grep -q "HTTP 404" "$err"; then
  emit off "NIGHTLY_NEXT_DEV_RING is unset; off"
else
  reason="$(head -c 300 "$err" | tr '\r\n' '  ')"
  echo "::warning title=DEV ring::DEV ring: live read refused (${reason:-gh api failed}), using off"
  emit off "refused; off"
fi
exit 0
