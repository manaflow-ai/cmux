#!/usr/bin/env bash
# Disk and wall time of the cmux_next_ daemon tests step (ci/steps.toml cmux-next-daemon-tests, run through ci/run
# with its rust and zig tools, as the linux job runs it) from a fresh target, once with cargo's incremental state on
# (CARGO_INCREMENTAL=1) and once off (0), one after the other on one machine. Run 45531606824 failed "No space left
# on device" writing cmux-tui/target/debug/incremental on a Linux pool VM. Before each run every Cargo target the
# step could use (cmux-tui/target and $CARGO_TARGET_DIR) is deleted; after it, the script sums every `incremental`
# directory under them and the disk the run used (df before minus df after). One line per mode:
#   mode=1|0 secs=N exit=N target_gib=N incremental_gib=N used_gib=N
# Usage (repository root, on a CI runner): scripts/measure/cargo-incremental-disk.sh
set -uo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"
targets=("$root/cmux-tui/target")
[ -z "${CARGO_TARGET_DIR:-}" ] || targets+=("$CARGO_TARGET_DIR")
echo "targets: ${targets[*]}"
gib() { awk -v b="$1" 'BEGIN {printf "%.2f", b / 1073741824}'; }
bytes() { du -scb "$@" 2>/dev/null | tail -n 1 | cut -f1; }
avail() { df -B1 --output=avail "$root" | tail -n 1 | tr -d ' '; }
for inc in 1 0; do
  rm -rf "${targets[@]}"
  log="$(mktemp "${RUNNER_TEMP:-/tmp}/incr-measure.XXXXXX")"
  before="$(avail)" start=$(date +%s)
  CARGO_INCREMENTAL=$inc python3 ci/run run --job linux --only cmux-next-daemon-tests >"$log" 2>&1
  code=$?
  secs=$(($(date +%s) - start)) after="$(avail)"
  [ "$code" = 0 ] || grep -E "^error|could not compile|exited" "$log" | head -n 20
  mapfile -t incs < <(find "${targets[@]}" -maxdepth 3 -type d -name incremental 2>/dev/null)
  echo "mode=$inc secs=$secs exit=$code target_gib=$(gib "$(bytes "${targets[@]}")")" \
    "incremental_gib=$(gib "$( [ ${#incs[@]} -gt 0 ] && bytes "${incs[@]}" || echo 0)")" \
    "used_gib=$(gib $((before - after)))"
done
rm -rf "${targets[@]}"
