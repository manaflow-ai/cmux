#!/usr/bin/env bash
# Run a workflow step's command in the background and take its verdict in a later step, so independent checks of
# one job overlap instead of queueing (ci-web.yml's react-apps-check shard 1: the merge driver test and the PR-scoped
# webview rules ran one after the other beside Oxlint, about 10 of the shard's 14 minutes, run 45527661750).
#
#   bg_step.sh start NAME -- CMD [ARG...]   start CMD now; returns at once
#   bg_step.sh wait NAME [SECONDS]          block until NAME ends, print its output, exit with its status
#
# `start` takes an exclusive flock on NAME's lock file before it returns and the background child keeps that
# descriptor until CMD ends, so `wait` blocks on the lock (no polling, no sleep) and can never read before the
# start. CMD itself runs without the descriptor: a process it leaves behind cannot hold the wait open. A wait that
# outlives SECONDS (default 1800), or a child that died without writing a status, fails the step.
# State lives in $RUNNER_TEMP/bg-steps (or $TMPDIR), one log, lock and status file per NAME.
set -euo pipefail

dir="${BG_STEP_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bg-steps}"
mode="${1:-}"
name="${2:-}"
case "$name" in
  ''|*/*|.*) echo "bg_step.sh: usage: bg_step.sh start NAME -- CMD... | bg_step.sh wait NAME [SECONDS]" >&2; exit 2 ;;
esac
lock="$dir/$name.lock"
log="$dir/$name.log"
rc="$dir/$name.status"

case "$mode" in
  start)
    shift 2
    [ "${1:-}" = "--" ] && shift
    [ "$#" -gt 0 ] || { echo "bg_step.sh: start $name: no command" >&2; exit 2; }
    mkdir -p "$dir"
    rm -f "$rc" "$log"
    exec 9>"$lock"
    flock -x 9
    # The child inherits fd 9 (the held lock); CMD runs with it closed.
    BG_STEP_LOG="$log" BG_STEP_RC="$rc" nohup bash -c 'started=$(date +%s); "$@" 9>&- >"$BG_STEP_LOG" 2>&1; s=$?; echo "$s $(( $(date +%s) - started ))" >"$BG_STEP_RC"' \
      bg_step "$@" </dev/null >/dev/null 2>&1 9>&9 &
    echo "bg_step.sh: started $name (pid $!): $*"
    ;;
  wait)
    limit="${3:-1800}"
    [ -e "$lock" ] || { echo "::error title=bg_step $name::it was never started"; exit 1; }
    if ! flock -s -w "$limit" "$lock" true; then
      [ -f "$log" ] && cat "$log"
      echo "::error title=bg_step $name::still running after ${limit}s"
      exit 1
    fi
    [ -f "$log" ] && cat "$log"
    if [ ! -s "$rc" ]; then
      echo "::error title=bg_step $name::ended without a status"
      exit 1
    fi
    read -r status seconds <"$rc"
    echo "bg_step.sh: $name exited $status after ${seconds}s in the background"
    exit "$status"
    ;;
  *)
    echo "bg_step.sh: usage: bg_step.sh start NAME -- CMD... | bg_step.sh wait NAME [SECONDS]" >&2
    exit 2
    ;;
esac
