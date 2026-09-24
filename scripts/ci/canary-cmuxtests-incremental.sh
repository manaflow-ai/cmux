#!/usr/bin/env bash
# CANARY (do not merge). Measures what one app-source edit costs cmuxTests on
# top of a seeded admission compile, with the compilation cache on and off.
# Usage: canary-cmuxtests-incremental.sh <derived-data> <cas> <series...>
# Series: cached | uncached | uncached-implicit
set +e -u

derived="$1" cas="$2"; shift 2
src=/private/tmp/cmux-ci/src
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
app_file="$src/Sources/Sidebar/GPUSpinner.swift"
wide_file="$src/Sources/Workspace.swift"
test_file="$src/cmuxTests/CmuxSSHURLRequestTests.swift"
cp "$app_file" "$RUNNER_TEMP/app.orig"
cp "$wide_file" "$RUNNER_TEMP/wide.orig"
cp "$test_file" "$RUNNER_TEMP/test.orig"

restore() {
  cp "$RUNNER_TEMP/app.orig" "$app_file"
  cp "$RUNNER_TEMP/wide.orig" "$wide_file"
  cp "$RUNNER_TEMP/test.orig" "$test_file"
}

# Per-target wall time from timestamped xcodebuild lines: first to last line
# naming the target. Rough (tasks print at start), but it separates the app
# from the test bundle within one scheme build.
report() {
  local series="$1" name="$2" log="$3" seconds="$4"
  python3 - "$series" "$name" "$log" "$seconds" "$summary" <<'PY'
import re, sys
from collections import Counter, defaultdict
series, name, log, seconds, summary = sys.argv[1:]
first, last = {}, {}
compiles, emits, files = Counter(), Counter(), Counter()
remarks = []
timing = []
in_timing = False
for raw in open(log, errors="replace"):
    ts, _, line = raw.partition(" ")
    try:
        ts = float(ts)
    except ValueError:
        continue
    m = re.search(r"\(in target '([^']+)'", line)
    if m:
        t = m.group(1)
        first.setdefault(t, ts)
        last[t] = ts
        if line.startswith("SwiftCompile "):
            compiles[t] += 1
            files[t] += max(1, line.count(".swift"))
        elif line.startswith(("SwiftEmitModule", "EmitSwiftModule")):
            emits[t] += 1
    if "Incremental compilation" in line or "Scheduling" in line and "incremental" in line.lower():
        remarks.append(line.strip())
    if line.startswith("Build Timing Summary"):
        in_timing = True
        continue
    if in_timing:
        if not line.strip() or line.startswith("**"):
            in_timing = False
        else:
            timing.append(line.rstrip())
out = [f"### {series} / {name}: {seconds}s"]
for t in ("cmux", "cmuxTests"):
    if t in first:
        out.append(f"- {t}: {last[t]-first[t]:.0f}s span, {compiles[t]} SwiftCompile lines, {emits[t]} emit-module")
    else:
        out.append(f"- {t}: no tasks")
for row in timing:
    if re.match(r"(SwiftCompile|SwiftEmitModule|SwiftDriver|Ld|CompileC|SwiftExplicit|ScanDependencies)", row):
        out.append(f"  - `{row}`")
notable = [r for r in dict.fromkeys(remarks) if re.search(r"disabled|module|external|interface|Fingerprint|all", r)]
if remarks:
    kinds = Counter(re.sub(r"'[^']*'|\{[^}]*\}|\S+\.swift\S*", "X", r)[:140] for r in remarks)
    out.append(f"- incremental remarks: {len(remarks)}")
    for k, n in kinds.most_common(12):
        out.append(f"  - {n} x `{k}`")
    for r in notable[:12]:
        out.append(f"  - raw: `{r[:220]}`")
text = "\n".join(out) + "\n"
print(text)
open(summary, "a").write(text)
PY
}

build() {
  local series="$1" name="$2" log="$RUNNER_TEMP/probe-$1-$2.txt" started=$SECONDS
  local -a extra=()
  case "$series" in
    cached) extra=(COMPILATION_CACHE_ENABLE_CACHING=YES) ;;
    uncached)
      extra=(COMPILATION_CACHE_ENABLE_CACHING=NO 'OTHER_SWIFT_FLAGS=$(inherited) -driver-show-incremental') ;;
    uncached-implicit)
      extra=(COMPILATION_CACHE_ENABLE_CACHING=NO SWIFT_ENABLE_EXPLICIT_MODULES=NO 'OTHER_SWIFT_FLAGS=$(inherited) -driver-show-incremental') ;;
  esac
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
      ${extra[@]+"${extra[@]}"} \
      -showBuildTimingSummary \
      build-for-testing < /dev/null 2>&1
  ) | perl -MTime::HiRes=time -ne 's/\r//g; printf "%.2f %s", time, $_' > "$log"
  local status=${PIPESTATUS[0]}
  [ "$status" = 0 ] || { echo "probe $series/$name failed ($status)"; grep -E "error:" "$log" | head -20; }
  report "$series" "$name" "$log" "$((SECONDS - started))"
}

series_run() {
  local s="$1"
  restore
  build "$s" baseline
  build "$s" null
  # 1. body-only edit of an app function (no declaration change).
  perl -0pi -e 's/(func updateNSView\(_ view: GPUSpinnerNSView, context: Context\) \{\n)/$1        let cmuxProbeBody = 1; _ = cmuxProbeBody\n/' "$app_file"
  build "$s" app-body-only
  # 2. a new private member in the same file.
  printf '\nprivate func cmuxProbePrivate() -> Int { 2 }\n' >> "$app_file"
  build "$s" app-new-private-func
  # 3. a new internal member on a type only one test file names.
  printf '\nextension GPUSpinner {\n    func cmuxProbeInternal() -> Int { 3 }\n}\n' >> "$app_file"
  build "$s" app-new-internal-func-narrow
  # 4. change that internal member's signature.
  perl -0pi -e 's/func cmuxProbeInternal\(\) -> Int \{ 3 \}/func cmuxProbeInternal(_ x: Int = 0) -> Int { x }/' "$app_file"
  build "$s" app-signature-change
  # 5. a new internal member on a type 239 test files name.
  printf '\nextension Workspace {\n    func cmuxProbeWide() -> Int { 5 }\n}\n' >> "$wide_file"
  build "$s" app-new-internal-func-wide
  # 6. body-only edit of one cmuxTests file.
  perl -0pi -e 's/(func testParsesSSHURLWithExplicitHostUserPortAndTitle\(\) throws \{\n)/$1        let cmuxProbeTestBody = 6; _ = cmuxProbeTestBody\n/' "$test_file"
  build "$s" test-body-only
  restore
}

for s in "$@"; do
  series_run "$s"
done
