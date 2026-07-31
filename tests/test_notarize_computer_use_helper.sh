#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci/notarize-computer-use-helper.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: executable Computer Use helper notarization script is required" >&2
  exit 1
fi

APP="$TMP_DIR/cmux.app"
HELPER="$APP/Contents/Library/cmux Computer Use.app"
FAKE_BIN="$TMP_DIR/bin"
LOG="$TMP_DIR/calls.log"
mkdir -p "$HELPER/Contents/MacOS" "$FAKE_BIN"
printf 'signed-helper-fixture\n' > "$HELPER/Contents/MacOS/cmux Computer Use"

cat > "$FAKE_BIN/ditto" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ditto %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
if [ "${1:-}" = "-c" ]; then
  output="${@: -1}"
  printf 'zip-fixture\n' > "$output"
else
  source_path="$1"
  destination_path="$2"
  cp -R "$source_path" "$destination_path"
fi
EOF

cat > "$FAKE_BIN/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "submit" ]; then
  printf '{"id":"helper-fixture-id","status":"%s"}\n' \
    "${CMUX_TEST_NOTARY_STATUS:-Accepted}"
fi
EOF

cat > "$FAKE_BIN/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
EOF

cat > "$FAKE_BIN/spctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'spctl %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
EOF

cat > "$FAKE_BIN/sign-bundle" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sign-bundle mode=%s %s\n' "${CMUX_SIGN_MODE:-<unset>}" "$*" \
  >> "$CMUX_TEST_CALL_LOG"
EOF
chmod +x "$FAKE_BIN"/*

run_helper() {
  CMUX_TEST_CALL_LOG="$LOG" \
  CMUX_DITTO_TOOL="$FAKE_BIN/ditto" \
  CMUX_XCRUN_TOOL="$FAKE_BIN/xcrun" \
  CMUX_CODESIGN_TOOL="$FAKE_BIN/codesign" \
  CMUX_SPCTL_TOOL="$FAKE_BIN/spctl" \
  CMUX_SIGN_BUNDLE_TOOL="$FAKE_BIN/sign-bundle" \
  APPLE_ID=fixture@example.com \
  APPLE_APP_SPECIFIC_PASSWORD=fixture-password \
  APPLE_TEAM_ID=FIXTURETEAM \
  "$SCRIPT" \
    "$APP" \
    "$TMP_DIR/cmux.release.entitlements" \
    'Developer ID Application: Fixture'
}

: > "$TMP_DIR/cmux.release.entitlements"
run_helper

if [ "$(grep -c '^xcrun notarytool submit ' "$LOG")" -ne 1 ]; then
  echo "FAIL: helper must have exactly one independent notarization submission" >&2
  exit 1
fi
if ! grep -Fq "ditto -c -k --sequesterRsrc --keepParent $HELPER" "$LOG"; then
  echo "FAIL: nested helper was not packaged as the notarization payload" >&2
  exit 1
fi

line_of() {
  grep -nF "$1" "$LOG" | head -n 1 | cut -d: -f1
}
submit_line="$(line_of "xcrun notarytool submit")"
staple_line="$(line_of "xcrun stapler staple $HELPER")"
validate_line="$(line_of "xcrun stapler validate $HELPER")"
reseal_line="$(line_of "sign-bundle mode=main-only")"
host_verify_line="$(line_of "codesign --verify --deep --strict --verbose=2 $APP")"
if ! [ "$submit_line" -lt "$staple_line" ] \
  || ! [ "$staple_line" -lt "$validate_line" ] \
  || ! [ "$validate_line" -lt "$reseal_line" ] \
  || ! [ "$reseal_line" -lt "$host_verify_line" ]; then
  echo "FAIL: helper notarization, stapling, and outer resealing ran out of order" >&2
  exit 1
fi
if ! grep -Eq '^spctl -a -vv --type execute .*/standalone/cmux Computer Use\.app$' "$LOG"; then
  echo "FAIL: independently copied helper did not pass the Gatekeeper check" >&2
  exit 1
fi

: > "$LOG"
if CMUX_TEST_NOTARY_STATUS=Invalid run_helper; then
  echo "FAIL: rejected helper notarization unexpectedly succeeded" >&2
  exit 1
fi
if grep -Fq 'xcrun stapler staple' "$LOG"; then
  echo "FAIL: rejected helper must not be stapled" >&2
  exit 1
fi
if grep -Fq 'sign-bundle mode=main-only' "$LOG"; then
  echo "FAIL: rejected helper must not reseal the outer app" >&2
  exit 1
fi
if ! grep -Fq 'xcrun notarytool log helper-fixture-id' "$LOG"; then
  echo "FAIL: rejected helper notarization did not retrieve its diagnostic log" >&2
  exit 1
fi

echo "PASS: Computer Use helper is independently notarized before outer resealing"
