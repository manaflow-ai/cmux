#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/repo/.git/modules/ghostty" "$TMP_DIR/bin"
touch "$TMP_DIR/repo/.git/modules/ghostty/index.lock"

cat > "$TMP_DIR/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "submodule sync --recursive")
    echo "sync" >> "$TEST_LOG"
    ;;
  "submodule update --init --recursive --depth=1")
    if [ -e "$TEST_REPO/.git/modules/ghostty/index.lock" ]; then
      echo "stale lock still exists" >&2
      exit 128
    fi
    echo "update" >> "$TEST_LOG"
    ;;
  *)
    echo "unexpected git args: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$TMP_DIR/bin/git"

TEST_REPO="$TMP_DIR/repo" \
TEST_LOG="$TMP_DIR/git.log" \
PATH="$TMP_DIR/bin:$PATH" \
  "$ROOT_DIR/scripts/ci/update-submodules.sh" "$TMP_DIR/repo"

if [ -e "$TMP_DIR/repo/.git/modules/ghostty/index.lock" ]; then
  echo "FAIL: stale submodule index.lock was not removed"
  exit 1
fi

if ! grep -Fxq "sync" "$TMP_DIR/git.log" || ! grep -Fxq "update" "$TMP_DIR/git.log"; then
  cat "$TMP_DIR/git.log" 2>/dev/null || true
  echo "FAIL: expected submodule sync and update"
  exit 1
fi

echo "PASS: submodule updater clears stale module locks before update"
