#!/usr/bin/env bash
# Builds itp-recorder.app from scripts/measure/itp-recorder.swift on a fleet Mac: a screen recorder that films one
# rect at the display's rate (minimumFrameInterval 1/120, no cursor) with host-time frames and a self-check that
# fails a run under 55 fps (the in-tree pages resize work: the Computer Use recorder is fixed at 30 fps). A tool,
# not a measurement: the step gives no number and installs nothing.
#   cmux-ci run --class light --script scripts/measure/itp-recorder.sh --ref <sha> \
#     --artifact .build/itp-recorder/dist [--arg=sign=IDENTITY]
#   sign=IDENTITY  a code signing identity the worker's keychain lists (security find-identity -v -p codesigning),
#                  signed with the designated requirement "bundle id dev.cmux.itp-recorder, team 7WLXT3NR37", so a
#                  Screen Recording grant survives a rebuild. Default ad hoc: the grant then holds for these exact
#                  bytes only (TCC keys an ad hoc app on its cdhash), so install one build and keep it.
# Re-signing the ad hoc build on a Mac that holds a team identity gives the same requirement:
#   codesign --force --options runtime --sign "Apple Development: ..." \
#     -r='designated => identifier "dev.cmux.itp-recorder" and anchor apple generic and certificate leaf[subject.OU] = "7WLXT3NR37"' \
#     itp-recorder.app
# Before packaging, the step checks the self-check (itp-recorder --analyze) on made-up frame lists: a 30 fps span, a
# span with frames missing from the movie and a span whose crop does not hold the bench window at its start (the window
# moved off the crop before the drag) must fail (exit 3); a 120 fps span with one hitch and an unmarked 120 fps run
# must pass (exit 0). dist/: itp-recorder.zip, build.json (commit, signature, cdhash, sha256), check.json.
set -euo pipefail
cd "$(dirname "$0")/../.."
sign=-
for arg in "$@"; do
  case "$arg" in
    sign=?*) sign="${arg#sign=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
bundle_id=dev.cmux.itp-recorder
team_id=7WLXT3NR37
out="$PWD/.build/itp-recorder"
rm -rf "$out"
mkdir -p "$out/dist" "$out/check"
app="$out/itp-recorder.app"
mkdir -p "$app/Contents/MacOS"
commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

xcrun swiftc -O -target arm64-apple-macos14.4 -o "$app/Contents/MacOS/itp-recorder" scripts/measure/itp-recorder.swift \
  >"$out/swiftc.log" 2>&1 || { echo "ITP-REC build failed"; cat "$out/swiftc.log"; exit 3; }
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleExecutable</key><string>itp-recorder</string>
  <key>CFBundleName</key><string>cmux Frame Recorder (dev)</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSUIElement</key><true/>
  <key>ItpRecorderCommit</key><string>$commit</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

if [[ "$sign" == - ]]; then
  codesign --force --sign - --identifier "$bundle_id" "$app"
else
  security find-identity -v -p codesigning | grep -qF "\"$sign\"" \
    || { echo "ITP-REC sign=: this worker's keychain lists no identity \"$sign\""; exit 2; }
  codesign --force --options runtime --timestamp=none --sign "$sign" \
    -r="designated => identifier \"$bundle_id\" and anchor apple generic and certificate leaf[subject.OU] = \"$team_id\"" "$app"
fi
codesign --verify --strict "$app"
"$app/Contents/MacOS/itp-recorder" --version

# The self-check on made-up frames: [name, expected exit, frame list, spans or none].
python3 -I - "$out/check" <<'PY'
import json, os, sys
root = sys.argv[1]
def frames(t0, fps, seconds, hitch=None, missing_every=0):
    out, t, i = [], t0, 0
    while t < t0 + seconds:
        out.append([t, "complete", not (missing_every and i % missing_every == 0)])
        t += 1.0 / fps
        if hitch is not None and i == hitch:
            t += 0.05
        i += 1
    return out
drag = [{"name": "drag", "start": 100.0, "end": 102.0}]
crop = [200.0, 100.0, 1200.0, 800.0]
inside = [[98.0, 210.0, 110.0, 1000.0, 700.0]]  # the bench window's frame, read before the drag: inside the crop
moved = inside + [[99.9, 420.0, 110.0, 1000.0, 700.0]]  # moved right 210 pt just before the drag: past the crop
cases = {
    "slow-30fps": (3, frames(100.0, 30, 2), drag, inside),
    "missing-from-movie": (3, frames(100.0, 120, 2, missing_every=20), drag, inside),
    "window-off-crop": (3, frames(100.0, 120, 2), drag, moved),
    "fast-120fps-one-hitch": (0, frames(100.0, 120, 2, hitch=60), drag, inside),
    "fast-120fps-unmarked": (0, [[99.0, "complete", True], [99.5, "idle", False]] + frames(100.0, 120, 2), None, inside),
}
for name, (expect, rows, spans, window) in cases.items():
    d = os.path.join(root, name)
    os.makedirs(d)
    with open(os.path.join(d, "frames.json"), "w") as f:
        json.dump({"frames": rows, "crop_global_pt": crop, "window": window}, f)
    if spans is not None:
        with open(os.path.join(d, "spans.json"), "w") as f:
            json.dump({"spans": spans}, f)
    with open(os.path.join(d, "expect"), "w") as f:
        f.write("%d\n" % expect)
PY
check_ok=1
printf '{' >"$out/dist/check.json"
sep=""
for dir in "$out/check"/*/; do
  name="$(basename "$dir")"
  expect="$(cat "$dir/expect")"
  set +e
  "$app/Contents/MacOS/itp-recorder" --analyze "$dir" >"$dir/result.json" 2>"$dir/stderr.txt"
  got=$?
  set -e
  if [[ "$got" == "$expect" ]]; then echo "ITP-REC check $name: exit $got as expected"; else
    echo "ITP-REC check $name: exit $got, expected $expect"; cat "$dir/result.json" "$dir/stderr.txt"; check_ok=0
  fi
  printf '%s"%s":{"expect":%s,"exit":%s,"result":%s}' "$sep" "$name" "$expect" "$got" "$(cat "$dir/result.json" 2>/dev/null || echo null)" >>"$out/dist/check.json"
  sep=","
done
printf '}\n' >>"$out/dist/check.json"
[[ "$check_ok" == 1 ]] || { echo "ITP-REC the self-check did not behave"; exit 1; }

(cd "$out" && ditto -c -k --keepParent itp-recorder.app dist/itp-recorder.zip)
info="$(codesign -dvvv "$app" 2>&1)"
requirement="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')"
python3 -I - "$out/dist/build.json" "$commit" "$bundle_id" "$sign" "$(shasum -a 256 "$out/dist/itp-recorder.zip" | awk '{print $1}')" "$requirement" "$info" <<'PY'
import json, sys
path, commit, bundle_id, sign, sha, requirement, info = sys.argv[1:]
fields = dict(line.split("=", 1) for line in info.splitlines() if "=" in line)
json.dump({"commit": commit, "bundle_id": bundle_id, "signature": "adhoc" if sign == "-" else sign,
           "team": fields.get("TeamIdentifier", ""), "cdhash": fields.get("CDHash", ""),
           "designated_requirement": requirement, "zip_sha256": sha}, open(path, "w"), indent=1, sort_keys=True)
PY
cat "$out/dist/build.json"
echo "ITP-REC built $(du -sh "$out/dist/itp-recorder.zip" | awk '{print $1}') at $commit"
