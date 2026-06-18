#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/scripts/ci" "$TMP_DIR/Packages/macOS/CmuxTerminalCore"
printf '// fixture\n' > "$TMP_DIR/Packages/macOS/CmuxTerminalCore/Package.swift"

cat > "$TMP_DIR/scripts/ci/run_with_timeout.py" <<'PY'
#!/usr/bin/env python3
import os
import sys

output = os.environ.get("CMUX_FAKE_SWIFT_OUTPUT", "")
if output:
    sys.stdout.write(output)
    if not output.endswith("\n"):
        sys.stdout.write("\n")

sys.exit(int(os.environ.get("CMUX_FAKE_SWIFT_STATUS", "0")))
PY
chmod +x "$TMP_DIR/scripts/ci/run_with_timeout.py"

set +e
(
  cd "$TMP_DIR"
  CMUX_FAKE_SWIFT_STATUS=124 \
    CMUX_FAKE_SWIFT_OUTPUT=$'Test run with 1 tests passed\n' \
    "$ROOT_DIR/scripts/ci/run_swift_package_tests.sh" CmuxTerminalCore
) >"$TMP_DIR/timeout.log" 2>&1
timeout_status=$?
set -e

if [ "$timeout_status" -ne 124 ]; then
  cat "$TMP_DIR/timeout.log"
  echo "FAIL: SwiftPM timeout must exit 124, got $timeout_status"
  exit 1
fi

if grep -Fq "Tolerated cosmetic GhosttyKit binaryTarget diagnostic" "$TMP_DIR/timeout.log"; then
  cat "$TMP_DIR/timeout.log"
  echo "FAIL: SwiftPM timeout must not be accepted as a cosmetic GhosttyKit diagnostic"
  exit 1
fi

(
  cd "$TMP_DIR"
  CMUX_FAKE_SWIFT_STATUS=1 \
    CMUX_FAKE_SWIFT_OUTPUT=$'error: unexpected binary target diagnostic\nTest run with 1 tests passed\n' \
    "$ROOT_DIR/scripts/ci/run_swift_package_tests.sh" CmuxTerminalCore
) >"$TMP_DIR/cosmetic.log" 2>&1

if ! grep -Fq "Tolerated cosmetic GhosttyKit binaryTarget diagnostic" "$TMP_DIR/cosmetic.log"; then
  cat "$TMP_DIR/cosmetic.log"
  echo "FAIL: non-timeout cosmetic GhosttyKit diagnostic should remain tolerated"
  exit 1
fi

echo "PASS: SwiftPM timeout is never accepted by the GhosttyKit diagnostic tolerance"
