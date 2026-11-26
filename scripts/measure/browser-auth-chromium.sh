#!/usr/bin/env bash
# The Chromium login/redirect/popup cases (cases 8-15 of scripts/cmux-next/browser-auth-flows-live.py) in cmux NEXT
# on a fleet Mac with a console session. Leo 2026-11-24 (after cmux#53071): "> this is fixable. I feel like there is
# similar thing maybe with probably logins and redirects and popups and whatnot... things to examine and shit"
# (ask-2d244f2b2e). A build of the ref (build=here, DEBUG: the debug.* checks need it) or the NIGHTLY DMG is copied
# into a side instance, as meet-browser.sh does, and the live script drives it with the local fixture provider.
#   cmux-ci run --class exclusive --label measure --display \
#     --script scripts/measure/browser-auth-chromium.sh --ref <sha> --arg=build=here [--arg=only=8,9] \
#     --artifact .build/browser-auth-chromium/report.tgz --timeout 3000
# Prints the script's ok/FAIL lines and BROWSER_AUTH_CHROMIUM exit=N.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/browser-auth-chromium"
rm -rf "$out" && mkdir -p "$out"
dmg="" build_job="" only=""
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    build=*) build_job="${arg#build=}" ;;
    only=*) only="${arg#only=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ -z "$only" || "$only" =~ ^[0-9,]+$ ]] || { echo "only=8,9 takes case numbers" >&2; exit 2; }
[[ -z "$build_job" || ( -z "$dmg" && "$build_job" =~ ^([0-9a-f]{24}|here)$ ) ]] || { echo "use one app source: build=JOB or dmg=URL" >&2; exit 2; }
if [[ -z "$build_job$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ -n "$build_job" || "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
echo "BROWSER_AUTH_CHROMIUM host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername) dmg $dmg"

work="$(mktemp -d "${TMPDIR:-/tmp}/browser-auth-chromium.XXXXXX")"
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="authchromium"
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
  tag="auth-$(git rev-parse --short=10 HEAD)"
  # A worker's warm checkout has no submodules and no GhosttyKit: get them first, as split-spring.sh does
  # (without them cargo's ghostty-vt-sys build script fails: cmux18 step c447fb01).
  for sub in ghostty ghostty-next; do
    if [ ! -e "$sub/.git" ]; then
      echo "BROWSER_AUTH_CHROMIUM fetching submodule $sub"
      git submodule update --init --depth 1 "$sub" || exit 1
    fi
  done
  if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
    rm -rf GhosttyKit.xcframework
    if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    echo "BROWSER_AUTH_CHROMIUM getting GhosttyKit"
    ./scripts/download-prebuilt-ghosttykit.sh || exit 1
  fi
  echo "BROWSER_AUTH_CHROMIUM building the app at $(git rev-parse HEAD) (reload.sh --tag $tag)"
  # Streamed into the step's output (and kept), so a failure shows its cause, not only cargo's last line.
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log"
  built="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
  if [[ -z "$built" || ! -d "$built" ]]; then
    echo "BROWSER_AUTH_CHROMIUM the tagged build printed no app path" >&2
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
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "BROWSER_AUTH_CHROMIUM download failed"; exit 3; }
  mnt="$work/mnt"; mkdir -p "$mnt"
  hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
  app="$work/app/cmux NIGHTLY.app"
  ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$app" || exit 3
  hdiutil detach "$mnt" >/dev/null || exit 3
  mnt=""
fi
[[ -f "$app/Contents/Info.plist" ]] || { echo "BROWSER_AUTH_CHROMIUM no app in the supplied artifact" >&2; exit 3; }
"$side" make "$name" --from "$app" --label "cmux auth" >&2 || exit 3
plist="$app/Contents/Info.plist"
version="" build=""
[[ -f "$plist" ]] && version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
[[ -f "$plist" ]] && build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
status=0
"$side" launch "$name" --front >&2 || exit 3
sock="$("$side" socket "$name")"
for _ in $(seq 1 90); do [[ -S "$sock" ]] && break; sleep 1; done
sleep 10
cli="$app/Contents/Resources/bin/cmux"
[[ -x "$cli" ]] || cli="$(command -v cmux || true)"
mkdir -p "$work/bin" && ln -sf "$cli" "$work/bin/cmux"
PATH="$work/bin:$PATH" python3 scripts/cmux-next/browser-auth-flows-live.py --socket "$sock" \
  --app-pid "$(cat "$CMUX_SIDE_ROOT/$name/pid" 2>/dev/null || echo 0)" --diag-dir "$out" \
  ${only:+--only "$only"} 2>&1 | tee "$out/fixture.log"
[[ ${PIPESTATUS[0]} -eq 0 ]] || status=1
"$side" stop "$name" >&2 || true
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . || exit 3
echo "BROWSER_AUTH_CHROMIUM exit=$status"
exit "$status"
