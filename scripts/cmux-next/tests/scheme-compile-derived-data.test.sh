#!/usr/bin/env bash
# check-cmux-scheme-compile.sh must not build into a DerivedData that another
# run left on the host. Its old default, /tmp/cmux-scheme-compile, was shared by
# every fleet step on a host and kept explicit precompiled modules from older
# xcframework headers (the same failure as check-release-compile.sh on
# cmuxs-Mac-mini-4, 2026-10-06). With no path argument a run gets a new empty
# DerivedData in $TMPDIR and removes it. The stale-PCM retry stays only for a
# caller's kept path (the glaeda job's per-runner cache), where it still has a
# purpose; a fresh directory has no earlier modules to clear. A stub xcodebuild
# records the -derivedDataPath it gets.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# Under /tmp: clear-stale-scheme-build-state.sh accepts only /tmp paths and the
# glaeda cache, so the kept-path retry case needs one.
TMP=$(mktemp -d /tmp/cmux-scheme-dd-test.XXXXXX); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/steptmp" "$TMP/dev"
cat > "$TMP/bin/xcodebuild" <<EOF
#!/bin/bash
if [[ "\$1" == "-version" ]]; then echo "Xcode 26.6"; exit 0; fi
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "-derivedDataPath" ]]; then
    printf '%s\n' "\$2" >> "$TMP/paths"
    [[ -n "\$(ls -A "\$2" 2>/dev/null)" ]] && echo nonempty >> "$TMP/existed"
    mkdir -p "\$2/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules"
  fi
  shift
done
if [[ -n "\${STUB_STALE_ONCE:-}" && ! -e "$TMP/stale-done" ]]; then
  touch "$TMP/stale-done"
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
    /bin/bash "$ROOT/scripts/cmux-next/check-cmux-scheme-compile.sh" ${SC_ARG:+"$SC_ARG"} >"$TMP/out" 2>&1
}
fail() { printf 'FAIL: %s\n' "$1"; cat "$TMP/out"; exit 1; }
reset() { rm -f "$TMP/paths" "$TMP/existed" "$TMP/stale-done"; }

# 1. With no argument, two runs get two fresh DerivedData paths in the step
#    TMPDIR (not the old shared /tmp/cmux-scheme-compile) and remove them.
reset
run || fail "run 1 exited $?"
run || fail "run 2 exited $?"
[[ $(wc -l < "$TMP/paths") -eq 2 ]] || fail "want 2 xcodebuild builds, got $(wc -l < "$TMP/paths")"
first=$(sed -n 1p "$TMP/paths"); second=$(sed -n 2p "$TMP/paths")
[[ "$first" != /tmp/cmux-scheme-compile && "$first" != /private/tmp/cmux-scheme-compile ]] \
  || fail "default DerivedData is the host-shared $first"
[[ "$first" != "$second" ]] || fail "two runs shared the DerivedData $first"
[[ "$first" == "$TMP/steptmp/"* ]] || fail "default DerivedData $first is not in the step TMPDIR"
[[ ! -e "$TMP/existed" ]] || fail "a run started on a DerivedData that held earlier build state"
[[ ! -e "$first" && ! -e "$second" ]] || fail "a run left its DerivedData behind"

# 2. A failed fresh build keeps its status, removes its DerivedData and does
#    not retry: a fresh directory has no stale modules to clear.
reset
status=0; run STUB_STALE_ONCE=1 || status=$?
[[ $status -eq 65 ]] || fail "fresh stale-looking failure exited $status (want 65)"
[[ $(wc -l < "$TMP/paths") -eq 1 ]] || fail "a fresh DerivedData was built $(wc -l < "$TMP/paths") times (want 1, no retry)"
[[ ! -e "$(sed -n 1p "$TMP/paths")" ]] || fail "a failed run left its DerivedData behind"

# 3. A caller's kept path is used as given, kept, and still retried once after
#    a stale-PCM failure.
reset
SC_ARG="$TMP/kept-dd" run STUB_STALE_ONCE=1 || fail "kept-path retry run exited $?"
[[ $(wc -l < "$TMP/paths") -eq 2 ]] || fail "kept path built $(wc -l < "$TMP/paths") times (want 2: build + retry)"
[[ $(sort -u "$TMP/paths") == "$TMP/kept-dd" ]] || fail "kept DerivedData not used"
[[ -d "$TMP/kept-dd" ]] || fail "kept DerivedData was removed"

printf 'scheme compile DerivedData tests: ok\n'
