#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

cat >"$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
chmod +x "$STUB_DIR/curl"

if PATH="$STUB_DIR:$PATH" CMUX_SPARKLE_MONOTONIC_STRICT=1 \
  "$ROOT_DIR/tests/test_ci_sparkle_build_monotonic.sh" >"$STUB_DIR/output.log" 2>&1; then
  echo "FAIL: release-mode Sparkle validation passed without an authoritative feed" >&2
  cat "$STUB_DIR/output.log" >&2
  exit 1
fi

echo "PASS: release-mode Sparkle validation fails closed when the feed is unavailable"
