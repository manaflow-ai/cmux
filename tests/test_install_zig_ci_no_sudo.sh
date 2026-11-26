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

read_zig_lib_dir_from_stdin() {
  python3 -c 'import json, re, sys
text = sys.stdin.read()
try:
    print(json.loads(text).get("lib_dir", ""))
except Exception:
    match = re.search(r"(?m)^\s*\.lib_dir\s*=\s*\"([^\"]*)\"", text)
    print(match.group(1) if match else "")
'
}

archive_sha256() {
  local archive="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$archive" | awk '{print $1}'
  else
    sha256sum "$archive" | awk '{print $1}'
  fi
}

ZIG_REQUIRED="99.99.99"
case "$(uname -s)" in
  Darwin) ZIG_OS="macos" ;;
  Linux) ZIG_OS="linux" ;;
  *)
    echo "Unsupported test operating system: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64 | aarch64) ZIG_ARCH="aarch64" ;;
  x86_64) ZIG_ARCH="x86_64" ;;
  *)
    echo "Unsupported test architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

FIXTURE_ROOT="$TMP_DIR/fixture"
ZIG_NAME="zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_REQUIRED}"
ARCHIVE="$TMP_DIR/${ZIG_NAME}.tar.xz"
DEFAULT_INSTALL_ROOT="/tmp/cmux-zig-ci/$ZIG_NAME"
SHARED_TMP_ZIG_DIR="/tmp/$ZIG_NAME"
SHARED_TMP_MARKER="$SHARED_TMP_ZIG_DIR/keep.txt"
BIN_DIR="$TMP_DIR/bin"
RUNNER_TEMP_DIR="$TMP_DIR/runner-temp"
GITHUB_PATH_FILE="$TMP_DIR/github-path"
GITHUB_ENV_FILE="$TMP_DIR/github-env"
OUTPUT_FILE="$TMP_DIR/output"
BROKEN_ZIG_LIB_DIR="$TMP_DIR/broken-zig-lib"
WRONG_VERSION_OUTPUT_FILE="$TMP_DIR/wrong-version-output"
WRONG_VERSION_GITHUB_PATH_FILE="$TMP_DIR/wrong-version-github-path"
WRONG_VERSION_GITHUB_ENV_FILE="$TMP_DIR/wrong-version-github-env"
WRONG_VERSION_RUNNER_TEMP_DIR="$TMP_DIR/wrong-version-runner-temp"
WRONG_VERSION_LIB_DIR="$TMP_DIR/wrong-version-zig-lib"
SUDO_OUTPUT_FILE="$TMP_DIR/sudo-output"
SUDO_GITHUB_PATH_FILE="$TMP_DIR/sudo-github-path"
SUDO_GITHUB_ENV_FILE="$TMP_DIR/sudo-github-env"
SUDO_SYSTEM_PREFIX="$TMP_DIR/system-prefix"
FORCE_LOCAL_OUTPUT_FILE="$TMP_DIR/force-local-output"
FORCE_LOCAL_GITHUB_PATH_FILE="$TMP_DIR/force-local-github-path"
FORCE_LOCAL_GITHUB_ENV_FILE="$TMP_DIR/force-local-github-env"
FORCE_LOCAL_INSTALL_PARENT="$TMP_DIR/force-local-install"
FORCE_LOCAL_MARKER="$FORCE_LOCAL_INSTALL_PARENT/keep.txt"
DEFAULT_OUTPUT_FILE="$TMP_DIR/default-output"
DEFAULT_GITHUB_PATH_FILE="$TMP_DIR/default-github-path"
DEFAULT_GITHUB_ENV_FILE="$TMP_DIR/default-github-env"
SUDO_LOG="$TMP_DIR/sudo.log"

mkdir -p "$FIXTURE_ROOT/$ZIG_NAME/lib/compiler" "$BIN_DIR" "$RUNNER_TEMP_DIR" "$WRONG_VERSION_RUNNER_TEMP_DIR" "$WRONG_VERSION_LIB_DIR/compiler"
rm -rf "$SHARED_TMP_ZIG_DIR"
mkdir -p "$SHARED_TMP_ZIG_DIR"
printf 'shared temp marker\n' > "$SHARED_TMP_MARKER"
cat > "$FIXTURE_ROOT/$ZIG_NAME/zig" <<EOF
#!/usr/bin/env bash
set -euo pipefail
self="\$0"
if [ -L "\$self" ]; then
  target="\$(readlink "\$self")"
  case "\$target" in
    /*)
      self="\$target"
      ;;
    *)
      self="\$(cd "\$(dirname "\$self")" && pwd -P)/\$target"
      ;;
  esac
fi
case "\${1:-}" in
  version)
    echo "$ZIG_REQUIRED"
    ;;
  env)
    zig_dir="\$(cd "\$(dirname "\$self")" && pwd -P)"
    printf '.{\\n    .lib_dir = "%s/lib",\\n}\\n' "\$zig_dir"
    ;;
  *)
    echo "$ZIG_REQUIRED"
    ;;
esac
EOF
chmod +x "$FIXTURE_ROOT/$ZIG_NAME/zig"
printf 'lib fixture\n' > "$FIXTURE_ROOT/$ZIG_NAME/lib/std"
printf 'build runner fixture\n' > "$FIXTURE_ROOT/$ZIG_NAME/lib/compiler/build_runner.zig"
printf 'wrong version build runner fixture\n' > "$WRONG_VERSION_LIB_DIR/compiler/build_runner.zig"
(cd "$FIXTURE_ROOT" && tar -cf "$ARCHIVE" "$ZIG_NAME")
ARCHIVE_SHA256="$(archive_sha256 "$ARCHIVE")"

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

cat > "$BIN_DIR/zig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  version)
    printf '%s\n' "${FAKE_ZIG_VERSION:?}"
    ;;
  env)
    printf '{"lib_dir":"%s"}\n' "${FAKE_ZIG_LIB_DIR:?}"
    ;;
  *)
    echo "unexpected fake zig invocation: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$BIN_DIR/zig"

cat > "$BIN_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN_DIR/sudo"

PATH="$BIN_DIR:/usr/bin:/bin" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  GITHUB_PATH="$GITHUB_PATH_FILE" \
  GITHUB_ENV="$GITHUB_ENV_FILE" \
  FAKE_ZIG_VERSION="$ZIG_REQUIRED" \
  FAKE_ZIG_LIB_DIR="$BROKEN_ZIG_LIB_DIR" \
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

if grep -Fq "already installed at" "$OUTPUT_FILE"; then
  cat "$OUTPUT_FILE"
  echo "FAIL: installer accepted a broken existing zig whose lib_dir lacks compiler/build_runner.zig" >&2
  exit 1
fi

if [ ! -f "$SHARED_TMP_MARKER" ]; then
  cat "$OUTPUT_FILE"
  echo "FAIL: installer touched the shared /tmp Zig extraction directory" >&2
  exit 1
fi

PATH="$BIN_DIR:/usr/bin:/bin" \
  RUNNER_TEMP="$WRONG_VERSION_RUNNER_TEMP_DIR" \
  GITHUB_PATH="$WRONG_VERSION_GITHUB_PATH_FILE" \
  GITHUB_ENV="$WRONG_VERSION_GITHUB_ENV_FILE" \
  FAKE_ZIG_VERSION="98.98.98" \
  FAKE_ZIG_LIB_DIR="$WRONG_VERSION_LIB_DIR" \
  ZIG_REQUIRED="$ZIG_REQUIRED" \
  ZIG_EXPECTED_SHA256="$ARCHIVE_SHA256" \
  ZIG_MIRROR_URL="https://example.invalid/$ZIG_NAME.tar.xz" \
  "$SCRIPT" > "$WRONG_VERSION_OUTPUT_FILE" 2>&1

WRONG_VERSION_INSTALL_ROOT="$WRONG_VERSION_RUNNER_TEMP_DIR/$ZIG_NAME"
EXPECTED_WRONG_VERSION_INSTALL_ROOT="$(canonical_install_root "$WRONG_VERSION_INSTALL_ROOT")"
if [ ! -x "$WRONG_VERSION_INSTALL_ROOT/zig" ]; then
  cat "$WRONG_VERSION_OUTPUT_FILE"
  echo "FAIL: wrong-version existing zig did not fall back to a verified install" >&2
  exit 1
fi

if grep -Fq "already installed at" "$WRONG_VERSION_OUTPUT_FILE"; then
  cat "$WRONG_VERSION_OUTPUT_FILE"
  echo "FAIL: installer accepted a wrong-version existing zig whose lib_dir looked complete" >&2
  exit 1
fi

if ! grep -Fxq "$EXPECTED_WRONG_VERSION_INSTALL_ROOT" "$WRONG_VERSION_GITHUB_PATH_FILE"; then
  cat "$WRONG_VERSION_OUTPUT_FILE"
  echo "FAIL: wrong-version fallback did not publish the verified local zig bin dir to GITHUB_PATH" >&2
  exit 1
fi

cat > "$BIN_DIR/sudo" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$SUDO_LOG"
if [ "\${1:-}" = "-n" ]; then
  shift
fi
exec "\$@"
EOF
chmod +x "$BIN_DIR/sudo"
rm -f "$SUDO_LOG"

PATH="$BIN_DIR:/usr/bin:/bin" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  GITHUB_PATH="$SUDO_GITHUB_PATH_FILE" \
  GITHUB_ENV="$SUDO_GITHUB_ENV_FILE" \
  FAKE_ZIG_VERSION="$ZIG_REQUIRED" \
  FAKE_ZIG_LIB_DIR="$BROKEN_ZIG_LIB_DIR" \
  ZIG_REQUIRED="$ZIG_REQUIRED" \
  ZIG_EXPECTED_SHA256="$ARCHIVE_SHA256" \
  ZIG_SYSTEM_PREFIX="$SUDO_SYSTEM_PREFIX" \
  ZIG_MIRROR_URL="https://example.invalid/$ZIG_NAME.tar.xz" \
  "$SCRIPT" > "$SUDO_OUTPUT_FILE" 2>&1

EXPECTED_SUDO_BIN_DIR="$(cd "$SUDO_SYSTEM_PREFIX/bin" && pwd)"
EXPECTED_SUDO_LIB_DIR="$(canonical_install_root "$SUDO_SYSTEM_PREFIX/lib/$ZIG_NAME/lib")"
if [ ! -x "$SUDO_SYSTEM_PREFIX/bin/zig" ]; then
  cat "$SUDO_OUTPUT_FILE"
  echo "FAIL: sudo install did not publish an executable zig in the system bin dir" >&2
  exit 1
fi

if [ "$(canonical_install_root "$(readlink "$SUDO_SYSTEM_PREFIX/lib/zig")")" != "$EXPECTED_SUDO_LIB_DIR" ]; then
  cat "$SUDO_OUTPUT_FILE"
  echo "FAIL: sudo install did not preserve the system Zig lib_dir symlink" >&2
  exit 1
fi

SUDO_LIB_DIR="$("$SUDO_SYSTEM_PREFIX/bin/zig" env | read_zig_lib_dir_from_stdin)"
if [ ! -f "$SUDO_LIB_DIR/compiler/build_runner.zig" ]; then
  cat "$SUDO_OUTPUT_FILE"
  echo "FAIL: sudo-installed zig does not resolve compiler/build_runner.zig through zig env" >&2
  exit 1
fi

if ! grep -Fxq "$EXPECTED_SUDO_BIN_DIR" "$SUDO_GITHUB_PATH_FILE"; then
  cat "$SUDO_OUTPUT_FILE"
  echo "FAIL: sudo install did not publish the system zig bin dir to GITHUB_PATH" >&2
  exit 1
fi

if ! grep -Fxq "CMUX_ZIG=$EXPECTED_SUDO_BIN_DIR/zig" "$SUDO_GITHUB_ENV_FILE"; then
  cat "$SUDO_OUTPUT_FILE"
  echo "FAIL: sudo install did not publish CMUX_ZIG" >&2
  exit 1
fi

rm -f "$SUDO_LOG"
mkdir -p "$FORCE_LOCAL_INSTALL_PARENT"
printf 'keep\n' > "$FORCE_LOCAL_MARKER"

PATH="$BIN_DIR:/usr/bin:/bin" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  GITHUB_PATH="$FORCE_LOCAL_GITHUB_PATH_FILE" \
  GITHUB_ENV="$FORCE_LOCAL_GITHUB_ENV_FILE" \
  FAKE_ZIG_VERSION="$ZIG_REQUIRED" \
  FAKE_ZIG_LIB_DIR="$BROKEN_ZIG_LIB_DIR" \
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
  FAKE_ZIG_VERSION="$ZIG_REQUIRED" \
  FAKE_ZIG_LIB_DIR="$BROKEN_ZIG_LIB_DIR" \
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

echo "PASS: install-zig-ci rejects broken or wrong-version existing zig, validates sudo lib_dir, falls back locally, isolates shared /tmp extraction, honors ZIG_FORCE_LOCAL_INSTALL, and handles missing RUNNER_TEMP"
