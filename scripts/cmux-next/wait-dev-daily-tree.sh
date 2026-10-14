#!/usr/bin/env bash
# Wait for a cmux NEXT DEV daily run's own cmux-tui tree, then let the run build.
#
# A DEV daily run (main's cmux-next-dev-daily-dispatch.yml) builds exactly the
# feat-cmux-next SHA it was asked for. When that tree is cold, path routing
# starts its publisher and reports tree_state=deferred. A same-tree run started
# by the publication cannot take over: it starts only while the branch tip is
# still this SHA (scripts/ci/cmux_next_tree_notify.py is_current), and a busy
# feat-cmux-next has moved by then. So the run waits here, on Linux, and its
# DEV Release compile runs once the tree is published.
#
# Probes with pin-cmux-tui.sh probe (no wait inside the probe) every
# CMUX_DEV_TREE_POLL_SECONDS (default 60) for up to CMUX_DEV_TREE_WAIT_SECONDS
# (default 3300). Writes the final probe's tree_* lines to $GITHUB_OUTPUT.
# Exit 0 when ready; 1 when nothing will publish the tree or the time ran out.
# Env: CMUX_DEV_TREE_PROBE (tests only) replaces pin-cmux-tui.sh.
set -euo pipefail

probe="${CMUX_DEV_TREE_PROBE:-$(cd "$(dirname "$0")" && pwd)/pin-cmux-tui.sh}"
wait_seconds="${CMUX_DEV_TREE_WAIT_SECONDS:-3300}"
poll_seconds="${CMUX_DEV_TREE_POLL_SECONDS:-60}"
[[ "$wait_seconds" =~ ^[0-9]+$ && "$poll_seconds" =~ ^[0-9]+$ ]] || { echo "error: the wait and poll must be whole seconds" >&2; exit 2; }
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
started=$SECONDS
while :; do
  : > "$tmp/out"
  GITHUB_OUTPUT="$tmp/out" CMUX_TUI_TREE_RECHECK_SECONDS=0 CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS=0 \
    bash "$probe" probe || true
  state="$(sed -n 's/^tree_state=//p' "$tmp/out" | tail -1)"
  case "$state" in
    ready)
      cat "$tmp/out" >> "$GITHUB_OUTPUT"
      echo "the cmux-tui tree is published after $((SECONDS - started))s; the DEV Release compile runs"
      exit 0 ;;
    deferred) ;;
    *)
      cat "$tmp/out" >> "$GITHUB_OUTPUT"
      echo "error: the cmux-tui tree will not be published (tree_state=${state:-none}): $(sed -n 's/^tree_reason=//p' "$tmp/out" | tail -1)" >&2
      exit 1 ;;
  esac
  if (( SECONDS - started >= wait_seconds )); then
    cat "$tmp/out" >> "$GITHUB_OUTPUT"
    echo "error: the cmux-tui tree is still not published after ${wait_seconds}s; the next dispatcher tick tries the new tip" >&2
    exit 1
  fi
  sleep "$poll_seconds"
done
