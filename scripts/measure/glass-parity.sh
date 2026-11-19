#!/usr/bin/env bash
# Fleet entry for the Liquid Glass Parity matrix (scripts/cmux-next/glass-parity-shots.py): builds a tagged cmux-next
# app at this checkout (bench configuration: Release optimization with the debug.* control commands kept, so the
# frame times are an optimized app's), starts a 2x virtual display at --hz on the host's 1x screen, and runs the
# overlay matrix (every glass surface native, in WebKit and in Chromium, diffed pixel by pixel) and the frame-time
# measure. It launches and activates an app, so it runs alone on a display worker's console session:
#   cmux-ci run --class exclusive --display --measurement --label measure --script scripts/measure/glass-parity.sh \
#     --ref <sha> --artifact artifacts/glass-parity/glass-parity.tar.gz [--arg=--matrix=quick] [--arg=--only=...]
# The artifact holds summary.md, results.json, frames.json, app.log, every crop of a failing cell and the crops and
# window shots of a few reference scenarios (all of them would be gigabytes). The step exits 0 when the matrix ran,
# whatever its cells say (the artifact comes back only from a passing step); GATE= in the log is the verdict.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="glassparity"
out="$(pwd)/artifacts/glass-parity"
shots="$out/shots"
mkdir -p "$shots"
hz=120 args=()
for arg in "$@"; do
  case "$arg" in
    --hz=*) hz="${arg#--hz=}" ;;
    *) args+=("$arg") ;;
  esac
done
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --config bench 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "glass-parity: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
vd="$out/vdisplay"
mkdir -p "$vd/VDisplay.app/Contents/MacOS"
xcrun clang -fobjc-arc -O2 -Wno-deprecated-declarations -framework AppKit -framework CoreVideo \
  scripts/ci/frame-pacing/vdisplay.m -o "$vd/VDisplay.app/Contents/MacOS/VDisplay"
cp scripts/ci/frame-pacing/VDisplay-Info.plist "$vd/VDisplay.app/Contents/Info.plist"
codesign -s - --force "$vd/VDisplay.app" 2>/dev/null || true
status=0
python3 scripts/cmux-next/glass-parity-shots.py --app "$app" --tag "$tag" --out "$shots" --vdisplay "$vd/VDisplay.app" \
  --vdisplay-hidpi --hz "$hz" --activate --frames ${args[@]+"${args[@]}"} || status=$?
python3 scripts/cmux-next/tag_teardown.py "$app" >/dev/null 2>&1 || true
if [[ ! -f "$shots/results.json" ]]; then
  echo "glass-parity: the matrix wrote no results" >&2
  exit 1
fi
# Keep every file of a failing cell and of the reference scenarios; drop the rest.
python3 - "$shots" <<'PY'
import json, os, re, sys
root = sys.argv[1]
data = json.load(open(os.path.join(root, "results.json")))
reference = re.compile(r"^(wallpaper|plain|terminal-o60|wallpaper-.*-hover)-host-active(-hover)?-(light|dark)-2x$")
stems = sorted({r["stem"] for r in data["rows"]}, key=len, reverse=True)
failing = {(r["stem"], r["kind"]) for r in data["rows"] if r["gated"] and not r["pass"]}
removed = 0
for name in os.listdir(root):
    if not name.endswith(".png"):
        continue
    stem = next((s for s in stems if f"-{s}." in name or f"-{s}-" in name), None)
    kind = name.split("-", 1)[0]
    # Window shots (seven a scenario, about a megabyte each at 2x) for the reference scenarios only.
    keep = stem is not None and (reference.match(stem) or (stem, kind) in failing)
    if not keep:
        os.remove(os.path.join(root, name))
        removed += 1
print(f"glass-parity: kept {sum(n.endswith('.png') for n in os.listdir(root))} shots, dropped {removed}")
PY
cp "$out/reload.log" "$shots/" 2>/dev/null || true
tar -czf "$out/glass-parity.tar.gz" -C "$out" shots
echo "GATE=$([[ $status == 0 ]] && echo pass || echo fail) (glass-parity-shots exit $status)"
head -n 3 "$shots/summary.md" || true
