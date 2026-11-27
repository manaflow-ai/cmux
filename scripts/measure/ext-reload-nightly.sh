#!/usr/bin/env bash
# Extension hot reload proven on a published cmux NEXT NIGHTLY, on a fleet Mac with a console session
# (measurement only): the NIGHTLY DMG from the feed is copied into a side instance (its own bundle id, data,
# daemon and customize folder; the Mac's own apps are untouched) and launched, then
# scripts/measure/ext-reload-nightly.py runs the NIGHTLY read-back (ext dev left watching
# examples/extensions/activity, a one-line save, then reads only: the watcher reloads on its own and the
# daemon's loaded copy and open views show the edit; no ext shot, no --once) and edit-repaint.py's
# customize, rows, pane, command and shortcut cases in read-back mode, 10 rounds each.
#   cmux-ci run --class exclusive --label measure --display \
#     --script scripts/measure/ext-reload-nightly.sh --ref <sha> [--arg=dmg=URL] [--arg=rounds=N] \
#     --artifact .build/ext-reload-nightly/report.tgz --timeout 1800
#   dmg=URL    the nightly DMG (default: the newest in the NEXT feed)
#   rounds=N   rounds per case (default 10)
# Prints the receipt (EXT_RELOAD_NIGHTLY {json}) and keeps it, with edit-repaint.json and the copy's log, in
# report.tgz. The copy is removed at the end.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/ext-reload-nightly"
rm -rf "$out" && mkdir -p "$out"
dmg="" rounds=10
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$rounds" =~ ^[0-9]+$ ]] || { echo "rounds=N takes a number" >&2; exit 2; }
if [[ -z "$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
echo "ERN host $(hostname -s) macOS $(sw_vers -productVersion) dmg $dmg"

work="$(mktemp -d "${TMPDIR:-/tmp}/ext-reload-nightly.XXXXXX")"
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="extreload"
cleanup() {
  "$side" remove "$name" >/dev/null 2>&1 || true
  [[ -n "${mnt:-}" ]] && hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "ERN download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt" "$work/app"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$work/app/cmux NIGHTLY.app"
hdiutil detach "$mnt" >/dev/null; mnt=""
"$side" make "$name" --from "$work/app/cmux NIGHTLY.app" --label "cmux ext reload" --customize >&2 || exit 3
app="$("$side" path "$name")"
"$side" launch "$name" >&2 || exit 3
python3 scripts/measure/ext-reload-nightly.py --app "$app" --pid-file "$CMUX_SIDE_ROOT/$name/pid" \
  --control-socket "$("$side" socket "$name")" \
  --customize "$CMUX_SIDE_ROOT/$name/customize" --config "$CMUX_SIDE_ROOT/$name/config/cmux-next.json" \
  --rounds "$rounds" --out "$out" 2>&1 | tee "$out/run.log"
status=${PIPESTATUS[0]}
"$side" stop "$name" >&2 || true
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
echo "ERN exit=$status"
exit "$status"
