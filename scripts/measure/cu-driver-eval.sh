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
# it could not measure at all (3: no Accessibility or event-posting grant; 4: nothing ran).
# In a VM (scripts/measure/cu-driver-bench.sh suite=input-ab) the copy is not a git checkout:
# CU_DRIVER_EVAL_ROOT and CU_DRIVER_EVAL_REV name the tree and its commit, and CU_DRIVER_EVAL_GRANT
# names a command that is given every executable the A/B runs, before the grants are checked.
# bench=preflight|run (with a model route, cu-driver-bench.sh suite=bench-v2) runs Cua Driver Bench v2
# with the drivers instead of the A/B (bench_v2.py): condition=background|foreground, reps= runs per
# task, tasks=A,B, waive=REGEX[;REGEX] for preflight checks that only fit the bench's own builds.
set -uo pipefail
reps=3 drivers="cmux-cua,cua-driver-0.38.0" electron=1 bench="" condition=background tasks="" waive=""
for arg in "$@"; do
  case "$arg" in
    reps=*) reps="${arg#reps=}" ;;
    drivers=*) drivers="${arg#drivers=}" ;;
    electron=*) electron="${arg#electron=}" ;;
    bench=*) bench="${arg#bench=}" ;;
    condition=*) condition="${arg#condition=}" ;;
    tasks=*) tasks="${arg#tasks=}" ;;
    waive=*) waive="${arg#waive=}" ;;
    *) echo "cu-driver-eval.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$reps" =~ ^[1-9][0-9]?$ ]] || { echo "cu-driver-eval.sh: reps= is 1..99" >&2; exit 2; }
[[ "$drivers" =~ ^[a-z0-9.,-]*$ ]] || { echo "cu-driver-eval.sh: drivers= is a comma list of names" >&2; exit 2; }
[[ -z "$bench" || "$bench" == preflight || "$bench" == run ]] || { echo "cu-driver-eval.sh: bench= is preflight or run" >&2; exit 2; }
[[ "$condition" == background || "$condition" == foreground ]] || { echo "cu-driver-eval.sh: condition= is background or foreground" >&2; exit 2; }
[[ "$tasks" =~ ^[A-Z0-9,-]*$ ]] || { echo "cu-driver-eval.sh: tasks= is a comma list of task ids" >&2; exit 2; }
root="${CU_DRIVER_EVAL_ROOT:-$(git rev-parse --show-toplevel)}"
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
  macos "$(sw_vers -productVersion) ($(sw_vers -buildVersion))" rev "${CU_DRIVER_EVAL_REV:-$(git rev-parse HEAD)}" display "$display" reps "$reps")
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
# CU_DRIVER_EVAL_DISPLAY=WxH (the bench VM's) switches the main display first; a console Mac keeps its own.
if [[ -n "${CU_DRIVER_EVAL_DISPLAY:-}" ]]; then
  echo "CU-DRIVER-EVAL-STAGE display"
  mode=$("$work/bin/cu-eval-inject" display-mode ${CU_DRIVER_EVAL_DISPLAY/x/ }) ||
    echo "CU-DRIVER-EVAL-ERROR could not switch the display to $CU_DRIVER_EVAL_DISPLAY"
  echo "CU-DRIVER-EVAL-DISPLAY $mode"
fi
# The screen in points, which every trial's geometry is in (a headless VM's system_profiler lists none).
screen=$("$work/bin/cu-eval-inject" observe | python3 -I -c 'import json, sys; print("%gx%g" % tuple(json.load(sys.stdin)["screen"]))') || screen=""
run=$(python3 -I -c 'import json, sys; run = json.loads(sys.argv[1]); run["screen"] = sys.argv[2]; print(json.dumps(run))' "$run" "$screen")
echo "CU-DRIVER-EVAL-SCREEN $screen"
echo "CU-DRIVER-EVAL-STAGE downloads"
driver_args=()
driver_bins=()
driver_pairs=()
names=()
[[ -n "$drivers" ]] && IFS=',' read -r -a names <<<"$drivers"
for name in ${names[@]+"${names[@]}"}; do
  [[ -n "$name" ]] || continue
  dir="$work/drivers/$name"
  mkdir -p "$dir"
  if [[ "$name" == cmux-cua ]]; then
    # The cmux-cua release at cmux's pin for this ref (scripts/build-cmux-cua.sh), checked against the
    # hash pinned there, so the arm follows every bump. It is the release binary: cmux's own patches
    # (CMUX_CUA_PATCH_RELATIVE_PATHS) are not applied.
    tag=$(sed -n 's/^CMUX_CUA_RELEASE_TAG="\(.*\)"$/\1/p' "$root/scripts/build-cmux-cua.sh")
    sum=$(sed -n 's/^CMUX_CUA_DARWIN_UNIVERSAL_UNSIGNED_SHA256="\(.*\)"$/\1/p' "$root/scripts/build-cmux-cua.sh")
    version="${tag#cmux-cua-v}"
    asset="cmux-cua-$version-darwin-universal-unsigned"
    if ! file=$(fetch "$name" "https://github.com/manaflow-ai/cmux-cua/releases/download/$tag/$asset.tar.gz" "$sum"); then
      echo "CU-DRIVER-EVAL-ERROR $name: could not fetch $asset.tar.gz" | tee -a "$out/input-ab/download-errors.txt"
      continue
    fi
    tar -xzf "$file" -C "$dir"
    # cmux runs it as its helper app, and the binary refuses `serve` from anywhere but
    # ".../cmux Computer Use.app/Contents/MacOS/cmux-cua": lay it out as scripts/build-cmux-cua.sh
    # assembles that bundle (id, owner marker, environment, ad-hoc signature with an identifier
    # requirement), without the icon and strings, which change nothing here.
    helper="$dir/cmux Computer Use.app"
    mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources"
    mv "$dir/$asset/cmux-cua" "$helper/Contents/MacOS/cmux-cua"
    owner_file=$(sed -n 's/^CMUX_CUA_HELPER_OWNER_FILE="\(.*\)"$/\1/p' "$root/scripts/build-cmux-cua.sh")
    sed -n 's/^CMUX_CUA_HELPER_OWNER_VALUE="\(.*\)"$/\1/p' "$root/scripts/build-cmux-cua.sh" >"$helper/Contents/Resources/${owner_file:-.cmux-cua-managed-helper}"
    # Read, not run: the script hashes cmux's patches before it parses arguments, and the VM's copy
    # of the tree has none.
    helper_id=$(sed -n '/^helper_bundle_id_for_host()/,/^}/s/^ *echo "\(.*\)"$/\1/p' "$root/scripts/build-cmux-cua.sh" | head -1)
    [[ "$helper_id" =~ ^[A-Za-z0-9.-]+$ ]] || {
      echo "CU-DRIVER-EVAL-ERROR $name: no helper id in build-cmux-cua.sh; using com.cmuxterm.cua" | tee -a "$out/input-ab/download-errors.txt"
      helper_id=com.cmuxterm.cua
    }
    cat >"$helper/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>cmux Computer Use</string>
  <key>CFBundleDisplayName</key><string>cmux Computer Use</string>
  <key>CFBundleIdentifier</key><string>$helper_id</string>
  <key>CFBundleExecutable</key><string>cmux-cua</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSEnvironment</key><dict>
    <key>CMUX_CUA_PERMISSIONS_GATE</key><string>0</string>
    <key>CMUX_CUA_EXTERNAL_PERMISSION_FLOW</key><string>1</string>
    <key>CMUX_CUA_TELEMETRY_ENABLED</key><string>false</string>
    <key>CMUX_CUA_UPDATE_CHECK</key><string>false</string>
  </dict>
</dict></plist>
PLIST
    codesign --force --sign - --timestamp=none --identifier "$helper_id" \
      --requirements "=designated => identifier \"$helper_id\"" "$helper" >/dev/null 2>&1 ||
      echo "CU-DRIVER-EVAL-ERROR $name: could not sign the helper bundle" | tee -a "$out/input-ab/download-errors.txt"
    binary="$helper/Contents/MacOS/cmux-cua"
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
  # An unsigned arm64 binary does not run; an ad-hoc signature is enough for a step process. The
  # helper bundle carries its own, which signing its executable alone would break.
  [[ "$name" == cmux-cua ]] || codesign -v "$binary" 2>/dev/null || codesign -s - -f "$binary" >/dev/null 2>&1
  driver_args+=(--driver "$label=$binary")
  driver_bins+=("$binary")
  driver_pairs+=("$label=$binary")
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

bench_args=()
if [[ -n "$bench" ]]; then
  # Cua Driver Bench v2 from its pinned source (pins.json bench_v2), with a Python new enough for it,
  # ffmpeg for its recordings, BenchLab built from that source, and each driver's own skill.
  echo "CU-DRIVER-EVAL-STAGE bench-v2 setup"
  bench_dir="$work/bench"
  mkdir -p "$bench_dir/src" "$bench_dir/build" "$bench_dir/skills" "$out/bench-v2"
  bench_fail() { finish "bench v2: $1"; exit 4; }
  file=$(fetch python "$(pin bench_v2 python url)" "$(pin bench_v2 python sha256)") || bench_fail "could not fetch the pinned Python"
  tar -xzf "$file" -C "$bench_dir" || bench_fail "could not unpack Python"
  bench_python="$bench_dir/python/bin/python3.12"
  codesign -v "$bench_python" 2>/dev/null || codesign -s - -f "$bench_python" >/dev/null 2>&1
  # The bench looks for ffmpeg on PATH and then in /opt/homebrew/bin, which the route stage made.
  sudo -n mkdir -p /opt/homebrew/bin && sudo -n chown "$(id -un)" /opt/homebrew/bin
  for tool in ffmpeg ffprobe; do
    file=$(fetch "$tool" "$(pin bench_v2 "$tool" url)" "$(pin bench_v2 "$tool" sha256)") || bench_fail "could not fetch $tool"
    ditto -x -k "$file" /opt/homebrew/bin || bench_fail "could not unpack $tool"
    codesign -v "/opt/homebrew/bin/$tool" 2>/dev/null || codesign -s - -f "/opt/homebrew/bin/$tool" >/dev/null 2>&1
  done
  commit=$(pin bench_v2 source commit) subdir=$(pin bench_v2 source path)
  file=$(fetch bench-source "$(pin bench_v2 source url)" "$(pin bench_v2 source sha256)") || bench_fail "could not fetch the bench source"
  tar -xzf "$file" -C "$bench_dir/src" --strip-components 3 "cua-$commit/$subdir" || bench_fail "could not unpack the bench source"
  macos_bench="$bench_dir/src/automated-eval/macos_bench"
  bash "$macos_bench/swift/build.sh" "$bench_dir/build" >"$out/bench-v2/build.log" 2>&1 || bench_fail "BenchLab did not build (bench-v2/build.log)"
  driver_bins+=("$bench_python" /opt/homebrew/bin/ffmpeg "$bench_dir/build/BenchLab.app/Contents/MacOS/BenchLab"
    "$bench_dir/build/BenchSentinel.app/Contents/MacOS/BenchSentinel")
  for pair in ${driver_pairs[@]+"${driver_pairs[@]}"}; do
    label=${pair%%=*} binary=${pair#*=}
    if [[ "$label" == cmux-cua-* ]]; then
      # cmux's own skill for its computer use tools, from this tree.
      bench_args+=(--driver "$label=$binary" --skills "$label=$root/skills/cmux-cua")
    else
      # The release's app, which the bench drives and macOS grants, and the release's skills.
      version=${label#cua-driver-}
      app_binary="$(dirname "$binary")/CuaDriver.app/Contents/MacOS/cua-driver"
      [[ -x "$app_binary" ]] || bench_fail "no CuaDriver.app in the $label release"
      [[ "$(pin bench_v2 cua_driver_skills version)" == "$version" ]] || bench_fail "no skills pinned for $label"
      file=$(fetch skills "$(pin bench_v2 cua_driver_skills url)" "$(pin bench_v2 cua_driver_skills sha256)") || bench_fail "could not fetch the $label skills"
      tar -xzf "$file" -C "$bench_dir/skills" || bench_fail "could not unpack the $label skills"
      bench_args+=(--driver "$label=$app_binary" --skills "$label=$bench_dir/skills/cua-driver-rs-v$version-skills")
      driver_bins+=("$app_binary")
    fi
  done
  [[ ${#bench_args[@]} -gt 0 ]] || bench_fail "no driver to run"
fi

grant() {
  $CU_DRIVER_EVAL_GRANT "$work/bin/cu-eval-inject" "$work/bin/cu-eval-app" \
    $(python3 -I -c 'import os, sys
# A framework build re-execs into Python.app, so that binary is the one running; grant both.
exe = os.path.realpath(sys.executable)
app = os.path.join(sys.base_prefix, "Resources/Python.app/Contents/MacOS/Python")
print(exe, *([app] if os.path.exists(app) else []))') ${driver_bins[@]+"${driver_bins[@]}"} ||
    echo "CU-DRIVER-EVAL-ERROR the grant command exited $?"
}
granted() { grep -q '"accessibility":true' <<<"$grants" && grep -q '"post_event":true' <<<"$grants"; }
if [[ -n "${CU_DRIVER_EVAL_GRANT:-}" ]]; then
  echo "CU-DRIVER-EVAL-STAGE grant"
  grant
fi
grants=$("$work/bin/cu-eval-inject" grants)
echo "CU-DRIVER-EVAL-GRANTS $grants"
# A tccd that answered from its old state once (run at 211335b8) gets one more grant and restart.
if [[ -n "${CU_DRIVER_EVAL_GRANT:-}" ]] && ! granted; then
  echo "CU-DRIVER-EVAL-STAGE grant again"
  grant
  grants=$("$work/bin/cu-eval-inject" grants)
  echo "CU-DRIVER-EVAL-GRANTS $grants"
fi
# Both: with Accessibility but no event posting, every per-pid post is dropped and would read as a
# measured zero instead of a blocked run.
if ! granted; then
  [[ -n "${CU_DRIVER_EVAL_GRANT:-}" ]] && $CU_DRIVER_EVAL_GRANT --diagnose >"$out/tcc-diagnose.txt" 2>&1 && cat "$out/tcc-diagnose.txt"
  finish "the step's processes lack Accessibility or event posting on this worker ($grants)"
  exit 3
fi

if [[ -n "$bench" ]]; then
  echo "CU-DRIVER-EVAL-STAGE bench-v2 $bench"
  waive_args=()
  IFS=';' read -r -a waivers <<<"$waive"
  for regex in ${waivers[@]+"${waivers[@]}"}; do [[ -n "$regex" ]] && waive_args+=(--waive "$regex"); done
  "$bench_python" -I "$here/bench_v2.py" --bench "$macos_bench" --work "$bench_dir/work" --build-dir "$bench_dir/build" \
    --out "$out/bench-v2" "${bench_args[@]}" ${waive_args[@]+"${waive_args[@]}"} --mode "$bench" --condition "$condition" \
    --runs "$reps" ${tasks:+--tasks "$tasks"}
  status=$?
  finish
  exit "$status"
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
