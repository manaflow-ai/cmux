#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-universal-verify.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

APP_PATH="$TMP_DIR/cmux.app"
FAKE_LIPO="$TMP_DIR/lipo"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources/bin"
cat > "$APP_PATH/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>cmux</string>
</dict>
</plist>
EOF

touch "$APP_PATH/Contents/MacOS/cmux"
touch "$APP_PATH/Contents/Resources/bin/cmux"
touch "$APP_PATH/Contents/Resources/bin/ghostty"
chmod 755 \
  "$APP_PATH/Contents/MacOS/cmux" \
  "$APP_PATH/Contents/Resources/bin/cmux" \
  "$APP_PATH/Contents/Resources/bin/ghostty"

cat > "$FAKE_LIPO" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "-archs" || $# -ne 2 ]]; then
  echo "unexpected lipo invocation" >&2
  exit 2
fi
cat "$2.archs"
EOF
chmod +x "$FAKE_LIPO"

set_archs() {
  printf '%s\n' "$2" > "$1.archs"
}

VERIFY_SCRIPT="$ROOT_DIR/scripts/verify-universal-macos-app.sh"
export CMUX_LIPO="$FAKE_LIPO"

set_archs "$APP_PATH/Contents/MacOS/cmux" "x86_64 arm64"
set_archs "$APP_PATH/Contents/Resources/bin/cmux" "arm64 x86_64"
set_archs "$APP_PATH/Contents/Resources/bin/ghostty" "arm64 x86_64"
"$VERIFY_SCRIPT" "$APP_PATH" --label "fixture app" >/dev/null

if "$VERIFY_SCRIPT" "$APP_PATH" --label >"$TMP_DIR/missing-label.out" 2>"$TMP_DIR/missing-label.err"; then
  echo "FAIL: verifier accepted --label without a value" >&2
  exit 1
fi
if ! grep -Fq "Missing value for --label" "$TMP_DIR/missing-label.err"; then
  echo "FAIL: verifier did not explain the missing label value" >&2
  cat "$TMP_DIR/missing-label.err" >&2
  exit 1
fi

set_archs "$APP_PATH/Contents/Resources/bin/ghostty" "x86_64"
if "$VERIFY_SCRIPT" "$APP_PATH" --label "fixture app" >"$TMP_DIR/missing-arm.out" 2>"$TMP_DIR/missing-arm.err"; then
  echo "FAIL: verifier accepted a helper missing the arm64 slice" >&2
  exit 1
fi
if ! grep -Fq "missing arm64 slice" "$TMP_DIR/missing-arm.err"; then
  echo "FAIL: verifier did not explain the missing arm64 slice" >&2
  cat "$TMP_DIR/missing-arm.err" >&2
  exit 1
fi

set_archs "$APP_PATH/Contents/Resources/bin/ghostty" "arm64"
if "$VERIFY_SCRIPT" "$APP_PATH" --label "fixture app" >"$TMP_DIR/missing-slice.out" 2>"$TMP_DIR/missing-slice.err"; then
  echo "FAIL: verifier accepted a helper missing the x86_64 slice" >&2
  exit 1
fi
if ! grep -Fq "missing x86_64 slice" "$TMP_DIR/missing-slice.err"; then
  echo "FAIL: verifier did not explain the missing x86_64 slice" >&2
  cat "$TMP_DIR/missing-slice.err" >&2
  exit 1
fi

rm "$APP_PATH/Contents/Resources/bin/cmux"
if "$VERIFY_SCRIPT" "$APP_PATH" --label "fixture app" >"$TMP_DIR/missing-cli.out" 2>"$TMP_DIR/missing-cli.err"; then
  echo "FAIL: verifier accepted an app bundle missing the embedded CLI" >&2
  exit 1
fi
if ! grep -Fq "CLI binary is missing or not executable" "$TMP_DIR/missing-cli.err"; then
  echo "FAIL: verifier did not explain the missing CLI" >&2
  cat "$TMP_DIR/missing-cli.err" >&2
  exit 1
fi

echo "PASS: universal macOS app verifier enforces app, CLI, and helper slices"
