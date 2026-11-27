#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/cmux-next/tests/lib/git-fixture.sh"  # turns off git's background maintenance in temp repos

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ghostty-helper-cache-test.XXXXXX")"
git_fixture_trap_exit 'rm -rf "$TMP_DIR"'
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX ZIG_REQUIRED

# Use a clean, owned repository: the developer's Ghostty tree can be absent or dirty.
FIXTURE_ROOT="$TMP_DIR/repo"
mkdir -p "$FIXTURE_ROOT/scripts" "$FIXTURE_ROOT/ghostty"
cp "$ROOT_DIR/scripts/build-ghostty-cli-helper.sh" "$ROOT_DIR/scripts/ghostty-zig-version.sh" "$FIXTURE_ROOT/scripts/"
mkdir -p "$FIXTURE_ROOT/scripts/cmux-next"
cp "$ROOT_DIR/scripts/cmux-next/zig-fetch-all.sh" "$FIXTURE_ROOT/scripts/cmux-next/"
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
if [[ "${1:-}" == "build" && "${2:-}" == "--fetch=all" ]]; then
  # zig-fetch-all.sh's prefetch: record it, with the proxy it set in mirror-only mode.
  printf '%s proxy=%s\n' "$PWD" "${https_proxy:-}" >> "$FETCH_LOG"
  [[ "${FAKE_ZIG_FETCH_FAIL:-0}" == 0 ]] || exit 1
  exit 0
fi
if [[ "${1:-}" == "build" ]]; then
  [[ ! -f "${FETCH_LOG:-/nonexistent}" ]] || [[ -s "$FETCH_LOG" ]] || { echo "built before the prefetch" >&2; exit 1; }
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

export FETCH_LOG="$TMP_DIR/fetch.log"
: > "$FETCH_LOG"
export CMUX_ZIG_FETCH_BACKOFF_S=0 CMUX_ZIG_FETCH_ATTEMPTS=2
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
# The build prefetched Ghostty's packages once, in the Ghostty tree, before zig built; a cache hit fetched nothing.
[[ "$(wc -l < "$FETCH_LOG" | tr -d ' ')" == 1 ]] || { cat "$FETCH_LOG"; echo "FAIL: expected one prefetch" >&2; exit 1; }
grep -q "^$FIXTURE_ROOT/ghostty " "$FETCH_LOG"
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

# Cache publication is best effort: an IO failure must warn, but keep the build.
mkdir -p "$TMP_DIR/shims"
cat > "$TMP_DIR/shims/mkdir" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"$BLOCK_CACHE"*) exit 1 ;;
esac
exec /bin/mkdir "$@"
EOF
chmod +x "$TMP_DIR/shims/mkdir"
PATH="$TMP_DIR/shims:$PATH" BLOCK_CACHE="$TMP_DIR/unwritable-cache" \
CMUX_ZIG="$FAKE_ZIG" CMUX_GHOSTTY_HELPER_CACHE_DIR="$TMP_DIR/unwritable-cache" \
  "$FIXTURE_ROOT/scripts/build-ghostty-cli-helper.sh" \
  --target aarch64-macos --output "$TMP_DIR/publication-failed" >"$TMP_DIR/publication-failed.log" 2>&1
grep -q 'warning: unable to publish Ghostty CLI helper cache' "$TMP_DIR/publication-failed.log"
cmp -s "$FIRST" "$TMP_DIR/publication-failed"

# In CI the prefetch is mirror-only (Zig gets a refusing proxy), and a failed one stops the build, named.
: > "$FETCH_LOG"
if CI=true FAKE_ZIG_FETCH_FAIL=1 CMUX_ZIG="$FAKE_ZIG" CMUX_DISABLE_GHOSTTY_HELPER_CACHE=1 \
  "$FIXTURE_ROOT/scripts/build-ghostty-cli-helper.sh" \
  --target aarch64-macos --output "$TMP_DIR/ci-fetch-failed" >"$TMP_DIR/ci-fetch-failed.log" 2>&1; then
  echo "FAIL: a failed CI prefetch must stop the build" >&2; exit 1
fi
grep -q "could not put Ghostty's Zig packages in the cache from the mirror" "$TMP_DIR/ci-fetch-failed.log"
grep -q 'proxy=http://127.0.0.1:9' "$FETCH_LOG"
[[ ! -e "$TMP_DIR/ci-fetch-failed" ]]
# Off CI a failed prefetch warns and the build still runs.
: > "$FETCH_LOG"
env -u CI FAKE_ZIG_FETCH_FAIL=1 CMUX_ZIG="$FAKE_ZIG" CMUX_DISABLE_GHOSTTY_HELPER_CACHE=1 \
  "$FIXTURE_ROOT/scripts/build-ghostty-cli-helper.sh" \
  --target aarch64-macos --output "$TMP_DIR/dev-fetch-failed" >"$TMP_DIR/dev-fetch-failed.log" 2>&1
grep -q 'prefetch failed; the build fetches what it lacks' "$TMP_DIR/dev-fetch-failed.log"
cmp -s "$FIRST" "$TMP_DIR/dev-fetch-failed"

echo "PASS: Ghostty CLI helper cache reuses matching builds, rejects tampering, and disables safely"

python3 "$ROOT_DIR/tests/test_ghostty_cli_helper_cache_failures.py"
