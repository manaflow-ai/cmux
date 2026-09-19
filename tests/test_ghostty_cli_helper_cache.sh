#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ghostty-helper-cache-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_ZIG="$TMP_DIR/zig"
cat > "$FAKE_ZIG" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "version" ]]; then
  echo "0.16.0"
  exit 0
fi
if [[ "${1:-}" == "build" ]]; then
  prefix=""
  previous=""
  for arg in "$@"; do
    if [[ "$previous" == "--prefix" ]]; then
      prefix="$arg"
      break
    fi
    previous="$arg"
  done
  [[ -n "$prefix" ]] || { echo "missing --prefix" >&2; exit 1; }
  mkdir -p "$prefix/bin"
  printf '#!/usr/bin/env bash\necho fake ghostty helper\n' > "$prefix/bin/ghostty"
  chmod +x "$prefix/bin/ghostty"
  exit 0
fi
echo "unsupported fake zig invocation" >&2
exit 1
EOF
chmod +x "$FAKE_ZIG"

CACHE_DIR="$TMP_DIR/cache"
FIRST="$TMP_DIR/first"
SECOND="$TMP_DIR/second"
THIRD="$TMP_DIR/third"
FOURTH="$TMP_DIR/fourth"

CMUX_ZIG="$FAKE_ZIG" \
CMUX_GHOSTTY_HELPER_CACHE_DIR="$CACHE_DIR" \
  "$ROOT_DIR/scripts/build-ghostty-cli-helper.sh" \
  --target aarch64-macos --output "$FIRST" >"$TMP_DIR/first.log"
CMUX_ZIG="$FAKE_ZIG" \
CMUX_GHOSTTY_HELPER_CACHE_DIR="$CACHE_DIR" \
  "$ROOT_DIR/scripts/build-ghostty-cli-helper.sh" \
  --target aarch64-macos --output "$SECOND" >"$TMP_DIR/second.log"

grep -q 'Building Ghostty CLI helper' "$TMP_DIR/first.log"
grep -q 'Reusing cached Ghostty CLI helper' "$TMP_DIR/second.log"
cmp -s "$FIRST" "$SECOND"

cached_helper="$(find "$CACHE_DIR" -type f -name ghostty -print -quit)"
[[ -n "$cached_helper" ]]
printf 'tampered\n' >> "$cached_helper"
CMUX_ZIG="$FAKE_ZIG" \
CMUX_GHOSTTY_HELPER_CACHE_DIR="$CACHE_DIR" \
  "$ROOT_DIR/scripts/build-ghostty-cli-helper.sh" \
  --target aarch64-macos --output "$FOURTH" >"$TMP_DIR/fourth.log"
grep -q 'Building Ghostty CLI helper' "$TMP_DIR/fourth.log"
cmp -s "$FIRST" "$FOURTH"

CMUX_ZIG="$FAKE_ZIG" \
CMUX_GHOSTTY_HELPER_CACHE_DIR="$CACHE_DIR" \
CMUX_DISABLE_GHOSTTY_HELPER_CACHE=1 \
  "$ROOT_DIR/scripts/build-ghostty-cli-helper.sh" \
  --target aarch64-macos --output "$THIRD" >"$TMP_DIR/third.log"
grep -q 'Building Ghostty CLI helper' "$TMP_DIR/third.log"
cmp -s "$FIRST" "$THIRD"

echo "PASS: Ghostty CLI helper cache reuses matching builds and honors disable switch"
