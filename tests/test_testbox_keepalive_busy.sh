#!/usr/bin/env bash
# The Testbox keepalive released a box 15 minutes after "ready" while a
# `cargo test --workspace` still ran in it (warmup run 37105812136, box
# tbx_01m409ybwc1hhwtrt1d7n1df11, 2026-10-03: "idle for 924 s"). It counted
# only an open SSH session or the activity marker as use, and a long command
# that outlives its SSH session (run detached, or a CLI that does not keep the
# session) touches neither. A process working inside the Testbox checkout is
# use too. This test needs Linux /proc, like the Testbox itself.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
busy="$root/scripts/blacksmith-testbox-busy.sh"
if [[ ! -d /proc/self ]]; then
  echo "SKIP: no /proc (the Testbox and CI run Linux)"
  exit 0
fi
test -x "$busy"

work="$(cd "$(mktemp -d)" && pwd -P)"
pids=()
cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/checkout/cmux-tui" "$work/elsewhere"

# Wait (deadline 30 s) until process $1 works in directory $2.
wait_for_cwd() {
  local pid="$1" want="$2" deadline=$((SECONDS + 30))
  until [[ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" == "$want" ]]; do
    (( SECONDS < deadline )) || { echo "FAIL: pid $pid never worked in $want" >&2; exit 1; }
    sleep 0.05
  done
}

# The keepalive itself runs in the checkout (the job workspace), and so does
# its sleep: neither is use of the box.
(cd "$work/checkout" && exec bash -c 'sleep 60 & wait') &
keepalive="$!"
pids+=("$keepalive")
wait_for_cwd "$keepalive" "$work/checkout"
deadline=$((SECONDS + 30))
until pgrep -P "$keepalive" -x sleep >/dev/null; do
  (( SECONDS < deadline )) || { echo "FAIL: the keepalive's sleep never started" >&2; exit 1; }
  sleep 0.05
done
if "$busy" "$work/checkout" "$keepalive"; then
  echo "FAIL: the keepalive or its own sleep counted as busy" >&2
  exit 1
fi

# A process outside the checkout is not use of the box.
(cd "$work/elsewhere" && exec sleep 60) &
pids+=("$!")
wait_for_cwd "$!" "$work/elsewhere"
if "$busy" "$work/checkout" "$keepalive"; then
  echo "FAIL: a process outside the checkout counted as busy" >&2
  exit 1
fi

# A long command inside the checkout (cargo test in cmux-tui/) is use.
(cd "$work/checkout/cmux-tui" && exec sleep 60) &
worker="$!"
pids+=("$worker")
wait_for_cwd "$worker" "$work/checkout/cmux-tui"
if ! "$busy" "$work/checkout" "$keepalive"; then
  echo "FAIL: a process working in the checkout did not count as busy" >&2
  exit 1
fi
kill "$worker"
wait "$worker" 2>/dev/null || true
if "$busy" "$work/checkout" "$keepalive"; then
  echo "FAIL: a finished process still counted as busy" >&2
  exit 1
fi
echo "PASS: the keepalive counts a process working in the Testbox checkout as use"
