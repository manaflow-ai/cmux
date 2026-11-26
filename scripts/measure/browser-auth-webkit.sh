#!/usr/bin/env bash
# Login flows (popups with opener, window.close, cross-host redirects, SameSite cookies, third-party iframes)
# in a cmux NEXT browser tab, on a fleet Mac: scripts/cmux-next/browser-auth-flows-live.py against a side
# instance of the NIGHTLY DMG (or a build of this checkout). Leo, 2026-11-24, after cmux#53071: "> this is
# fixable. I feel like there is similar thing maybe with probably logins and redirects and popups and
# whatnot... things to examine and shit". Leo-Ask-Trace: ask-2d244f2b2e
#   cmux-ci run --class exclusive --label measure --display \
#     --script scripts/measure/browser-auth-webkit.sh --ref <sha> [--arg=engine=webkit] [--arg=build=here] \
#     --timeout 2700
#   engine=webkit|chromium  the tab's engine (default webkit)
#   dmg=URL | build=JOB | build=here   the app, as in meet-browser.sh (default: newest NIGHTLY)
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/browser-auth-webkit"
rm -rf "$out" && mkdir -p "$out"
dmg="" build_job="" engine=webkit
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    build=*) build_job="${arg#build=}" ;;
    engine=webkit|engine=chromium) engine="${arg#engine=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ -z "$build_job" || ( -z "$dmg" && "$build_job" =~ ^([0-9a-f]{24}|here)$ ) ]] || { echo "use one app source: build=JOB or dmg=URL" >&2; exit 2; }
if [[ -z "$build_job$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ -n "$build_job" || "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
echo "AUTHFLOWS host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername) dmg $dmg"

work="$(mktemp -d "${TMPDIR:-/tmp}/browser-auth-webkit.XXXXXX")"
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="authflows"
mnt=""
# shellcheck disable=SC2317  # run by the EXIT trap
cleanup() {
  "$side" remove "$name" >/dev/null 2>&1 || true
  [[ -n "$mnt" ]] && hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$work/app"
if [[ "$build_job" == here ]]; then
  tag="authflows-$(git rev-parse --short=10 HEAD)"
  # A worker's warm checkout has no submodules and no GhosttyKit: get them first, as split-spring.sh does
  # (without them cargo's ghostty-vt-sys build script fails: cmux18 step c447fb01).
  for sub in ghostty ghostty-next; do
    if [ ! -e "$sub/.git" ]; then
      echo "AUTHFLOWS fetching submodule $sub"
      git submodule update --init --depth 1 "$sub" || exit 1
    fi
  done
  if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
    rm -rf GhosttyKit.xcframework
    if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    echo "AUTHFLOWS getting GhosttyKit"
    ./scripts/download-prebuilt-ghosttykit.sh || exit 1
  fi
  echo "AUTHFLOWS building the app at $(git rev-parse HEAD) (reload.sh --tag $tag)"
  # Streamed into the step's output (and kept), so a failure shows its cause, not only cargo's last line.
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log"
  built="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
  if [[ -z "$built" || ! -d "$built" ]]; then
    echo "AUTHFLOWS the tagged build printed no app path" >&2
    grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 40 >&2
    build_log="$(sed -n 's/^==> log: //p' "$out/reload.log" | tail -n 1)"
    [[ -n "$build_log" && -f "$build_log" ]] && grep -E "error: " "$build_log" | head -n 40 >&2
    exit 1
  fi
  app="$work/app/$(basename "$built")"
  ditto "$built" "$app" || exit 3
elif [[ -n "$build_job" ]]; then
  ci="$(command -v cmux-ci || true)"
  ci="${ci:-$HOME/.local/bin/cmux-ci}"
  "$ci" artifact "$build_job" "$work/app.zip" || exit 3
  ditto -x -k "$work/app.zip" "$work/app" || exit 3
  app="$(find "$work/app" -maxdepth 3 -name '*.app' -prune -print | head -1)"
else
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "AUTHFLOWS download failed"; exit 3; }
  mnt="$work/mnt"; mkdir -p "$mnt"
  hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
  app="$work/app/cmux NIGHTLY.app"
  ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$app" || exit 3
  hdiutil detach "$mnt" >/dev/null || exit 3
  mnt=""
fi
[[ -f "$app/Contents/Info.plist" ]] || { echo "AUTHFLOWS no app in the supplied artifact" >&2; exit 3; }
"$side" make "$name" --from "$app" --label "cmux authflows" >&2 || exit 3
plist="$app/Contents/Info.plist"
version="" build=""
[[ -f "$plist" ]] && version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
[[ -f "$plist" ]] && build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
"$side" launch "$name" --shown >&2 || exit 3
sock=""
for _ in $(seq 1 60); do sock="$("$side" socket "$name" 2>/dev/null)"; [[ -S "$sock" ]] && break; sleep 2; done
[[ -S "$sock" ]] || { echo "AUTHFLOWS the side copy gave no control socket" >&2; exit 3; }
sleep 5
# The app's own CLI first on PATH, as browser-auth-chromium.sh does: the harness's `cmux --app-socket`
# calls (tabs, downloads) must reach this side copy, not a host cmux on the default socket.
cli="$app/Contents/Resources/bin/cmux"
[[ -x "$cli" ]] || cli="$(command -v cmux || true)"
mkdir -p "$work/bin" && ln -sf "$cli" "$work/bin/cmux"
PATH="$work/bin:$PATH" python3 scripts/cmux-next/browser-auth-flows-live.py --socket "$sock" --engine "$engine" \
  --app-pid "$(cat "$CMUX_SIDE_ROOT/$name/pid" 2>/dev/null || echo 0)" --diag-dir "$out" 2>&1 | tee "$out/run.log"
status=${PIPESTATUS[0]}
"$side" stop "$name" >&2 || true
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . || exit 3
echo "AUTHFLOWS engine=$engine exit=$status"
exit "$status"
