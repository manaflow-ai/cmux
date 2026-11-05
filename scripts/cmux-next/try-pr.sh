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
# (default /Applications/cmux NEXT.app; a nightly, or a DEV build for rebuilds only: a DEV copy
# cannot load a web overlay) with its own data, socket,
# daemon, settings and web overlay, so your app and its sessions are not touched. Like every cmux
# build on the Mac, it shares two folders: agent-home (the folder a chat with no folder runs in)
# and Chat Uploads. A rebuild opens the PR's own build
# there instead of the copy. --here patches the running app instead (the web overlay of your
# cmux-next.json), and for a rebuild only prints where the build is. --no-build stops at the
# verdict when the PR needs a build. --front opens the side instance in front. --dry-run prints the
# verdict and the commands it would run. --port and --fork go to web-overlay.sh follow; a side
# instance's dev server takes the first free port from 20000 + N % 10000 (and keeps it) unless --port
# names one. The Swift verdict is
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

# One physical root for this script and side-instance.sh (which resolves it the same way), so the
# marker, pid and build paths both use agree.
side_root="${CMUX_SIDE_ROOT:-$HOME/Library/Application Support/cmux-side}"
mkdir -p "$side_root"; side_root="$(cd "$side_root" && pwd -P)"; export CMUX_SIDE_ROOT="$side_root"
if [[ -n "$stop" ]]; then
  if "$side" path "$name" >/dev/null 2>&1; then
    side_env
    run "$ROOT/scripts/cmux-next/web-overlay.sh" server off
    run "$side" remove "$name"
  else
    echo "no side instance for #$pr"
  fi
  # The fleet builds this script downloaded for the PR go too.
  for build in "$side_root/builds/pr-$pr-"*; do
    if [[ -d "$build" ]]; then run rm -rf "$build"; fi
  done
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

# Makes the side instance from APP (again when it was made from another app, or APP updated since),
# then opens it.
open_side() {
  local app="$1" marker="$side_root/$name/.side-instance" made="" version=""
  if [[ -f "$marker" ]]; then
    made="$(sed -n 's/^from=//p' "$marker")"
    version="$(sed -n 's/^version=//p' "$marker")"
  fi
  if [[ "$made" != "$app" || "$version" != "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist" 2>/dev/null || true)" ]]; then
    if [[ -n "$made" ]]; then run "$side" stop "$name"; fi
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
      # A DEV copy has its own bundle id, and the app reads web-dev.json only under DEV's own.
      if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$from/Contents/Info.plist" 2>/dev/null || true)" == com.cmuxterm.app.debug.next ]]; then
        echo "a copy of cmux NEXT DEV cannot load the PR's web UI (it reads web-dev.json only under DEV's own bundle id): --from a nightly, or --here to patch your DEV" >&2; exit 1
      fi
      open_side "$from"
      side_env
      # The side instance keeps the port it was given; a new one takes the first free port from
      # 20000 + N % 10000, so two PRs never share a dev server.
      saved="$side_root/$name/port"
      if [[ -z "$port" && -f "$saved" ]]; then port="$(cat "$saved")"; fi
      if [[ -z "$port" ]]; then
        port=$((20000 + pr % 10000))
        while nc -z 127.0.0.1 "$port" 2>/dev/null; do port=$((port + 1)); done
      fi
      if [[ -z "$dry" ]]; then echo "$port" >"$saved"; fi
    fi
    run "$ROOT/scripts/cmux-next/web-overlay.sh" follow "$pr" ${port:+--port "$port"} ${follow[@]+"${follow[@]}"}
    ;;
  daemon|swift-live|rebuild)
    case "$verdict" in
      daemon) echo "the daemon or CLI changes: it needs the PR's binary, so a dev build" ;;
      swift-live) echo "Swift changes only inside function bodies, or new Swift files: injectable once the app takes live code, a dev build until then" ;;
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
    if [[ -n "$dry" ]]; then run "$ci" "${build[@]}"; if [[ -n "$here" ]]; then echo "would wait for it and print where it is"; else echo "would wait for it and open it as cmux PR #$pr"; fi; exit 0; fi
    job="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$("$ci" "${build[@]}")")"
    echo "fleet job $job"
    "$ci" wait "$job" >&2 || { echo "job $job is not done; \`try-pr.sh $pr\` again picks up the same build" >&2; exit 1; }
    out="$side_root/builds/pr-$pr-${head:0:12}"
    if [[ ! -d "$out/bundle" ]]; then
      # Into a scratch folder first, so an interrupted download is never taken for a build.
      rm -rf "$out.partial"; mkdir -p "$out.partial"
      # The per-file bundle, else the zip (artifact --bundle exits 3 when the store has no bundle).
      if "$ci" artifact "$job" "$out.partial/bundle" --bundle >&2; then :
      else
        code=$?
        [[ $code -eq 3 ]] || { echo "downloading job $job's app failed (cmux-ci artifact exit $code)" >&2; exit 1; }
        "$ci" artifact "$job" "$out.partial/app.zip" >&2
        mkdir -p "$out.partial/bundle" && ditto -x -k "$out.partial/app.zip" "$out.partial/bundle"
        rm -f "$out.partial/app.zip"
      fi
      rm -rf "$out"; mv "$out.partial" "$out"
    fi
    app="$(find "$out/bundle" -maxdepth 2 -name '*.app' -type d | head -1)"
    [[ -n "$app" ]] || { echo "job $job returned no app bundle" >&2; exit 1; }
    if [[ -z "$here" ]] && "$side" path "$name" >/dev/null 2>&1; then
      # A web-live try of an earlier head left a dev server and web-dev.json pointing at it, which
      # would serve that head's web code over the build's own: both go before the build opens.
      side_env
      run "$ROOT/scripts/cmux-next/web-overlay.sh" server off
      run "$ROOT/scripts/cmux-next/web-overlay.sh" off
    fi
    if [[ -n "$here" ]]; then
      echo "built: $app (dev-build-try $pr installs and opens it as cmux DEV try)"
    else
      open_side "$app"
    fi
    ;;
esac
