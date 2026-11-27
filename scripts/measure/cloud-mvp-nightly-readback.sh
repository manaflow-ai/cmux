#!/usr/bin/env bash
# The Auto/Cloud MVP read back in the app on a published cmux NEXT NIGHTLY, on a fleet Mac with a console session.
# The NIGHTLY DMG is copied into a side instance (its own bundle id, data, daemon and config folder; the Mac's own
# apps are untouched), signed in with the step's own agent session (cmux-ci run --sign-in agent: its refresh token
# goes into the copy's own token store file, never argv, environment or logs), with experiments.cloudToggle and
# cloud.autoCloud on in the copy's own settings only, and launched in front while CuaDriver records the display
# (launch_reveal_record.py: fleet steps hold no `screencapture -v` grant). scripts/measure/cloud-mvp-nightly-readback.py
# then drives the copy the way a person does (through the accessibility tree CuaDriver reports): a Claude chat on a
# small folder with Auto, one with Cloud, submit-to-first-reply timed, the place control's labels read as they go,
# and a running chat moved with Only in Cloud (its Moved to Cloud line and Undo).
#   cmux-ci run --class exclusive --display --target-worker HOST --pin-strict --sign-in agent \
#     --script scripts/measure/cloud-mvp-nightly-readback.sh --ref <sha> \
#     [--arg=build=VERSION | --arg=dmg=URL] \
#     --artifact .build/cloud-mvp-nightly-readback/report.tgz --timeout 2400
#   build=VERSION  a NIGHTLY's build number (CFBundleVersion, e.g. 4592220755201): its DMG on files-next.cmux.com
#   dmg=URL        any NIGHTLY DMG (default: the newest in the NEXT feed)
# Leo, 2026-11-26 (ask-bcaf32b275): "austin was also really wanting to have a demo of the auto/hybrid cloud thing.
# and have it in the nightly. can we put our mvp in?"
# Prints CMR PASS/FAIL lines with numbers, then the receipt (CLOUD_MVP_READBACK {json}); report.tgz holds result.json,
# the shots, the video and the copy's log. Exit 0 when every product step passed, 1 on a product failure, 3 when the
# rig could not run it (no recorder, no session, no download). The copy and its sign-in are removed at the end.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/cloud-mvp-nightly-readback"
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
echo "CMR host macOS $(sw_vers -productVersion) dmg $dmg"
[[ -n "${CMUX_CI_SIGNIN_FILE:-}" ]] || { echo "CMR FAIL rig: no CMUX_CI_SIGNIN_FILE (send the step with --sign-in agent)"; exit 3; }
rec_ready="$(python3 scripts/measure/launch_reveal_record.py preflight 2>&1)" \
  || { echo "CMR FAIL rig: cannot record: $rec_ready"; exit 3; }
echo "CMR recorder: $rec_ready"

work="$(mktemp -d "${TMPDIR:-/tmp}/cloud-mvp-readback.XXXXXX")"
mkdir -p "$work/side" "$work/chat"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
side="$root/scripts/cmux-next/side-instance.sh"
name="cloudmvp"
rec_pid=""
cleanup() {
  [[ -n "$rec_pid" ]] && kill -TERM "$rec_pid" 2>/dev/null && wait "$rec_pid" 2>/dev/null
  "$side" remove "$name" >/dev/null 2>&1 || true
  [[ -n "${mnt:-}" ]] && hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/nightly.dmg" "$dmg" || { echo "CMR FAIL rig: download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt" "$work/app"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$work/nightly.dmg" >/dev/null || exit 3
ditto "$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)" "$work/app/cmux NIGHTLY.app"
hdiutil detach "$mnt" >/dev/null; mnt=""
"$side" make "$name" --from "$work/app/cmux NIGHTLY.app" --label "cmux cloud mvp" --neutral-shell >&2 || exit 3
app="$("$side" path "$name")"
config="$CMUX_SIDE_ROOT/$name/config"

# The small folder the chats work in: two files, a git repo, nothing of the Mac's own.
folder="$work/chat/cloud-mvp-demo"
mkdir -p "$folder"
printf '# cloud mvp demo\n\nA small folder for the Auto/Cloud read-back.\n' >"$folder/README.md"
printf 'def add(a, b):\n    return a + b\n' >"$folder/calc.py"
git -C "$folder" init -q && git -C "$folder" add -A \
  && git -C "$folder" -c user.name=readback -c user.email=readback@example.invalid commit -qm init

# Settings and sign-in before the first launch, in the copy's own config and token store only.
python3 scripts/measure/cloud-mvp-nightly-readback.py prepare --app "$app" --config "$config" --out "$out" || exit 3

python3 scripts/measure/launch_reveal_record.py record "$out/video" 1500 >"$out/rec.log" 2>&1 &
rec_pid=$!
for _ in $(seq 1 700); do
  grep -q '^READY' "$out/rec.log" 2>/dev/null && break
  kill -0 "$rec_pid" 2>/dev/null || break
  sleep 0.1
done
grep -q '^READY' "$out/rec.log" || { echo "CMR FAIL rig: recorder did not start: $(head -c 300 "$out/rec.log")"; exit 3; }
"$side" launch "$name" --front -- --skip-onboarding >&2 || exit 3
python3 scripts/measure/cloud-mvp-nightly-readback.py run --app "$app" --pid-file "$CMUX_SIDE_ROOT/$name/pid" \
  --control-socket "$("$side" socket "$name")" --config "$config" --folder "$folder" --dmg "$dmg" \
  --out "$out" 2>&1 | tee "$out/run.log"
status=${PIPESTATUS[0]}
kill -TERM "$rec_pid" 2>/dev/null; wait "$rec_pid" 2>/dev/null; rec_pid=""
video="$(sed -n 's/^VIDEO //p' "$out/rec.log" | tail -1)"
if [[ -n "$video" && -s "$video" ]]; then
  [[ "$video" == "$out"/* ]] || cp "$video" "$out/video/" 2>/dev/null
  echo "CMR video $(basename "$video") $(($(stat -f %z "$video") / 1024)) KiB"
else
  echo "CMR video none: $(tail -c 300 "$out/rec.log")"
fi
"$side" stop "$name" >&2 || true
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
echo "CMR exit=$status"
exit "$status"
