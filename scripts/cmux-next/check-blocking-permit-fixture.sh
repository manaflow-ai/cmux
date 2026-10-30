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
FIXTURE="$PACKAGE/CompileFailFixtures/BlockingPermitNoasync.swift"

if [ "${1:-}" != "--no-build" ]; then
  swift build --package-path "$PACKAGE" --target CmuxNextCompat
fi
BIN="$(swift build --package-path "$PACKAGE" --show-bin-path)"
MODULES="$BIN/Modules"
[ -d "$MODULES" ] || MODULES="$BIN"

# CmuxNextCompat's Swift dependencies are in $MODULES, but a C module under them (swift-atomics' _AtomicsShims)
# comes only from its module map, which SwiftPM passes as -fmodule-map-file: its generated maps are under
# $BIN/<target>.build/, a package's own map is in the target's include/ directory.
shopt -s nullglob
MODULE_MAPS=()
for map in "$BIN"/*.build/module.modulemap "$PACKAGE"/.build/checkouts/swift-atomics/Sources/*/include/module.modulemap; do
  MODULE_MAPS+=(-Xcc "-fmodule-map-file=$map")
done
shopt -u nullglob

set +e
OUTPUT="$(xcrun swiftc -typecheck -swift-version 6 -target "$(uname -m)-apple-macos14.0" -I "$MODULES" \
  ${MODULE_MAPS[@]+"${MODULE_MAPS[@]}"} "$FIXTURE" 2>&1)"
STATUS=$?
set -e

if grep -qE "missing required module|no such module" <<<"$OUTPUT"; then
  echo "error: the fixture could not load CmuxNextCompat or one of its modules; no diagnostic was judged:" >&2
  grep -E "missing required module|no such module" <<<"$OUTPUT" >&2
  exit 2
fi

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
