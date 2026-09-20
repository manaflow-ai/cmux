#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-bundled-resources-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

SRCROOT="$TMP_DIR/src"
BUILD_DIR="$TMP_DIR/build"
mkdir -p "$SRCROOT/ghostty/zig-out/share/ghostty/nested" \
  "$SRCROOT/ghostty/zig-out/share/terminfo" \
  "$SRCROOT/ghostty/src/shell-integration/zsh" \
  "$SRCROOT/Resources/shell-integration" \
  "$SRCROOT/Resources/terminfo-overlay" \
  "$SRCROOT/scripts" "$BUILD_DIR/Resources" "$BUILD_DIR/Products"

FAKE_TOOLCHAIN="$TMP_DIR/toolchain"
mkdir -p "$FAKE_TOOLCHAIN"
for tool in rustc cargo; do
  printf '#!/bin/bash\necho "%s 1.88.0 (fixture)"\n' "$tool" > "$FAKE_TOOLCHAIN/$tool"
  chmod +x "$FAKE_TOOLCHAIN/$tool"
done

printf 'resource-v1\n' > "$SRCROOT/ghostty/zig-out/share/ghostty/nested/file"
printf 'shell\n' > "$SRCROOT/ghostty/src/shell-integration/zsh/ghostty-integration"
printf 'term\n' > "$SRCROOT/ghostty/zig-out/share/terminfo/x"
printf 'cmux\n' > "$SRCROOT/Resources/shell-integration/cmux.zsh"
printf 'plist\n' > "$BUILD_DIR/Products/Info.plist"

git -C "$SRCROOT/ghostty" init -q
git -C "$SRCROOT/ghostty" config user.email test@example.invalid
git -C "$SRCROOT/ghostty" config user.name test
git -C "$SRCROOT/ghostty" add .
git -C "$SRCROOT/ghostty" commit -q -m fixture

cat > "$SRCROOT/scripts-build-helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "--output" ]] && output="$2" && shift 2 || shift
done
mkdir -p "$(dirname "$output")"
printf 'ghostty-helper\n' > "$output"
chmod +x "$output"
EOF
cat > "$SRCROOT/scripts-build-cua" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "--output" ]] && output="$2" && shift 2 || shift
done
mkdir -p "$(dirname "$output")"
printf 'cua-helper\n' > "$output"
printf 'license\n' > "${output}-LICENSE.md"
chmod +x "$output"
EOF
chmod +x "$SRCROOT/scripts-build-helper" "$SRCROOT/scripts-build-cua"
ln -s "$SRCROOT/scripts-build-helper" "$SRCROOT/scripts/build-ghostty-cli-helper.sh"
ln -s "$SRCROOT/scripts-build-cua" "$SRCROOT/scripts/build-cmux-cua.sh"
ln -s "$ROOT_DIR/scripts/build-app-bundled-resources.sh" "$SRCROOT/scripts/build-app-bundled-resources.sh"

run_phase() {
  TARGET_BUILD_DIR="$BUILD_DIR" \
  DERIVED_FILE_DIR="$BUILD_DIR/Derived" \
  UNLOCALIZED_RESOURCES_FOLDER_PATH=Resources \
  INFOPLIST_PATH=Products/Info.plist \
  SRCROOT="$SRCROOT" \
  PATH="$FAKE_TOOLCHAIN:$PATH" \
  ARCHS=arm64 \
  bash "$ROOT_DIR/scripts/build-app-bundled-resources.sh" "$@"
}

run_phase > "$TMP_DIR/first.log"
run_phase > "$TMP_DIR/second.log"
grep -q 'skipping helper rebuilds' "$TMP_DIR/second.log"

# Changing the compiler identity must invalidate the helper cache even when all
# source trees and build settings are unchanged.
for tool in rustc cargo; do
  printf '#!/bin/bash\necho "%s 1.89.0 (fixture)"\n' "$tool" > "$FAKE_TOOLCHAIN/$tool"
  run_phase > "$TMP_DIR/$tool-changed.log"
  if grep -q 'skipping helper rebuilds' "$TMP_DIR/$tool-changed.log"; then
    echo "FAIL: $tool toolchain change did not invalidate resource cache" >&2
    exit 1
  fi
  run_phase > "$TMP_DIR/$tool-warm.log"
  grep -q 'skipping helper rebuilds' "$TMP_DIR/$tool-warm.log"
done
echo 'PASS: Rust and Cargo toolchain changes invalidate bundled resources'

rm "$BUILD_DIR/Resources/ghostty/nested/file"
run_phase > "$TMP_DIR/third.log"
if grep -q 'skipping helper rebuilds' "$TMP_DIR/third.log"; then
  echo 'FAIL: deleted nested output was not regenerated' >&2
  exit 1
fi
[[ -f "$BUILD_DIR/Resources/ghostty/nested/file" ]]

echo 'PASS: bundled-resource manifest invalidates deleted nested outputs'

# A dangling resource symlink must invalidate both source and output receipts.
link="$SRCROOT/Resources/shell-integration/bench-link"
ln -s missing-first "$link"
run_phase > "$TMP_DIR/link-first.log"
[[ "$(readlink "$BUILD_DIR/Resources/shell-integration/bench-link")" == missing-first ]]
ln -sfn missing-second "$link"
run_phase > "$TMP_DIR/link-second.log"
[[ "$(readlink "$BUILD_DIR/Resources/shell-integration/bench-link")" == missing-second ]]
if grep -q 'skipping helper rebuilds' "$TMP_DIR/link-second.log"; then exit 1; fi
run_phase > "$TMP_DIR/link-warm.log"
grep -q 'skipping helper rebuilds' "$TMP_DIR/link-warm.log"
ln -sfn wrong-output "$BUILD_DIR/Resources/shell-integration/bench-link"
run_phase > "$TMP_DIR/link-repair.log"
[[ "$(readlink "$BUILD_DIR/Resources/shell-integration/bench-link")" == missing-second ]]

# An enclosing caller's Git environment must not redirect source discovery.
GIT_DIR="$TMP_DIR/nonexistent.git" GIT_WORK_TREE="$TMP_DIR/foreign" \
 GIT_INDEX_FILE="$TMP_DIR/foreign-index" run_phase > "$TMP_DIR/git-env.log"
grep -q 'skipping helper rebuilds' "$TMP_DIR/git-env.log"
echo 'PASS: symlink retargets, corrupted outputs, and inherited Git environment'
