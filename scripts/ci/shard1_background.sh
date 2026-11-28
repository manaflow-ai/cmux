#!/usr/bin/env bash
# Runs one of react-apps-check shard 1's independent checks in the background, so it overlaps the steps after it,
# and hands its exit status to its own step later (ci-web.yml: the step keeps its id, so the gate and the Test
# webviews condition read its outcome as before).
#
#   shard1_background.sh start NAME -- CMD...   start CMD now; its output and status wait for `wait NAME`
#   shard1_background.sh wait NAME -- CMD...    print NAME's output and exit with its status; CMD runs here instead
#                                               when NAME never started, or its process died without a status
#
# Leo, 2026-11-22: "if it's relaly so big then you guys need to be hurrying up and thining more innovatively".
# Shard 1 ran these one after another on a 16 vCPU runner (job 137332637156, 11-22 19:49Z, 15.2 min): the merge
# driver test 80 s, the PR-scoped rules 133 s and the compiler bail check 84 s, beside the bundle build (108 s) and
# the Oxlint, Oxfmt and type check step (240 s) they do not read. Shard 1 runs on every pull request head the React
# check routes, so each second of its serial path is a runner-second on every head.
#
# Any failure to start falls back to the inline run: the check always runs, at worst where it did before.
set -uo pipefail

dir="${RUNNER_TEMP:-/tmp}/shard1-background"
mode="${1:-}"
name="${2:-}"
if [ -z "$mode" ] || [ -z "$name" ] || [ "${3:-}" != -- ] || [ "$#" -lt 4 ]; then
  echo "usage: shard1_background.sh start|wait NAME -- CMD..." >&2
  exit 2
fi
shift 3
case "$name" in
  *[!A-Za-z0-9_-]*) echo "shard1_background.sh: NAME takes letters, digits, - and _ ($name)" >&2; exit 2 ;;
esac

case "$mode" in
  start)
    mkdir -p "$dir" || exit 1
    rm -f "$dir/$name.rc" "$dir/$name.rc.tmp" "$dir/$name.pid"
    # setsid: its own session, so the step's end does not signal it; the runner reaps it at the job's end.
    setsid bash -c '"${@:2}" > "$1.log" 2>&1; echo "$?" > "$1.rc.tmp" && mv "$1.rc.tmp" "$1.rc"' \
      shard1-background "$dir/$name" "$@" < /dev/null > /dev/null 2>&1 &
    echo "$!" > "$dir/$name.pid"
    echo "started $name in the background (pid $!): $*"
    ;;
  wait)
    pid="$(cat "$dir/$name.pid" 2> /dev/null || true)"
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
      echo "$name did not start in the background: running it here"
      exec "$@"
    fi
    waited=0
    while [ ! -f "$dir/$name.rc" ] && kill -0 "$pid" 2> /dev/null; do
      sleep 1
      waited=$((waited + 1))
    done
    if [ ! -f "$dir/$name.rc" ]; then
      echo "::warning title=shard 1 background check::$name's process ended without a status; running it here"
      cat "$dir/$name.log" 2> /dev/null || true
      exec "$@"
    fi
    cat "$dir/$name.log" 2> /dev/null || true
    rc="$(cat "$dir/$name.rc")"
    echo "$name finished in the background (exit $rc; this step waited ${waited} s for it)"
    [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
    exit "$rc"
    ;;
  *)
    echo "usage: shard1_background.sh start|wait NAME -- CMD..." >&2
    exit 2
    ;;
esac
