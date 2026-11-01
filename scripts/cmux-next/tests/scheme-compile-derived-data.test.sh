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
# The kept path's binary-module guard resolves packages first; not a build.
for arg in "\$@"; do [[ "\$arg" == -resolvePackageDependencies ]] && exit 0; done
printf '%s\n' "\$*" >> "$TMP/args"
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "-derivedDataPath" ]]; then
    printf '%s\n' "\$2" >> "$TMP/paths"
    [[ -n "\$(ls -A "\$2" 2>/dev/null)" ]] && echo nonempty >> "$TMP/existed"
    mkdir -p "\$2/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules"
  fi
  shift
done
if [[ -n "\${STUB_CAS_FAIL_ONCE:-}" && ! -e "$TMP/cas-done" ]]; then
  touch "$TMP/cas-done"
  echo "error: failed to open the CAS database: UnifiedOnDiskCache: corrupt"
  exit 65
fi
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
reset() { rm -f "$TMP/paths" "$TMP/existed" "$TMP/stale-done" "$TMP/cas-done" "$TMP/args"; }

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

# 4. A new kept path outside /tmp and the glaeda cache (a runner's RUNNER_TEMP
#    on Blacksmith or hosted macOS) builds: it has no outputs to clear, so the
#    binary-module guard never asks clear-stale-scheme-build-state.sh. (That
#    script accepts only $RUNNER_TEMP's cmux-next-* and cmux-scheme-compile
#    outside /tmp and the glaeda cache.)
reset
outside="$ROOT/.scheme-dd-test.$$"
trap 'rm -rf "$TMP" "$outside"' EXIT
SC_ARG="$outside" run || fail "a new kept path outside /tmp exited $?"
[[ $(sort -u "$TMP/paths") == "$outside" ]] || fail "the new kept DerivedData was not used"
[[ -s "$outside/.cmux-binary-module-inputs" ]] || fail "the guard wrote no header digest"

# 5. A Package.resolved that xcodebuild rewrote is restored on exit, so the
#    glaeda job-start hook finds a clean workspace and keeps it (a reset
#    workspace rewrites every file and the kept DerivedData rebuilds every
#    module). A clean file, a missing file and a non-repository are no-ops,
#    and none of them fails the build.
# shellcheck source=scripts/cmux-next/lib/workspace-resolved.sh
source "$ROOT/scripts/cmux-next/lib/workspace-resolved.sh"
# shellcheck source=scripts/cmux-next/lib/compilation-cache.sh
source "$ROOT/scripts/cmux-next/lib/compilation-cache.sh"
repo="$TMP/repo"; rel=cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
mkdir -p "$repo/$(dirname "$rel")"
git -C "$repo" init -q
printf '{ "pins" : [] }\n' > "$repo/$rel"
git -C "$repo" add "$rel"
git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init
cmux_next_restore_workspace_resolved "$repo" >"$TMP/out" 2>&1 || fail "clean restore failed"
[[ ! -s "$TMP/out" ]] || fail "a clean Package.resolved printed output"
printf '{ "pins" : [ "swift-atomics" ] }\n' > "$repo/$rel"
cmux_next_restore_workspace_resolved "$repo" >"$TMP/out" 2>&1 || fail "dirty restore failed"
git -C "$repo" diff --quiet -- "$rel" || fail "the rewritten Package.resolved was not restored"
grep -q '^::warning file=cmux.xcodeproj/.*Package.resolved::' "$TMP/out" || fail "no warning for a stale Package.resolved"
cmux_next_restore_workspace_resolved "$TMP/steptmp" >"$TMP/out" 2>&1 || fail "a non-repository failed"
git -C "$repo" rm -q "$rel"
cmux_next_restore_workspace_resolved "$repo" >"$TMP/out" 2>&1 || fail "a repository without the file failed"

# 6. CMUX_NEXT_COMPILATION_CACHE=1 on a kept path: the build starts from a tree
#    that keeps only the compilation cache and the package checkouts (no kept
#    build products, manaflow-ai/cmux#21761), passes the cache settings and
#    the build-mode overrides, and a cache failure drops the cache and builds
#    once more without it. Off, or on a fresh directory, nothing changes.
reset
cas_dd="$TMP/cas-dd"
mkdir -p "$cas_dd/Build/Products" "$cas_dd/CompilationCache.noindex/v1.1" "$cas_dd/SourcePackages/checkouts" "$cas_dd/ModuleCache.noindex"
touch "$cas_dd/Build/Products/stale.o" "$cas_dd/CompilationCache.noindex/v1.1/data" "$cas_dd/SourcePackages/checkouts/pkg" "$cas_dd/info.plist"
SC_ARG="$cas_dd" run CMUX_NEXT_COMPILATION_CACHE=1 CMUX_NEXT_SWIFT_COMPILATION_MODE=singlefile || fail "cache run exited $?"
[[ ! -e "$cas_dd/Build/Products/stale.o" && ! -e "$cas_dd/ModuleCache.noindex" && ! -e "$cas_dd/info.plist" ]] \
  || fail "kept build products survived into a cache build"
[[ -e "$cas_dd/CompilationCache.noindex/v1.1/data" && -e "$cas_dd/SourcePackages/checkouts/pkg" ]] \
  || fail "the cache or the package checkouts were removed"
grep -q 'COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_LIMIT_SIZE=3221225472' "$TMP/args" || fail "no cache settings: $(cat "$TMP/args")"
grep -q 'SWIFT_COMPILATION_MODE=singlefile' "$TMP/args" || fail "no SWIFT_COMPILATION_MODE"
reset
SC_ARG="$cas_dd" run CMUX_NEXT_COMPILATION_CACHE=1 STUB_CAS_FAIL_ONCE=1 || fail "a cache failure failed the build"
[[ $(wc -l < "$TMP/args") -eq 2 ]] || fail "want a build and one retry after a cache failure, got $(wc -l < "$TMP/args")"
sed -n 2p "$TMP/args" | grep -q COMPILATION_CACHE_ENABLE_CACHING && fail "the retry still used the cache"
[[ ! -e "$cas_dd/CompilationCache.noindex/v1.1/data" ]] || fail "the failing cache was kept"
# Swift's own CAS diagnostics count as cache failures; a code error does not.
for line in "error: CAS error encountered during compilation" "error: CAS error: No such file or directory" "error: cannot create CAS filesystem: x" \
    "error: failed to load input '/x/a.swift' from CAS" "/x/a.swift:1:2: error: CAS error encountered during x" \
    "error: failed to replay cached diagnostics: x" "error: cannot create cache key for compilation x: y"; do
  printf '%s\n' "$line" > "$TMP/caslog"
  cmux_next_cas_failed "$TMP/caslog" || fail "not a cache failure: $line"
done
printf '%s\n' "error: cannot find 'CASE' in scope" "error: use of unresolved identifier 'cas'" "  348 1 99.4 error CAS process dump" > "$TMP/caslog"
cmux_next_cas_failed "$TMP/caslog" && fail "a code error read as a cache failure"
# The nightly fleet fallback uses the stricter runtime predicate: source
# diagnostics that happen to mention CAS/cache must not trigger a second build.
for line in "error: CAS error encountered during compilation" "error: CAS error: No such file or directory" "error: cannot create CAS filesystem: x" \
    "error: failed to load input '/x/a.swift' from CAS" "error: failed to replay cached diagnostics: x" \
    "error: remote service unavailable" "error: cache plugin failed"; do
  printf '%s\n' "$line" > "$TMP/caslog"
  cmux_next_runtime_cas_failed "$TMP/caslog" || fail "runtime CAS failure was not recognized: $line"
done
for line in "error: cannot find 'CAS' in scope" "error: use of unresolved identifier 'cache'"; do
  printf '%s\n' "$line" > "$TMP/caslog"
  cmux_next_runtime_cas_failed "$TMP/caslog" && fail "source error triggered runtime cache retry: $line"
done
reset
status=0; SC_ARG="$cas_dd" run CMUX_NEXT_COMPILATION_CACHE=1 STUB_XCODEBUILD_STATUS=65 || status=$?
[[ $status -eq 65 && $(wc -l < "$TMP/args") -eq 1 ]] || fail "a code failure exited $status after $(wc -l < "$TMP/args") builds (want 65 after 1)"
# A leftover product that cannot be removed: never build on it.
reset
mkdir -p "$cas_dd/Build/locked" && touch "$cas_dd/Build/locked/stale.o" && chmod 500 "$cas_dd/Build/locked"
status=0; SC_ARG="$cas_dd" run CMUX_NEXT_COMPILATION_CACHE=1 || status=$?
chmod 700 "$cas_dd/Build/locked"
[[ $status -eq 1 && ! -s "$TMP/args" ]] || fail "a tree that could not be emptied exited $status after $(wc -l < "$TMP/args" 2>/dev/null || echo 0) builds (want 1 after none)"
reset
run CMUX_NEXT_COMPILATION_CACHE=1 || fail "cache on a fresh directory exited $?"
grep -q COMPILATION_CACHE_ENABLE_CACHING "$TMP/args" && fail "a fresh directory used the cache"
reset
SC_ARG="$TMP/kept-dd" run || fail "default kept run exited $?"
grep -Eq 'COMPILATION_CACHE|SWIFT_COMPILATION_MODE' "$TMP/args" && fail "defaults changed the build: $(cat "$TMP/args")"
status=0; run CMUX_NEXT_SWIFT_COMPILATION_MODE=fast || status=$?
[[ $status -eq 2 ]] || fail "an unknown compilation mode exited $status (want 2)"

printf 'scheme compile DerivedData tests: ok\n'
