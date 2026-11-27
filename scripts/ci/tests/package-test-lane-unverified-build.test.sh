#!/usr/bin/env bash
# scripts/ci/tests/package-test-lane-unverified-build.test.sh: a .build that a
# fleet worker kept after an unfinished step (.build/.cmux-ci-unverified, hq
# build-fleet cmd/worker step_warm.go) is resumed; when the build on it fails,
# package-test-lane.sh builds once more from clean outputs, and a complete
# build clears the mark. A failed build on a .build with no mark is not retried.
#
# 2026-11-21: CmuxNext suite steps on lent minis were stopped at their 180 min
# max-run with 27 of 13,437-15,760 targets left; the worker dropped the .build,
# so the next step on the slot compiled every target again and ran into the cap
# again. The worker now keeps it, marked; this is the script's half.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../cmux-next/tests/lib/git-fixture.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d)
git_fixture_trap_exit 'rm -rf "$tmp"'
repo="$tmp/repo"
pkg="$repo/Packages/macOS/Fake"
mkdir -p "$repo/scripts/ci/package-test-lane" "$repo/scripts/cmux-next" "$pkg" "$tmp/bin"
cp "$ROOT/scripts/ci/package-test-lane.sh" "$ROOT"/scripts/ci/*.py \
  "$ROOT/scripts/ci/swift-test-debug-info.sh" "$ROOT/scripts/ci/swiftpm-binary-module-guard.sh" \
  "$ROOT/scripts/ci/github-egress-direct.sh" "$repo/scripts/ci/"
cp "$ROOT/scripts/ci/package-test-lane/swift_suite_outcomes.py" "$repo/scripts/ci/package-test-lane/"
cp "$ROOT/scripts/cmux-next/stale-pcm-retry-needed.sh" "$repo/scripts/cmux-next/"
printf '// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "Fake")\n' > "$pkg/Package.swift"
git_fixture_init "$repo" && git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat > "$tmp/bin/xcrun" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = --show-sdk-path ] && { echo "$DEVELOPER_DIR/SDKs/MacOSX.sdk"; exit 0; }; done
exit 1
SH
# The fake build fails while a leftover output named "poison" is in .build
# (the purge removes it); FAKE_BROKEN=1 is a real compile error that no
# rebuild fixes.
cat > "$tmp/bin/swift" <<'SH'
#!/usr/bin/env bash
echo "swift $*" >> "$FAKE_SEEN"
case "$1" in
  build)
    mkdir -p Packages/macOS/Fake/.build
    if [ -e Packages/macOS/Fake/.build/poison ] || [ "${FAKE_BROKEN:-0}" = 1 ]; then
      echo "error: undefined symbols"; exit 1
    fi
    echo "Build complete!"; exit 0 ;;
  test)
    if [ "${2:-}" = list ]; then
      echo "FakeTests.FakeTests/example()"
    else
      echo "✔ Test run with 1 test in 1 suite passed after 0.1 seconds."
    fi
    exit 0 ;;
esac
exit 0
SH
chmod +x "$tmp/bin/xcrun" "$tmp/bin/swift"
dev="$tmp/Xcode.app/Contents/Developer"
mkdir -p "$dev/SDKs/MacOSX.sdk"
ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$tmp/bin/python3"
fails=0
lane() {
  local status=0
  : > "$tmp/seen"
  LANE_OUT=$(cd "$repo" && env ${LANE_ENV:-} PATH="$tmp/bin:$PATH" DEVELOPER_DIR="$dev" FAKE_SEEN="$tmp/seen" RUNNER_TEMP="$tmp" \
    CMUX_PACKAGE_LANE_TEST_OS=Darwin CMUX_SWIFT_TEST_STALL_SECONDS=30 CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS=60 \
    bash scripts/ci/package-test-lane.sh suite Packages/macOS/Fake FakeTests 2>&1) || status=$?
  LANE_STATUS=$status
  BUILDS=$(grep -c '^swift build --build-tests' "$tmp/seen" || true)
}
fail() { printf 'FAIL: %s\n%s\n' "$1" "$LANE_OUT" >&2; cat "$tmp/seen" >&2; fails=$((fails + 1)); }
# A warm slot: everything but the binary-module guard's stamp goes, so the guard keeps the rest (as on a
# slot whose binary inputs did not change), then the named leftovers are put back.
reset_build() {
  find "$pkg/.build" -mindepth 1 -maxdepth 1 ! -name "$(cd "$repo" && bash -c '. scripts/ci/swiftpm-binary-module-guard.sh; echo "$swiftpm_binary_module_inputs_file"')" -exec rm -rf {} +
  for f in "$@"; do : > "$pkg/.build/$f"; done
}
lane # the first, cold run writes the guard's stamp
[ "$LANE_STATUS" -eq 0 ] || fail "the cold run failed (exit $LANE_STATUS)"

# 1. A bad leftover: the build on it fails, the lane builds again from clean outputs and passes.
reset_build .cmux-ci-unverified poison
lane
[ "$LANE_STATUS" -eq 0 ] || fail "a failed build on an unverified .build was not rebuilt clean (exit $LANE_STATUS)"
[ "$BUILDS" -eq 2 ] || fail "want 2 builds (resume, then clean), got $BUILDS"
[[ "$LANE_OUT" == *"::warning title=Unfinished warm build::"* ]] || fail "no warning names the clean rebuild"
[ ! -e "$pkg/.build/.cmux-ci-unverified" ] || fail "a complete build left the unverified mark"
[ -s "$pkg/.build/.cmux-ci-built-ref" ] || fail "a complete build wrote no built ref"

# 2. A good leftover: one build resumes it, and the mark goes.
reset_build .cmux-ci-unverified
lane
[ "$LANE_STATUS" -eq 0 ] && [ "$BUILDS" -eq 1 ] || fail "a resumable unverified .build took $BUILDS builds (exit $LANE_STATUS), want 1"
[ ! -e "$pkg/.build/.cmux-ci-unverified" ] || fail "a complete resumed build left the unverified mark"

# 3. A real compile error on an unverified .build: one clean retry, then the error stands.
reset_build .cmux-ci-unverified
LANE_ENV=FAKE_BROKEN=1 lane
[ "$LANE_STATUS" -ne 0 ] && [ "$BUILDS" -eq 2 ] || fail "a broken tree on an unverified .build: exit $LANE_STATUS after $BUILDS builds, want red after 2"

# 4. A failed build on a .build with no mark is reported as is: no retry.
reset_build poison
lane
[ "$LANE_STATUS" -ne 0 ] && [ "$BUILDS" -eq 1 ] || fail "a failed build with no unverified mark: exit $LANE_STATUS after $BUILDS builds, want red after 1"

if [ "$fails" -ne 0 ]; then exit 1; fi
echo "package-test-lane unverified .build: ok"
