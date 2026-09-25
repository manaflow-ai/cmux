#!/usr/bin/env bash
# CANARY (do not merge). Where does the cmuxTests SwiftEmitModule job spend
# its ~26 s on a one-test-file rebuild, and which lever shrinks it?
# Usage: canary-cmuxtests-emit-module.sh <derived-data> <cas> <series...>
# Each series first rebuilds cmuxTests with its own arguments (a full cmuxTests
# rebuild, since the arguments changed), then edits one test body and rebuilds.
# The app and packages keep their exact arguments: every setting below is
# evaluated per target through $(X_$(TARGET_NAME)).
set +e -u

derived="$1" cas="$2"; shift 2
src="${CMUX_CI_CANONICAL_ROOT:-/private/tmp/cmux-ci}/src"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
test_file="$src/cmuxTests/CmuxSSHURLRequestTests.swift"
pbxproj="$src/cmux.xcodeproj/project.pbxproj"
stats="$RUNNER_TEMP/swift-stats"
cp "$test_file" "$RUNNER_TEMP/test.orig"
cp "$pbxproj" "$RUNNER_TEMP/pbxproj.orig"

restore() {
  cp "$RUNNER_TEMP/test.orig" "$test_file"
  cp "$RUNNER_TEMP/pbxproj.orig" "$pbxproj"
}

frontend_help="$(xcrun swift-frontend -frontend -help-hidden 2>/dev/null)"
driver_help="$(xcrun swiftc -help-hidden 2>/dev/null)"
has_frontend() { grep -q -- "  $1\b" <<<"$frontend_help"; }
has_driver() { grep -q -- "  $1\b" <<<"$driver_help"; }

# Round 1 showed -fine-grained-timers doubles emit-module time, so round 2
# measures without stats.
base_flags=""
echo "swift: $(xcrun swiftc --version 2>&1 | head -1)" | tee -a "$summary"

report() {
  local series="$1" name="$2" log="$3" seconds="$4" tarball="$5"
  python3 - "$series" "$name" "$log" "$seconds" "$summary" "$stats" <<'PY'
import glob, json, os, re, sys
from collections import Counter
series, name, log, seconds, summary, stats = sys.argv[1:]
first, last = {}, {}
emit_start = emit_end = None
timing, in_timing = [], False
long_checks = []
for raw in open(log, errors="replace"):
    ts, _, line = raw.partition(" ")
    try:
        ts = float(ts)
    except ValueError:
        continue
    m = re.search(r"\(in target '([^']+)'", line)
    if m:
        first.setdefault(m.group(1), ts)
        last[m.group(1)] = ts
    if line.startswith("SwiftEmitModule") and "cmuxTests" in line:
        emit_start = ts
    if line.startswith("SwiftDriverJobDiscovery") and "Emitting module for cmuxTests" in line:
        emit_end = ts
    if "cmuxTests/" in line and re.search(r"warning: (instance method|global function|getter|initializer|expression|closure|static method|.*) took \d+ms", line):
        long_checks.append(line.strip())
    if line.startswith("Build Timing Summary"):
        in_timing = True
        continue
    if in_timing:
        if line.startswith("**"):
            in_timing = False
        elif line.strip():
            timing.append(line.rstrip())
out = [f"### {series} / {name}: {seconds}s"]
for t in ("cmux", "cmuxTests"):
    out.append(f"- {t}: {last[t]-first[t]:.1f}s span" if t in first else f"- {t}: no tasks")
if emit_start and emit_end:
    out.append(f"- cmuxTests emit-module wall (start line to discovery line): {emit_end-emit_start:.1f}s")
for row in timing[:14]:
    out.append(f"  - `{row}`")
if long_checks:
    out.append(f"- long type-check warnings in cmuxTests: {len(set(long_checks))}")
    for w in list(dict.fromkeys(long_checks))[:15]:
        out.append(f"  - `{w[:230]}`")

def load(path):
    try:
        return json.load(open(path))
    except Exception:
        return {}

files = sorted(glob.glob(os.path.join(stats, "*.json")))
tests = [f for f in files if "cmuxTests" in os.path.basename(f)]
emit = [f for f in tests if "swiftmodule" in os.path.basename(f)]
compile_ = [f for f in tests if f not in emit]
out.append(f"- stats files: {len(files)} total, cmuxTests {len(tests)} ({len(emit)} emit-module)")
for f in emit[:2]:
    d = load(f)
    out.append(f"- emit-module stats `{os.path.basename(f)[:150]}`")
    walls = sorted(((v, k) for k, v in d.items() if k.endswith(".wall") and isinstance(v, (int, float))), reverse=True)
    for v, k in walls[:40]:
        out.append(f"  - {v:9.3f}s `{k}`")
    counters = sorted(((v, k) for k, v in d.items() if not k.startswith("time.") and isinstance(v, (int, float))), reverse=True)
    out.append("  - counters:")
    for v, k in counters[:40]:
        out.append(f"    - {v:>12} `{k}`")
if compile_:
    agg = Counter()
    for f in compile_:
        for k, v in load(f).items():
            if k.endswith(".wall") and isinstance(v, (int, float)):
                agg[k] += v
    out.append(f"- compile jobs ({len(compile_)}), summed wall top 12:")
    for k, v in agg.most_common(12):
        out.append(f"  - {v:9.3f}s `{k}`")
text = "\n".join(out) + "\n"
print(text)
open(summary, "a").write(text)
PY
  tar -C "$stats" -czf "$tarball" . 2>/dev/null
}

build() {
  local series="$1" name="$2" flags="$3" log="$RUNNER_TEMP/probe-$1-$2.txt" started=$SECONDS
  shift 3
  rm -rf "$stats"; mkdir -p "$stats"
  (
    cd "$src" || exit 1
    # A pty keeps xcodebuild line-buffered so the timestamps are real.
    script -q /dev/null xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
      -derivedDataPath "$derived" \
      -clonedSourcePackagesDirPath "$src/.ci-source-packages" \
      -disableAutomaticPackageResolution \
      -destination "platform=macOS" \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_CI_APP_HOST_ISOLATION_REQUIRED' \
      'LD_RUNPATH_SEARCH_PATHS=$(inherited) @executable_path/../Frameworks /private/tmp/cmux-app-host-package-frameworks' \
      "COMPILATION_CACHE_CAS_PATH=$cas" \
      COMPILATION_CACHE_LIMIT_SIZE=3221225472 \
      ${CMUX_CI_MODULE_CACHE_PATH:+"CLANG_MODULE_CACHE_PATH=$CMUX_CI_MODULE_CACHE_PATH"} \
      'COMPILATION_CACHE_ENABLE_CACHING=$(CMUX_CI_TARGET_CACHE_$(TARGET_NAME):default=YES)' \
      CMUX_CI_TARGET_CACHE_cmuxTests=NO \
      'OTHER_SWIFT_FLAGS=$(inherited) $(CMUX_CI_TARGET_FLAGS_$(TARGET_NAME))' \
      "CMUX_CI_TARGET_FLAGS_cmuxTests=$flags" \
      "$@" \
      -showBuildTimingSummary \
      build-for-testing < /dev/null 2>&1
  ) | perl -MTime::HiRes=time -ne 's/\r//g; printf "%.2f %s", time, $_' > "$log"
  local status=${PIPESTATUS[0]}
  [ "$status" = 0 ] || { echo "probe $series/$name failed ($status)" | tee -a "$summary"; grep -E "error:" "$log" | head -20 | tee -a "$summary"; }
  report "$series" "$name" "$log" "$((SECONDS - started))" "$RUNNER_TEMP/stats-$series-$name.tgz"
}

edit_test_body() {
  # Replace the probe line if present, else insert it: one body edit per build.
  if grep -q 'let cmuxProbeTestBody = ' "$test_file"; then
    perl -pi -e 's/let cmuxProbeTestBody = \d+;/let cmuxProbeTestBody = '"$1"';/' "$test_file"
  else
    perl -0pi -e 's/(func testParsesSSHURLWithExplicitHostUserPortAndTitle\(\) throws \{\n)/$1        let cmuxProbeTestBody = '"$1"'; _ = cmuxProbeTestBody\n/' "$test_file"
  fi
}

no_objc_header() {
  # cmuxTests' Debug configuration only; no source imports cmuxTests-Swift.h.
  perl -0pi -e 's/(F1000011A1B2C3D4E5F60718 \/\* Debug \*\/ = \{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = \{\n)/$1\t\t\t\tSWIFT_OBJC_INTERFACE_HEADER_NAME = "";\n/' "$pbxproj"
  grep -q 'SWIFT_OBJC_INTERFACE_HEADER_NAME = "";' "$pbxproj" || echo "noobjc: pbxproj edit did not apply" | tee -a "$summary"
}

# What the built bundle holds: Swift Testing records, ObjC classes, and the
# enumerated test count, so a mode that drops the module cannot drop tests.
inventory() {
  local series="$1" bin
  bin="$(find "$derived/Build/Products/Debug" -path '*cmuxTests.xctest/Contents/MacOS/cmuxTests' -type f | head -1)"
  {
    echo "- inventory $series: binary \`${bin#$derived/}\`"
    [ -n "$bin" ] && otool -l "$bin" | awk '/sectname __swift5_tests/{f=1} f&&/size/{print "  - __swift5_tests size " $2; exit}'
    [ -n "$bin" ] && echo "  - ObjC classes named *Tests: $(nm -j "$bin" 2>/dev/null | grep -c '^_OBJC_CLASS_\$_.*Tests$')"
    ls "$derived/Build/Intermediates.noindex/cmux.build/Debug/cmuxTests.build/Objects-normal/arm64/" 2>/dev/null | grep -E 'swiftmodule|Swift\.h|abi\.json' | sed 's/^/  - intermediate: /'
  } | tee -a "$summary"
  local xctestrun out="$RUNNER_TEMP/enum-$series.json"
  xctestrun="$(ls -t "$derived"/Build/Products/*.xctestrun 2>/dev/null | head -1)"
  [ -n "$xctestrun" ] || { echo "  - no xctestrun" | tee -a "$summary"; return; }
  (cd "$src" && perl -e 'alarm 420; exec @ARGV' scripts/ci/run-in-console-session.sh \
    xcodebuild test-without-building -enumerate-tests -xctestrun "$xctestrun" \
    -destination "platform=macOS" -test-enumeration-style flat \
    -test-enumeration-format json -test-enumeration-output-path "$out") \
    > "$RUNNER_TEMP/probe-$series-enumerate.txt" 2>&1
  python3 - "$out" "$summary" <<'PY'
import json, sys
out, summary = sys.argv[1:]
try:
    d = json.load(open(out))
except Exception as e:
    line = f"  - enumeration failed: {e}"
else:
    n = 0
    def walk(x):
        global n
        if isinstance(x, dict):
            if "identifier" in x and not x.get("children"):
                n += 1
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    walk(d)
    line = f"  - enumerated tests: {n}"
print(line)
open(summary, "a").write(line + "\n")
PY
}

series_run() {
  local s="$1" flags="${PROBE_BASE_FLAGS:-}"
  local -a extra=()
  local legacy=(
    'SWIFT_USE_INTEGRATED_DRIVER=$(CMUX_CI_TARGET_DRIVER_$(TARGET_NAME):default=YES)'
    CMUX_CI_TARGET_DRIVER_cmuxTests=NO)
  local implicit=(
    'SWIFT_ENABLE_EXPLICIT_MODULES=$(CMUX_CI_TARGET_EXPLICIT_$(TARGET_NAME):default=YES)'
    CMUX_CI_TARGET_EXPLICIT_cmuxTests=NO)
  restore
  case "$s" in
    base) ;;
    lazy) flags+=" -Xfrontend -experimental-lazy-typecheck" ;;
    legacy) no_objc_header; extra=("${legacy[@]}" "${implicit[@]}") ;;
    nomodule)
      no_objc_header; flags+=" -no-emit-module-separately"
      extra=("${legacy[@]}" "${implicit[@]}") ;;
    nomodule-explicit)
      no_objc_header; flags+=" -no-emit-module-separately"
      extra=("${legacy[@]}") ;;
    *) echo "unknown series $s"; return ;;
  esac
  echo "## series $s: \`$flags\` ${extra[*]+${extra[*]}}" >> "$summary"
  build "$s" prime "$flags" ${extra[@]+"${extra[@]}"}
  edit_test_body 6
  build "$s" test-body "$flags" ${extra[@]+"${extra[@]}"}
  edit_test_body 7
  build "$s" test-body-2 "$flags" ${extra[@]+"${extra[@]}"}
  case "$s" in base|nomodule|nomodule-explicit) inventory "$s" ;; esac
}

for s in "$@"; do
  series_run "$s"
done
restore
