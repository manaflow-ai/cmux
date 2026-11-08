#!/usr/bin/env bash
# nightly.yml: "Finish the browser-data import proof". Waits for the scan
# browser-data-proof-start.sh started and fails the step when it found a browser target.
set -euo pipefail
state="$RUNNER_TEMP/browser-data-proof"
[ -p "$state/status.fifo" ] || { echo "the browser-data import proof was never started" >&2; exit 1; }
status=""
read -r status <"$state/status.fifo" || true
cat "$state/proof.log"
rm -rf "$state"
case "$status" in
  0) ;;
  "") echo "the browser-data import proof ended without a status" >&2; exit 1 ;;
  *) echo "the browser-data import proof failed (status $status)" >&2; exit 1 ;;
esac
