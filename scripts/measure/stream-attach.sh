#!/usr/bin/env bash
# D3 daemon-side numbers (plans/cmux-next/app-daemon-connection-DESIGN.md): per-view attach
# cost and key echo beside output floods, one connection per view against client streams
# with binary frames on one connection, on a headless cmux-tui built from this checkout
# (cargo --release), measured by scripts/cmux-next/stream-attach-bench.py.
# Run alone on an idle worker:
#   cmux-ci run --class exclusive --measurement --script scripts/measure/stream-attach.sh --ref SHA
#     [--arg=views=24] [--arg=floods=10] [--arg=echoes=60] [--arg=mode=both]
# Output: one STREAM-ATTACH-BENCH line; JSON at .build/stream-attach/result.json.
set -euo pipefail
views=24
floods=10
echoes=60
mode=both
for arg in "$@"; do
  case "$arg" in
    views=*) views="${arg#views=}" ;;
    floods=*) floods="${arg#floods=}" ;;
    echoes=*) echoes="${arg#echoes=}" ;;
    mode=*) mode="${arg#mode=}" ;;
    *) echo "stream-attach.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ -n "${CMUX_CI_STEP_KEY:-}" ]] || { echo "stream-attach.sh runs cargo and runs only as a fleet step" >&2; exit 2; }
umask 022
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/stream-attach"
mkdir -p "$work"
export CARGO_TARGET_DIR="$root/.build/perf-daemon-target"
if [[ -z "$(git submodule status ghostty-next 2>/dev/null || true)" && -f ghostty-next/build.zig ]]; then
  echo "ghostty-next: synced copy"
else
  git submodule update --init --depth 1 ghostty-next
fi
toolchain_cargo="$(cd cmux-tui && rustup which cargo)"
export PATH="$(dirname "$toolchain_cargo"):$PATH"
echo "STREAM-ATTACH-SHA $(git rev-parse HEAD)"
(cd cmux-tui && cargo build --release --locked -p cmux-tui --bin cmux-tui 2>&1 | tail -n 5)
echo "STREAM-ATTACH-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion)"
ulimit -n "$(ulimit -Hn)" 2>/dev/null || ulimit -n 65536 2>/dev/null || true
python3 scripts/cmux-next/stream-attach-bench.py --binary "$CARGO_TARGET_DIR/release/cmux-tui" \
  --views "$views" --floods "$floods" --echoes "$echoes" --mode "$mode" --out "$work/result.json"
