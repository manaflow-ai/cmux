#!/usr/bin/env bash
# Usage: scripts/blacksmith-testbox-release.sh <tbx_id> [wait-seconds]
#
# Ends your Testbox so its warm cmux-tui target dir is committed as the shared
# sticky disk of its branch family (`cmux-tui-target-v2-main` or
# `cmux-tui-target-v2-next`) for the next box. Use it instead of
# `blacksmith testbox stop`: stop destroys the VM before the warmup job's post
# steps run, so nothing is committed on that path.
#
# It writes the keepalive's release marker on the box, then waits for the
# warmup run to finish (prune, then the sticky disk commit). If the run is not
# finished after [wait-seconds] (default 600), it falls back to
# `blacksmith testbox stop`, so a box never outlives this command.
# Run it from the same cmux worktree root as your other `testbox run` commands.
set -euo pipefail

tbx="${1:?usage: $0 <tbx_id> [wait-seconds]}"
wait_seconds="${2:-600}"
[[ "$tbx" =~ ^tbx_[A-Za-z0-9_-]+$ ]] || { echo "malformed Testbox ID: $tbx" >&2; exit 2; }
[[ "$wait_seconds" =~ ^[0-9]+$ ]] || { echo "wait-seconds must be an integer" >&2; exit 2; }

run_url="$(blacksmith testbox status --id "$tbx" 2>/dev/null | grep -Eo 'https://github.com/[^ ]+/actions/runs/[0-9]+' | head -n 1 || true)"
run_id="${run_url##*/}"

stop_box() {
  echo "release: falling back to blacksmith testbox stop --id $tbx (no sticky disk commit)" >&2
  blacksmith testbox stop --id "$tbx"
}

# shellcheck disable=SC2016 # $HOME expands on the box, not here.
if ! blacksmith testbox run --id "$tbx" 'touch "$HOME/.testbox-release"'; then
  echo "release: could not write the release marker on $tbx" >&2
  stop_box
  exit 1
fi
echo "release: marker written on $tbx; the keepalive prunes target/ and exits within ~30 s"

if [[ ! "$run_id" =~ ^[0-9]+$ ]]; then
  echo "release: no warmup run URL for $tbx; not waiting for the commit" >&2
  exit 0
fi
deadline=$((SECONDS + wait_seconds))
run_state() {
  gh run view "$run_id" --repo manaflow-ai/cmux --json status,conclusion --jq '.status + " " + .conclusion' 2>/dev/null || true
}
finish_if_done() {
  case "$1" in
    "completed success")
      echo "release: run $run_id succeeded; the warm target dir commit is requested and lands when the VM shuts down"
      exit 0
      ;;
    completed*)
      echo "release: run $run_id ended ($1); nothing was committed" >&2
      exit 1
      ;;
  esac
}
# One waiter, no poll loop: glaeda-gh shares one cheap poller per machine (exit 2
# on timeout); without it, one gh run watch checks once per five minutes, ended
# by a timer at the deadline.
if command -v glaeda-gh >/dev/null 2>&1; then
  glaeda-gh wait run "manaflow-ai/cmux/$run_id" --until "done" --timeout "$wait_seconds" >/dev/null 2>&1 || true
else
  gh run watch "$run_id" --repo manaflow-ai/cmux --interval 300 >/dev/null 2>&1 &
  watch_pid=$!
  (
    sleep "$wait_seconds" &
    sleep_pid=$!
    trap 'kill "$sleep_pid" 2>/dev/null; exit 0' TERM
    wait "$sleep_pid"
    kill "$watch_pid" 2>/dev/null
  ) &
  timer_pid=$!
  wait "$watch_pid" 2>/dev/null || true
  kill "$timer_pid" 2>/dev/null || true
  wait "$timer_pid" 2>/dev/null || true
fi
finish_if_done "$(run_state)"
# A waiter that failed early (network, auth) is not the deadline: give the run
# the rest of its time once, then read it once more before stopping the box.
if (( SECONDS < deadline )); then
  echo "release: the wait for run $run_id ended early; checking once more at the deadline" >&2
  sleep $((deadline - SECONDS))
  finish_if_done "$(run_state)"
fi
echo "release: run $run_id did not finish within ${wait_seconds}s" >&2
stop_box
exit 1
