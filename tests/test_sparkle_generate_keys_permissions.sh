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
echo "unverified source clone must not run" >&2
exit 97
GIT

cat > "$FAKE_BIN/xcodebuild" <<'XCODEBUILD'
#!/usr/bin/env bash
echo "source-built key tool must not run" >&2
exit 98
XCODEBUILD

cat > "$FAKE_BIN/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
[ "$url" = "https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-2.8.1.tar.xz" ]
[ -n "$out" ]
printf '%s' fixture-tarball > "$out"
echo download >> "$CMUX_TEST_PINNED_CALLS"
CURL

cat > "$FAKE_BIN/shasum" <<'SHASUM'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -a ] && [ "$2" = 256 ] && [ "$(cat "$3")" = fixture-tarball ]
echo checksum >> "$CMUX_TEST_PINNED_CALLS"
printf '%s  %s\n' "${CMUX_TEST_PINNED_SHA:-5cddb7695674ef7704268f38eccaee80e3accbf19e61c1689efff5b6116d85be}" "$3"
SHASUM

cat > "$FAKE_BIN/tar" <<'TAR'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -xf ] && [ "$3" = -C ] && [ "$5" = ./bin ]
[ "$(cat "$2")" = fixture-tarball ]
mkdir -p "$4/bin"
cp "$CMUX_TEST_GENERATE_KEYS" "$4/bin/generate_keys"
chmod +x "$4/bin/generate_keys"
echo extract >> "$CMUX_TEST_PINNED_CALLS"
TAR

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
  : > "$TMP_DIR/pinned-calls"
  PATH="$FAKE_BIN:$PATH" \
    CMUX_TEST_GENERATE_KEYS="$FAKE_TOOLS/generate_keys" \
    CMUX_TEST_PINNED_CALLS="$TMP_DIR/pinned-calls" \
    SPARKLE_ENV_FILE="$target" \
    "$SCRIPT" >/dev/null
  [ "$(paste -sd, "$TMP_DIR/pinned-calls")" = download,checksum,extract ] \
    || fail "Sparkle tools were not downloaded, verified, then extracted"
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

bad_target="$TMP_DIR/bad.env"
: > "$TMP_DIR/pinned-calls"
if PATH="$FAKE_BIN:$PATH" \
  CMUX_TEST_GENERATE_KEYS="$FAKE_TOOLS/generate_keys" \
  CMUX_TEST_PINNED_CALLS="$TMP_DIR/pinned-calls" \
  CMUX_TEST_PINNED_SHA=bad \
  SPARKLE_ENV_FILE="$bad_target" \
  "$SCRIPT" >/dev/null 2>&1; then
  fail "a mismatched Sparkle tools checksum was accepted"
fi
[ "$(paste -sd, "$TMP_DIR/pinned-calls")" = download,checksum ] \
  || fail "the mismatched tarball was extracted or executed"
[ ! -e "$bad_target" ] || fail "a key file was written after a checksum mismatch"

echo "PASS: Sparkle key generation uses pinned tools and writes mode-600 exports"
