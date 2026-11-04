#!/usr/bin/env bash
# Try a pull request in a running cmux NEXT without waiting for a dev build when it does not need
# one (docs/cmux-next/hot-reload.md, "Try a pull request"). Fetches the PR's head with git (no
# GitHub API), sorts its change with live_apply.py, then takes the cheapest path:
#
#   no-app      nothing in the app changes: says so and stops
#   web-live    web-overlay.sh follow PR: the running app hot-reloads the PR's web UI now
#   daemon, swift-live, rebuild
#               says why it needs a new binary, and with --build requests the fleet dev build
#               (cmux-ci build cmux, the same build the HQ request gives, tagged pr-N)
#   ios-only    the Mac app does not change
#
#   try-pr.sh PR [--dry-run] [--build] [--port N] [--fork]
#
# --dry-run prints the verdict and the command it would run. --port and --fork go to
# web-overlay.sh follow. The Swift verdict is a hint: live Swift patches exist only in the view
# shell today (Prototypes/ViewShell, "Live code"), so the app still takes a dev build for them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }

pr="${1:-}"; [[ "$pr" =~ ^[0-9]+$ ]] || usage 1; shift
dry="" build="" follow=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --build) build=1; shift ;;
    --port) [[ $# -ge 2 ]] || usage 1; follow+=(--port "$2"); shift 2 ;;
    --fork) follow+=(--fork); shift ;;
    -h|--help) usage ;;
    *) usage 1 ;;
  esac
done

base_ref="${CMUX_TRY_PR_BASE:-feat-cmux-next}"
git -C "$ROOT" fetch -q origin "refs/pull/$pr/head" "refs/heads/$base_ref"
head="$(git -C "$ROOT" rev-parse "FETCH_HEAD")"
base="$(git -C "$ROOT" merge-base "$head" "origin/$base_ref")"

result="$(python3 "$ROOT/scripts/cmux-next/live_apply.py" --repo "$ROOT" --json "$base" "$head")"
verdict="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])' <<<"$result")"
echo "#$pr at $head: $verdict"
python3 -c '
import json, sys
for reason, paths in sorted(json.load(sys.stdin)["reasons"].items()):
    print("  " + reason + ": " + ", ".join(paths[:5]) + (" …" if len(paths) > 5 else ""))
' <<<"$result"

# Runs a command, or prints it under --dry-run.
run() {
  if [[ -n "$dry" ]]; then printf 'would run:'; printf ' %q' "$@"; echo; else "$@"; fi
}

case "$verdict" in
  no-app)
    echo "nothing in the app changes (CI, tests, docs, tools): nothing to try"
    ;;
  ios-only)
    echo "only the iPhone app changes: nothing to try in the Mac app"
    ;;
  web-live)
    echo "web only: no build, the running app hot-reloads the PR's web UI"
    run "$ROOT/scripts/cmux-next/web-overlay.sh" follow "$pr" ${follow[@]+"${follow[@]}"}
    ;;
  daemon|swift-live|rebuild)
    case "$verdict" in
      daemon) echo "the daemon or CLI changes: it needs the PR's binary, so a dev build" ;;
      swift-live) echo "Swift changes only inside function bodies, or new Swift files: injectable once the app takes live code, a dev build until then" ;;
      rebuild) echo "the app needs a new binary: a dev build" ;;
    esac
    if [[ -z "$build" ]]; then
      echo "run again with --build to request it from the fleet (cmux DEV pr-$pr)"
      exit 0
    fi
    ci="${CMUX_CI:-$HOME/.local/bin/cmux-ci}"
    [[ -n "$dry" || -x "$ci" ]] || { echo "no cmux-ci client at $ci (CMUX_CI names another)" >&2; exit 1; }
    # A later push with the same tag and workspace supersedes a queued build of an older head.
    run "$ci" build cmux --ref "$head" --tag "pr-$pr" --backend-mode local --workspace "try-pr:$pr:$(id -un)"
    ;;
esac
