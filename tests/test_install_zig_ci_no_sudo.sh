#!/usr/bin/env bash
# Behavioral guard for installing verified Zig on CI runners without sudo.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/install-zig-ci.sh"
TMP_DIR="$(mktemp -d)"
DEFAULT_INSTALL_ROOT=""

cleanup() {
  rm -rf "$TMP_DIR"
  if [ -n "$DEFAULT_INSTALL_ROOT" ]; then
    rm -rf "$DEFAULT_INSTALL_ROOT"
  fi
  if [ -n "${SHARED_TMP_ZIG_DIR:-}" ]; then
    rm -rf "$SHARED_TMP_ZIG_DIR"
  fi
}
trap cleanup EXIT

canonical_install_root() {
  local root="$1"
  mkdir -p "$(dirname "$root")"
  printf '%s/%s\n' "$(cd "$(dirname "$root")" && pwd -P)" "$(basename "$root")"
}

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
DEFAULT_INSTALL_ROOT="/tmp/cmux-zig-ci/$ZIG_NAME"
SHARED_TMP_ZIG_DIR="/tmp/$ZIG_NAME"
SHARED_TMP_MARKER="$SHARED_TMP_ZIG_DIR/keep.txt"
BIN_DIR="$TMP_DIR/bin"
RUNNER_TEMP_DIR="$TMP_DIR/runner-temp"
GITHUB_PATH_FILE="$TMP_DIR/github-path"
GITHUB_ENV_FILE="$TMP_DIR/github-env"
OUTPUT_FILE="$TMP_DIR/output"
FORCE_LOCAL_OUTPUT_FILE="$TMP_DIR/force-local-output"
FORCE_LOCAL_GITHUB_PATH_FILE="$TMP_DIR/force-local-github-path"
FORCE_LOCAL_GITHUB_ENV_FILE="$TMP_DIR/force-local-github-env"
FORCE_LOCAL_INSTALL_PARENT="$TMP_DIR/force-local-install"
FORCE_LOCAL_MARKER="$FORCE_LOCAL_INSTALL_PARENT/keep.txt"
DEFAULT_OUTPUT_FILE="$TMP_DIR/default-output"
DEFAULT_GITHUB_PATH_FILE="$TMP_DIR/default-github-path"
DEFAULT_GITHUB_ENV_FILE="$TMP_DIR/default-github-env"
SUDO_LOG="$TMP_DIR/sudo.log"

mkdir -p "$FIXTURE_ROOT/$ZIG_NAME/lib" "$BIN_DIR" "$RUNNER_TEMP_DIR"
rm -rf "$SHARED_TMP_ZIG_DIR"
mkdir -p "$SHARED_TMP_ZIG_DIR"
printf 'shared temp marker\n' > "$SHARED_TMP_MARKER"
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
EXPECTED_INSTALLED_ZIG="$(canonical_install_root "$RUNNER_TEMP_DIR/$ZIG_NAME")/zig"
if [ ! -x "$INSTALLED_ZIG" ]; then
  cat "$OUTPUT_FILE"
  echo "FAIL: zig was not installed under RUNNER_TEMP" >&2
  exit 1
fi

if ! grep -Fxq "$(dirname "$EXPECTED_INSTALLED_ZIG")" "$GITHUB_PATH_FILE"; then
  cat "$OUTPUT_FILE"
  echo "FAIL: installer did not publish the local zig bin dir to GITHUB_PATH" >&2
  exit 1
fi

if ! grep -Fxq "CMUX_ZIG=$EXPECTED_INSTALLED_ZIG" "$GITHUB_ENV_FILE"; then
  cat "$OUTPUT_FILE"
  echo "FAIL: installer did not publish CMUX_ZIG" >&2
  exit 1
fi

if ! grep -Fq "sudo unavailable; installing zig under" "$OUTPUT_FILE"; then
  cat "$OUTPUT_FILE"
  echo "FAIL: installer did not report local fallback" >&2
  exit 1
fi

if [ ! -f "$SHARED_TMP_MARKER" ]; then
  cat "$OUTPUT_FILE"
  echo "FAIL: installer touched the shared /tmp Zig extraction directory" >&2
  exit 1
fi

cat > "$BIN_DIR/sudo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SUDO_LOG"
exit 0
EOF
chmod +x "$BIN_DIR/sudo"
rm -f "$SUDO_LOG"
mkdir -p "$FORCE_LOCAL_INSTALL_PARENT"
printf 'keep\n' > "$FORCE_LOCAL_MARKER"

PATH="$BIN_DIR:/usr/bin:/bin" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  GITHUB_PATH="$FORCE_LOCAL_GITHUB_PATH_FILE" \
  GITHUB_ENV="$FORCE_LOCAL_GITHUB_ENV_FILE" \
  ZIG_REQUIRED="$ZIG_REQUIRED" \
  ZIG_EXPECTED_SHA256="$ARCHIVE_SHA256" \
  ZIG_FORCE_LOCAL_INSTALL=1 \
  ZIG_INSTALL_ROOT="$FORCE_LOCAL_INSTALL_PARENT" \
  ZIG_MIRROR_URL="https://example.invalid/$ZIG_NAME.tar.xz" \
  "$SCRIPT" > "$FORCE_LOCAL_OUTPUT_FILE" 2>&1

FORCE_LOCAL_INSTALL_ROOT="$FORCE_LOCAL_INSTALL_PARENT/$ZIG_NAME"
EXPECTED_FORCE_LOCAL_INSTALL_ROOT="$(canonical_install_root "$FORCE_LOCAL_INSTALL_ROOT")"
if [ ! -x "$FORCE_LOCAL_INSTALL_ROOT/zig" ]; then
  cat "$FORCE_LOCAL_OUTPUT_FILE"
  echo "FAIL: force-local install did not install zig under ZIG_INSTALL_ROOT" >&2
  exit 1
fi

if [ ! -f "$FORCE_LOCAL_MARKER" ]; then
  cat "$FORCE_LOCAL_OUTPUT_FILE"
  echo "FAIL: force-local install deleted unrelated parent directory contents" >&2
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

if ! grep -Fxq "$EXPECTED_FORCE_LOCAL_INSTALL_ROOT" "$FORCE_LOCAL_GITHUB_PATH_FILE"; then
  cat "$FORCE_LOCAL_OUTPUT_FILE"
  echo "FAIL: force-local install did not publish the local zig bin dir to GITHUB_PATH" >&2
  exit 1
fi

if ! grep -Fxq "CMUX_ZIG=$EXPECTED_FORCE_LOCAL_INSTALL_ROOT/zig" "$FORCE_LOCAL_GITHUB_ENV_FILE"; then
  cat "$FORCE_LOCAL_OUTPUT_FILE"
  echo "FAIL: force-local install did not publish CMUX_ZIG" >&2
  exit 1
fi

cat > "$BIN_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN_DIR/sudo"
rm -rf "$DEFAULT_INSTALL_ROOT"

env -u RUNNER_TEMP -u ZIG_FORCE_LOCAL_INSTALL -u ZIG_INSTALL_ROOT \
  PATH="$BIN_DIR:/usr/bin:/bin" \
  GITHUB_PATH="$DEFAULT_GITHUB_PATH_FILE" \
  GITHUB_ENV="$DEFAULT_GITHUB_ENV_FILE" \
  ZIG_REQUIRED="$ZIG_REQUIRED" \
  ZIG_EXPECTED_SHA256="$ARCHIVE_SHA256" \
  ZIG_MIRROR_URL="https://example.invalid/$ZIG_NAME.tar.xz" \
  "$SCRIPT" > "$DEFAULT_OUTPUT_FILE" 2>&1

EXPECTED_DEFAULT_INSTALL_ROOT="$(canonical_install_root "$DEFAULT_INSTALL_ROOT")"
if [ ! -x "$DEFAULT_INSTALL_ROOT/zig" ]; then
  cat "$DEFAULT_OUTPUT_FILE"
  echo "FAIL: missing RUNNER_TEMP did not install zig under the distinct /tmp fallback root" >&2
  exit 1
fi

if ! grep -Fq "sudo unavailable; installing zig under $EXPECTED_DEFAULT_INSTALL_ROOT" "$DEFAULT_OUTPUT_FILE"; then
  cat "$DEFAULT_OUTPUT_FILE"
  echo "FAIL: missing RUNNER_TEMP fallback did not report the distinct /tmp install root" >&2
  exit 1
fi

if ! grep -Fxq "$EXPECTED_DEFAULT_INSTALL_ROOT" "$DEFAULT_GITHUB_PATH_FILE"; then
  cat "$DEFAULT_OUTPUT_FILE"
  echo "FAIL: missing RUNNER_TEMP fallback did not publish the local zig bin dir to GITHUB_PATH" >&2
  exit 1
fi

if ! grep -Fxq "CMUX_ZIG=$EXPECTED_DEFAULT_INSTALL_ROOT/zig" "$DEFAULT_GITHUB_ENV_FILE"; then
  cat "$DEFAULT_OUTPUT_FILE"
  echo "FAIL: missing RUNNER_TEMP fallback did not publish CMUX_ZIG" >&2
  exit 1
fi

echo "PASS: install-zig-ci falls back locally, isolates shared /tmp extraction, honors ZIG_FORCE_LOCAL_INSTALL, and handles missing RUNNER_TEMP"
