#!/usr/bin/env bash
# check-release-compile.sh must not build into a DerivedData that another run
# left on the host. A shared /tmp/cmux-next-release-compile kept explicit
# precompiled modules (SwiftExplicitPrecompiledModules/CCmuxRdFFI-*.pcm) built
# from an older CCmuxAppFFI xcframework header; the next run with a new FFI pin
# failed with exit 65 ("cmux_rd_ffi.h has been modified since the module file
# was built") on cmuxs-Mac-mini-4 (steps c0601e588400 and 804c1cbc315c,
# 2026-10-06). A stub xcodebuild records the -derivedDataPath it gets.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d /tmp/cmux-release-dd-test.XXXXXX); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/steptmp" "$TMP/dev"
cat > "$TMP/bin/xcodebuild" <<EOF
#!/bin/bash
if [[ "\$1" == "-version" ]]; then echo "Xcode 26.6"; exit 0; fi
# The kept path's binary-module guard resolves packages first; not a build.
for arg in "\$@"; do [[ "\$arg" == -resolvePackageDependencies ]] && exit 0; done
while [[ \$# -gt 0 ]]; do
  [[ "\$1" == ARCHS=* ]] && printf '%s\n' "\$1" >> "$TMP/archs"
  [[ "\$1" == OTHER_SWIFT_FLAGS=* ]] && printf '%s\n' "\$1" >> "$TMP/swiftflags"
  if [[ "\$1" == "-derivedDataPath" ]]; then
    printf '%s\n' "\$2" >> "$TMP/paths"
    [[ -n "\$(ls -A "\$2" 2>/dev/null)" ]] && echo nonempty >> "$TMP/existed"
    mkdir -p "\$2/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules"
  fi
  shift
done
if [[ "\${STUB_STALE_PCM:-0}" == 1 && ! -e "$TMP/retried" ]]; then
  touch "$TMP/retried"
  echo "error: file '/x/include/CCmuxRdFFI/cmux_rd_ffi.h' has been modified since the module file '/x/CCmuxRdFFI-1.pcm' was built"
  exit 65
fi
exit "\${STUB_XCODEBUILD_STATUS:-0}"
EOF
chmod +x "$TMP/bin/xcodebuild"

run() {
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP/steptmp" \
    CMUX_CI_STEP_KEY=test-step DEVELOPER_DIR="$TMP/dev" \
    CMUX_XCODEBUILD_HEARTBEAT_SECONDS=1 "$@" \
    /bin/bash "$ROOT/scripts/cmux-next/check-release-compile.sh" ${RC_ARG:+"$RC_ARG"} >"$TMP/out" 2>&1
}
fail() { printf 'FAIL: %s\n' "$1"; cat "$TMP/out"; exit 1; }

# 1. With no argument, two runs on one host get two fresh DerivedData paths
#    (not the old shared /tmp/cmux-next-release-compile), inside the step's
#    TMPDIR, and each run removes its own path when it ends.
rm -f "$TMP/paths" "$TMP/existed"
run || fail "run 1 exited $?"
run || fail "run 2 exited $?"
[[ $(wc -l < "$TMP/paths") -eq 2 ]] || fail "want 2 xcodebuild builds, got $(wc -l < "$TMP/paths")"
first=$(sed -n 1p "$TMP/paths"); second=$(sed -n 2p "$TMP/paths")
[[ "$first" != /tmp/cmux-next-release-compile && "$first" != /private/tmp/cmux-next-release-compile ]] \
  || fail "default DerivedData is the host-shared $first"
[[ "$first" != "$second" ]] || fail "two runs shared the DerivedData $first"
[[ "$first" == "$TMP/steptmp/"* ]] || fail "default DerivedData $first is not in the step TMPDIR"
[[ ! -e "$TMP/existed" ]] || fail "a run started on a DerivedData that held earlier build state"
[[ ! -e "$first" && ! -e "$second" ]] || fail "a run left its DerivedData behind"

# 2. A failed build keeps its exit status and still removes its DerivedData.
rm -f "$TMP/paths"
status=0; run STUB_XCODEBUILD_STATUS=65 || status=$?
[[ $status -eq 65 ]] || fail "failed build exited $status (want 65)"
failed=$(sed -n 1p "$TMP/paths")
[[ ! -e "$failed" ]] || fail "a failed run left its DerivedData $failed"

# 3. An explicit path (including a kept owned-worker cache) is
#    used as given and kept for the caller.
rm -f "$TMP/paths"
RC_ARG="$TMP/explicit-dd" run || fail "explicit run exited $?"
[[ $(sed -n 1p "$TMP/paths") == "$TMP/explicit-dd" ]] || fail "explicit DerivedData not used"
[[ -d "$TMP/explicit-dd" ]] || fail "explicit DerivedData was removed"

# 4. A stale PCM in a kept path retries once, dropping derived outputs while
#    retaining downloaded packages. A normal compile failure never retries.
mkdir -p "$TMP/kept-dd/SourcePackages" "$TMP/kept-dd/Build/Products"
touch "$TMP/kept-dd/SourcePackages/package" "$TMP/kept-dd/Build/Products/stale.o"
rm -f "$TMP/paths" "$TMP/retried"
RC_ARG="$TMP/kept-dd" run STUB_STALE_PCM=1 || fail "stale PCM recovery exited $?"
[[ $(wc -l < "$TMP/paths") -eq 2 ]] || fail "stale PCM was not retried exactly once"
[[ -e "$TMP/kept-dd/SourcePackages/package" ]] || fail "recovery removed downloaded packages"
[[ ! -e "$TMP/kept-dd/Build/Products/stale.o" ]] || fail "recovery retained stale build products"
rm -f "$TMP/paths" "$TMP/retried"
status=0; RC_ARG="$TMP/kept-dd" run STUB_XCODEBUILD_STATUS=65 || status=$?
[[ $status -eq 65 && $(wc -l < "$TMP/paths") -eq 1 ]] || fail "ordinary failure retried or lost its status"
rm -f "$TMP/paths" "$TMP/retried"
status=0; RC_ARG="$TMP/kept-dd" run STUB_STALE_PCM=1 STUB_XCODEBUILD_STATUS=66 || status=$?
[[ $status -eq 66 && $(wc -l < "$TMP/paths") -eq 2 ]] || fail "retry failure lost its status or retried again"
rm -f "$TMP/paths" "$TMP/retried"
status=0; run STUB_STALE_PCM=1 || status=$?
[[ $status -eq 65 && $(wc -l < "$TMP/paths") -eq 1 ]] || fail "fresh path retried a stale PCM diagnostic"

# 5. Outside the glaeda pools release-derived-data-path.sh gives
#    $RUNNER_TEMP/cmux-next-release-compile, which hosted macOS runners keep
#    under /Users/runner/_work/_temp, not /tmp. The binary-module guard clears
#    it on a first build, so refusing it failed every such Release compile
#    ("refusing unexpected DerivedData path", from 2026-10-18). Other paths
#    under RUNNER_TEMP stay refused.
RT=$(mktemp -d /var/tmp/cmux-release-rt.XXXXXX); trap 'rm -rf "$TMP" "$RT"' EXIT
mkdir -p "$RT/cmux-next-release-compile/Build/Products" "$RT/cmux-next-release-compile/SourcePackages" "$RT/other/Build"
status=0
RUNNER_TEMP="$RT" /bin/bash "$ROOT/scripts/cmux-next/clear-stale-scheme-build-state.sh" "$RT/cmux-next-release-compile" >"$TMP/out" 2>&1 || status=$?
[[ $status -eq 0 ]] || fail "RUNNER_TEMP DerivedData refused (exit $status)"
[[ ! -e "$RT/cmux-next-release-compile/Build" && -d "$RT/cmux-next-release-compile/SourcePackages" ]] \
  || fail "RUNNER_TEMP DerivedData was not cleared to its packages"
status=0
RUNNER_TEMP="$RT" /bin/bash "$ROOT/scripts/cmux-next/clear-stale-scheme-build-state.sh" "$RT/other" >"$TMP/out" 2>&1 || status=$?
[[ $status -eq 2 && -d "$RT/other/Build" ]] || fail "an unrelated RUNNER_TEMP path was cleared (exit $status)"
mkdir -p "$RT/cmux-scheme-compile/Build"
RUNNER_TEMP="$RT" /bin/bash "$ROOT/scripts/cmux-next/clear-stale-scheme-build-state.sh" "$RT/cmux-scheme-compile" >"$TMP/out" 2>&1 \
  || fail "the scheme compile's RUNNER_TEMP DerivedData was refused"
[[ ! -e "$RT/cmux-scheme-compile/Build" ]] || fail "the scheme compile's RUNNER_TEMP DerivedData was not cleared"
status=0
RUNNER_TEMP="$RT" /bin/bash "$ROOT/scripts/cmux-next/clear-stale-scheme-build-state.sh" "$RT/cmux-next-x/../other" >"$TMP/out" 2>&1 || status=$?
[[ $status -eq 2 && -d "$RT/other/Build" ]] || fail "a .. path escaped the guard (exit $status)"

# 6. The guard gates an rm -rf. A RUNNER_TEMP that is empty, /, a top-level
#    directory or a home directory accepts nothing, and a path is judged where it resolves: a link
#    named like a lane's DerivedData cannot aim the clear elsewhere. Every path
#    here is under $RT or does not exist, so a broken guard removes nothing real.
clear_at() {
  status=0
  env -i PATH=/usr/bin:/bin "$@" /bin/bash "$ROOT/scripts/cmux-next/clear-stale-scheme-build-state.sh" "$path" \
    >"$TMP/out" 2>&1 || status=$?
}
victim="$RT/victim"; mkdir -p "$victim/Build"
top="/$(printf '%s' "$RT" | cut -d/ -f2)"
missing="cmux-next-guard-test-$$-missing"
[[ ! -e "/$missing" && ! -e "$top/$missing" ]] || fail "test paths /$missing or $top/$missing exist"
home="/$(printf '%s' "$HOME" | cut -d/ -f2-3)"
[[ ! -e "$home/$missing" ]] || fail "test path $home/$missing exists"
for spec in "RUNNER_TEMP=/|/$missing" "RUNNER_TEMP=$top|$top/$missing" "RUNNER_TEMP=$home|$home/$missing" "RUNNER_TEMP=|$RT/cmux-next-release-compile" \
  "RUNNER_TEMP=relative|relative/cmux-next-release-compile"; do
  path=${spec#*|}; clear_at "${spec%%|*}"
  [[ $status -eq 2 ]] || fail "${spec%%|*} accepted $path (exit $status)"
done
ln -s "$victim" "$RT/cmux-next-linked"
path="$RT/cmux-next-linked"; clear_at RUNNER_TEMP="$RT"
[[ $status -eq 2 && -d "$victim/Build" ]] || fail "a lane-named link under RUNNER_TEMP cleared $victim (exit $status)"
ln -s "$victim" "$TMP/linked"
path="$TMP/linked"; clear_at RUNNER_TEMP="$RT"
[[ $status -eq 2 && -d "$victim/Build" ]] || fail "a link under /tmp cleared $victim (exit $status)"
path="$RT/./cmux-next-release-compile"; clear_at RUNNER_TEMP="$RT"
[[ $status -eq 2 ]] || fail "a . segment was accepted (exit $status)"
# A RUNNER_TEMP reached through a link is still RUNNER_TEMP.
ln -s "$RT" "$RT-link"; trap 'rm -rf "$TMP" "$RT" "$RT-link"' EXIT
mkdir -p "$RT/cmux-next-release-compile/Build"
path="$RT-link/cmux-next-release-compile"; clear_at RUNNER_TEMP="$RT-link"
[[ $status -eq 0 && ! -e "$RT/cmux-next-release-compile/Build" ]] || fail "a linked RUNNER_TEMP's DerivedData was refused (exit $status)"

# --archs picks the architecture xcodebuild compiles (nightly-next ships an
# x86_64 app); the default stays arm64, and a bad or misplaced flag is refused.
archs_run() {
  rm -f "$TMP/archs"; status=0
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP/steptmp" \
    CMUX_CI_STEP_KEY=test-step DEVELOPER_DIR="$TMP/dev" CMUX_XCODEBUILD_HEARTBEAT_SECONDS=1 \
    /bin/bash "$ROOT/scripts/cmux-next/check-release-compile.sh" "$@" >"$TMP/out" 2>&1 || status=$?
}
archs_run; [[ $status -eq 0 && "$(cat "$TMP/archs")" == ARCHS=arm64 ]] || fail "default run compiled $(cat "$TMP/archs" 2>/dev/null) (exit $status)"
archs_run --archs x86_64; [[ $status -eq 0 && "$(cat "$TMP/archs")" == ARCHS=x86_64 ]] || fail "--archs x86_64 compiled $(cat "$TMP/archs" 2>/dev/null) (exit $status)"
archs_run --archs x86_64 "$TMP/kept-x86"; [[ $status -eq 0 && "$(cat "$TMP/archs")" == ARCHS=x86_64 ]] || fail "--archs x86_64 with a path compiled $(cat "$TMP/archs" 2>/dev/null) (exit $status)"
for bad in "--archs" "--archs i386" "$TMP/kept-x86 --archs x86_64"; do
  # shellcheck disable=SC2086 # each case is a word list
  archs_run $bad
  [[ $status -eq 2 && ! -e "$TMP/archs" ]] || fail "'$bad' was not refused (exit $status)"
done

# 7. The build setting is OTHER_SWIFT_FLAGS=$(inherited) [bench defines], never a doubled
#    "OTHER_SWIFT_FLAGS=OTHER_SWIFT_FLAGS=...": c6d2865fcf9 passed that to xcodebuild, which then read
#    "-DXcode..." as an input file and failed every plain Release compile (landq 2026-10-25, tip 7921f4febe78).
rm -f "$TMP/swiftflags"
run || fail "the plain release compile exited $?"
[[ "$(cat "$TMP/swiftflags")" == 'OTHER_SWIFT_FLAGS=$(inherited)' ]] \
  || fail "plain OTHER_SWIFT_FLAGS is '$(cat "$TMP/swiftflags")'"
rm -f "$TMP/swiftflags"
RC_ARG=--bench-hooks run || fail "the bench-hooks release compile exited $?"
# The bench defines come from one shared file (lib/bench-swift-defines.sh, also reload.sh's).
# shellcheck source=../lib/bench-swift-defines.sh
source "$ROOT/scripts/cmux-next/lib/bench-swift-defines.sh"
[[ "$(cat "$TMP/swiftflags")" == "OTHER_SWIFT_FLAGS=\$(inherited) $CMUX_BENCH_SWIFT_DEFINES" ]] \
  || fail "bench OTHER_SWIFT_FLAGS is '$(cat "$TMP/swiftflags")'"

printf 'release compile DerivedData tests: ok\n'
