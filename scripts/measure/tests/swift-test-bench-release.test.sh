#!/usr/bin/env bash
# swift-test-bench.sh config=release enable=CMUX_<NAME>_BENCH: the build and the run both use
# package-test-lane.sh's release flags (`-c release -Xswiftc -enable-testing ...`: @testable imports), and the
# run (only) sees NAME=1. A Release benchmark such as MainTurnMeterBench
# (2026-10-29) is skipped by its suite unless enabled, and measures Debug code without -c release.
# Runs the script on a copy of the repo's own scripts with stand-in swift, git, xcodebuild and
# sysctl that record their calls; builds nothing. Run: bash scripts/measure/tests/swift-test-bench-release.test.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/scripts/measure" "$root/scripts/cmux-next/lib" "$root/Packages/macOS/CmuxNext" "$tmp/bin"
cp "$repo/scripts/measure/swift-test-bench.sh" "$root/scripts/measure/"
cp "$repo/scripts/cmux-next/lib/fleet-only.sh" "$root/scripts/cmux-next/lib/"
: >"$root/Packages/macOS/CmuxNext/Package.swift"
log="$tmp/calls.log"
cat >"$tmp/bin/swift" <<'SH'
#!/bin/sh
printf 'swift %s | bench=%s\n' "$*" "${CMUX_MAIN_TURN_BENCH:-unset}" >>"$CALLS_LOG"
case "$1" in test) echo "Test run with 1 test passed after 0.1 seconds." ;; esac
exit 0
SH
cat >"$tmp/bin/git" <<'SH'
#!/bin/sh
case "$*" in
  "rev-parse HEAD") echo 0123456789abcdef0123456789abcdef01234567 ;;
  "rev-parse --is-shallow-repository") echo false ;;
esac
exit 0
SH
printf '#!/bin/sh\necho "Xcode 26.6"\n' >"$tmp/bin/xcodebuild"
printf '#!/bin/sh\necho 1\n' >"$tmp/bin/sysctl"
printf '#!/bin/sh\necho 27.0\n' >"$tmp/bin/sw_vers"
chmod +x "$tmp/bin/"*
fail=0
run() { # run ARGS...: the script as a fleet step, with the stand-ins first on PATH
  : >"$log"
  ( cd "$root" && CALLS_LOG="$log" CMUX_CI_STEP_KEY=test DEVELOPER_DIR=/x PATH="$tmp/bin:$PATH" \
      bash scripts/measure/swift-test-bench.sh "$@" >"$tmp/out.log" 2>&1 ) ||
    { echo "FAIL: swift-test-bench.sh $* exited $?"; sed 's/^/    /' "$tmp/out.log"; fail=1; }
}
want() { grep -qF -- "$1" "$log" || { echo "FAIL: no call like: $1"; sed 's/^/    /' "$log"; fail=1; }; }
none() { ! grep -qF -- "$1" "$log" || { echo "FAIL: unexpected call like: $1"; sed 's/^/    /' "$log"; fail=1; }; }

run Packages/macOS/CmuxNext MainTurnMeterBench config=release enable=CMUX_MAIN_TURN_BENCH
want "swift build --package-path Packages/macOS/CmuxNext --build-tests -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=copy-propagation | bench=unset"
want "swift test --package-path Packages/macOS/CmuxNext --skip-build --filter MainTurnMeterBench -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=copy-propagation | bench=1"

run Packages/macOS/CmuxNext SomeSuite
want "swift build --package-path Packages/macOS/CmuxNext --build-tests | bench=unset"
want "swift test --package-path Packages/macOS/CmuxNext --skip-build --filter SomeSuite | bench=unset"
none "-c release"

[[ $fail -eq 0 ]] && echo "swift-test-bench release: ok"
exit $fail
