#!/usr/bin/env bash
# Launch image capture probe, on a display Mac where the app holds NO Screen Recording grant: does picturing the app's
# own window prompt or add a TCC row, does the picture hold the terminal text and the Chromium page, and what does
# each source cost (scripts/measure/launch-capture-probe.py, schema launch-capture-probe/v1).
#   cmux-ci run --class exclusive --measurement --label measure --display --key KEY \
#     --script scripts/measure/launch-capture-probe.sh --ref <feat-cmux-next sha> \
#     [--arg=build=nightly|SHA|head] [--arg=config=bench] [--arg=rounds=12] \
#     --artifact .build/launch-capture-probe/report.tgz --timeout 3600
#   build=nightly  the newest app the NIGHTLY feed offers (default; as tab-switch.sh); dmg=https:// one DMG instead
#   build=SHA|head an app built at SHA (40 hex) or this checkout, Release; config=bench keeps the debug.* commands, which
#                  add the window server's composite alone and with the page images (debug.window_snapshot)
#   rounds=N       runs per source for the timing (10 to 50, default 12)
# A key=value mode of tab-switch.sh's shape, with its helpers (sourced): the app comes from app_under_test, the screen
# pixels from CuaDriver (the fleet's granted recorder, never the app), the window rect from tools.swift's marker.
# Writes .build/launch-capture-probe/report.json, report.md and images/*.png, all in report.tgz. Prints LCP lines.
# Exit: 0 once a report is written, even one that says it could not measure (an artifact comes back only from a
# passing step, and the report names what failed); 3 when no report was written.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=scripts/measure/tab-switch.sh
source scripts/measure/tab-switch.sh # prepare_build, app_under_test

build=nightly config=release dmg="" rounds=12
for arg in "$@"; do
  case "$arg" in
    build=*) build="${arg#build=}" ;;
    config=release|config=bench) config="${arg#config=}" ;;
    dmg=https://*) dmg="${arg#dmg=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    *) echo "launch-capture-probe: unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$rounds" =~ ^([1-4][0-9]|50)$ && "$rounds" -ge 10 ]] || { echo "launch-capture-probe: rounds= takes 10 to 50" >&2; exit 2; }
[[ "$build" == nightly || "$build" == head || "$build" =~ ^[0-9a-f]{40}$ ]] || { echo "launch-capture-probe: build= is nightly, head or a 40-hex commit" >&2; exit 2; }

root="$PWD" out="$PWD/.build/launch-capture-probe"
rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
tmp="$(mktemp -d)"
# Every exit removes this folder and the build worktree in it, by its own path (a build holds 13 to 18 GB).
LCP_ROOT="$root" LCP_TMP="$tmp"
trap 'git -C "$LCP_ROOT" worktree remove --force "$LCP_TMP/src" >/dev/null 2>&1 || true; rm -rf -- "$LCP_TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 0755 "$tmp" # the probe runs as the console user: it reads the tools and the DMG here
echo "LCP host chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) host $(hostname -s) load=\"$(sysctl -n vm.loadavg)\""
[ -x /Applications/CuaDriver.app/Contents/MacOS/cua-driver ] || { echo "LCP no CuaDriver on this Mac: no screen pixels"; exit 3; }
GITHUB_WORKSPACE="$root" scripts/ci/frame-pacing/console-session.sh python3 -I "$root/scripts/cmux-next/tab_switch_capture.py" \
  preflight || exit 3
swiftc -O -o "$tmp/tab-switch-tools" scripts/measure/tab-switch-frames/tools.swift 2>&1 | tail -n 40 || true
[ -x "$tmp/tab-switch-tools" ] || { echo "LCP the marker did not compile"; exit 3; }
app_under_test "$build" "$config" "$dmg" "$tmp" "$root" launchcap LCP || exit 3

rc=0
set +e
GITHUB_WORKSPACE="$root" scripts/ci/frame-pacing/console-session.sh python3 -I "$root/scripts/measure/launch-capture-probe.py" \
  "${APP_ARGS[@]}" --build "$APP_LABEL" --tools "$tmp/tab-switch-tools" --rounds "$rounds" --out "$out" 2>&1 | tee "$out/run.log"
rc=${PIPESTATUS[0]}
set -e
rm -f "$tmp/in.dmg"
tar -czf "$tmp/report.tgz" -C "$out" . 2>/dev/null && mv "$tmp/report.tgz" "$out/report.tgz"
[[ -f "$out/report.json" ]] || exit 3
echo "LCP probe exit $rc (3: the report says why it could not measure)"
exit 0
