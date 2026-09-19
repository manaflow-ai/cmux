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

printf 'resource-v1\n' > "$SRCROOT/ghostty/zig-out/share/ghostty/nested/file"
printf 'shell\n' > "$SRCROOT/ghostty/src/shell-integration/zsh/ghostty-integration"
printf 'term\n' > "$SRCROOT/ghostty/zig-out/share/terminfo/x"
printf 'cmux\n' > "$SRCROOT/Resources/shell-integration/cmux.zsh"
printf 'alternate\n' > "$SRCROOT/Resources/shell-integration/alternate.zsh"
ln -s cmux.zsh "$SRCROOT/Resources/shell-integration/current.zsh"
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
if [[ "$output" == *.app/Contents/Resources/bin/cmux-cua ]]; then
  resources_dir="${output%/bin/cmux-cua}"
  helper_app="$resources_dir/../Library/cmux Computer Use.app"
  mkdir -p "$helper_app/Contents/MacOS" "$helper_app/Contents/Resources"
  printf 'cua-helper-app\n' > "$helper_app/Contents/MacOS/cmux-cua"
  chmod +x "$helper_app/Contents/MacOS/cmux-cua"
  printf 'plist\n' > "$helper_app/Contents/Info.plist"
  printf 'managed\n' > "$helper_app/Contents/Resources/.cmux-cua-managed-helper"
fi
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
  ARCHS=arm64 \
  bash "$ROOT_DIR/scripts/build-app-bundled-resources.sh" "$@"
}

run_app_phase() {
  TARGET_BUILD_DIR="$BUILD_DIR" \
  DERIVED_FILE_DIR="$BUILD_DIR/Derived" \
  UNLOCALIZED_RESOURCES_FOLDER_PATH="cmux.app/Contents/Resources" \
  INFOPLIST_PATH=Products/Info.plist \
  SRCROOT="$SRCROOT" \
  ARCHS=arm64 \
  bash "$ROOT_DIR/scripts/build-app-bundled-resources.sh" "$@"
}

run_phase > "$TMP_DIR/first.log"
run_phase > "$TMP_DIR/second.log"
grep -q 'skipping helper rebuilds' "$TMP_DIR/second.log"

rm "$SRCROOT/Resources/shell-integration/current.zsh"
ln -s alternate.zsh "$SRCROOT/Resources/shell-integration/current.zsh"
run_phase > "$TMP_DIR/symlink.log"
if grep -q 'skipping helper rebuilds' "$TMP_DIR/symlink.log"; then
  echo 'FAIL: retargeted resource symlink did not invalidate the fingerprint' >&2
  exit 1
fi
[[ "$(readlink "$BUILD_DIR/Resources/shell-integration/current.zsh")" == "alternate.zsh" ]]

GIT_DIR="$TMP_DIR/poison.git" GIT_WORK_TREE="$TMP_DIR/poison-worktree" \
  run_phase > "$TMP_DIR/git-env.log"
grep -q 'skipping helper rebuilds' "$TMP_DIR/git-env.log"

rm "$BUILD_DIR/Resources/ghostty/nested/file"
run_phase > "$TMP_DIR/third.log"
if grep -q 'skipping helper rebuilds' "$TMP_DIR/third.log"; then
  echo 'FAIL: deleted nested output was not regenerated' >&2
  exit 1
fi
[[ -f "$BUILD_DIR/Resources/ghostty/nested/file" ]]

run_app_phase > "$TMP_DIR/app-first.log"
run_app_phase > "$TMP_DIR/app-second.log"
grep -q 'skipping helper rebuilds' "$TMP_DIR/app-second.log"

HELPER_APP="$BUILD_DIR/cmux.app/Contents/Library/cmux Computer Use.app"
rm "$HELPER_APP/Contents/Info.plist"
run_app_phase > "$TMP_DIR/app-missing-plist.log"
if grep -q 'skipping helper rebuilds' "$TMP_DIR/app-missing-plist.log"; then
  echo 'FAIL: missing cmux-cua helper Info.plist did not invalidate the manifest' >&2
  exit 1
fi
[[ -f "$HELPER_APP/Contents/Info.plist" ]]

rm "$HELPER_APP/Contents/Resources/.cmux-cua-managed-helper"
run_app_phase > "$TMP_DIR/app-missing-owner.log"
if grep -q 'skipping helper rebuilds' "$TMP_DIR/app-missing-owner.log"; then
  echo 'FAIL: missing cmux-cua ownership marker did not invalidate the manifest' >&2
  exit 1
fi
[[ -f "$HELPER_APP/Contents/Resources/.cmux-cua-managed-helper" ]]

echo 'PASS: bundled-resource invalidation covers copied trees, Git environment, and complete helper bundles'
