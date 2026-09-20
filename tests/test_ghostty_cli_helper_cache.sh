#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ghostty-helper-cache-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX ZIG_REQUIRED

# Use a clean, owned repository: the developer's Ghostty tree can be absent or dirty.
FIXTURE_ROOT="$TMP_DIR/repo"
mkdir -p "$FIXTURE_ROOT/scripts" "$FIXTURE_ROOT/ghostty"
cp "$ROOT_DIR/scripts/build-ghostty-cli-helper.sh" "$ROOT_DIR/scripts/ghostty-zig-version.sh" "$FIXTURE_ROOT/scripts/"
touch "$FIXTURE_ROOT/ghostty/build.zig"
printf '.minimum_zig_version = "1.2.3",\n' > "$FIXTURE_ROOT/ghostty/build.zig.zon"
git -C "$FIXTURE_ROOT/ghostty" init -q
git -C "$FIXTURE_ROOT/ghostty" -c user.name=fixture -c user.email=fixture@example.invalid add .
git -C "$FIXTURE_ROOT/ghostty" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
source "$ROOT_DIR/scripts/ghostty-zig-version.sh"
export FAKE_ZIG_VERSION="$(ghostty_minimum_zig_version "$FIXTURE_ROOT")"

FAKE_ZIG="$TMP_DIR/zig"
cat > "$FAKE_ZIG" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "version" ]]; then
  echo "$FAKE_ZIG_VERSION"
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
FIFTH="$TMP_DIR/fifth"
SIXTH="$TMP_DIR/sixth"

CMUX_ZIG="$FAKE_ZIG" \
CMUX_GHOSTTY_HELPER_CACHE_DIR="$CACHE_DIR" \
  "$FIXTURE_ROOT/scripts/build-ghostty-cli-helper.sh" \
  --target aarch64-macos --output "$FIRST" >"$TMP_DIR/first.log"
CMUX_ZIG="$FAKE_ZIG" \
CMUX_GHOSTTY_HELPER_CACHE_DIR="$CACHE_DIR" \
  "$FIXTURE_ROOT/scripts/build-ghostty-cli-helper.sh" \
  --target aarch64-macos --output "$SECOND" >"$TMP_DIR/second.log"

grep -q 'Building Ghostty CLI helper' "$TMP_DIR/first.log"
grep -q 'Reusing cached Ghostty CLI helper' "$TMP_DIR/second.log"
cmp -s "$FIRST" "$SECOND"

cached_helper="$(find "$CACHE_DIR" -type f -name ghostty -print -quit)"
[[ -n "$cached_helper" ]]
printf 'tampered\n' >> "$cached_helper"
CMUX_ZIG="$FAKE_ZIG" \
CMUX_GHOSTTY_HELPER_CACHE_DIR="$CACHE_DIR" \
  "$FIXTURE_ROOT/scripts/build-ghostty-cli-helper.sh" \
  --target aarch64-macos --output "$FOURTH" >"$TMP_DIR/fourth.log"
grep -q 'Building Ghostty CLI helper' "$TMP_DIR/fourth.log"
cmp -s "$FIRST" "$FOURTH"

CMUX_ZIG="$FAKE_ZIG" \
CMUX_GHOSTTY_HELPER_CACHE_DIR="$CACHE_DIR" \
CMUX_DISABLE_GHOSTTY_HELPER_CACHE=1 \
  "$FIXTURE_ROOT/scripts/build-ghostty-cli-helper.sh" \
  --target aarch64-macos --output "$THIRD" >"$TMP_DIR/third.log"
grep -q 'Building Ghostty CLI helper' "$TMP_DIR/third.log"
cmp -s "$FIRST" "$THIRD"

env -u HOME -u CMUX_GHOSTTY_HELPER_CACHE_DIR \
  CMUX_ZIG="$FAKE_ZIG" \
  "$FIXTURE_ROOT/scripts/build-ghostty-cli-helper.sh" \
  --target aarch64-macos --output "$FIFTH" >"$TMP_DIR/fifth.log"
env -u HOME -u CMUX_GHOSTTY_HELPER_CACHE_DIR \
  CMUX_ZIG="$FAKE_ZIG" \
  "$FIXTURE_ROOT/scripts/build-ghostty-cli-helper.sh" \
  --target aarch64-macos --output "$SIXTH" >"$TMP_DIR/sixth.log"
grep -q 'Building Ghostty CLI helper' "$TMP_DIR/fifth.log"
grep -q 'Building Ghostty CLI helper' "$TMP_DIR/sixth.log"
cmp -s "$FIFTH" "$SIXTH"

echo "PASS: Ghostty CLI helper cache reuses matching builds, rejects tampering, and disables safely"

python3 "$ROOT_DIR/tests/test_ghostty_cli_helper_cache_failures.py"
