#!/usr/bin/env bash
# Type-check the BlockingPermit compile-fail fixture (plans/cmux-next/chrome-parity/p02-threads.md, task 111)
# against a built CmuxNextCompat and require every diagnostic its `// expect:` lines name: a permit seam in async
# code is unavailable (noasync), a permit-less seam is deprecated, and no module outside the package makes a permit.
#
# macOS only (a fleet step: cmux-ci run --class isolated --script scripts/cmux-next/check-blocking-permit-fixture.sh
# --ref SHA). Not a CI gate.
#
# Usage: scripts/cmux-next/check-blocking-permit-fixture.sh [--no-build]
#   --no-build: use the CmuxNextCompat module of an earlier `swift build` of the package.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGE="$ROOT/Packages/macOS/CmuxNext"
FIXTURE="$PACKAGE/Tests/CompileFailFixtures/BlockingPermitNoasync.swift"

if [ "${1:-}" != "--no-build" ]; then
  swift build --package-path "$PACKAGE" --target CmuxNextCompat
fi
BIN="$(swift build --package-path "$PACKAGE" --show-bin-path)"
MODULES="$BIN/Modules"
[ -d "$MODULES" ] || MODULES="$BIN"

set +e
OUTPUT="$(xcrun swiftc -typecheck -swift-version 6 -target "$(uname -m)-apple-macos14.0" -I "$MODULES" "$FIXTURE" 2>&1)"
STATUS=$?
set -e

if [ "$STATUS" -eq 0 ]; then
  echo "error: the fixture type-checked; the permit's compile-time checks are gone" >&2
  exit 1
fi

missing=0
while IFS= read -r expected; do
  if ! grep -qF -- "$expected" <<<"$OUTPUT"; then
    echo "error: no diagnostic contains: $expected" >&2
    missing=1
  fi
done < <(sed -n 's|^// expect: ||p' "$FIXTURE")

if [ "$missing" -ne 0 ]; then
  echo "--- swiftc output ---" >&2
  echo "$OUTPUT" >&2
  exit 1
fi
echo "ok: every expected BlockingPermit diagnostic is reported"
