#!/usr/bin/env bash
# hot-apply.py proven on a published cmux NEXT NIGHTLY, on a fleet Mac with a console session
# (measurement only): a side-instance copy of the nightly runs with two shells open, a merged
# commit's Rust part is applied to it, then rolled back, and each step is checked.
#   cmux-ci run --class exclusive --label measure --display \
#     --script scripts/measure/hot-apply-nightly.sh --ref <sha> \
#     --arg=sha=<merged commit> [--arg=dmg=URL] \
#     --artifact .build/hot-apply-nightly/report.tgz --timeout 1800
#   sha=SHA  the merged feat-cmux-next commit to apply (after the nightly's commit)
#   dmg=URL  the nightly DMG (default: the newest in the NEXT feed)
# Prints the receipt (scripts/measure/hot-apply-nightly.py) and keeps it, with both hot-apply receipts
# and the copy's log, in report.tgz. The copy is removed at the end; the Mac's own apps are untouched.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/hot-apply-nightly"
rm -rf "$out" && mkdir -p "$out"
sha="" dmg=""
for arg in "$@"; do
  case "$arg" in
    sha=*) sha="${arg#sha=}" ;;
    dmg=https://*) dmg="${arg#dmg=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "give sha=<40-hex merged commit>" >&2; exit 2; }
# hot-apply.py diffs the nightly's commit against SHA: both must be in this checkout's history.
git fetch -q origin "+refs/heads/feat-cmux-next:refs/remotes/origin/feat-cmux-next"
[[ "$(git rev-parse --is-shallow-repository)" == true ]] && git fetch -q --unshallow origin
if [[ -z "$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
echo "HAN host $(hostname -s) macOS $(sw_vers -productVersion) dmg $dmg sha $sha"

work="$(mktemp -d "${TMPDIR:-/tmp}/hot-apply-nightly.XXXXXX")"
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
export CMUX_HOT_APPLY_STATE_DIR="$work/state"
side="$root/scripts/cmux-next/side-instance.sh"
cleanup() {
  "$side" remove hotapply >/dev/null 2>&1 || true
  [[ -n "${mnt:-}" ]] && hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

curl -fsSL --proto '=https' --retry 3 -o "$work/nightly.dmg" "$dmg" || { echo "HAN download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt" "$work/app"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$work/app/cmux NIGHTLY.app"
hdiutil detach "$mnt" >/dev/null; mnt=""
"$side" make hotapply --from "$work/app/cmux NIGHTLY.app" --label "cmux hot-apply" >&2 || exit 3
app="$("$side" path hotapply)"
eval "$("$side" env hotapply)"
"$side" launch hotapply >&2 || exit 3
python3 scripts/measure/hot-apply-nightly.py --app "$app" --sha "$sha" --pid-file "$CMUX_SIDE_ROOT/hotapply/pid" \
  --out "$out" 2>&1 | tee "$out/run.log"
status=${PIPESTATUS[0]}
cp "$CMUX_HOT_APPLY_STATE_DIR/history.jsonl" "$out/hot-apply-history.jsonl" 2>/dev/null || true
"$side" stop hotapply >&2 || true
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
echo "HAN exit=$status"
exit "$status"
