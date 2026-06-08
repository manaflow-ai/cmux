#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-universal-verify.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

APP_PATH="$TMP_DIR/cmux.app"
FAKE_LIPO="$TMP_DIR/lipo"
FAKE_OTOOL="$TMP_DIR/otool"

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

cat > "$FAKE_OTOOL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "-l" || $# -ne 2 ]]; then
  echo "unexpected otool invocation" >&2
  exit 2
fi
SDK_FILE="$2.sdk"
if [[ ! -f "$SDK_FILE" ]]; then
  exit 0
fi
cat <<OTOOLOUT
Load command 9
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform MACOS
    minos 14.0
      sdk $(cat "$SDK_FILE")
OTOOLOUT
EOF
chmod +x "$FAKE_OTOOL"

set_archs() {
  printf '%s\n' "$2" > "$1.archs"
}

set_sdk() {
  printf '%s\n' "$2" > "$1.sdk"
}

VERIFY_SCRIPT="$ROOT_DIR/scripts/verify-universal-macos-app.sh"
export CMUX_LIPO="$FAKE_LIPO"
export CMUX_OTOOL="$FAKE_OTOOL"

set_archs "$APP_PATH/Contents/MacOS/cmux" "x86_64 arm64"
set_archs "$APP_PATH/Contents/Resources/bin/cmux" "arm64 x86_64"
set_archs "$APP_PATH/Contents/Resources/bin/ghostty" "arm64 x86_64"
set_sdk "$APP_PATH/Contents/MacOS/cmux" "26.1"
"$VERIFY_SCRIPT" "$APP_PATH" --label "fixture app" >/dev/null
"$VERIFY_SCRIPT" "$APP_PATH" --label "fixture app" --require-sdk-prefix "26." >/dev/null

if "$VERIFY_SCRIPT" "$APP_PATH" --label >"$TMP_DIR/missing-label.out" 2>"$TMP_DIR/missing-label.err"; then
  echo "FAIL: verifier accepted --label without a value" >&2
  exit 1
fi
if ! grep -Fq "Missing value for --label" "$TMP_DIR/missing-label.err"; then
  echo "FAIL: verifier did not explain the missing label value" >&2
  cat "$TMP_DIR/missing-label.err" >&2
  exit 1
fi

if "$VERIFY_SCRIPT" "$APP_PATH" --require-sdk-prefix >"$TMP_DIR/missing-sdk-prefix.out" 2>"$TMP_DIR/missing-sdk-prefix.err"; then
  echo "FAIL: verifier accepted --require-sdk-prefix without a value" >&2
  exit 1
fi
if ! grep -Fq "Missing value for --require-sdk-prefix" "$TMP_DIR/missing-sdk-prefix.err"; then
  echo "FAIL: verifier did not explain the missing SDK prefix value" >&2
  cat "$TMP_DIR/missing-sdk-prefix.err" >&2
  exit 1
fi

set_sdk "$APP_PATH/Contents/MacOS/cmux" "15.5"
if "$VERIFY_SCRIPT" "$APP_PATH" --label "fixture app" --require-sdk-prefix "26." >"$TMP_DIR/sdk-prefix.out" 2>"$TMP_DIR/sdk-prefix.err"; then
  echo "FAIL: verifier accepted an app built with the wrong SDK" >&2
  exit 1
fi
if ! grep -Fq "expected prefix 26." "$TMP_DIR/sdk-prefix.err"; then
  echo "FAIL: verifier did not explain the wrong SDK prefix" >&2
  cat "$TMP_DIR/sdk-prefix.err" >&2
  exit 1
fi
set_sdk "$APP_PATH/Contents/MacOS/cmux" "26.1"

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
