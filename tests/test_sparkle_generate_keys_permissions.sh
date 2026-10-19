#!/usr/bin/env bash
# Behavioral test for the file that scripts/sparkle_generate_keys.sh writes.
# The exported private key must never inherit the caller's ordinary 022 umask,
# whether the target is new or replaces an existing environment file.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/sparkle_generate_keys.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-sparkle-key-mode.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_BIN="$TMP_DIR/bin"
FAKE_TOOLS="$TMP_DIR/tools"
mkdir -p "$FAKE_BIN" "$FAKE_TOOLS"
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$FAKE_BIN/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = clone ] || exit 2
mkdir -p "${@: -1}"
GIT

cat > "$FAKE_BIN/xcodebuild" <<'XCODEBUILD'
#!/usr/bin/env bash
set -euo pipefail
derived=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = -derivedDataPath ]; then derived="$2"; shift; fi
  shift
done
[ -n "$derived" ] || exit 2
mkdir -p "$derived/Build/Products/Release"
cp "$CMUX_TEST_GENERATE_KEYS" "$derived/Build/Products/Release/generate_keys"
chmod +x "$derived/Build/Products/Release/generate_keys"
XCODEBUILD

cat > "$FAKE_TOOLS/generate_keys" <<'GENERATE_KEYS'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" -p "*) printf '%s\n' 'fixture-public-key' ;;
  *" -x "*)
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -x ]; then printf '%s\n' 'fixture-private-key' > "$2"; exit 0; fi
      shift
    done
    exit 2
    ;;
esac
GENERATE_KEYS
chmod +x "$FAKE_BIN"/* "$FAKE_TOOLS/generate_keys"

mode_of() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

run_case() {
  local target="$1"
  local expect_keep="$2"
  PATH="$FAKE_BIN:$PATH" \
    CMUX_TEST_GENERATE_KEYS="$FAKE_TOOLS/generate_keys" \
    SPARKLE_ENV_FILE="$target" \
    "$SCRIPT" >/dev/null
  [ "$(mode_of "$target")" = 600 ] || fail "$target mode is $(mode_of "$target"), expected 600"
  if [ "$expect_keep" = yes ]; then
    grep -qx 'KEEP_ME=yes' "$target" || fail "$target did not preserve unrelated settings"
  fi
  grep -qx 'SPARKLE_PUBLIC_KEY=fixture-public-key' "$target" || fail "$target has the wrong public key"
  grep -qx 'SPARKLE_PRIVATE_KEY=fixture-private-key' "$target" || fail "$target has the wrong private key"
  [ "$(grep -c '^SPARKLE_PRIVATE_KEY=' "$target")" = 1 ] || fail "$target has duplicate private-key entries"
}

umask 022
new_target="$TMP_DIR/new.env"
run_case "$new_target" no

existing_target="$TMP_DIR/existing.env"
printf '%s\n' 'KEEP_ME=yes' 'SPARKLE_PUBLIC_KEY=old' 'SPARKLE_PRIVATE_KEY=old' > "$existing_target"
chmod 644 "$existing_target"
run_case "$existing_target" yes

echo "PASS: Sparkle key export files are mode 600"
