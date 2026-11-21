#!/usr/bin/env bash
# scripts/ci/tests/swiftpm-resolve-seeds-artifacts.test.sh: swiftpm_resolve_package
# (scripts/ci/swiftpm-binary-module-guard.sh) seeds SwiftPM's artifact cache with curl
# before `swift package resolve`, so SwiftPM never downloads a binary artifact itself.
#
# On the fleet workers SwiftPM's own NSURLSession download of an artifact that is not in its
# cache traps (exit 133): macOS's single sign-on check (AppSSO) calls
# xpc_connection_set_target_uid, an API misuse in the worker's process context
# (2026-11-20, cmux-austin-mini-0, every CmuxNext swift test on a new FFI pin). A cached
# artifact needs no download and passes. This is a fresh worker with an empty cache and the
# CCmuxAppFFI pin acbebf97: the fake `swift package resolve` traps (133) exactly when the
# artifact is not cached, as SwiftPM did. No network, Xcode or real SwiftPM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pin=acbebf974eeba025d55ce5cce5e781e19681b0bd
url="https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-$pin/CCmuxAppFFI.xcframework.zip"
printf 'fake xcframework zip for %s\n' "$pin" > "$tmp/artifact.zip"
checksum="$(shasum -a 256 "$tmp/artifact.zip" 2>/dev/null | cut -d' ' -f1 || sha256sum "$tmp/artifact.zip" | cut -d' ' -f1)"
key="$(printf '%s' "$url" | LC_ALL=C sed 's/[^A-Za-z0-9_]/_/g')"

mkdir -p "$tmp/bin" "$tmp/pkg" "$tmp/cache" "$tmp/store"
printf '// swift-tools-version:6.0\n' > "$tmp/pkg/Package.swift"
cat > "$tmp/bin/swift" <<SWIFT
#!/usr/bin/env bash
echo "swift \$*" >> "$tmp/calls.log"
case "\$1 \$2" in
  "package dump-package")
    printf '{"targets":[{"name":"CCmuxAppFFI","type":"binary","url":"%s","checksum":"%s"}],"dependencies":[]}\n' "$url" "$checksum"
    ;;
  "package resolve")
    if [ ! -f "$tmp/cache/$key" ]; then
      echo "Downloading binary artifact $url" >&2
      echo "xpc_connection_set_target_uid: API misuse (AppSSO): Trace/BPT trap" >&2
      exit 133
    fi
    echo "Fetching binary artifact $url from cache"
    ;;
  *) echo "swift 6.2 (fake)" ;;
esac
SWIFT
cat > "$tmp/bin/curl" <<CURL
#!/usr/bin/env bash
out=""; prev=""
for arg in "\$@"; do [ "\$prev" = --output ] && out="\$arg"; prev="\$arg"; done
echo "curl \$*" >> "$tmp/calls.log"
cp "$tmp/artifact.zip" "\$out"
CURL
chmod +x "$tmp/bin/swift" "$tmp/bin/curl"

export PATH="$tmp/bin:$PATH" CMUX_SWIFTPM_ARTIFACT_CACHE="$tmp/cache" CMUX_SWIFTPM_ARTIFACT_STORE="$tmp/store" \
  CMUX_SWIFTPM_RESOLVE_RETRY_DELAYS=""
# shellcheck source=scripts/ci/swiftpm-binary-module-guard.sh
source "$ROOT/scripts/ci/swiftpm-binary-module-guard.sh"

code=0
swiftpm_resolve_package "$tmp/pkg" > "$tmp/out.log" 2>&1 || code=$?
if [ "$code" -ne 0 ]; then
  echo "FAIL: swift package resolve on an empty cache exited $code (SwiftPM downloaded the artifact itself):"
  sed 's/^/  | /' "$tmp/out.log" "$tmp/calls.log" 2>/dev/null || true
  exit 1
fi
[ -f "$tmp/cache/$key" ] || { echo "FAIL: the artifact is not in SwiftPM's cache at $key"; exit 1; }
grep -q '^curl ' "$tmp/calls.log" || { echo "FAIL: the artifact was not downloaded with curl"; exit 1; }
first_curl="$(grep -n '^curl ' "$tmp/calls.log" | head -1 | cut -d: -f1)"
first_resolve="$(grep -n '^swift package resolve' "$tmp/calls.log" | head -1 | cut -d: -f1)"
[ "$first_curl" -lt "$first_resolve" ] || { echo "FAIL: resolve ran before the seed"; exit 1; }

# A wrong checksum is never cached: SwiftPM is left to fail on it as before.
rm -rf "$tmp/cache"/* "$tmp/store"/*
printf 'tampered\n' > "$tmp/artifact.zip"
code=0
swiftpm_resolve_package "$tmp/pkg" > "$tmp/out2.log" 2>&1 || code=$?
[ ! -f "$tmp/cache/$key" ] || { echo "FAIL: an artifact with the wrong checksum was cached"; exit 1; }
[ "$code" -ne 0 ] || { echo "FAIL: resolve passed with no verified artifact"; exit 1; }

echo "ok: swift package resolve on a fresh worker reads pin $pin from a cache seeded with curl (checksum verified)"
