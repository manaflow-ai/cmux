#!/usr/bin/env bash
# Screen Sharing's five entry points walked by accessibility on one build, as hq's feature-flow probes judge them
# (tools/fleet-reconcilers/feature_flows.json: screen-sharing-palette, -open (the shortcut), -file-menu, -chevron,
# -cli all end in `{"expect": {"ax": {"identifier": "macScreen.home"}}}`). A before/after for a PR without waiting
# for it to land: run this once per build on the same worker, same harness.
#   cmux-ci run --class exclusive --label measure --display --script scripts/measure/screen-share-ax-walk.sh \
#     --ref <sha> --arg=build=JOB|dmg=URL [--arg=only=palette,shortcut,file-menu,chevron,cli] \
#     --artifact .build/screen-share-ax-walk/report.tgz --timeout 1800
# No build or dmg: the newest NIGHTLY. Each probe gets a fresh side instance (scripts/cmux-next/side-instance.sh)
# launched with --skip-onboarding, takes its entry point, then the app's windows are walked down once a second for
# up to 10 s (screen-share-ax-walk.swift `wait`). Prints one `SSAX probe=NAME pass=0|1 {...}` line per probe with
# elements_read, elements_complete (no element, depth or time bound cut the walk), the per-window counts and
# whether cmux.topPage.home showed, then `SSAX exit=N`. report.tgz holds results.json, the logs and a shot each.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/screen-share-ax-walk"
rm -rf "$out" && mkdir -p "$out"
dmg="" build_job="" only="palette,shortcut,file-menu,chevron,cli"
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    build=*) build_job="${arg#build=}" ;;
    only=*) only="${arg#only=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$only" =~ ^[a-z,-]+$ ]] || { echo "only=a,b takes probe names" >&2; exit 2; }
[[ -z "$build_job" || ( -z "$dmg" && "$build_job" =~ ^[0-9a-f]{24}$ ) ]] || { echo "use one app source: build=JOB or dmg=URL" >&2; exit 2; }
if [[ -z "$build_job$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
  [[ "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
fi
echo "SSAX host $(hostname -s) macOS $(sw_vers -productVersion) session $(launchctl managername) source ${build_job:+build=$build_job}${dmg:+dmg=$dmg}"

work="$(mktemp -d "${TMPDIR:-/tmp}/screen-share-ax-walk.XXXXXX")"
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="ssaxwalk"
mnt=""
# shellcheck disable=SC2317  # run by the EXIT trap
cleanup() {
  "$side" stop "$name" >/dev/null 2>&1 || true
  "$side" remove "$name" >/dev/null 2>&1 || true
  [[ -n "$mnt" ]] && hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$work/app"
if [[ -n "$build_job" ]]; then
  ci="$(command -v cmux-ci || true)"
  ci="${ci:-$HOME/.local/bin/cmux-ci}"
  "$ci" artifact "$build_job" "$work/app.zip" || exit 3
  ditto -x -k "$work/app.zip" "$work/app" || exit 3
  app="$(find "$work/app" -maxdepth 3 -name '*.app' -prune -print | head -1)"
else
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "SSAX download failed"; exit 3; }
  mnt="$work/mnt"; mkdir -p "$mnt"
  hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
  app="$work/app/cmux NIGHTLY.app"
  ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$app" || exit 3
  hdiutil detach "$mnt" >/dev/null || exit 3
  mnt=""
fi
[[ -n "$app" && -f "$app/Contents/Info.plist" ]] || { echo "SSAX no app in the supplied artifact" >&2; exit 3; }
pb() { [[ -f "$1/Contents/Info.plist" ]] || return 0; /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
echo "SSAX app $(basename "$app") version $(pb "$app" CFBundleShortVersionString) build $(pb "$app" CFBundleVersion) commit $(pb "$app" CMUXCommit)"

drv="$work/ssax"
xcrun swiftc -O -o "$drv" scripts/measure/screen-share-ax-walk.swift 2>"$out/swiftc.log" || { cat "$out/swiftc.log" >&2; exit 3; }

status=0
results="$out/results.jsonl"
: >"$results"
IFS=, read -r -a probes <<<"$only"
for probe in "${probes[@]}"; do
  log="$out/$probe.log"
  "$side" stop "$name" >/dev/null 2>&1 || true
  "$side" remove "$name" >/dev/null 2>&1 || true
  "$side" make "$name" --from "$app" --label "cmux ssax" >"$log" 2>&1 || { echo "SSAX probe=$probe setup failed (make)"; status=1; continue; }
  copy="$("$side" path "$name")"
  bid="$(pb "$copy" CFBundleIdentifier)"
  "$side" launch "$name" --front -- --skip-onboarding >>"$log" 2>&1 || { echo "SSAX probe=$probe setup failed (launch)"; status=1; continue; }
  sock="$("$side" socket "$name")"
  for _ in $(seq 1 90); do [[ -S "$sock" ]] && break; sleep 1; done
  "$drv" "$bid" trusted >>"$log" 2>&1 || { echo "SSAX probe=$probe no Accessibility grant for the step"; status=2; break; }
  # The window settles: the tab strip's + shows (the chevron flow's first element), at most 60 s.
  ready="$("$drv" "$bid" wait cmux.tabs.newTab 60 2>>"$log")"
  echo "ready $ready" >>"$log"
  "$drv" "$bid" activate >>"$log" 2>&1 || true
  act=0
  case "$probe" in
    palette)
      "$drv" "$bid" key cmd+shift+p >>"$log" 2>&1 || act=1
      "$drv" "$bid" wait palette.search 5 >>"$log" 2>&1 || act=1
      "$drv" "$bid" type "Screen Sharing" >>"$log" 2>&1 || act=1
      sleep 1  # the palette filters as typed; return picks the top row
      "$drv" "$bid" key return >>"$log" 2>&1 || act=1 ;;
    shortcut) "$drv" "$bid" key cmd+shift+s >>"$log" 2>&1 || act=1 ;;
    file-menu) "$drv" "$bid" menu File "Screen Sharing" >>"$log" 2>&1 || act=1 ;;
    chevron)
      "$drv" "$bid" hover cmux.tabs.newTab >>"$log" 2>&1 || act=1
      sleep 1  # the flow's hover dwell: the chevron shows on hover
      "$drv" "$bid" click cmux.tabs.newTabMenu >>"$log" 2>&1 || act=1
      sleep 1
      "$drv" "$bid" menuitem "Screen Sharing" >>"$log" 2>&1 || act=1 ;;
    cli)
      cli="$copy/Contents/Resources/bin/cmux"
      CMUX_SOCKET_PATH="$sock" CMUX_NEXT_SOCKET_PATH="$sock" "$cli" --app-socket "$sock" tab new-mac-screen >>"$log" 2>&1 || act=1 ;;
    *) echo "SSAX probe=$probe unknown"; status=2; continue ;;
  esac
  row="$("$drv" "$bid" wait macScreen.home 10 2>>"$log")"
  pass=0; [[ "$row" == *'"found":true'* ]] && pass=1
  [[ $pass == 1 ]] || status=1
  screencapture -x "$out/$probe.png" 2>/dev/null || true
  echo "SSAX probe=$probe pass=$pass action_ok=$((1 - act)) ${row:-"{}"}"
  printf '{"probe":"%s","pass":%s,"action_ok":%s,"walk":%s,"ready":%s}\n' "$probe" "$pass" "$((1 - act))" "${row:-null}" "${ready:-null}" >>"$results"
  "$side" stop "$name" >>"$log" 2>&1 || true
done
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . || exit 3
echo "SSAX exit=$status"
exit "$status"
