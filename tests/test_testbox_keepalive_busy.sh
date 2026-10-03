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

work="$(mktemp -d)"
pids=()
cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/checkout/cmux-tui" "$work/elsewhere"

if "$busy" "$work/checkout" "$$"; then
  echo "FAIL: an empty checkout counted as busy" >&2
  exit 1
fi

# A process outside the checkout is not use of the box.
(cd "$work/elsewhere" && exec sleep 60) &
pids+=("$!")
if "$busy" "$work/checkout" "$$"; then
  echo "FAIL: a process outside the checkout counted as busy" >&2
  exit 1
fi

# A long command inside the checkout (cargo test in cmux-tui/) is use.
(cd "$work/checkout/cmux-tui" && exec sleep 60) &
worker="$!"
pids+=("$worker")
sleep 0.2
if ! "$busy" "$work/checkout" "$$"; then
  echo "FAIL: a process working in the checkout did not count as busy" >&2
  exit 1
fi

# The keepalive's own children (its sleep) never count.
if "$busy" "$work/checkout" "$worker"; then
  echo "FAIL: the excluded process itself counted as busy" >&2
  exit 1
fi
kill "$worker"
wait "$worker" 2>/dev/null || true
if "$busy" "$work/checkout" "$$"; then
  echo "FAIL: a finished process still counted as busy" >&2
  exit 1
fi
echo "PASS: the keepalive counts a process working in the Testbox checkout as use"
