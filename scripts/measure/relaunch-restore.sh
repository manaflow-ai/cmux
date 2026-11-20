#!/usr/bin/env bash
# Relaunch restore of a cmux NEXT build on a fleet Mac with a console session (cmuxterm-hq#7149 row L5;
# scripts/ci/relaunch_restore_check.py does the driving): seed workspaces, a terminal process with scrollback and an
# agent chat, Quit and Keep Sessions, relaunch, and time quit to usable with every probe equal.
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/relaunch-restore.sh --ref <sha> [--arg=dmg=nightly|URL|build] [--arg=rounds=3] \
#     [--arg=fronts=chat] [--arg=config=bench] --artifact .build/relaunch-restore/report.tgz --timeout 1800
#   dmg=nightly  the newest build the NIGHTLY feed offers (default); dmg=https://... one DMG
#   dmg=build    a tagged app built from this checkout (scripts/reload.sh, config=bench by default: Release
#                optimization with the debug.* commands; config=Release or config=Debug), so a PR's base and head
#                are measured by the same harness: one step at each commit, pinned to one worker (--target-worker).
#   build=SHA    with dmg=build: build the tagged app at SHA (40 hex, a pull request's head or base, fetched when
#                absent) with that commit's own reload.sh (scripts/measure/app-at-commit.sh), while the check and
#                everything it runs stay this checkout's. The controller runs this script only at a landed commit, so
#                this is how an unlanded pair is measured: one step per arm, both at the same landed commit.
#   fronts=LIST  what each round leaves in front at the quit (the check's --fronts; default terminal,chat)
# Prints L5-ROUND lines per relaunch and one L5 {json} verdict; keeps l5.json, report.json and app.log in report.tgz.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
out="$PWD/.build/relaunch-restore"
rm -rf "$out" && mkdir -p "$out"
dmg=nightly config=bench extra=() build_sha=""
for arg in "$@"; do
  case "$arg" in
    dmg=nightly|dmg=build|dmg=https://*) dmg="${arg#dmg=}" ;;
    rounds=*) extra+=(--rounds "${arg#rounds=}") ;;
    budget_ms=*) extra+=(--budget-ms "${arg#budget_ms=}") ;;
    fronts=*) extra+=(--fronts "${arg#fronts=}") ;;
    config=bench|config=Release|config=Debug) config="${arg#config=}" ;;
    build=*) build_sha="${arg#build=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if [[ -n "$build_sha" ]]; then
  [[ "$build_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "build=$build_sha: want a full 40-hex commit sha" >&2; exit 2; }
  [[ "$dmg" == build ]] || { echo "build=SHA needs dmg=build (it builds the app at SHA)" >&2; exit 2; }
fi
echo "L5 host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
if [[ "$dmg" == build ]]; then
  configuration=()
  case "$config" in
    bench) configuration=(--config bench) ;;
    Release) configuration=(--release) ;;
  esac
fi
if [[ -n "$build_sha" ]]; then
  echo "L5 build $build_sha config $config"
  echo "L5 driver $(git rev-parse HEAD)"
  . scripts/measure/app-at-commit.sh
  # The commit's worktree lives outside $out, so report.tgz holds its build log and not its tree.
  at_dir="$(mktemp -d)"
  trap 'rm -rf -- "$at_dir"' EXIT
  app="$(measure_app_at_commit "$build_sha" l5relaunch "$at_dir/at" --no-global-cli-links ${configuration[@]+"${configuration[@]}"} 2>"$out/reload.log")"
  build_status=$?
  if [[ "$build_status" -ne 0 || -z "$app" || ! -d "$app" ]]; then
    echo "L5 build failed: the build at $build_sha printed no app path" >&2
    tail -n 60 "$out/reload.log" >&2
    exit 3
  fi
  trap 'python3 scripts/cmux-next/tag_teardown.py "$app" >/dev/null 2>&1; rm -rf -- "$at_dir"' EXIT
  python3 scripts/ci/relaunch_restore_check.py --app "$app" --out "$out/run" ${extra[@]+"${extra[@]}"} 2>&1 | tee "$out/run.log"
  rc=${PIPESTATUS[0]}
elif [[ "$dmg" == build ]]; then
  echo "L5 build $(git rev-parse HEAD) config $config"
  # A fleet step checks out no submodules: the app build needs Ghostty's headers and the ghostty-next tree,
  # and GhosttyKit.xcframework (a prebuilt download), as perf-idle-power.sh fetches them.
  for sub in ghostty ghostty-next; do
    [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub" || exit 3
  done
  if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
    rm -rf GhosttyKit.xcframework
    if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    ./scripts/download-prebuilt-ghosttykit.sh || exit 3
  fi
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag l5relaunch --no-global-cli-links ${configuration[@]+"${configuration[@]}"} >"$out/reload.log" 2>&1
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "L5 build failed: the tagged build printed no app path" >&2
    grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2
    tail -n 40 "$out/reload.log" >&2
    exit 3
  fi
  # The tagged app's processes end with the step, also when the check is stopped mid-run.
  trap 'python3 scripts/cmux-next/tag_teardown.py "$app" >/dev/null 2>&1' EXIT
  python3 scripts/ci/relaunch_restore_check.py --app "$app" --out "$out/run" ${extra[@]+"${extra[@]}"} 2>&1 | tee "$out/run.log"
  rc=${PIPESTATUS[0]}
else
  if [[ "$dmg" == nightly ]]; then
    feed="https://files-next.cmux.com/nightly-next/appcast-arm64.xml"  # the one feed since #36287
    curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-relaunch-restore/1 -H "Cache-Control: no-cache" -o "$out/feed.xml" "$feed" || { echo "L5 feed download failed"; exit 3; }
    picked="$(python3 scripts/ci/nightly_next_launch_smoke.py pick --feed "$out/feed.xml")" || { echo "L5 no nightly build on the feed"; exit 3; }
    echo "$picked" | sed 's/^/L5 pick /'
    dmg="$(sed -n 's/^url=//p' <<<"$picked")"
  fi
  echo "L5 dmg $dmg"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-relaunch-restore/1 -o "$out/in.dmg" "$dmg" || { echo "L5 download failed"; exit 3; }
  python3 scripts/ci/relaunch_restore_check.py --dmg "$out/in.dmg" --out "$out/run" ${extra[@]+"${extra[@]}"} 2>&1 | tee "$out/run.log"
  rc=${PIPESTATUS[0]}
  rm -f "$out/in.dmg"
fi
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
exit "$rc"
