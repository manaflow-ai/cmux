#!/usr/bin/env bash
# Goal next-first-run-setup (cmuxterm-hq goals/next-first-run-setup.md) read once on a fleet Mac, outside the
# synthetic-probes onboarding walk: the newest NEXT Nightly (or build=JOB, dmg=URL) as a fresh side instance
# (scripts/cmux-next/side-instance.sh: its own identity and state, no NEXT state), launched with --onboarding (the
# on side) and then with no flag (the off side, as it ships: onboarding is off by default since cmux 5bef2324).
# Each launch's windows are read by accessibility every 5 s for 45 s, and the rows are judged as hq's
# onboarding_golden_path_probe.py setup_rows does: no row without the title "Set Up cmux"; agents needs both
# "Claude Code" and "Codex", account "cmux account", cli "command line", classic "cmux Classic" (only when Classic
# left a session on this Mac). This changes no default.
#   cmux-ci run --class exclusive --label measure --display --script scripts/measure/first-run-setup-walk.sh \
#     --ref <sha> [--arg=build=JOB|dmg=URL] --artifact .build/first-run-setup-walk/report.tgz --timeout 1800
# Prints `FRSW side=on|off title=0|1 rows=a,b,... {...}` per side, then `FRSW exit=N` (0: on shows the title and
# agents, account and cli; off shows no title).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/first-run-setup-walk"
rm -rf "$out" && mkdir -p "$out"
dmg="" build_job=""
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    build=*) build_job="${arg#build=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ -z "$build_job" || ( -z "$dmg" && "$build_job" =~ ^[0-9a-f]{24}$ ) ]] || { echo "use one app source: build=JOB or dmg=URL" >&2; exit 2; }
if [[ -z "$build_job$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
  [[ "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
fi
echo "FRSW host $(hostname -s) macOS $(sw_vers -productVersion) session $(launchctl managername) source ${build_job:+build=$build_job}${dmg:+dmg=$dmg}"

work="$(mktemp -d "${TMPDIR:-/tmp}/first-run-setup-walk.XXXXXX")"
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="frswalk"
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
  ci="$(command -v cmux-ci || true)"; ci="${ci:-$HOME/.local/bin/cmux-ci}"
  "$ci" artifact "$build_job" "$work/app.zip" || exit 3
  ditto -x -k "$work/app.zip" "$work/app" || exit 3
  app="$(find "$work/app" -maxdepth 3 -name '*.app' -prune -print | head -1)"
else
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "FRSW download failed"; exit 3; }
  mnt="$work/mnt"; mkdir -p "$mnt"
  hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
  app="$work/app/cmux NIGHTLY.app"
  ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$app" || exit 3
  hdiutil detach "$mnt" >/dev/null || exit 3
  mnt=""
fi
[[ -n "$app" && -f "$app/Contents/Info.plist" ]] || { echo "FRSW no app in the supplied artifact" >&2; exit 3; }
pb() { [[ -f "$1/Contents/Info.plist" ]] || return 0; /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
echo "FRSW app $(basename "$app") version $(pb "$app" CFBundleShortVersionString) build $(pb "$app" CFBundleVersion) commit $(pb "$app" CMUXCommit)"
classic=0
[[ -d "$HOME/Library/Application Support/cmux" ]] && classic=1
echo "FRSW classic_state_on_host=$classic"

drv="$work/frsw"
xcrun swiftc -O -o "$drv" scripts/measure/first-run-setup-walk.swift 2>"$out/swiftc.log" || { cat "$out/swiftc.log" >&2; exit 3; }

# rows FILE: setup_rows of the text in FILE, comma-joined (empty without the title).
rows() {
  local t; t="$(tr '\n' ' ' <"$1" | tr -s '[:space:]' ' ' | tr '[:upper:]' '[:lower:]')"
  [[ "$t" == *"set up cmux"* ]] || return 0
  local r=()
  [[ "$t" == *"claude code"* && "$t" == *"codex"* ]] && r+=(agents)
  [[ "$t" == *"cmux account"* ]] && r+=(account)
  [[ "$t" == *"command line"* ]] && r+=(cli)
  [[ "$t" == *"cmux classic"* ]] && r+=(classic)
  (IFS=,; echo ${r[*]+"${r[*]}"})
}

status=0
for which in on off; do
  log="$out/$which.log"; text="$out/$which.text"; : >"$text"
  "$side" stop "$name" >/dev/null 2>&1 || true
  "$side" remove "$name" >/dev/null 2>&1 || true
  "$side" make "$name" --from "$app" --label "cmux frsw" >"$log" 2>&1 || { echo "FRSW side=$which setup failed (make)"; status=3; continue; }
  copy="$("$side" path "$name")"
  bid="$(pb "$copy" CFBundleIdentifier)"
  flag=(); [[ $which == on ]] && flag=(--onboarding)
  "$side" launch "$name" --front -- ${flag[@]+"${flag[@]}"} >>"$log" 2>&1 || { echo "FRSW side=$which setup failed (launch)"; status=3; continue; }
  sock="$("$side" socket "$name")"
  waited=0
  for _ in $(seq 1 90); do [[ -S "$sock" ]] && break; sleep 1; waited=$((waited + 1)); done
  "$drv" "$bid" trusted >>"$log" 2>&1 || { echo "FRSW side=$which no Accessibility grant for the step"; status=2; break; }
  best="" counts=""
  for i in $(seq 1 9); do
    sleep 5
    "$drv" "$bid" text >"$out/$which-$i.ax" 2>>"$log" || true
    grep -v '^FRSW-COUNT' "$out/$which-$i.ax" >>"$text"
    counts="$counts $(grep '^FRSW-COUNT' "$out/$which-$i.ax" | cut -d' ' -f2-)"
    [[ $i == 5 ]] && screencapture -x "$out/$which.png" 2>/dev/null
    r="$(rows "$out/$which-$i.ax")"; [[ ${#r} -gt ${#best} ]] && best="$r"
  done
  title=0; grep -qi 'set up cmux' "$text" && title=1
  union="$(rows "$text")"
  echo "FRSW side=$which title=$title rows=${union} best_single_read=${best} socket_s=$waited reads:${counts}"
  if [[ $which == on ]]; then [[ $title == 1 && "$union" == *agents* && "$union" == *account* && "$union" == *cli* ]] || status=1
  else [[ $title == 0 ]] || status=1; fi
  "$side" stop "$name" >>"$log" 2>&1 || true
done
sort -u "$out/on.text" 2>/dev/null | head -150 | sed 's/^/FRSW on-text: /'
sort -u "$out/off.text" 2>/dev/null | head -60 | sed 's/^/FRSW off-text: /'
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . || exit 3
echo "FRSW exit=$status"
exit "$status"
