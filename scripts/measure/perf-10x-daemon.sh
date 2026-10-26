#!/usr/bin/env bash
# perf-10x daemon area: request latency of a headless cmux-tui built from this
# checkout (cargo --release), measured by cmux-tui/scripts/bench-daemon-latency.py:
# raw ping / identify / list-workspaces / send / new-tab, 10 concurrent clients,
# and the CLI end to end, at 1 terminal and at 50 workspaces / 200 terminals.
# storm=N adds N automation clients against the app's echo and split
# (bench --automation-storm). After each scenario's load it reads
# debug-daemon-locks: PERF-DAEMON-LOCKS lines give wait_us and hold_us count,
# p95, p99 and max per lock (mux.state, workspace.registry) for the frontend
# and automation callers. Frontend is the signed, verified app only: the
# bench's unsigned app handshake counts as automation.
# Run alone on an idle worker:
#   cmux-ci run --class exclusive --measurement --script scripts/measure/perf-10x-daemon.sh --ref SHA
#     [--arg=n=300] [--arg=cli_n=40] [--arg=scenarios=small,scale] [--arg=storm=8]
# Output: PERF-DAEMON and PERF-DAEMON-LOCKS lines; JSON at .build/perf-daemon/result.json.
set -euo pipefail
n=300
cli_n=40
scenarios="small,scale"
storm=0
for arg in "$@"; do
  case "$arg" in
    n=*) n="${arg#n=}" ;;
    cli_n=*) cli_n="${arg#cli_n=}" ;;
    scenarios=*) scenarios="${arg#scenarios=}" ;;
    storm=*) storm="${arg#storm=}" ;;
    *) echo "perf-10x-daemon.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ -n "${CMUX_CI_STEP_KEY:-}" ]] || { echo "perf-10x-daemon.sh runs cargo and runs only as a fleet step" >&2; exit 2; }
umask 022
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/perf-daemon"
mkdir -p "$work"
export CARGO_TARGET_DIR="$root/.build/perf-daemon-target"
if [[ -z "$(git submodule status ghostty-next 2>/dev/null || true)" && -f ghostty-next/build.zig ]]; then
  echo "ghostty-next: synced copy"
else
  git submodule update --init --depth 1 ghostty-next
fi
cd cmux-tui
toolchain_cargo="$(rustup which cargo)"
export PATH="$(dirname "$toolchain_cargo"):$PATH"
echo "PERF-DAEMON-SHA $(git rev-parse HEAD)"
t0=$(date +%s)
cargo build --release --locked -p cmux-tui --bin cmux-tui 2>&1 | tail -n 5
echo "PERF-DAEMON-BUILD seconds=$(( $(date +%s) - t0 ))"
bin="$CARGO_TARGET_DIR/release/cmux-tui"
echo "PERF-DAEMON-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""
ulimit -n "$(ulimit -Hn)" 2>/dev/null || ulimit -n 65536 2>/dev/null || true
python3 scripts/bench-daemon-latency.py --bin "$bin" --n "$n" --cli-n "$cli_n" --scenarios "$scenarios" \
  --automation-storm "$storm" --out "$work/result.json"
