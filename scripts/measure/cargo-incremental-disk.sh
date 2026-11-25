#!/usr/bin/env bash
# Disk and wall time of the cmux_next_ daemon tests' test build (ci/steps.toml cmux-next-daemon-tests) into a fresh
# target, with cargo's default incremental state and with CARGO_INCREMENTAL=0, one after the other on one machine.
# Run 45531606824 failed "No space left on device" writing cmux-tui/target/debug/incremental on a Linux pool VM.
# Each build runs into its own fresh target, which is deleted before the next starts. Prints one line per mode:
#   mode=incremental|off secs=N target_gib=N incremental_gib=N free_gib=N
# Usage (repository root, on a CI runner): scripts/measure/cargo-incremental-disk.sh
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root/cmux-tui"
channel="$(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' rust-toolchain.toml)"
rustup toolchain install "$channel" --profile minimal >/dev/null
export CARGO_NET_RETRY=10 CARGO_HTTP_TIMEOUT=120 CMUX_GHOSTTY_SRC="" GHOSTTY_ZIG_SOURCE=ghostty-next
read -r -a members <<<"$("$root/scripts/ci/cmux-next-daemon-test-packages.sh")"
cargo fetch --locked >/dev/null
gib() { du -sb "$1" 2>/dev/null | awk '{printf "%.2f", $1 / 1073741824}'; }
for mode in incremental off; do
  target="$(mktemp -d "${RUNNER_TEMP:-/tmp}/incr-measure.XXXXXX")"
  inc=1; [ "$mode" = off ] && inc=0
  start=$(date +%s)
  CARGO_TARGET_DIR="$target" CARGO_INCREMENTAL=$inc cargo test "${members[@]}" --locked --no-run >/dev/null 2>&1 ||
    { echo "mode=$mode build failed"; rm -rf "$target"; exit 1; }
  secs=$(($(date +%s) - start))
  echo "mode=$mode secs=$secs target_gib=$(gib "$target") incremental_gib=$(gib "$target/debug/incremental")" \
    "free_gib=$(df -B1 --output=avail "$target" | tail -n 1 | awk '{printf "%.1f", $1 / 1073741824}')"
  rm -rf "$target"
done
