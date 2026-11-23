#!/usr/bin/env bash
# Extension rows closed in code, read back on a published cmux NEXT NIGHTLY, on a fleet Mac with a console
# session (measurement only): the NIGHTLY DMG from the feed is copied into a side instance (its own bundle
# id, data, daemon and customize folder; the Mac's own apps are untouched) and launched, then
# scripts/measure/ext-rows-nightly.py runs one function per row through the copy's own CLI and daemon ops,
# no clicks: web panes, background activation, link openers, the New Tab page, `ext new` for every kind,
# composer slash commands and mentions, status items, background event workers, chat-widget routing,
# context-menu rows, agent (MCP) tools, plugin CLI subcommands and a forked first-party app.
#   cmux-ci run --class exclusive --label measure --display \
#     --script scripts/measure/ext-rows-nightly.sh --ref <sha> [--arg=dmg=URL] [--arg=rows=a,b] \
#     --artifact .build/ext-rows-nightly/report.tgz --timeout 1200
#   dmg=URL    the nightly DMG (default: the newest in the NEXT feed)
#   rows=a,b   some rows only (default: every row in ext-rows-nightly.py ROWS)
# Prints the receipt (EXT_ROWS_NIGHTLY {json}) and keeps it, with the scaffolds' pictures and the run log, in
# report.tgz. The copy is removed at the end.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/ext-rows-nightly"
rm -rf "$out" && mkdir -p "$out"
dmg="" rows=""
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    rows=*) rows="${arg#rows=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ -z "$rows" || "$rows" =~ ^[a-z_,]+$ ]] || { echo "rows=a,b takes row names" >&2; exit 2; }
if [[ -z "$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
echo "ERW host $(hostname -s) macOS $(sw_vers -productVersion) dmg $dmg"

work="$(mktemp -d "${TMPDIR:-/tmp}/ext-rows-nightly.XXXXXX")"
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="extrows"
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

curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "ERW download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt" "$work/app"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$work/app/cmux NIGHTLY.app"
hdiutil detach "$mnt" >/dev/null; mnt=""
"$side" make "$name" --from "$work/app/cmux NIGHTLY.app" --label "cmux ext rows" --customize >&2 || exit 3
app="$("$side" path "$name")"
"$side" launch "$name" >&2 || exit 3
python3 scripts/measure/ext-rows-nightly.py --app "$app" --pid-file "$CMUX_SIDE_ROOT/$name/pid" \
  --control-socket "$("$side" socket "$name")" \
  --customize "$CMUX_SIDE_ROOT/$name/customize" --out "$out" ${rows:+--rows "$rows"} 2>&1 | tee "$out/run.log"
status=${PIPESTATUS[0]}
"$side" stop "$name" >&2 || true
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
echo "ERW exit=$status"
exit "$status"
