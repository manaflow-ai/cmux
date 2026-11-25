#!/usr/bin/env bash
# Disk and wall time of the cmux_next_ daemon tests step (ci/steps.toml cmux-next-daemon-tests, run through ci/run
# with its rust and zig tools, as the linux job runs it) into a fresh cmux-tui/target, once with cargo's incremental
# state on (CARGO_INCREMENTAL=1) and once off (0), one after the other on one machine. Run 45531606824 failed "No
# space left on device" writing cmux-tui/target/debug/incremental on a Linux pool VM. The target is deleted before
# each run. Prints one line per mode:
#   mode=1|0 secs=N exit=N target_gib=N incremental_gib=N free_gib=N
# Usage (repository root, on a CI runner): scripts/measure/cargo-incremental-disk.sh
set -uo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"
target="${CARGO_TARGET_DIR:-$root/cmux-tui/target}"
echo "target dir: $target"
gib() { du -sb "$1" 2>/dev/null | awk '{printf "%.2f", $1 / 1073741824}'; }
for inc in 1 0; do
  rm -rf "$target"
  log="$(mktemp "${RUNNER_TEMP:-/tmp}/incr-measure.XXXXXX")"
  start=$(date +%s)
  CARGO_INCREMENTAL=$inc python3 ci/run run --job linux --only cmux-next-daemon-tests >"$log" 2>&1
  code=$?
  secs=$(($(date +%s) - start))
  [ "$code" = 0 ] || tail -n 40 "$log"
  echo "mode=$inc secs=$secs exit=$code target_gib=$(gib "$target") incremental_gib=$(gib "$target/debug/incremental")" \
    "free_gib=$(df -B1 --output=avail "$root" | tail -n 1 | awk '{printf "%.1f", $1 / 1073741824}')"
done
rm -rf "$target"
