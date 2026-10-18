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

printf 'release compile DerivedData tests: ok\n'
