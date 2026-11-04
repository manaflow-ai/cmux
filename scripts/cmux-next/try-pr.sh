#!/usr/bin/env bash
# Try a pull request in cmux NEXT without waiting for a dev build when it does not need one
# (docs/cmux-next/hot-reload.md, "Try a pull request"). Fetches the PR's head with git (no GitHub
# API), sorts its change with live_apply.py, then takes the cheapest path:
#
#   no-app      nothing in the app changes: says so and stops
#   web-live    patches the PR's web UI in: web-overlay.sh follow PR, no build
#   daemon, swift-live, rebuild
#               says why it needs a new binary, requests the fleet dev build (cmux-ci build cmux,
#               the same build the HQ request gives, tagged pr-N), waits for it and opens it
#   ios-only    the Mac app does not change
#
#   try-pr.sh PR [--here] [--from APP] [--front] [--no-build] [--dry-run] [--port N] [--fork]
#   try-pr.sh PR --stop             quit and remove the PR's side instance and its dev server
#
# By default the PR opens in a side instance, "cmux PR #N" (side-instance.sh pr-N): a copy of APP
# (default /Applications/cmux NEXT.app; a nightly or a DEV build) with its own data, settings and
# web overlay, so your app and its sessions are never touched. A rebuild opens the PR's own build
# there instead of the copy. --here patches the running app instead (the web overlay of your
# cmux-next.json), and for a rebuild only prints where the build is. --no-build stops at the
# verdict when the PR needs a build. --front opens the side instance in front. --dry-run prints the
# verdict and the commands it would run. --port and --fork go to web-overlay.sh follow; a side
# instance's dev server takes port 20000 + N % 10000 unless --port names one. The Swift verdict is
# a hint: live Swift patches exist only in the view shell today (Prototypes/ViewShell, "Live
# code"), so the app still takes a dev build for them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }

pr="${1:-}"; [[ "$pr" =~ ^[0-9]+$ ]] || usage 1; shift
dry="" here="" front="" nobuild="" stop="" port="" from="/Applications/cmux NEXT.app" follow=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --here) here=1; shift ;;
    --front) front=1; shift ;;
    --no-build) nobuild=1; shift ;;
    --build) shift ;;  # the default now; kept so older commands still run
    --stop) stop=1; shift ;;
    --from) [[ $# -ge 2 ]] || usage 1; from="${2%/}"; shift 2 ;;
    --port) [[ $# -ge 2 ]] || usage 1; port="$2"; shift 2 ;;
    --fork) follow+=(--fork); shift ;;
    -h|--help) usage ;;
    *) usage 1 ;;
  esac
done

side="$ROOT/scripts/cmux-next/side-instance.sh"
name="pr-$pr"
# Runs a command, or prints it under --dry-run.
run() {
  if [[ -n "$dry" ]]; then printf 'would run:'; printf ' %q' "$@"; echo; else "$@"; fi
}
# The side instance's environment for web-overlay.sh, in this shell.
side_env() { if [[ -z "$dry" ]] || "$side" path "$name" >/dev/null 2>&1; then eval "$("$side" env "$name")"; fi; }

if [[ -n "$stop" ]]; then
  # The fleet builds this script downloaded for the PR go too.
  "$side" path "$name" >/dev/null 2>&1 || { echo "no side instance for #$pr"; exit 0; }
  side_env
  run "$ROOT/scripts/cmux-next/web-overlay.sh" server off
  run "$side" remove "$name"
  run rm -rf "${CMUX_SIDE_ROOT:-$HOME/Library/Application Support/cmux-side}/builds/pr-$pr-"*
  exit 0
fi

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

# Makes the side instance from APP (again when it was made from another app), then opens it.
open_side() {
  local app="$1" made
  made="$(sed -n 's/^from=//p' "${CMUX_SIDE_ROOT:-$HOME/Library/Application Support/cmux-side}/$name/.side-instance" 2>/dev/null || true)"
  if [[ "$made" != "$app" ]]; then
    [[ -n "$made" ]] && run "$side" stop "$name"
    run "$side" make "$name" --from "$app" --label "cmux PR #$pr"
  fi
  run "$side" launch "$name" ${front:+--front}
}

case "$verdict" in
  no-app)
    echo "nothing in the app changes (CI, tests, docs, tools): nothing to try"
    ;;
  ios-only)
    echo "only the iPhone app changes: nothing to try in the Mac app"
    ;;
  web-live)
    echo "web only: no build, the PR's web UI is patched in and hot-reloads"
    if [[ -z "$here" ]]; then
      [[ -n "$dry" || -d "$from" ]] || { echo "no app at $from to copy (--from APP names another)" >&2; exit 1; }
      open_side "$from"
      side_env
      port="${port:-$((20000 + pr % 10000))}"
    fi
    run "$ROOT/scripts/cmux-next/web-overlay.sh" follow "$pr" ${port:+--port "$port"} ${follow[@]+"${follow[@]}"}
    ;;
  daemon|swift-live|rebuild)
    case "$verdict" in
      daemon) echo "the daemon or CLI changes: it needs the PR's binary, so a dev build" ;;
      swift-live) echo "Swift changes only inside function bodies: injectable once the app takes live code, a dev build until then" ;;
      rebuild) echo "the app needs a new binary: a dev build" ;;
    esac
    if [[ -n "$nobuild" ]]; then
      echo "run again without --no-build to build it on the fleet and open it (cmux PR #$pr)"
      exit 0
    fi
    ci="${CMUX_CI:-$HOME/.local/bin/cmux-ci}"
    [[ -n "$dry" || -x "$ci" ]] || { echo "no cmux-ci client at $ci (CMUX_CI names another)" >&2; exit 1; }
    # A later push with the same tag and workspace supersedes a queued build of an older head.
    build=(build cmux --ref "$head" --tag "pr-$pr" --backend-mode local --workspace "try-pr:$pr:$(id -un)")
    if [[ -n "$dry" ]]; then run "$ci" "${build[@]}"; echo "would wait for it and open it as cmux PR #$pr"; exit 0; fi
    job="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$("$ci" "${build[@]}")")"
    echo "fleet job $job"
    "$ci" wait "$job" >&2 || { echo "job $job is not done; \`try-pr.sh $pr\` again picks up the same build" >&2; exit 1; }
    out="${CMUX_SIDE_ROOT:-$HOME/Library/Application Support/cmux-side}/builds/pr-$pr-${head:0:12}"
    if [[ ! -d "$out/bundle" ]]; then
      mkdir -p "$out"
      # The per-file bundle, else the zip (artifact --bundle exits 3 when the store has no bundle).
      if "$ci" artifact "$job" "$out/bundle" --bundle >&2; then :
      else
        [[ $? -eq 3 ]] || exit 1
        "$ci" artifact "$job" "$out/app.zip" >&2
        mkdir -p "$out/bundle" && ditto -x -k "$out/app.zip" "$out/bundle" && rm -f "$out/app.zip"
      fi
    fi
    app="$(find "$out/bundle" -maxdepth 2 -name '*.app' -type d | head -1)"
    [[ -n "$app" ]] || { echo "job $job returned no app bundle" >&2; exit 1; }
    if [[ -n "$here" ]]; then
      echo "built: $app (dev-build-try $pr installs and opens it as cmux DEV try)"
    else
      open_side "$app"
    fi
    ;;
esac
