#!/usr/bin/env bash
# scripts/ci/tests/package-test-lane-sdkroot.test.sh: package-test-lane.sh pins
# SDKROOT to the macOS SDK of the Xcode whose swiftc it uses, and fails loud
# when `swift test` says the toolchain and SDK differ or no test ran.
#
# 2026-10-07 on cmux-lawrence-2: with DEVELOPER_DIR=Xcode_26.6, the
# /usr/bin/python3 shim that starts hung_test_watchdog.py exported
# SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk (Swift 6.4) to
# `swift test`, so every suite failed with "this SDK is not supported by the
# compiler", "Invalid manifest" and "no tests found" after a good build. The
# test starts the lane with that leaked SDKROOT and fake swift/xcrun tools.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/scripts/ci" "$repo/Packages/macOS/Fake" "$tmp/bin"
# The lane and the Python helpers it imports (hung_test_watchdog.py needs ci_process_tree.py).
cp "$ROOT/scripts/ci/package-test-lane.sh" "$ROOT"/scripts/ci/*.py "$repo/scripts/ci/"
printf '// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "Fake")\n' \
  > "$repo/Packages/macOS/Fake/Package.swift"
dev="$tmp/Xcode_26.6.app/Contents/Developer"
mkdir -p "$dev"
want_sdk="$dev/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
mkdir -p "$want_sdk"
cat > "$tmp/bin/xcrun" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = --show-sdk-path ]; then
    echo "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"; exit 0
  fi
done
exit 1
SH
cat > "$tmp/bin/swift" <<'SH'
#!/usr/bin/env bash
echo "swift $1 SDKROOT=${SDKROOT:-unset}" >> "$FAKE_SEEN"
case "$1" in
  build) echo "Build complete!"; exit 0 ;;
  test)
    case "$FAKE_MODE" in
      ok) echo "✔ Test run with 3 tests in 1 suite passed after 0.1 seconds."; exit 0 ;;
      mismatch)
        echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface:1:1: error: failed to build module 'Swift'; this SDK is not supported by the compiler"
        echo "error: 'fake': Invalid manifest (compiled with: [\"swiftc\"])"
        echo "error: no tests found; create a target in the 'Tests' directory"
        exit "$FAKE_EXIT" ;;
    esac ;;
esac
exit 0
SH
chmod +x "$tmp/bin/xcrun" "$tmp/bin/swift"
# The real interpreter: on macOS /usr/bin/python3 is itself an xcrun shim, and
# the fake Xcode above has no python3.
ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$tmp/bin/python3"
fails=0
lane() {
  local mode="$1" code="$2" out status=0
  : > "$tmp/seen"
  out=$(cd "$repo" && env PATH="$tmp/bin:$PATH" DEVELOPER_DIR="$dev" \
    SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
    FAKE_SEEN="$tmp/seen" FAKE_MODE="$mode" FAKE_EXIT="$code" RUNNER_TEMP="$tmp" \
    CMUX_SWIFT_TEST_STALL_SECONDS=30 CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS=60 \
    bash scripts/ci/package-test-lane.sh suite Packages/macOS/Fake FakeTests 2>&1) || status=$?
  LANE_OUT="$out"; LANE_STATUS=$status
}
lane ok 0
if [ "$LANE_STATUS" -ne 0 ]; then
  printf "FAIL: a passing suite exited %s:\n%s\n" "$LANE_STATUS" "$LANE_OUT" >&2; fails=$((fails + 1))
fi
if grep -v "SDKROOT=$want_sdk\$" "$tmp/seen" >/dev/null; then
  echo "FAIL: swift ran without the Xcode's own SDK ($want_sdk):" >&2; cat "$tmp/seen" >&2; fails=$((fails + 1))
fi
for code in 1 0; do
  lane mismatch "$code"
  if [ "$LANE_STATUS" -eq 0 ] || [[ "$LANE_OUT" != *"::error title=Swift toolchain and SDK differ::"* ]]; then
    echo "FAIL: a toolchain/SDK mismatch (swift test exit $code) gave exit $LANE_STATUS without the error: $LANE_OUT" >&2
    fails=$((fails + 1))
  fi
done
if [ "$fails" -ne 0 ]; then exit 1; fi
echo "package-test-lane SDKROOT pin: ok"
