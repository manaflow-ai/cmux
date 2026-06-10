#!/usr/bin/env bash
# Regression test for nightly Xcode selection on one-Xcode runner images.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/select-nightly-xcodes.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN_DIR="$TMP_DIR/bin"
APPS_DIR="$TMP_DIR/Applications"
mkdir -p "$BIN_DIR" "$APPS_DIR"

cat > "$BIN_DIR/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--sdk" ] && [ "${2:-}" = "macosx" ] && [ "${3:-}" = "--show-sdk-version" ]; then
  cat "${DEVELOPER_DIR:?}/sdk-version"
  exit 0
fi

echo "unexpected xcrun invocation: $*" >&2
exit 2
EOF
chmod +x "$BIN_DIR/xcrun"

make_xcode() {
  local name="$1" sdk="$2" dev
  dev="$APPS_DIR/$name/Contents/Developer"
  mkdir -p "$dev"
  printf '%s\n' "$sdk" > "$dev/sdk-version"
}

run_selector() {
  local out="$1" env_file="$2"
  PATH="$BIN_DIR:$PATH" \
    CMUX_XCODE_APPLICATIONS_DIR="$APPS_DIR" \
    CMUX_SELECT_XCODE_PRINT_VERSION=0 \
    GITHUB_ENV="$env_file" \
    "$SCRIPT" > "$out" 2>&1
}

assert_env_line() {
  local env_file="$1" expected="$2"
  if ! grep -Fxq "$expected" "$env_file"; then
    echo "FAIL: missing env line: $expected" >&2
    echo "--- env file ---" >&2
    cat "$env_file" >&2
    exit 1
  fi
}

make_xcode "Xcode.app" "26.2"
ONLY_OUT="$TMP_DIR/only.out"
ONLY_ENV="$TMP_DIR/only.env"
run_selector "$ONLY_OUT" "$ONLY_ENV"
assert_env_line "$ONLY_ENV" "DEVELOPER_DIR=$APPS_DIR/Xcode.app/Contents/Developer"
assert_env_line "$ONLY_ENV" "HELPER_DEVELOPER_DIR=$APPS_DIR/Xcode.app/Contents/Developer"
if ! grep -Fq "falling back to the app Xcode" "$ONLY_OUT"; then
  echo "FAIL: one-Xcode selection must explain the helper fallback" >&2
  cat "$ONLY_OUT" >&2
  exit 1
fi

make_xcode "Xcode_16.app" "15.5"
DUAL_OUT="$TMP_DIR/dual.out"
DUAL_ENV="$TMP_DIR/dual.env"
run_selector "$DUAL_OUT" "$DUAL_ENV"
assert_env_line "$DUAL_ENV" "DEVELOPER_DIR=$APPS_DIR/Xcode.app/Contents/Developer"
assert_env_line "$DUAL_ENV" "HELPER_DEVELOPER_DIR=$APPS_DIR/Xcode_16.app/Contents/Developer"

rm -rf "$APPS_DIR"
mkdir -p "$APPS_DIR"
make_xcode "Xcode_16.app" "15.5"
MISSING_OUT="$TMP_DIR/missing.out"
MISSING_ENV="$TMP_DIR/missing.env"
if run_selector "$MISSING_OUT" "$MISSING_ENV"; then
  echo "FAIL: selection must fail when no macOS 26+ SDK app Xcode exists" >&2
  cat "$MISSING_OUT" >&2
  exit 1
fi
if ! grep -Fq "No Xcode with the macOS 26+ SDK found" "$MISSING_OUT"; then
  echo "FAIL: missing app Xcode failure did not explain the macOS 26 requirement" >&2
  cat "$MISSING_OUT" >&2
  exit 1
fi

echo "PASS: nightly Xcode selection supports one-Xcode macOS 26 runners"
