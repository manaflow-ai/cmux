#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/select-ci-xcode.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

bin_dir="$tmp_dir/bin"
apps_dir="$tmp_dir/apps"
env_file="$tmp_dir/github-env"
xcode_select_log="$tmp_dir/xcode-select.log"
pins_file="$tmp_dir/xcode-pins.txt"
mkdir -p "$bin_dir" "$apps_dir"
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

cat > "$bin_dir/xcode-select" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CMUX_TEST_XCODE_SELECT_LOG"
EOF

cat > "$bin_dir/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'Xcode %s\n' "$(cat "$DEVELOPER_DIR/xcode-version")"
printf '%s\n' "Build version 17C52"
EOF

cat > "$bin_dir/sw_vers" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "-productVersion" ] || exit 64
printf '%s\n' "$CMUX_TEST_MACOS_VERSION"
EOF
chmod +x "$bin_dir/xcrun" "$bin_dir/xcode-select" "$bin_dir/xcodebuild" "$bin_dir/sw_vers"

# make_xcode <app name> <xcode version> <macOS SDK version>
make_xcode() {
  local developer="$apps_dir/$1/Contents/Developer"
  mkdir -p "$developer"
  printf '%s\n' "$2" > "$developer/xcode-version"
  printf '%s\n' "$3" > "$developer/sdk-version"
  printf '%s' "$developer"
}

current_developer="$(make_xcode Xcode_26.2.app 26.2 26.2)"
old_developer="$(make_xcode Xcode_16.4.app 16.4 15.5)"
future_developer="$(make_xcode Xcode_27.0.app 27.0 27.0)"
beta_developer="$(make_xcode Xcode_26.9_Beta.app 26.9 26.9)"

printf '%s\n' "# macOS  Xcode" "15 26.1" "26 26.2" > "$pins_file"

fail() {
  echo "FAIL: $1"
  shift
  for log in "$@"; do
    printf '%s\n' "--- $log" >&2
    cat "$log" >&2 || true
  done
  exit 1
}

# run_select <log> [VAR=value ...]: runs the selector on a stubbed macOS 26
# runner against the fixture pins. Returns the selector's exit status.
run_select() {
  local log="$1"
  shift
  : > "$env_file"
  : > "$xcode_select_log"
  env -i \
    HOME="$tmp_dir" \
    PATH="$bin_dir:/usr/bin:/bin" \
    GITHUB_ENV="$env_file" \
    CMUX_TEST_XCODE_SELECT_LOG="$xcode_select_log" \
    CMUX_TEST_MACOS_VERSION=26.1 \
    CMUX_XCODE_APPLICATIONS_DIR="$apps_dir" \
    CMUX_CI_XCODE_PINS_FILE="$pins_file" \
    "$@" \
    "$SCRIPT" > "$log" 2>&1
}

expect_env() {
  local want="$1" log="$2"
  [[ "$(cat "$env_file")" == "DEVELOPER_DIR=$want" ]] \
    || fail "expected DEVELOPER_DIR=$want" "$env_file" "$log"
}

# The error must be a single annotation naming what was found and what the repo
# requires, not the compiler's downstream noise.
expect_one_error() {
  local log="$1" text="$2"
  [[ "$(grep -c '^::error::' "$log")" == 1 ]] || fail "expected exactly one ::error:: line" "$log"
  grep -Fq "$text" "$log" || fail "missing error text: $text" "$log"
}

# 1. An explicit developer dir wins, skips the scan, and points xcode-select at it.
log="$tmp_dir/pinned.log"
run_select "$log" CMUX_CI_DEVELOPER_DIR="$current_developer" CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=26 \
  || fail "explicit pin should select" "$log"
grep -Fq "Selected pinned Xcode (DEVELOPER_DIR): $current_developer (macOS SDK 26.2)" "$log" \
  || fail "pinned developer dir was not selected" "$log"
! grep -Fq "Found " "$log" || fail "pinned developer dir should skip scanning Xcode apps" "$log"
! grep -Fq "::warning::" "$log" || fail "a pin that matches the pool should not warn" "$log"
expect_env "$current_developer" "$log"
[[ "$(cat "$xcode_select_log")" == "-s $current_developer" ]] \
  || fail "xcode-select was not pointed at the pinned developer dir" "$xcode_select_log"

# 2. Shared-machine workloads keep the host-global selector untouched.
log="$tmp_dir/skip.log"
run_select "$log" CMUX_CI_DEVELOPER_DIR="$current_developer" CMUX_CI_SKIP_XCODE_SELECT=1 \
  || fail "skip mode should select" "$log"
expect_env "$current_developer" "$log"
[[ ! -s "$xcode_select_log" ]] || fail "profile-local selection mutated the host-global selector" "$xcode_select_log"
grep -Fq "Skipping host-global xcode-select update" "$log" || fail "skip mode not reported" "$log"

# 3. CMUX_CI_XCODE_APP is the same pin, spelled as an app path.
log="$tmp_dir/app-pin.log"
run_select "$log" CMUX_CI_XCODE_APP="$apps_dir/Xcode_26.2.app/" || fail "app pin should select" "$log"
expect_env "$current_developer" "$log"

# 4. A pin below the .xcode-version major stops with one clear error, before the
#    SDK check can print its own less specific message.
log="$tmp_dir/below-floor-pin.log"
if run_select "$log" CMUX_CI_DEVELOPER_DIR="$old_developer" CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=26; then
  fail "a pinned Xcode below the floor should fail" "$log"
fi
expect_one_error "$log" "Found Xcode 16.4 at $old_developer; cmux requires Xcode 26 (.xcode-version)"
! grep -Fq "required major is 26" "$log" || fail "the floor should report before the SDK check" "$log"
[[ ! -s "$env_file" ]] || fail "a refused Xcode must not be exported" "$env_file"

# 5. The floor comes from .xcode-version, not a number in the script.
printf '27.0\n' > "$tmp_dir/xcode-version-27"
log="$tmp_dir/floor-from-file.log"
if run_select "$log" CMUX_CI_DEVELOPER_DIR="$current_developer" CMUX_XCODE_VERSION_FILE="$tmp_dir/xcode-version-27"; then
  fail "the floor should follow .xcode-version" "$log"
fi
expect_one_error "$log" "Found Xcode 26.2 at $current_developer; cmux requires Xcode 27 (.xcode-version)"

# 6. A missing pinned path fails instead of falling back.
log="$tmp_dir/missing-pin.log"
if run_select "$log" CMUX_CI_DEVELOPER_DIR="$tmp_dir/missing/Contents/Developer"; then
  fail "a missing pinned developer dir should fail" "$log"
fi
grep -Fq "Pinned Xcode developer dir does not exist" "$log" || fail "missing pin not explained" "$log"

# 7. An explicit pin must still respect the SDK ceiling.
log="$tmp_dir/pin-over-ceiling.log"
if run_select "$log" CMUX_CI_DEVELOPER_DIR="$future_developer" CMUX_CI_MAX_MACOS_SDK_MAJOR=26; then
  fail "an explicit Xcode pin must respect the SDK ceiling" "$log"
fi

# 8. With no pin, the pool pin wins over both the newest stable Xcode and a beta.
log="$tmp_dir/pool.log"
run_select "$log" || fail "an unpinned job should take the pool pin" "$log"
expect_env "$current_developer" "$log"
grep -Fq "Selected Xcode 26.2 pinned for macOS 26 runners (DEVELOPER_DIR): $current_developer" "$log" \
  || fail "pool selection not reported" "$log"

# 9. The pool pin applies under an SDK ceiling too (test-e2e sets one).
log="$tmp_dir/pool-ceiling.log"
run_select "$log" CMUX_CI_MAX_MACOS_SDK_MAJOR=26 || fail "pool pin under a ceiling should select" "$log"
expect_env "$current_developer" "$log"

# 10. The pool is the runner's macOS, so a macOS 15 runner gets the 15 pin.
fifteen_developer="$(make_xcode Xcode_26.1.app 26.1 26.1)"
log="$tmp_dir/pool-15.log"
run_select "$log" CMUX_TEST_MACOS_VERSION=15.7.4 || fail "a macOS 15 runner should take its pin" "$log"
expect_env "$fifteen_developer" "$log"

# 11. An explicit pin that disagrees with the pool is allowed but warned about.
log="$tmp_dir/pin-disagrees.log"
run_select "$log" CMUX_CI_DEVELOPER_DIR="$fifteen_developer" || fail "a disagreeing pin should still select" "$log"
grep -Fq "::warning::This job pins Xcode 26.1, but scripts/ci/xcode-pins.txt pins Xcode 26.2 for macOS 26 runners" "$log" \
  || fail "a pin that disagrees with the pool should warn" "$log"

# 12. The pool pin matches by reported version, so an app not named
#     Xcode_<version>.app (a fleet Mac's Xcode.app) still resolves.
mv "$apps_dir/Xcode_26.2.app" "$apps_dir/Xcode.app"
renamed_developer="$apps_dir/Xcode.app/Contents/Developer"
log="$tmp_dir/pool-renamed.log"
run_select "$log" || fail "the pool pin should match an app by version" "$log"
expect_env "$renamed_developer" "$log"

# 13. The runner lacks the pool's Xcode: one error naming what is installed,
#     never the image default. This is the hosted macos-15 image whose
#     /Applications/Xcode.app is 16.4.
mv "$apps_dir/Xcode.app" "$tmp_dir/hidden-26.2.app"
log="$tmp_dir/pool-missing.log"
if run_select "$log"; then
  fail "a runner without the pool's Xcode should fail" "$log"
fi
expect_one_error "$log" "This macOS 26 runner has no Xcode 26.2, the version scripts/ci/xcode-pins.txt pins for its pool. Installed:"
grep -Fq "Xcode_16.4.app=16.4" "$log" || fail "the error should list the installed Xcodes" "$log"
[[ ! -s "$env_file" ]] || fail "a failed pool selection must not export an Xcode" "$env_file"

# 13a. A fork's own CI on a hosted image without the pool's Xcode keeps working
#      on the newest stable Xcode, with a warning instead of an error. The floor
#      still applies to what it finds.
log="$tmp_dir/pool-missing-fork.log"
run_select "$log" GITHUB_REPOSITORY_OWNER=some-fork \
  || fail "a fork without the pool's Xcode should fall back to the newest stable Xcode" "$log"
expect_env "$future_developer" "$log"
grep -Fq "::warning::This macOS 26 runner has no Xcode 26.2" "$log" \
  || fail "the fork fallback should warn" "$log"
! grep -Fq "::error::" "$log" || fail "the fork fallback should not error" "$log"

# 13b. manaflow-ai's own runs keep the hard failure.
log="$tmp_dir/pool-missing-upstream.log"
if run_select "$log" GITHUB_REPOSITORY_OWNER=manaflow-ai; then
  fail "manaflow-ai runs without the pool's Xcode should fail" "$log"
fi
expect_one_error "$log" "This macOS 26 runner has no Xcode 26.2"
mv "$tmp_dir/hidden-26.2.app" "$apps_dir/Xcode_26.2.app"

# 14. A macOS major with no line in the pins file fails and says where to add it.
log="$tmp_dir/pool-unknown.log"
if run_select "$log" CMUX_TEST_MACOS_VERSION=14.7; then
  fail "a runner with no pool pin should fail" "$log"
fi
expect_one_error "$log" "No Xcode is pinned for macOS 14 runners. Add a line to scripts/ci/xcode-pins.txt"

# 14a. A fork on an unpinned macOS major scans instead, still above the floor.
log="$tmp_dir/pool-unknown-fork.log"
run_select "$log" CMUX_TEST_MACOS_VERSION=14.7 GITHUB_REPOSITORY_OWNER=some-fork \
  || fail "a fork on an unpinned macOS should fall back to the scan" "$log"
expect_env "$future_developer" "$log"

# 15. The SDK 15 helper opts out of the pool and the floor together, and keeps
#     the scan's required-SDK filter.
log="$tmp_dir/helper.log"
run_select "$log" CMUX_CI_XCODE_ALLOW_BELOW_FLOOR=1 CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=15 \
  || fail "the below-floor helper scan should select" "$log"
expect_env "$old_developer" "$log"
grep -Fq "Skipping $apps_dir/Xcode_26.2.app -> macOS SDK 26.2; required major is 15" "$log" \
  || fail "the helper scan did not report skipping the SDK 26 Xcode" "$log"

# 16. Without the opt-out, requiring SDK 15 cannot reach a below-floor Xcode.
log="$tmp_dir/helper-without-optout.log"
if run_select "$log" CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=15; then
  fail "requiring SDK 15 without the opt-out should fail" "$log"
fi

# 17. The scan still prefers stable over beta and honors the SDK ceiling.
log="$tmp_dir/scan-ceiling.log"
run_select "$log" CMUX_CI_XCODE_ALLOW_BELOW_FLOOR=1 CMUX_CI_MAX_MACOS_SDK_MAJOR=26 \
  || fail "the capped scan should select" "$log"
expect_env "$current_developer" "$log"
[[ -n "$beta_developer" ]]

# 18. The repository's own pins satisfy the repository's own floor.
floor="$(tr -d '[:space:]' < "$ROOT_DIR/.xcode-version")"
floor="${floor%%.*}"
while read -r macos version _; do
  case "$macos" in ''|'#'*) continue ;; esac
  [[ "${version%%.*}" == "$floor" ]] \
    || fail "scripts/ci/xcode-pins.txt pins Xcode $version for macOS $macos, outside the .xcode-version major $floor"
done < "$ROOT_DIR/scripts/ci/xcode-pins.txt"

echo "PASS: CI Xcode selection, pool pins, and the .xcode-version floor"
