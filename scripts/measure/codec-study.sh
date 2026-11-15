#!/usr/bin/env bash
# The still-frame codec study (scripts/measure/codec-study/README.md): JPEG, PNG, WebP, AVIF, JPEG XL
# and HEIC on cmux screens, at native Retina and at the 1366 px long edge computer use sends a model:
# encode and decode ms, bytes, and Vision OCR character error rate against the lossless original.
# On an Apple-silicon worker (no console grant needed: the scenes are drawn offscreen):
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/codec-study.sh \
#     --ref SHA --artifact artifacts/codec-study/results.json --key KEY --timeout 5400 [--arg=runs=5]
# Args: runs=N (median of N, default 5), only=a,b (setting ids containing a or b), images=N (the
# first N corpus images, for a quick run), sizes=native,1366, ocr=0 (skip OCR).
# On Linux (or with swiftc absent) it runs the library codecs only: a check of the harness, not a
# number to quote, since the ms must come from the Mac.
# Output: CODEC-STUDY lines, artifacts/codec-study/{results.json,summary.md} and the JSON lines
# under it. Exit 0 with results, 4 when no codec ran.
set -uo pipefail
runs=5 only="" images=0 sizes="native,1366" ocr=1
for arg in "$@"; do
  case "$arg" in
    runs=*) runs="${arg#runs=}" ;;
    only=*) only="${arg#only=}" ;;
    images=*) images="${arg#images=}" ;;
    sizes=*) sizes="${arg#sizes=}" ;;
    ocr=*) ocr="${arg#ocr=}" ;;
    *) echo "codec-study.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$runs" =~ ^[1-9][0-9]*$ ]] || { echo "codec-study.sh: runs= is a number from 1" >&2; exit 2; }
[[ "$images" =~ ^[0-9]+$ ]] || { echo "codec-study.sh: images= is a number" >&2; exit 2; }
[[ "$ocr" =~ ^[01]$ ]] || { echo "codec-study.sh: ocr= is 0 or 1" >&2; exit 2; }
[[ "$only" =~ ^[a-z0-9,-]*$ ]] || { echo "codec-study.sh: only= is setting ids" >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
here="$root/scripts/measure/codec-study"
out="$root/artifacts/codec-study"
work="$root/.build/codec-study"
rm -rf "$out" "$work"
mkdir -p "$out" "$work/bin" "$work/corpus/native" "$work/corpus/1366" "$work/encoded"
stage() { echo "CODEC-STUDY-STAGE $* ($(date -u +%H:%M:%SZ))"; }

mac=0
[[ "$(uname -s)" == Darwin ]] && command -v swiftc >/dev/null 2>&1 && mac=1

# The Python codecs: uv (pinned by sha256) makes a venv of a uv-managed Python 3.12 inside $work and
# installs requirements.txt with --require-hashes. Nothing lands outside $work.
stage python
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) uv_asset=uv-aarch64-apple-darwin uv_sha=e0b1d4743ce64c55d9f0f4a444afa6b81125680070ee04e853fcd0f6c1ebf8f1 ;;
  Linux-x86_64) uv_asset=uv-x86_64-unknown-linux-gnu uv_sha=2b428396f12572d4429cf210ca234dd599a33b3af0958a4d5ed569d63e3f344f ;;
  *) echo "CODEC-STUDY-ERROR no pinned uv for $(uname -s)-$(uname -m)"; exit 4 ;;
esac
export UV_CACHE_DIR="$work/uv-cache" UV_PYTHON_INSTALL_DIR="$work/uv-python" UV_NO_CONFIG=1 UV_PYTHON_PREFERENCE=only-managed
uv_tar="$work/$uv_asset.tar.gz"
curl -fsSL --retry 3 -o "$uv_tar" "https://github.com/astral-sh/uv/releases/download/0.13.4/$uv_asset.tar.gz" ||
  { echo "CODEC-STUDY-ERROR could not fetch uv"; exit 4; }
got=$(shasum -a 256 "$uv_tar" 2>/dev/null || sha256sum "$uv_tar")
[[ "${got%% *}" == "$uv_sha" ]] || { echo "CODEC-STUDY-ERROR uv sha256 ${got%% *}, want $uv_sha"; exit 4; }
tar -xzf "$uv_tar" -C "$work/bin" --strip-components 1 "$uv_asset/uv"
"$work/bin/uv" venv --quiet --python 3.12 "$work/venv" || { echo "CODEC-STUDY-ERROR uv venv failed"; exit 4; }
"$work/bin/uv" pip install --quiet --python "$work/venv/bin/python" --require-hashes --only-binary :all: -r "$here/requirements.txt" ||
  { echo "CODEC-STUDY-ERROR the pinned wheels did not install"; exit 4; }
py="$work/venv/bin/python"

machine=$("$py" -I - "$root" "$runs" "$mac" <<'EOF'
import datetime, json, os, platform, subprocess, sys
def run(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception:
        return ""
root, runs, mac = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1"
cpu = run("sysctl", "-n", "machdep.cpu.brand_string") if mac else platform.processor() or platform.machine()
if not mac:
    for line in open("/proc/cpuinfo") if os.path.exists("/proc/cpuinfo") else []:
        if line.startswith("model name"):
            cpu = line.split(":", 1)[1].strip()
            break
print(json.dumps({
    "cpu": cpu, "cores": os.cpu_count(), "macos": run("sw_vers", "-productVersion") if mac else None,
    "os": platform.platform(), "rev": run("git", "-C", root, "rev-parse", "HEAD"), "runs": runs,
    "host_kind": "Apple silicon Mac" if mac else "Linux check (times are not for the study)",
    "memory_gb": round(int(run("sysctl", "-n", "hw.memsize") or 0) / 2**30) if mac else None,
    "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}))
EOF
)
echo "$machine" >"$out/machine.json"
echo "CODEC-STUDY-MACHINE $machine"

# The corpus: the drawn scenes (Mac only) and the committed screenshots in corpus.txt, each an
# opaque sRGB PNG; then each scaled to a 1366 px long edge (an image already smaller is left out).
stage corpus
if [[ $mac == 1 ]]; then
  for tool in corpus imageio ocr; do
    swiftc -O -o "$work/bin/codec-study-$tool" "$here/$tool.swift" || { echo "CODEC-STUDY-ERROR could not build $tool.swift"; exit 4; }
  done
  "$work/bin/codec-study-corpus" render "$work/corpus/native" >/dev/null || { echo "CODEC-STUDY-ERROR the scenes did not render"; exit 4; }
  prepare() { "$work/bin/codec-study-corpus" prepare "$@"; }
else
  prepare() { "$py" -I "$here/study.py" prepare "$@"; }
fi
while IFS= read -r path; do
  [[ -z "$path" || "$path" == \#* ]] && continue
  if [[ -f "$root/$path" ]]; then
    name="repo-$(basename "$(dirname "$path")")-$(basename "${path%.*}")"
    prepare "$root/$path" "$work/corpus/native/$name.png" || echo "CODEC-STUDY-ERROR could not prepare $path"
  else
    echo "CODEC-STUDY-ERROR corpus.txt names $path, which this commit lacks"
  fi
done <"$here/corpus.txt"
natives=()
while IFS= read -r file; do natives+=("$file"); done < <(ls "$work/corpus/native"/*.png 2>/dev/null | sort)
(( ${#natives[@]} > 0 )) || { echo "CODEC-STUDY-ERROR no corpus images"; exit 4; }
(( images > 0 && ${#natives[@]} > images )) && natives=("${natives[@]:0:$images}")
corpus=()
[[ ",$sizes," == *,native,* ]] && corpus+=("${natives[@]}")
if [[ ",$sizes," == *,1366,* ]]; then
  for file in "${natives[@]}"; do
    small="$work/corpus/1366/$(basename "$file")"
    prepare "$file" "$small" 1366 && corpus+=("$small")
  done
fi
(( ${#corpus[@]} > 0 )) || { echo "CODEC-STUDY-ERROR no corpus images"; exit 4; }
echo "CODEC-STUDY-CORPUS ${#corpus[@]} images: $(for f in "${corpus[@]}"; do printf '%s ' "${f#"$work/corpus/"}"; done)"

# Encode and decode: the library codecs, then ImageIO's (Mac), then every encoded file's ImageIO decode.
stage encode library
CODEC_STUDY_ONLY="$only" "$py" -I "$here/study.py" encode "$runs" "$work/encoded" "${corpus[@]}" >"$out/library.jsonl" ||
  echo "CODEC-STUDY-ERROR the library encode ended early (exit $?)"
if [[ $mac == 1 ]]; then
  stage encode imageio
  CODEC_STUDY_ONLY="$only" "$work/bin/codec-study-imageio" types >"$out/imageio-types.json"
  echo "CODEC-STUDY-IMAGEIO $("$py" -I -c 'import json,sys; print(json.load(sys.stdin)["settings"])' <"$out/imageio-types.json")"
  CODEC_STUDY_ONLY="$only" "$work/bin/codec-study-imageio" encode "$runs" "$work/encoded" "${corpus[@]}" >"$out/imageio.jsonl" ||
    echo "CODEC-STUDY-ERROR the ImageIO encode ended early (exit $?)"
  stage decode imageio
  encoded=()
  while IFS= read -r file; do encoded+=("$file"); done < <(find "$work/encoded" -type f ! -name '*.decoded.png' | sort)
  (( ${#encoded[@]} > 0 )) && "$work/bin/codec-study-imageio" decode "$runs" ${encoded[@]+"${encoded[@]}"} >"$out/imageio-decode.jsonl"
  if [[ $ocr == 1 ]]; then
    stage ocr
    cat "$out/library.jsonl" "$out/imageio.jsonl" 2>/dev/null >"$work/all.jsonl"
    "$py" -I "$here/study.py" pairs "$work/all.jsonl" "$work/pairs.jsonl"
    "$work/bin/codec-study-ocr" "$work/pairs.jsonl" "$out/ocr.jsonl" 4 || echo "CODEC-STUDY-ERROR OCR failed (exit $?)"
  fi
fi

stage report
"$py" -I "$here/study.py" report "$out" "$out/results.json" "$out/summary.md" || { echo "CODEC-STUDY-ERROR no report"; exit 4; }
cat "$out/summary.md"
"$py" -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["rows"] else 4)' "$out/results.json"
