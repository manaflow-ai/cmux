#!/usr/bin/env bash
# Behavioral guard for installing verified Zig on CI runners without sudo.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/install-zig-ci.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ZIG_REQUIRED="99.99.99"
case "$(uname -m)" in
  arm64 | aarch64) ZIG_ARCH="aarch64" ;;
  x86_64) ZIG_ARCH="x86_64" ;;
  *)
    echo "Unsupported test architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

FIXTURE_ROOT="$TMP_DIR/fixture"
ZIG_NAME="zig-${ZIG_ARCH}-macos-${ZIG_REQUIRED}"
ARCHIVE="$TMP_DIR/${ZIG_NAME}.tar.xz"
BIN_DIR="$TMP_DIR/bin"
RUNNER_TEMP_DIR="$TMP_DIR/runner-temp"
GITHUB_PATH_FILE="$TMP_DIR/github-path"
GITHUB_ENV_FILE="$TMP_DIR/github-env"
OUTPUT_FILE="$TMP_DIR/output"
FORCE_LOCAL_OUTPUT_FILE="$TMP_DIR/force-local-output"
FORCE_LOCAL_GITHUB_PATH_FILE="$TMP_DIR/force-local-github-path"
FORCE_LOCAL_GITHUB_ENV_FILE="$TMP_DIR/force-local-github-env"
FORCE_LOCAL_INSTALL_ROOT="$TMP_DIR/force-local-install"
SUDO_LOG="$TMP_DIR/sudo.log"

mkdir -p "$FIXTURE_ROOT/$ZIG_NAME/lib" "$BIN_DIR" "$RUNNER_TEMP_DIR"
cat > "$FIXTURE_ROOT/$ZIG_NAME/zig" <<EOF
#!/usr/bin/env bash
echo "$ZIG_REQUIRED"
EOF
chmod +x "$FIXTURE_ROOT/$ZIG_NAME/zig"
printf 'lib fixture\n' > "$FIXTURE_ROOT/$ZIG_NAME/lib/std"
(cd "$FIXTURE_ROOT" && tar -cf "$ARCHIVE" "$ZIG_NAME")
ARCHIVE_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"

cat > "$BIN_DIR/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
OUTPUT=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --output)
      OUTPUT="\$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
if [ -z "\$OUTPUT" ]; then
  echo "curl stub missing --output" >&2
  exit 1
fi
cp "$ARCHIVE" "\$OUTPUT"
EOF
chmod +x "$BIN_DIR/curl"

cat > "$BIN_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN_DIR/sudo"

PATH="$BIN_DIR:/usr/bin:/bin" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  GITHUB_PATH="$GITHUB_PATH_FILE" \
  GITHUB_ENV="$GITHUB_ENV_FILE" \
  ZIG_REQUIRED="$ZIG_REQUIRED" \
  ZIG_EXPECTED_SHA256="$ARCHIVE_SHA256" \
  ZIG_MIRROR_URL="https://example.invalid/$ZIG_NAME.tar.xz" \
  "$SCRIPT" > "$OUTPUT_FILE" 2>&1

INSTALLED_ZIG="$RUNNER_TEMP_DIR/$ZIG_NAME/zig"
if [ ! -x "$INSTALLED_ZIG" ]; then
  cat "$OUTPUT_FILE"
  echo "FAIL: zig was not installed under RUNNER_TEMP" >&2
  exit 1
fi

if ! grep -Fxq "$(dirname "$INSTALLED_ZIG")" "$GITHUB_PATH_FILE"; then
  cat "$OUTPUT_FILE"
  echo "FAIL: installer did not publish the local zig bin dir to GITHUB_PATH" >&2
  exit 1
fi

if ! grep -Fxq "CMUX_ZIG=$INSTALLED_ZIG" "$GITHUB_ENV_FILE"; then
  cat "$OUTPUT_FILE"
  echo "FAIL: installer did not publish CMUX_ZIG" >&2
  exit 1
fi

if ! grep -Fq "sudo unavailable; installing zig under" "$OUTPUT_FILE"; then
  cat "$OUTPUT_FILE"
  echo "FAIL: installer did not report local fallback" >&2
  exit 1
fi

cat > "$BIN_DIR/sudo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SUDO_LOG"
exit 0
EOF
chmod +x "$BIN_DIR/sudo"
rm -f "$SUDO_LOG"

PATH="$BIN_DIR:/usr/bin:/bin" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  GITHUB_PATH="$FORCE_LOCAL_GITHUB_PATH_FILE" \
  GITHUB_ENV="$FORCE_LOCAL_GITHUB_ENV_FILE" \
  ZIG_REQUIRED="$ZIG_REQUIRED" \
  ZIG_EXPECTED_SHA256="$ARCHIVE_SHA256" \
  ZIG_FORCE_LOCAL_INSTALL=1 \
  ZIG_INSTALL_ROOT="$FORCE_LOCAL_INSTALL_ROOT" \
  ZIG_MIRROR_URL="https://example.invalid/$ZIG_NAME.tar.xz" \
  "$SCRIPT" > "$FORCE_LOCAL_OUTPUT_FILE" 2>&1

if [ ! -x "$FORCE_LOCAL_INSTALL_ROOT/zig" ]; then
  cat "$FORCE_LOCAL_OUTPUT_FILE"
  echo "FAIL: force-local install did not install zig under ZIG_INSTALL_ROOT" >&2
  exit 1
fi

if [ -s "$SUDO_LOG" ]; then
  cat "$FORCE_LOCAL_OUTPUT_FILE"
  cat "$SUDO_LOG"
  echo "FAIL: force-local install invoked sudo" >&2
  exit 1
fi

if ! grep -Fq "ZIG_FORCE_LOCAL_INSTALL=1; installing zig under" "$FORCE_LOCAL_OUTPUT_FILE"; then
  cat "$FORCE_LOCAL_OUTPUT_FILE"
  echo "FAIL: force-local install did not report the forced local path" >&2
  exit 1
fi

if ! grep -Fxq "$(dirname "$FORCE_LOCAL_INSTALL_ROOT/zig")" "$FORCE_LOCAL_GITHUB_PATH_FILE"; then
  cat "$FORCE_LOCAL_OUTPUT_FILE"
  echo "FAIL: force-local install did not publish the local zig bin dir to GITHUB_PATH" >&2
  exit 1
fi

if ! grep -Fxq "CMUX_ZIG=$FORCE_LOCAL_INSTALL_ROOT/zig" "$FORCE_LOCAL_GITHUB_ENV_FILE"; then
  cat "$FORCE_LOCAL_OUTPUT_FILE"
  echo "FAIL: force-local install did not publish CMUX_ZIG" >&2
  exit 1
fi

echo "PASS: install-zig-ci falls back locally without sudo and honors ZIG_FORCE_LOCAL_INSTALL"
