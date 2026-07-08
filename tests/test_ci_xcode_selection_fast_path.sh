#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/select-ci-xcode.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

bin_dir="$tmp_dir/bin"
env_file="$tmp_dir/github-env"
xcode_select_log="$tmp_dir/xcode-select.log"
mkdir -p "$bin_dir"
touch "$env_file" "$xcode_select_log"

cat > "$bin_dir/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "--sdk macosx --show-sdk-version")
    cat "$DEVELOPER_DIR/sdk-version"
    ;;
  "--sdk macosx --show-sdk-path")
    printf '%s\n' "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    ;;
  *)
    echo "unexpected xcrun args: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$bin_dir/xcrun"

cat > "$bin_dir/xcode-select" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CMUX_TEST_XCODE_SELECT_LOG"
EOF
chmod +x "$bin_dir/xcode-select"

cat > "$bin_dir/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "Xcode 26.2" "Build version 17C52"
EOF
chmod +x "$bin_dir/xcodebuild"

pinned_app="$tmp_dir/Xcode_26.2.app"
pinned_developer="$pinned_app/Contents/Developer"
mkdir -p "$pinned_developer"
printf '%s\n' "26.2" > "$pinned_developer/sdk-version"

output="$(
  PATH="$bin_dir:/usr/bin:/bin" \
    GITHUB_ENV="$env_file" \
    CMUX_TEST_XCODE_SELECT_LOG="$xcode_select_log" \
    CMUX_CI_DEVELOPER_DIR="$pinned_developer" \
    CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=26 \
    CMUX_XCODE_APPLICATIONS_DIR="$tmp_dir/no-apps" \
    "$SCRIPT"
)"

if ! grep -Fq "Selected pinned Xcode (DEVELOPER_DIR): $pinned_developer (macOS SDK 26.2)" <<< "$output"; then
  echo "FAIL: pinned developer dir was not selected"
  printf '%s\n' "$output" >&2
  exit 1
fi

if grep -Fq "Found " <<< "$output"; then
  echo "FAIL: pinned developer dir path should skip scanning Xcode apps"
  printf '%s\n' "$output" >&2
  exit 1
fi

if [[ "$(cat "$env_file")" != "DEVELOPER_DIR=$pinned_developer" ]]; then
  echo "FAIL: select-ci-xcode.sh did not export the pinned developer dir"
  cat "$env_file" >&2
  exit 1
fi

if [[ "$(cat "$xcode_select_log")" != "-s $pinned_developer" ]]; then
  echo "FAIL: select-ci-xcode.sh did not point xcode-select at the pinned developer dir"
  cat "$xcode_select_log" >&2
  exit 1
fi

old_app="$tmp_dir/Xcode_16.4.app"
old_developer="$old_app/Contents/Developer"
mkdir -p "$old_developer"
printf '%s\n' "15.5" > "$old_developer/sdk-version"

wrong_sdk_output="$(
  PATH="$bin_dir:/usr/bin:/bin" \
    GITHUB_ENV="$env_file" \
    CMUX_TEST_XCODE_SELECT_LOG="$xcode_select_log" \
    CMUX_CI_DEVELOPER_DIR="$old_developer" \
    CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=26 \
    "$SCRIPT" 2>&1 >/dev/null
)" && {
  echo "FAIL: pinned Xcode with the wrong SDK major should fail"
  exit 1
}

if ! grep -Fq "required major is 26" <<< "$wrong_sdk_output"; then
  echo "FAIL: wrong pinned SDK major failure was not explained"
  printf '%s\n' "$wrong_sdk_output" >&2
  exit 1
fi

missing_output="$(
  PATH="$bin_dir:/usr/bin:/bin" \
    GITHUB_ENV="$env_file" \
    CMUX_TEST_XCODE_SELECT_LOG="$xcode_select_log" \
    CMUX_CI_DEVELOPER_DIR="$tmp_dir/missing/Contents/Developer" \
    "$SCRIPT" 2>&1 >/dev/null
)" && {
  echo "FAIL: missing pinned developer dir should fail"
  exit 1
}

if ! grep -Fq "Pinned Xcode developer dir does not exist" <<< "$missing_output"; then
  echo "FAIL: missing pinned developer dir failure was not explained"
  printf '%s\n' "$missing_output" >&2
  exit 1
fi

echo "PASS: CI Xcode selection fast path"
