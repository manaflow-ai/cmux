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
# Exit 0 when ready; 1 when the time ran out. A failed (or empty) answer is
# polled like a deferred one: the probe says failed until GitHub lists a
# just-dispatched publisher, and also while a same-tree artifacts run it did
# not find is still publishing (DEV run 38562080086 gave up at 12:25Z on
# 2026-10-14 while run 38561677744 was publishing its tree). Only the probes up
# to the first failed answer may dispatch a publisher
# (CMUX_TUI_TREE_DISPATCH); later ones only look, so a tree whose build keeps
# failing is not rebuilt for the whole wait.
#
# The run also takes an older published tree, the nightly's own answer
# (scripts/cmux-next/older-tree-for-tip.sh: newest manifest-verified tree within
# 24 h and 400 commits with this commit's daemon-capabilities.json). It asks on
# the first look and every CMUX_DEV_TREE_OLDER_EVERY_SECONDS (default 600) after,
# and builds this exact app head against that tree, as the nightly does. Path
# routing's own fallback looks only 50 commits back and reports skipped, which
# until 2026-11-27 skipped every compile job: feat-cmux-next published no tree
# of its own from 00:55Z (every artifacts run red), the newest published tree
# was 160 commits back, and DEV published nothing after 2026-11-26 13:54Z (run
# 45955325112 at ea9738b597: "no tree in its recent history is published; the
# tree jobs are skipped").
# A failed answer that proves no publisher (the probe read every cmux-tui
# artifacts run and none builds this tree: "no cmux-tui artifacts run can
# publish tree") ends the wait once it has held for
# CMUX_DEV_TREE_NO_PUBLISHER_SECONDS (default 300; 0 keeps the full wait) and
# no older tree exists. This job cannot start a publisher, so the full wait only
# held a runner: from 23:16Z on 2026-11-27 every DEV daily run (one per 5-minute
# dispatcher tick) waited 3300s for a tree nothing was building and failed,
# about 57 runner-min each, ~12k a day (run 46086091622: "has no publisher").
# Env: CMUX_DEV_TREE_PROBE and CMUX_DEV_TREE_OLDER (tests only) replace
# pin-cmux-tui.sh and older-tree-for-tip.sh.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
probe="${CMUX_DEV_TREE_PROBE:-$here/pin-cmux-tui.sh}"
older="${CMUX_DEV_TREE_OLDER:-$here/older-tree-for-tip.sh}"
wait_seconds="${CMUX_DEV_TREE_WAIT_SECONDS:-3300}"
poll_seconds="${CMUX_DEV_TREE_POLL_SECONDS:-60}"
older_every="${CMUX_DEV_TREE_OLDER_EVERY_SECONDS:-600}"
no_publisher_seconds="${CMUX_DEV_TREE_NO_PUBLISHER_SECONDS:-300}"
[[ "$wait_seconds" =~ ^[0-9]+$ && "$poll_seconds" =~ ^[0-9]+$ && "$older_every" =~ ^[0-9]+$ && "$no_publisher_seconds" =~ ^[0-9]+$ ]] || { echo "error: the wait, poll, older-tree interval and no-publisher hold must be whole numbers" >&2; exit 2; }
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
started=$SECONDS
dispatch="${CMUX_TUI_TREE_DISPATCH:-}"
older_at=""
no_publisher_at=""
# Exit 0 with the older tree's outputs when one exists; 1 otherwise.
take_older_tree() {
  local out rc=0 key fetch_key
  out="$(bash "$older" 2>"$tmp/older.err")" || rc=$?
  sed 's/^/older-tree: /; s/^older-tree: older-tree: /older-tree: /' "$tmp/older.err" >&2 || true
  (( rc == 0 )) || return 1
  key="$(sed -n 's/^tip_key=//p' <<<"$out" | head -1)"
  fetch_key="$(sed -n 's/^key=//p' <<<"$out" | head -1)"
  [[ "$fetch_key" =~ ^[0-9a-f]{40}$ ]] || { echo "older-tree printed no tree key; looking again" >&2; return 1; }
  {
    echo "tree_key=${key:-$fetch_key}"
    echo "tree_fetch_key=$fetch_key"
    echo "tree_state=ready"
    echo "tree_reason=this commit's tree ${key:-unknown} is not published; the DEV app builds against the newest published tree $fetch_key (from $(sed -n 's/^tree_from=//p' <<<"$out" | head -1)), as the nightly does"
  } >> "$GITHUB_OUTPUT"
  echo "this commit's cmux-tui tree is not published; the DEV Release compile uses the published tree $fetch_key after $((SECONDS - started))s"
  return 0
}
while :; do
  : > "$tmp/out"
  GITHUB_OUTPUT="$tmp/out" CMUX_TUI_TREE_DISPATCH="$dispatch" CMUX_TUI_TREE_RECHECK_SECONDS=0 CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS=0 \
    bash "$probe" probe || true
  state="$(sed -n 's/^tree_state=//p' "$tmp/out" | tail -1)"
  reason="$(sed -n 's/^tree_reason=//p' "$tmp/out" | tail -1)"
  if [[ "$state" == failed && "$reason" == "no cmux-tui artifacts run can publish tree"* ]]; then
    no_publisher_at="${no_publisher_at:-$SECONDS}"
  else
    no_publisher_at=""
  fi
  case "$state" in
    ready)
      cat "$tmp/out" >> "$GITHUB_OUTPUT"
      echo "the cmux-tui tree is published after $((SECONDS - started))s; the DEV Release compile runs"
      exit 0 ;;
    deferred) ;;
    *) echo "the probe says tree_state=${state:-none} ($reason); looking again"
       dispatch=0 ;;
  esac
  if [[ -z "$older_at" ]] || (( SECONDS - older_at >= older_every )); then
    older_at=$SECONDS
    take_older_tree && exit 0
  fi
  if [[ -n "$no_publisher_at" ]] && (( no_publisher_seconds > 0 && SECONDS - no_publisher_at >= no_publisher_seconds )); then
    cat "$tmp/out" >> "$GITHUB_OUTPUT"
    echo "error: no cmux-tui artifacts run has been building this tree for $((SECONDS - no_publisher_at))s and no older tree is published; the run stops instead of holding a runner for ${wait_seconds}s, and the next dispatcher tick tries the new tip" >&2
    exit 1
  fi
  if (( SECONDS - started >= wait_seconds )); then
    cat "$tmp/out" >> "$GITHUB_OUTPUT"
    echo "error: the cmux-tui tree is still not published after ${wait_seconds}s; the next dispatcher tick tries the new tip" >&2
    exit 1
  fi
  sleep "$poll_seconds"
done
