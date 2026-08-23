#!/usr/bin/env bash
# Behavioral coverage for the bundle-wide macOS architecture verifier.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_SCRIPT="$ROOT_DIR/scripts/verify-macos-bundle-architectures.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-macho-sweep-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

APP_PATH="$TMP_DIR/app with spaces/cmux.app"
TOOLS_DIR="$TMP_DIR/tools"
mkdir -p \
  "$APP_PATH/Contents/MacOS" \
  "$APP_PATH/Contents/Resources/bin" \
  "$APP_PATH/Contents/Resources/Single Arch" \
  "$APP_PATH/Contents/Frameworks" \
  "$TOOLS_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'FAIL: expected output to contain %s\n--- output ---\n%s\n--- end output ---\n' \
      "$needle" "$haystack" >&2
    exit 1
  fi
}

USE_REAL_MACHO_TOOLS=0
if [[ "${CMUX_TEST_FORCE_FAKE_MACHO_TOOLS:-0}" != 1 ]] &&
  [[ "$(uname -s)" == "Darwin" ]] &&
  command -v clang >/dev/null 2>&1 && command -v lipo >/dev/null 2>&1; then
  USE_REAL_MACHO_TOOLS=1
fi

if (( USE_REAL_MACHO_TOOLS )); then
  make_thin_executable() {
    local arch="$1"
    local output="$2"
    printf 'int main(void) { return 0; }\n' | clang -arch "$arch" -x c - -o "$output"
  }

  make_thin_dylib() {
    local arch="$1"
    local output="$2"
    printf 'int cmux_fixture(void) { return 0; }\n' | clang -arch "$arch" -dynamiclib -x c - -o "$output"
  }

  make_universal() {
    local arm64_path="$1"
    local x86_64_path="$2"
    local output="$3"
    lipo -create "$arm64_path" "$x86_64_path" -output "$output"
  }

  ARM64_EXECUTABLE="$TMP_DIR/arm64-executable"
  X86_64_EXECUTABLE="$TMP_DIR/x86_64-executable"
  ARM64_DYLIB="$TMP_DIR/arm64-library.dylib"
  X86_64_DYLIB="$TMP_DIR/x86_64-library.dylib"
  make_thin_executable arm64 "$ARM64_EXECUTABLE"
  make_thin_executable x86_64 "$X86_64_EXECUTABLE"
  make_thin_dylib arm64 "$ARM64_DYLIB"
  make_thin_dylib x86_64 "$X86_64_DYLIB"

  UNIVERSAL_EXECUTABLE="$TMP_DIR/universal-executable"
  UNIVERSAL_DYLIB="$TMP_DIR/universal-library.dylib"
  make_universal "$ARM64_EXECUTABLE" "$X86_64_EXECUTABLE" "$UNIVERSAL_EXECUTABLE"
  make_universal "$ARM64_DYLIB" "$X86_64_DYLIB" "$UNIVERSAL_DYLIB"

  cp "$UNIVERSAL_EXECUTABLE" "$APP_PATH/Contents/MacOS/cmux"
  cp "$UNIVERSAL_DYLIB" "$APP_PATH/Contents/Frameworks/libuniversal.dylib"
  cp "$UNIVERSAL_EXECUTABLE" "$APP_PATH/Contents/Resources/opaque-macho"
  chmod 644 "$APP_PATH/Contents/Resources/opaque-macho"
else
  FILE_TOOL="$TOOLS_DIR/file"
  LIPO_TOOL="$TOOLS_DIR/lipo"

  cat > "$FILE_TOOL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target=""
for argument in "$@"; do
  target="$argument"
done
first_line="$(sed -n '1p' "$target")"
case "$first_line" in
  FAKE-MACHO:*) printf 'Mach-O synthetic binary\n' ;;
  *) printf 'ASCII text\n' ;;
esac
EOF

  cat > "$LIPO_TOOL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target=""
for argument in "$@"; do
  target="$argument"
done
first_line="$(sed -n '1p' "$target")"
case "$first_line" in
  FAKE-MACHO:ERROR*)
    echo "fatal error: synthetic malformed Mach-O" >&2
    exit 1
    ;;
  FAKE-MACHO:*) printf '%s\n' "${first_line#FAKE-MACHO:}" ;;
  *)
    echo "fatal error: not a synthetic Mach-O" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$FILE_TOOL" "$LIPO_TOOL"

  make_fake_macho() {
    local archs="$1"
    local output="$2"
    printf 'FAKE-MACHO:%s\n' "$archs" > "$output"
  }

  make_fake_macho 'arm64 x86_64' "$APP_PATH/Contents/MacOS/cmux"
  make_fake_macho 'arm64 x86_64' "$APP_PATH/Contents/Frameworks/libuniversal.dylib"
  make_fake_macho 'arm64 x86_64' "$APP_PATH/Contents/Resources/opaque-macho"
  chmod 644 "$APP_PATH/Contents/Resources/opaque-macho"
fi

printf '#!/bin/sh\nexit 0\n' > "$APP_PATH/Contents/Resources/bin/not a Mach-O executable"
chmod +x "$APP_PATH/Contents/Resources/bin/not a Mach-O executable"
printf 'plain resource\n' > "$APP_PATH/Contents/Resources/plain.txt"

run_verifier() {
  if (( USE_REAL_MACHO_TOOLS )); then
    "$VERIFY_SCRIPT" "$@"
  else
    CMUX_FILE_TOOL="$FILE_TOOL" CMUX_LIPO_TOOL="$LIPO_TOOL" "$VERIFY_SCRIPT" "$@"
  fi
}

if ! initial_output="$(run_verifier "$APP_PATH" 2>&1)"; then
  printf '%s\n' "$initial_output" >&2
  fail "a bundle containing only universal Mach-Os should pass"
fi
assert_contains "$initial_output" "Mach-O files"

if (( USE_REAL_MACHO_TOOLS )); then
  cp "$ARM64_EXECUTABLE" "$APP_PATH/Contents/Resources/Single Arch/arm64 payload"
  chmod 644 "$APP_PATH/Contents/Resources/Single Arch/arm64 payload"
  cp "$X86_64_DYLIB" "$APP_PATH/Contents/Resources/Single Arch/x86_64 payload.dylib"
  chmod 644 "$APP_PATH/Contents/Resources/Single Arch/x86_64 payload.dylib"
  cp "$ARM64_EXECUTABLE" "$APP_PATH/Contents/Resources/malformed macho"
  truncate -s 64 "$APP_PATH/Contents/Resources/malformed macho"
else
  make_fake_macho arm64 "$APP_PATH/Contents/Resources/Single Arch/arm64 payload"
  chmod 644 "$APP_PATH/Contents/Resources/Single Arch/arm64 payload"
  make_fake_macho x86_64 "$APP_PATH/Contents/Resources/Single Arch/x86_64 payload.dylib"
  chmod 644 "$APP_PATH/Contents/Resources/Single Arch/x86_64 payload.dylib"
  make_fake_macho ERROR "$APP_PATH/Contents/Resources/malformed macho"
fi

if failure_output="$(run_verifier "$APP_PATH" 2>&1)"; then
  fail "single-arch and malformed Mach-Os should fail the verifier"
fi
assert_contains "$failure_output" "Contents/Resources/Single Arch/arm64 payload"
assert_contains "$failure_output" "arm64"
assert_contains "$failure_output" "Contents/Resources/Single Arch/x86_64 payload.dylib"
assert_contains "$failure_output" "x86_64"
assert_contains "$failure_output" "lipo -archs failed"
assert_contains "$failure_output" "Contents/Resources/malformed macho"

rm -f "$APP_PATH/Contents/Resources/malformed macho"
ALLOWLIST="$TMP_DIR/allowlist.txt"
cat > "$ALLOWLIST" <<'EOF'
# Deliberate synthetic exceptions used by this behavioral test.
Contents/Resources/Single Arch/*
EOF

if ! allowlisted_output="$(run_verifier --allowlist "$ALLOWLIST" "$APP_PATH" 2>&1)"; then
  printf '%s\n' "$allowlisted_output" >&2
  fail "matching single-arch paths should be suppressible only through the explicit allowlist"
fi
assert_contains "$allowlisted_output" "Allowlisted"
assert_contains "$allowlisted_output" "Contents/Resources/Single Arch/arm64 payload"
assert_contains "$allowlisted_output" "Contents/Resources/Single Arch/x86_64 payload.dylib"

cat > "$ALLOWLIST" <<'EOF'
# Deliberately leave the x86_64 payload unallowlisted.
Contents/Resources/Single Arch/arm64 payload
EOF
if partial_allowlist_output="$(run_verifier --allowlist "$ALLOWLIST" "$APP_PATH" 2>&1)"; then
  fail "an unallowlisted single-arch path should still fail"
fi
assert_contains "$partial_allowlist_output" "Contents/Resources/Single Arch/x86_64 payload.dylib"
if printf '%s\n' "$partial_allowlist_output" |
  grep -F 'ERROR: non-universal Mach-O' |
  grep -Fq 'Contents/Resources/Single Arch/arm64 payload'; then
  fail "an allowlisted path should not be reported as a failure"
fi

echo "PASS: bundle-wide Mach-O architecture verifier catches all non-universal files, surfaces lipo errors, and honors relative allowlist patterns"
