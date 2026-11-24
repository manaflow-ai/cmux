#!/usr/bin/env bash
# Fleet entry for the Liquid Glass Parity matrix (scripts/cmux-next/glass-parity-shots.py): builds a tagged bench app
# (Release optimization with the debug.* control commands kept, so frame times are an optimized app's) at this
# checkout through app-at-commit.sh, compiles the virtual display helper (scripts/ci/frame-pacing/vdisplay.m; the
# harness starts it as the main display, 2x at --hz, beside the host's own 1x screen for the 1x cells), and runs the
# overlay matrix (every glass surface native, in WebKit and in Chromium, diffed pixel by pixel) and the frame-time
# measure in the console user's GUI session (scripts/ci/frame-pacing/console-session.sh), as hover-card-press.sh does:
#   cmux-ci run --class exclusive --measurement --label measure --urgent --pool perf-lead --target-worker aws-m4pro-7 \
#     --pin-strict --script scripts/measure/glass-parity.sh --ref <a feat-cmux-next sha with this script> \
#     --artifact artifacts/glass-parity/glass-parity.tar.gz [--arg=--hz=120] [--arg=--matrix=quick] [--arg=--only=...]
# 2x cells need --arg=--hz=60 on aws-m4pro-7: its HiDPI virtual display comes up at 2x only at 60 Hz (at 120 Hz it
# stays 1x and the 2x cells are skipped; scripts/measure/vdisplay-hidpi-probe.sh, runs 11 and 12).
# The artifact holds summary.md, results.json, frames.json, app.log, every crop of a failing cell and the crops and
# window shots of the reference scenarios (all of them would be gigabytes). The step exits 0 when the matrix ran,
# whatever its cells say (the artifact comes back only from a passing step); GATE= in the log is the verdict.
# No xctrace: a long attached recording took a Mac down (2026-11-18).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/measure/app-at-commit.sh
tag="glassparity"
out="$(pwd)/artifacts/glass-parity"
shots="$out/shots"
mkdir -p "$shots"
hz=120 cef="" args=()
for arg in "$@"; do
  case "$arg" in
    --hz=*) hz="${arg#--hz=}" ;;
    # --cef=VERSION@SHA256: build against an unreleased engine the fleet store holds (cmux-ci artifact-put of its
    # macos-arm64 archive), to measure a fork change before its release; the pinned manifest otherwise.
    --cef=*) cef="${arg#--cef=}" ;;
    *) args+=("$arg") ;;
  esac
done
# cmux-tui builds in a target of this measure's own: the host's shared one (CI_SHARED_CACHE_DIR/cmux-tui-client-target)
# reused a stale cmux-tui-util on aws-m4pro-7 (step a89bbf49c265a936150712bf: "unresolved import AgentsCmuxMcp", which
# this tree defines), and failed the app build.
export CMUX_TUI_CLIENT_TARGET_DIR="${CI_SHARED_CACHE_DIR:-$(pwd)/cmux-tui/target}/glass-parity-cmux-tui-target"
# The explicit precompiled modules of the kept DerivedData go stale when a C header a module map names changes
# (step b144aae4: "cmux_motion_ffi.h has been modified since the module file", the bench app did not build). They
# rebuild in seconds; the compiled Swift stays.
rm -rf "$(pwd)/.build/DerivedData/cmux-measure-at/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules"
scratch="$(mktemp -d)"
trap 'measure_remove_scratch "$scratch"' EXIT
if [[ -n "$cef" ]]; then
  python3 - "$cef" scripts/cmux-next/cef-manifest.json "$scratch/cef-manifest.json" <<'PY'
import json, re, sys
version, sha = sys.argv[1].split("@")
assert re.fullmatch(r"cef-[0-9.]+-cmux\.[0-9]+", version) and re.fullmatch(r"[0-9a-f]{64}", sha), sys.argv[1]
manifest = json.load(open(sys.argv[2]))
asset = f"{version}-macos-arm64.tar.xz"
manifest.update(version=version, tag=version, asset=asset, sha256=sha, r2_key="", url="")
json.dump(manifest, open(sys.argv[3], "w"), indent=2)
PY
  export CMUX_CEF_MANIFEST="$scratch/cef-manifest.json" CMUX_CEF_NO_R2=1 CMUX_CEF_NO_GITHUB=1
  echo "glass-parity: engine $cef (store)"
fi
app="$(measure_app_at_commit "$(git rev-parse HEAD)" "$tag" "$scratch/tree" --config bench)" \
  || { echo "glass-parity: the bench app did not build" >&2; exit 1; }
echo "glass-parity: app $app"
vd="$out/vdisplay"
mkdir -p "$vd/VDisplay.app/Contents/MacOS"
xcrun clang -fobjc-arc -O2 -Wno-deprecated-declarations -framework AppKit -framework CoreVideo \
  scripts/ci/frame-pacing/vdisplay.m -o "$vd/VDisplay.app/Contents/MacOS/VDisplay"
cp scripts/ci/frame-pacing/VDisplay-Info.plist "$vd/VDisplay.app/Contents/Info.plist"
codesign -s - --force "$vd/VDisplay.app" 2>/dev/null || true
status=0
GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh \
  python3 -I "$PWD/scripts/cmux-next/glass-parity-shots.py" --app "$app" --tag "$tag" --out "$shots" --vdisplay "$vd/VDisplay.app" \
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
reference = re.compile(r"^(wallpaper|plain|terminal-o60|wallpaper-.*-hover)-host-active(-hover)?-(light|dark)-(1x|2x)$")
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
tar -czf "$out/glass-parity.tar.gz" -C "$out" shots
echo "GATE=$([[ $status == 0 ]] && echo pass || echo fail) (glass-parity-shots exit $status)"
head -n 3 "$shots/summary.md" || true
