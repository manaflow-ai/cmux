#!/usr/bin/env bash
# Exercise the xcodebuild diagnostic wrapper with deterministic fake commands.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$ROOT_DIR/scripts/ci/run-xcodebuild-with-diagnostics.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/fake-xcodebuild.sh" <<'EOF'
#!/usr/bin/env bash
printf 'fake xcodebuild args: %s\n' "$*"
exit "${FAKE_XCODEBUILD_STATUS:-0}"
EOF
chmod +x "$TMP_DIR/fake-xcodebuild.sh"

if ! "$WRAPPER" -- "$TMP_DIR/fake-xcodebuild.sh" -scheme cmux >"$TMP_DIR/success.log" 2>&1; then
  echo "FAIL: wrapper must preserve a successful xcodebuild exit" >&2
  exit 1
fi
grep -Fq 'xcodebuild exit status: 0' "$TMP_DIR/success.log"
grep -Fq 'fake xcodebuild args: -scheme cmux' "$TMP_DIR/success.log"

set +e
FAKE_XCODEBUILD_STATUS=137 "$WRAPPER" -- "$TMP_DIR/fake-xcodebuild.sh" -scheme cmux >"$TMP_DIR/failure.log" 2>&1
status=$?
set -e
if [[ "$status" -ne 137 ]]; then
  echo "FAIL: wrapper must return the xcodebuild status, got $status" >&2
  exit 1
fi
grep -Fq 'xcodebuild exit status: 137' "$TMP_DIR/failure.log"
grep -Fq 'xcodebuild termination: signal=9' "$TMP_DIR/failure.log"
grep -Fq 'resource diagnostics follow' "$TMP_DIR/failure.log"
grep -Fq -- '--- top processes by resident memory ---' "$TMP_DIR/failure.log"

echo "PASS: xcodebuild failures retain exit, signal, and resource diagnostics"
