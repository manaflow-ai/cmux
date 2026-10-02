# Sourced by Xcode script phases that look up external tools (cargo, rustup,
# go, zig). CI runs xcodebuild under a fixed environment so SwiftPM's manifest
# cache hits, and hands the caller's PATH over as the CMUX_CALLER_PATH build
# setting (scripts/ci/compile-app-host-test-product.sh). Put it back where
# Xcode would have: after Xcode's own tool directories, in place of the fixed
# PATH from scripts/ci/swiftpm-manifest-cache.sh. Without the setting (local
# builds, Xcode.app) this does nothing.
if [ -n "${CMUX_CALLER_PATH:-}" ]; then
  export PATH="${PATH%:/usr/bin:/bin:/usr/sbin:/sbin}:${CMUX_CALLER_PATH}"
fi
