#!/usr/bin/env bash
# CANARY (do not merge). Why does a body-only edit to one app file recompile
# the whole `cmux` target on the macOS 15 pool (Xcode 26.3, compilation cache
# on)? Runs after the admission compile, which already passed
# -driver-show-incremental to the `cmux` target only.
# Usage: canary-macos15-app-incremental.sh <derived-data> <cas>
set +e -u

derived="$1" cas="$2"
src=/private/tmp/cmux-ci/src
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
app_file="$src/Sources/Sidebar/GPUSpinner.swift"
cp "$app_file" "$RUNNER_TEMP/app.orig"

{
  echo "### Host"
  echo '```'
  sw_vers
  xcodebuild -version
  ls -d /Applications/Xcode*.app
  echo '```'
} | tee -a "$summary"

# Files a Swift compile of `cmux` can depend on that the build itself writes:
# bridging-header PCHs, chained bridging headers, the generated -Swift.h.
snapshot() {
  find "$derived/Build/Intermediates.noindex" -type f \( -name '*Bridging*' -o -name '*.pch' -o -name '*-Swift.h' \) 2>/dev/null \
    | grep -v cmuxTests | sort | while read -r f; do
    printf '%s %s %s\n' "$(stat -f %m "$f")" "$(shasum -a 256 "$f" | cut -c1-16)" "${f#"$derived"/}"
  done
}

build() {
  local name="$1"; shift
  local log="$RUNNER_TEMP/probe-$name.txt" started=$SECONDS
  snapshot > "$RUNNER_TEMP/probe-$name-before.snap.txt"
  (
    cd "$src" || exit 1
    # A pty keeps xcodebuild line-buffered so the timestamps are real.
    # shellcheck disable=SC2016 # Xcode expands $(...), not the shell
    FileSystemMode=checksum-only script -q /dev/null xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
      -derivedDataPath "$derived" \
      -clonedSourcePackagesDirPath "$src/.ci-source-packages" \
      -disableAutomaticPackageResolution \
      -destination "platform=macOS" \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_CI_APP_HOST_ISOLATION_REQUIRED' \
      'LD_RUNPATH_SEARCH_PATHS=$(inherited) @executable_path/../Frameworks /private/tmp/cmux-app-host-package-frameworks' \
      'COMPILATION_CACHE_ENABLE_CACHING=$(CMUX_CI_COMPILATION_CACHE_$(TARGET_NAME):default=YES)' \
      CMUX_CI_COMPILATION_CACHE_cmuxTests=NO \
      'OTHER_SWIFT_FLAGS=$(inherited) $(CMUX_CI_TARGET_FLAGS_$(TARGET_NAME))' \
      CMUX_CI_TARGET_FLAGS_cmux=-driver-show-incremental \
      "COMPILATION_CACHE_CAS_PATH=$cas" \
      COMPILATION_CACHE_LIMIT_SIZE=3221225472 \
      ${CMUX_CI_MODULE_CACHE_PATH:+"CLANG_MODULE_CACHE_PATH=$CMUX_CI_MODULE_CACHE_PATH"} \
      "$@" \
      -showBuildTimingSummary \
      build-for-testing < /dev/null 2>&1
  ) | perl -MTime::HiRes=time -ne 's/\r//g; printf "%.2f %s", time, $_' > "$log"
  local status=${PIPESTATUS[0]}
  snapshot > "$RUNNER_TEMP/probe-$name-after.snap.txt"
  [ "$status" = 0 ] || { echo "probe $name failed ($status)"; grep -E "error:" "$log" | head -20; }
  report "$name" "$log" "$((SECONDS - started))"
}

report() {
  local name="$1" log="$2" seconds="$3"
  python3 - "$name" "$log" "$seconds" "$summary" "$RUNNER_TEMP/probe-$name-before.snap.txt" "$RUNNER_TEMP/probe-$name-after.snap.txt" <<'PY'
import re, sys
from collections import Counter
name, log, seconds, summary, before, after = sys.argv[1:]
compiles, emits = Counter(), Counter()
first, last = {}, {}
remarks = []
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
        elif line.startswith(("SwiftEmitModule", "EmitSwiftModule")):
            emits[t] += 1
    if "Incremental compilation" in line or "remark:" in line and "incremental" in line.lower():
        remarks.append(line.strip())
out = [f"### {name}: {seconds}s"]
for t in ("cmux", "cmuxTests"):
    if t in first:
        out.append(f"- {t}: {last[t]-first[t]:.0f}s span, {compiles[t]} SwiftCompile, {emits[t]} emit-module")
    else:
        out.append(f"- {t}: no tasks")
kinds = Counter(re.sub(r"'[^']*'|\{[^}]*\}|\S+\.(swift|h|pch|swiftmodule)\S*", "X", r)[:160] for r in remarks)
out.append(f"- incremental remarks: {len(remarks)}")
for k, n in kinds.most_common(15):
    out.append(f"  - {n} x `{k}`")
reasons = [r for r in dict.fromkeys(remarks) if re.search(r"Newer|disabl|Disabl|not.*incremental|external|Fingerprint|missing|changed", r)]
for r in reasons[:25]:
    out.append(f"  - raw: `{r[:300]}`")
b = {l.split(" ", 2)[2]: l.split(" ", 2)[:2] for l in open(before).read().splitlines() if l.count(" ") >= 2}
a = {l.split(" ", 2)[2]: l.split(" ", 2)[:2] for l in open(after).read().splitlines() if l.count(" ") >= 2}
changed = [p for p in a if p in b and a[p] != b[p]]
out.append(f"- generated headers/PCH: {len(a)} tracked, {len(changed)} rewritten, {len(set(a)-set(b))} new")
for p in changed[:15]:
    same = "same bytes" if a[p][1] == b[p][1] else "new bytes"
    out.append(f"  - rewritten ({same}): `{p}`")
for p in sorted(set(a) - set(b))[:10]:
    out.append(f"  - new: `{p}`")
text = "\n".join(out) + "\n"
print(text)
open(summary, "a").write(text)
PY
}

edit() {
  local n="$1"
  cp "$RUNNER_TEMP/app.orig" "$app_file"
  perl -0pi -e "s/(func updateNSView\(_ view: GPUSpinnerNSView, context: Context\) \{\n)/\$1        let cmuxProbeBody = $n; _ = cmuxProbeBody\n/" "$app_file"
  grep -q "cmuxProbeBody = $n" "$app_file" || echo "edit $n did not apply"
}

# Did the admission compile the app without the cache? A cached Swift job
# carries -cache-compile-job on its command line, next to -module-name.
{
  echo "### Admission cache use per target"
  for t in cmux cmuxTests CmuxFoundation; do
    n="$(grep -e '-cache-compile-job' "$RUNNER_TEMP/cmux-compile-admission.txt" | grep -c -e "-module-name $t ")"
    echo "- $t: $n lines with -cache-compile-job"
  done
} | tee -a "$summary"

# The fix's settings: cache off for cmux (Xcode 26.3) and cmuxTests.
build fix-null CMUX_CI_COMPILATION_CACHE_cmux=NO
edit 1; build fix-app-body-1 CMUX_CI_COMPILATION_CACHE_cmux=NO
edit 2; build fix-app-body-2 CMUX_CI_COMPILATION_CACHE_cmux=NO

cp "$RUNNER_TEMP/app.orig" "$app_file"
exit 0
