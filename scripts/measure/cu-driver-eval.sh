#!/usr/bin/env bash
# The Computer Use driver eval (HQ#7146 G3a; scripts/measure/cu-driver-eval/README.md). Suite
# input-ab: every input route and Cua Driver build sends the same click, key and scroll to an
# AppKit, a WebKit and an Electron window, behind the user's window and in front of it, and counts
# what arrived and what it disturbed. Run alone on a console worker whose step processes hold
# Accessibility:
#   cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 \
#     --script scripts/measure/cu-driver-eval.sh --ref SHA --artifact artifacts/cu-driver-eval.tgz \
#     [--target-worker W] [--arg=reps=3] [--arg=drivers=cmux-cua,cua-driver-0.38.0] --timeout 3600
# Output: CU-DRIVER-EVAL lines, the summary, and artifacts/cu-driver-eval.tgz (results.json,
# summary.md, trials.jsonl and every app's log). No gate: it reports, and exits non-zero only when
# it could not measure at all (3: no Accessibility grant; 4: nothing ran).
set -uo pipefail
reps=3 drivers="cmux-cua,cua-driver-0.38.0" electron=1
for arg in "$@"; do
  case "$arg" in
    reps=*) reps="${arg#reps=}" ;;
    drivers=*) drivers="${arg#drivers=}" ;;
    electron=*) electron="${arg#electron=}" ;;
    *) echo "cu-driver-eval.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$reps" =~ ^[1-9][0-9]?$ ]] || { echo "cu-driver-eval.sh: reps= is 1..99" >&2; exit 2; }
[[ "$drivers" =~ ^[a-z0-9.,-]*$ ]] || { echo "cu-driver-eval.sh: drivers= is a comma list of names" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
here="$root/scripts/measure/cu-driver-eval"
out="$root/artifacts/cu-driver-eval"
work="$root/.build/cu-driver-eval"
cache="${HOME:-/tmp}/Library/Caches/cmux/cu-driver-eval"
rm -rf "$out" "$work" "$root/artifacts/cu-driver-eval.tgz"
mkdir -p "$out/input-ab" "$work/bin" "$cache"
chmod 700 "$work"

display=$(system_profiler SPDisplaysDataType 2>/dev/null | sed -n 's/^ *Resolution: //p' | head -1)
run=$(python3 -I -c '
import json, sys, datetime
keys, values = sys.argv[1::2], sys.argv[2::2]
run = dict(zip(keys, values))
run["at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps(run))' host "$(scutil --get ComputerName 2>/dev/null || hostname)" cpu "$(sysctl -n machdep.cpu.brand_string)" \
  macos "$(sw_vers -productVersion) ($(sw_vers -buildVersion))" rev "$(git rev-parse HEAD)" display "$display" reps "$reps")
echo "CU-DRIVER-EVAL-MACHINE $run"

finish() {
  python3 -I "$here/eval.py" results "$out/results.json" "$run" "$out" "${1:-}"
  python3 -I "$here/eval.py" summary "$out/results.json" "$out/summary.md"
  cat "$out/summary.md"
  tar -czf "$root/artifacts/cu-driver-eval.tgz" -C "$root/artifacts" cu-driver-eval
}

# fetch NAME URL SHA256: a verified download in the cache; prints its path.
fetch() {
  local file="$cache/$3-$(basename "$2")"
  if [[ ! -s "$file" ]]; then
    curl -fsSL --retry 3 -o "$file.part" "$2" || { rm -f "$file.part"; return 1; }
    mv "$file.part" "$file"
  fi
  if [[ "$(shasum -a 256 "$file" | awk '{print $1}')" != "$3" ]]; then
    echo "CU-DRIVER-EVAL-ERROR $1: sha256 mismatch for $2" >&2
    rm -f "$file"
    return 1
  fi
  echo "$file"
}

# pin KEY...: one value of pins.json.
pin() { python3 -I -c 'import functools, json, sys; print(functools.reduce(lambda d, k: d[k], sys.argv[2:], json.load(open(sys.argv[1]))))' "$here/pins.json" "$@"; }

echo "CU-DRIVER-EVAL-STAGE tools"
swiftc -O -o "$work/bin/cu-eval-app" "$here/apps.swift" || { finish "could not build apps.swift"; exit 4; }
swiftc -O -o "$work/bin/cu-eval-inject" "$here/inject.swift" || { finish "could not build inject.swift"; exit 4; }
grants=$("$work/bin/cu-eval-inject" grants)
echo "CU-DRIVER-EVAL-GRANTS $grants"
if ! grep -q '"accessibility":true' <<<"$grants"; then
  finish "the step's processes lack Accessibility on this worker ($grants)"
  exit 3
fi

echo "CU-DRIVER-EVAL-STAGE downloads"
driver_args=()
IFS=',' read -r -a names <<<"$drivers"
for name in "${names[@]}"; do
  [[ -n "$name" ]] || continue
  dir="$work/drivers/$name"
  mkdir -p "$dir"
  if [[ "$name" == cmux-cua ]]; then
    # The pin cmux ships at this ref (scripts/build-cmux-cua.sh), so the arm follows every bump.
    tag=$(sed -n 's/^CMUX_CUA_RELEASE_TAG="\(.*\)"$/\1/p' "$root/scripts/build-cmux-cua.sh")
    version="${tag#cmux-cua-v}"
    asset="cmux-cua-$version-darwin-universal-unsigned-binary.tar.gz"
    base="https://github.com/manaflow-ai/cmux-cua/releases/download/$tag"
    sum=$(curl -fsSL --retry 3 "$base/SHA256SUMS" | awk -v a="$asset" '{f = $2; sub(/^\*/, "", f); if (f == a) print $1}')
    if [[ ! "$sum" =~ ^[0-9a-f]{64}$ ]] || ! file=$(fetch "$name" "$base/$asset" "$sum"); then
      echo "CU-DRIVER-EVAL-ERROR $name: could not fetch $asset" | tee -a "$out/input-ab/download-errors.txt"
      continue
    fi
    tar -xzf "$file" -C "$dir"
    binary="$dir/cmux-cua"
    label="cmux-cua-$version"
  else
    url=$(pin drivers "$name" url 2>/dev/null) && sum=$(pin drivers "$name" sha256) && inner=$(pin drivers "$name" binary) || {
      echo "CU-DRIVER-EVAL-ERROR $name: not in pins.json" | tee -a "$out/input-ab/download-errors.txt"
      continue
    }
    if ! file=$(fetch "$name" "$url" "$sum"); then
      echo "CU-DRIVER-EVAL-ERROR $name: could not fetch $url" | tee -a "$out/input-ab/download-errors.txt"
      continue
    fi
    tar -xzf "$file" -C "$dir"
    binary="$dir/$inner"
    label="$name"
  fi
  # An unsigned arm64 binary does not run; an ad-hoc signature is enough for a step process.
  codesign -v "$binary" 2>/dev/null || codesign -s - -f "$binary" >/dev/null 2>&1
  driver_args+=(--driver "$label=$binary")
done
electron_args=()
if [[ "$electron" == 1 ]]; then
  if file=$(fetch electron "$(pin electron url)" "$(pin electron sha256)"); then
    mkdir -p "$work/electron"
    ditto -x -k "$file" "$work/electron"
    electron_args=(--electron "$work/electron/Electron.app/Contents/MacOS/Electron")
  else
    echo "CU-DRIVER-EVAL-ERROR electron: could not fetch; the electron target is skipped" | tee -a "$out/input-ab/download-errors.txt"
  fi
fi

echo "CU-DRIVER-EVAL-STAGE input-ab"
python3 -I "$here/input_ab.py" --bin "$work/bin" --out "$out/input-ab" --reps "$reps" \
  ${driver_args[@]+"${driver_args[@]}"} ${electron_args[@]+"${electron_args[@]}"}
status=$?
if [[ -s "$out/input-ab/download-errors.txt" && -s "$out/input-ab/input-ab.json" ]]; then
  python3 -I - "$out/input-ab/input-ab.json" "$out/input-ab/download-errors.txt" <<'EOF'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["errors"] = Path(sys.argv[2]).read_text().splitlines() + data.get("errors", [])
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
EOF
fi
if [[ $status == 4 || ! -s "$out/input-ab/input-ab.json" ]]; then
  finish "the input A/B ran no trial (exit $status)"
  exit 4
fi
finish
