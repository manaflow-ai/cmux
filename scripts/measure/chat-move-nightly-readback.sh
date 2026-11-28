#!/usr/bin/env bash
# A chat moved between Local, Cloud and AutoCloud by the CLI, every direction, in a published cmux NEXT
# NIGHTLY, on a fleet Mac. The NIGHTLY DMG is copied into a side instance (its own bundle id, data, daemon
# and config folder; the Mac's own apps are untouched), signed in with the step's own agent session
# (cmux-ci run --sign-in agent; cloud-mvp-nightly-readback.py prepare puts its refresh token in the copy's
# own token store file, never argv, environment or logs), with experiments.cloudToggle and cloud.autoCloud
# on in the copy's own settings only. scripts/measure/chat-move-nightly-readback.py then drives the copy's
# bundled `cmux` CLI: one chat on a small git folder, moved L->C, C->A, A->L, L->A, A->C, C->L with
# `cmux chat move SESSION --on PLACE --json`, each move timed to the point where the same move answers
# `already` (the chat's row reads that place), and one move by the chat's own agent (`cmux chat move --on
# cloud` from its shell).
#   cmux-ci run --class exclusive --display --pin-strict --sign-in agent \
#     --script scripts/measure/chat-move-nightly-readback.sh --ref <sha> \
#     [--arg=build=VERSION | --arg=dmg=URL] \
#     --artifact .build/chat-move-nightly-readback/report.tgz --timeout 2400
#   build=VERSION  a NIGHTLY's build number (CFBundleVersion, e.g. 4612541169301): its DMG on files-next.cmux.com
#   dmg=URL        any NIGHTLY DMG (default: the newest in the NEXT feed)
# Leo, 2026-11-25 (ask-af0e3bf355): "cli stuff/agents being able to toggle to and from and whatever
# autocloud and such".
# Prints CMV PASS/FAIL lines with ms, then the receipt (CHAT_MOVE_READBACK {json}); report.tgz holds
# result.json and every answer. Exit 0 when every move passed, 1 on a product failure, 3 when the rig could
# not run it (no session, no download, no daemon). The copy and its sign-in are removed at the end.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/chat-move-nightly-readback"
rm -rf "$out" && mkdir -p "$out"
dmg="" build=""
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmg="${arg#dmg=}" ;;
    build=*) build="${arg#build=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if [[ -n "$build" ]]; then
  [[ "$build" =~ ^[0-9]+$ ]] || { echo "build=VERSION takes a NIGHTLY build number" >&2; exit 2; }
  dmg="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-$build.dmg"
fi
if [[ -z "$dmg" ]]; then
  dmg="$(curl -fsSL --retry 3 --retry-all-errors https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ "$dmg" == https://* ]] || { echo "no nightly DMG in the feed" >&2; exit 3; }
echo "CMV host macOS $(sw_vers -productVersion) dmg $dmg"
# A move to the Cloud needs the account: signed out, the run is the rig's (exit 3), not the product's.
[[ -n "${CMUX_CI_SIGNIN_FILE:-}" ]] || { echo "CMV FAIL rig: no CMUX_CI_SIGNIN_FILE (send the step with --sign-in agent)"; exit 3; }

work="$(mktemp -d "${TMPDIR:-/tmp}/chat-move-readback.XXXXXX")"
mkdir -p "$work/side" "$work/chat"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="chatmove"
cleanup() {
  "$side" stop "$name" >/dev/null 2>&1 || true
  "$side" remove "$name" >/dev/null 2>&1 || true
  [[ -n "${mnt:-}" ]] && hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "CMV FAIL rig: download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt" "$work/app"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$work/app/cmux NIGHTLY.app"
hdiutil detach "$mnt" >/dev/null; mnt=""
"$side" make "$name" --from "$work/app/cmux NIGHTLY.app" --label "cmux chat move" --neutral-shell >&2 || exit 3
app="$("$side" path "$name")"
config="$CMUX_SIDE_ROOT/$name/config"

# The small folder the chat works in: one file, a git repo, nothing of the Mac's own.
folder="$work/chat/chat-move-demo"
mkdir -p "$folder"
printf '# chat move demo\n\nA small folder for the Local/Cloud/Auto read-back.\n' >"$folder/README.md"
git -C "$folder" init -q && git -C "$folder" add -A \
  && git -C "$folder" -c user.name=readback -c user.email=readback@example.invalid commit -qm init

# Settings and sign-in before the first launch, in the copy's own config and token store only.
python3 scripts/measure/cloud-mvp-nightly-readback.py prepare --app "$app" --config "$config" --out "$out" \
  | sed 's/^CMR /CMV /'
[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 3
[[ -s "$out/token-store-path" ]] || { echo "CMV FAIL rig: the copy was not signed in"; exit 3; }

eval "$("$side" env "$name")"
"$side" launch "$name" -- --skip-onboarding >&2 || exit 3
python3 scripts/measure/chat-move-nightly-readback.py --app "$app" --folder "$folder" --dmg "$dmg" --out "$out" \
  2>&1 | tee "$out/run.log"
status=${PIPESTATUS[0]}
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz --exclude token-store-path . 2>/dev/null || true
echo "CMV exit=$status"
exit "$status"
