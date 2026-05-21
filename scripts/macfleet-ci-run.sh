#!/usr/bin/env bash
set -euo pipefail

ref="${1:-main}"
mode="${2:-core-ci}"
root="${CMUX_CI_ROOT:-$HOME/cmux-ci}"
repo="$root/cmux"
spm="$root/spm-cache"
run_id="${CMUX_CI_RUN_ID:-$(hostname)-$(id -un)-$(date -u +%Y%m%dT%H%M%SZ)}"
safe_run_id="$(printf '%s' "$run_id" | tr -c 'A-Za-z0-9_.-' '-')"
derived="$root/DerivedData/$safe_run_id"
tmp_root="$root/tmp/$safe_run_id"
keep_derived="${CMUX_CI_KEEP_DERIVEDDATA:-0}"
xcodebuild_timeout="${CMUX_CI_XCODEBUILD_TIMEOUT_SECONDS:-2700}"
postgres_slot_hash="$(printf '%s' "$safe_run_id" | cksum | awk '{ print $1 % 200 }')"
postgres_port="${CMUX_CI_POSTGRES_PORT:-$((25432 + (($(id -u) - 500) * 200) + postgres_slot_hash))}"
postgres_data="$root/postgres-$safe_run_id-$postgres_port"
postgres_sock="$tmp_root/pg-socket"
postgres_log="$tmp_root/postgres.log"
pid_file="$tmp_root/pids"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="/opt/homebrew/opt/postgresql@16/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.cargo/bin:$PATH"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export TOOLCHAINS="${TOOLCHAINS:-com.apple.dt.toolchain.Metal.32023.864}"
export CMUX_SKIP_ZIG_BUILD="${CMUX_SKIP_ZIG_BUILD:-1}"
export SWIFT_BACKTRACE="${SWIFT_BACKTRACE:-enable=no,interactive=no,timeout=0s,color=no,symbolicate=off}"

log() {
  printf '[macfleet-ci] %s\n' "$*"
}

cleanup_current_run() {
  local code=$?
  if [ -f "$pid_file" ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      pkill -TERM -P "$pid" >/dev/null 2>&1 || true
      kill "$pid" >/dev/null 2>&1 || true
    done < "$pid_file"
  fi
  pkill -TERM -f "$derived" >/dev/null 2>&1 || true
  sleep 1
  pkill -KILL -f "$derived" >/dev/null 2>&1 || true
  if [ -d "$postgres_data" ]; then
    pg_ctl -D "$postgres_data" -m fast -w stop >/dev/null 2>&1 || true
    rm -rf "$postgres_data" || true
  fi
  if [ "$keep_derived" != "1" ] && [ -d "$derived" ]; then
    rm -rf "$derived" || true
  fi
  rm -rf "$tmp_root" || true
  exit "$code"
}
trap cleanup_current_run EXIT

track_pid() {
  mkdir -p "$tmp_root"
  printf '%s\n' "$1" >> "$pid_file"
}

untrack_pid() {
  local pid="$1"
  local tmp_file="$pid_file.tmp"
  [ -f "$pid_file" ] || return 0
  grep -vxF "$pid" "$pid_file" > "$tmp_file" 2>/dev/null || true
  mv "$tmp_file" "$pid_file" 2>/dev/null || true
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  "$@" &
  local pid=$!
  track_pid "$pid"
  local timeout_marker="$tmp_root/timeout-$pid.log"
  local restore_errexit=0
  case "$-" in
    *e*) restore_errexit=1 ;;
  esac

  (
    sleep "$timeout_seconds"
    if kill -0 "$pid" >/dev/null 2>&1; then
      echo "command timed out after ${timeout_seconds}s: $*" > "$timeout_marker"
      kill "$pid" >/dev/null 2>&1 || true
      sleep 5
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  ) >/dev/null 2>&1 &
  local watcher=$!
  track_pid "$watcher"

  set +e
  wait "$pid"
  local code=$?
  if [ "$restore_errexit" -eq 1 ]; then
    set -e
  else
    set +e
  fi
  pkill -TERM -P "$watcher" >/dev/null 2>&1 || true
  kill "$watcher" >/dev/null 2>&1 || true
  wait "$watcher" >/dev/null 2>&1 || true
  untrack_pid "$pid"
  untrack_pid "$watcher"
  if [ -f "$timeout_marker" ]; then
    cat "$timeout_marker" >&2
    return 124
  fi
  return "$code"
}

require_gui_session() {
  if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
    return 0
  fi

  cat >&2 <<EOF
mode=$mode requires an active GUI login session for user $(id -un) on $(hostname).
Connect that VNC slot first, or run a headless mode such as core-ci, release-build, or debug-build.
EOF
  exit 78
}

ensure_checkout() {
  mkdir -p "$root" "$spm" "$tmp_root" "$(dirname "$derived")"
  if [ ! -d "$repo/.git" ]; then
    git clone https://github.com/manaflow-ai/cmux.git "$repo"
  fi

  cd "$repo"
  git -c fetch.recurseSubmodules=false fetch --prune origin
  if git rev-parse --verify --quiet "origin/$ref" >/dev/null; then
    git checkout -B "ci-$ref" "origin/$ref"
  else
    git checkout --detach "$ref"
  fi
  git reset --hard
  git clean -ffdx -e .ci-source-packages -e .spm-cache -e GhosttyKit.xcframework
  git submodule update --init --recursive
}

ensure_toolchain() {
  if [ ! -d GhosttyKit.xcframework ]; then
    ./scripts/download-prebuilt-ghosttykit.sh
  fi
  ./scripts/install-zig-ci.sh
  ./scripts/install-rust-ci.sh
}

resolve_packages() {
  local scheme="${1:-cmux}"
  mkdir -p "$spm"
  for attempt in 1 2 3; do
    if run_with_timeout 600 xcodebuild -project cmux.xcodeproj -scheme "$scheme" -configuration Debug \
      -clonedSourcePackagesDirPath "$spm" \
      -resolvePackageDependencies; then
      return 0
    fi
    if [ "$attempt" -eq 3 ]; then
      echo "Failed to resolve Swift packages after 3 attempts" >&2
      exit 1
    fi
    log "Package resolution failed on attempt $attempt, retrying..."
    sleep $((attempt * 5))
  done
}

debug_build() {
  resolve_packages cmux
  run_with_timeout "$xcodebuild_timeout" xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
    -derivedDataPath "$derived" \
    -clonedSourcePackagesDirPath "$spm" \
    -disableAutomaticPackageResolution \
    -destination "platform=macOS,arch=arm64" \
    CODE_SIGNING_ALLOWED=NO \
    build
}

debug_build_with_log() {
  resolve_packages cmux
  run_with_timeout "$xcodebuild_timeout" xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
    -derivedDataPath "$derived" \
    -clonedSourcePackagesDirPath "$spm" \
    -disableAutomaticPackageResolution \
    -destination "platform=macOS" \
    CODE_SIGNING_ALLOWED=NO \
    build > "$tmp_root/cmux-build-output.txt" 2>&1
  cat "$tmp_root/cmux-build-output.txt"
}

release_build() {
  resolve_packages cmux
  run_with_timeout "$xcodebuild_timeout" xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Release \
    -derivedDataPath "$derived" \
    -destination "generic/platform=macOS" \
    -clonedSourcePackagesDirPath "$spm" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-Nightly \
    build
}

unit_test() {
  resolve_packages cmux-unit
  feed_xcodebuild_stdin() {
    while true; do
      printf '\n'
      sleep 1
    done
  }

  run_unit_tests() {
    # Xcode 16.4's XCTest memory checker crashes in WebKit teardown for these
    # MarkdownPanelTests on hosted and GUI-less runners, then retries until the
    # job timeout. Keep the quarantine narrow and explicit.
    set +e
    feed_xcodebuild_stdin | run_with_timeout "$xcodebuild_timeout" xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
      -derivedDataPath "$derived" \
      -clonedSourcePackagesDirPath "$spm" \
      -disableAutomaticPackageResolution \
      -destination "platform=macOS" \
      CMUX_SKIP_ZIG_BUILD=1 \
      -skip-testing:cmuxTests/AppDelegateShortcutRoutingTests/testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace \
      -skip-testing:cmuxTests/MarkdownPanelTests/testMarkdownRenderHandlesLocalImageSources \
      -skip-testing:cmuxTests/MarkdownPanelTests/testMarkdownRenderKeepsVisibleHeadingPositionAfterContentUpdate \
      -skip-testing:cmuxTests/MarkdownPanelTests/testMarkdownRenderLoadsSafeDataImage \
      test 2>&1
    local xcode_status=${PIPESTATUS[1]}
    set -e
    return "$xcode_status"
  }

  set +e
  run_unit_tests > "$tmp_root/test-output.txt" 2>&1
  local exit_code=$?
  local output
  output="$(cat "$tmp_root/test-output.txt")"
  cat "$tmp_root/test-output.txt"
  set -e

  if [ "$exit_code" -ne 0 ] && echo "$output" | grep -q "Could not resolve package dependencies"; then
    log "SwiftPM package resolution failed, clearing caches and retrying once"
    rm -rf "$HOME/Library/Caches/org.swift.swiftpm"
    mkdir -p "$HOME/Library/Caches/org.swift.swiftpm"
    rm -rf "$derived"
    set +e
    run_unit_tests > "$tmp_root/test-output.txt" 2>&1
    exit_code=$?
    output="$(cat "$tmp_root/test-output.txt")"
    cat "$tmp_root/test-output.txt"
    set -e
  fi

  if [ "$exit_code" -ne 0 ]; then
    local summary
    summary="$(echo "$output" | grep "Executed.*tests.*with.*failures" | tail -1 || true)"
    if echo "$summary" | grep -q "(0 unexpected)"; then
      log "All failures are expected, treating as pass"
    elif echo "$output" | grep -q "command timed out after" && echo "$output" | grep -q "Test Suite 'Selected tests' passed"; then
      log "xcodebuild hung after completing a selected test shard, treating as pass"
    else
      echo "Unexpected test failures detected" >&2
      return "$exit_code"
    fi
  fi
}

ci_tests_job() {
  require_gui_session
  ensure_toolchain
  unit_test
  CMUX_SOURCE_PACKAGES_DIR="$spm" ./tests/test_bundled_ghostty_theme_picker_helper.sh

  local cli_bin
  cli_bin="$(
    find "$derived" -path "*/Build/Products/Debug/cmux" -exec stat -f '%m %N' {} \; 2>/dev/null \
      | sort -nr \
      | head -1 \
      | cut -d' ' -f2-
  )"
  if [ -z "${cli_bin:-}" ] || [ ! -x "$cli_bin" ]; then
    echo "cmux CLI binary not found in $derived" >&2
    exit 1
  fi

  CMUX_CLI_BIN="$cli_bin" python3 tests/test_cli_version_memory_guard.py
  CMUX_CLI_BIN="$cli_bin" python3 tests/test_cli_contract_help.py
  CMUX_CLI_BIN="$cli_bin" python3 tests/test_cli_layout_focus_contract.py
  CMUX_CLI_BIN="$cli_bin" python3 tests/test_cli_socket_operation_deadline.py
  CMUX_CLI_BIN="$cli_bin" python3 tests/test_cli_omo_openagent_plugin_migration.py
  CMUX_CLI_BIN="$cli_bin" python3 tests/test_cli_socket_autodiscovery.py
  python3 tests/test_claude_wrapper_hooks.py
  CMUX_CLI_BIN="$cli_bin" python3 tests/test_claude_hook_stop_last_assistant.py
  CMUX_CLI_BIN="$cli_bin" python3 tests/test_claude_hook_clear_running_status.py
  CMUX_CLI_BIN="$cli_bin" python3 tests/test_pi_extension_install.py
}

app_path() {
  find "$derived" -path "*/Build/Products/Debug/cmux DEV.app" -type d -print -quit
}

tests_build_and_lag() {
  require_gui_session
  ensure_toolchain
  debug_build_with_log
  python3 scripts/swift_warning_budget.py --log "$tmp_root/cmux-build-output.txt"

  local app
  app="$(app_path)"
  if [ -z "${app:-}" ] || [ ! -d "$app" ]; then
    echo "cmux DEV.app not found in $derived" >&2
    exit 1
  fi

  CMUX_ALLOW_UNTAGGED_CA_REGRESSION=1 \
  CMUX_CA_ASSERT_HOLD_SECONDS=15 \
  CMUX_TAG="ci-ca-main-thread-$run_id" \
  ./scripts/verify-main-thread-ca-transactions.sh "$app"

  local helper="$tmp_root/create-virtual-display"
  clang -framework Foundation -framework CoreGraphics \
    -o "$helper" scripts/create-virtual-display.m
  "$helper" > "$tmp_root/create-virtual-display.log" 2>&1 &
  local vdisplay_pid=$!
  track_pid "$vdisplay_pid"
  for _ in $(seq 1 12); do
    if kill -0 "$vdisplay_pid" 2>/dev/null; then
      break
    fi
    sleep 0.25
  done
  kill -0 "$vdisplay_pid"

  local tag="ci-lag-$run_id"
  local sock="/tmp/cmux-debug-${tag}.sock"
  local bundle_id
  bundle_id="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null \
      || echo 'com.cmuxterm.app.debug'
  )"

  pkill -x "cmux DEV" || true
  rm -f "$sock" "/tmp/cmux-${tag}.sock" || true
  defaults write "$bundle_id" socketControlMode -string full >/dev/null 2>&1 || true

  CMUX_TAG="$tag" CMUX_SOCKET_PATH="$sock" CMUX_UI_TEST_MODE=1 "$app/Contents/MacOS/cmux DEV" >"$tmp_root/cmux-ci-lag.log" 2>&1 &
  local app_pid=$!
  track_pid "$app_pid"
  for _ in $(seq 1 240); do
    [ -S "$sock" ] && break
    sleep 0.25
  done
  [ -S "$sock" ] || { echo "Socket not ready at $sock" >&2; exit 1; }

  CMUX_SOCKET_PATH="$sock" \
  CMUX_LAG_MAX_P95_RATIO=1.70 \
  CMUX_LAG_MAX_AVG_RATIO=1.70 \
  CMUX_LAG_MIN_BASELINE_P95_MS_FOR_RATIO=6.0 \
  CMUX_LAG_MIN_BASELINE_AVG_MS_FOR_RATIO=4.0 \
  CMUX_LAG_MAX_P95_DELTA_MS=20.0 \
  CMUX_LAG_MAX_AVG_DELTA_MS=12.0 \
  CMUX_LAG_MAX_CHURN_P95_MS=35 \
  CMUX_LAG_KEY_EVENTS=180 \
  python3 tests/test_workspace_churn_up_arrow_lag.py

  kill "$app_pid" >/dev/null 2>&1 || true
  untrack_pid "$app_pid"
  kill "$vdisplay_pid" >/dev/null 2>&1 || true
  untrack_pid "$vdisplay_pid"
}

ui_regressions() {
  require_gui_session
  ensure_toolchain
  resolve_packages cmux
  run_with_timeout "$xcodebuild_timeout" xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
    -derivedDataPath "$derived" \
    -clonedSourcePackagesDirPath "$spm" \
    -disableAutomaticPackageResolution \
    -destination "platform=macOS" \
    build-for-testing

  local helper="$tmp_root/create-virtual-display"
  clang -framework Foundation -framework CoreGraphics \
    -o "$helper" scripts/create-virtual-display.m

  local persistent_ready="/tmp/cmux-vdisplay-persistent-$run_id.ready"
  local persistent_id="/tmp/cmux-vdisplay-persistent-$run_id.id"
  local persistent_log="$tmp_root/cmux-vdisplay-persistent.log"
  rm -f "$persistent_ready" "$persistent_id"
  "$helper" \
    --modes "1920x1080" \
    --ready-path "$persistent_ready" \
    --display-id-path "$persistent_id" \
    > "$persistent_log" 2>&1 &
  local persistent_pid=$!
  track_pid "$persistent_pid"

  for _ in $(seq 1 24); do
    [ -f "$persistent_ready" ] && break
    sleep 0.5
  done
  if [ ! -f "$persistent_ready" ]; then
    echo "Persistent virtual display not ready" >&2
    cat "$persistent_log" >&2 || true
    exit 1
  fi

  local diag_path="/tmp/cmux-ui-test-display-churn-${run_id}.json"
  local display_ready="/tmp/cmux-ui-test-display-${run_id}.ready"
  local display_id_path="/tmp/cmux-ui-test-display-${run_id}.id"
  local display_done="/tmp/cmux-ui-test-display-${run_id}.done"
  local helper_log="$tmp_root/cmux-ui-test-display-helper.log"
  local manifest_path="/tmp/cmux-ui-test-display-harness-${run_id}.json"
  local prelaunch_path="/tmp/cmux-ui-test-prelaunch-${run_id}.json"
  local app_binary
  app_binary="$(find "$derived" -path "*/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV" -print -quit 2>/dev/null || true)"
  if [ -z "$app_binary" ]; then
    echo "App binary not found in $derived" >&2
    exit 1
  fi

  for attempt in 1 2; do
    pkill -x "cmux DEV" 2>/dev/null || true
    rm -f "$diag_path" "$display_ready" "$display_id_path" "$display_done" "$helper_log" "$manifest_path" "$prelaunch_path"

    "$helper" \
      --modes "1920x1080,1728x1117,1600x900,1440x810" \
      --ready-path "$display_ready" \
      --display-id-path "$display_id_path" \
      --done-path "$display_done" \
      --iterations 40 \
      --interval-ms 40 \
      --start-delay-ms 10000 \
      > "$helper_log" 2>&1 &
    local helper_pid=$!
    track_pid "$helper_pid"

    for _ in $(seq 1 24); do
      [ -f "$display_ready" ] && break
      sleep 0.5
    done
    if [ ! -f "$display_ready" ]; then
      cat "$helper_log" >&2 || true
      kill "$helper_pid" >/dev/null 2>&1 || true
      untrack_pid "$helper_pid"
      continue
    fi

    local display_id
    display_id="$(cat "$display_id_path")"
    CMUX_UI_TEST_MODE=1 \
    CMUX_UI_TEST_DIAGNOSTICS_PATH="$diag_path" \
    CMUX_UI_TEST_DISPLAY_RENDER_STATS=1 \
    CMUX_UI_TEST_TARGET_DISPLAY_ID="$display_id" \
    CMUX_TAG="ui-tests-display-resolution-$run_id" \
    "$app_binary" > "$tmp_root/cmux-ui-test-app.log" 2>&1 &
    local app_pid=$!
    track_pid "$app_pid"

    local app_ready=false
    for _ in $(seq 1 30); do
      if [ -f "$diag_path" ] && python3 -c "import json; d=json.load(open('$diag_path')); assert d.get('pid')" 2>/dev/null; then
        app_ready=true
        break
      fi
      if ! kill -0 "$app_pid" 2>/dev/null; then
        break
      fi
      sleep 0.5
    done

    if [ "$app_ready" != "true" ]; then
      pkill -x "cmux DEV" 2>/dev/null || true
      kill "$helper_pid" >/dev/null 2>&1 || true
      untrack_pid "$helper_pid"
      if [ "$attempt" -eq 2 ]; then
        echo "Display resolution UI regression failed to prepare" >&2
        cat "$tmp_root/cmux-ui-test-app.log" >&2 || true
        cat "$helper_log" >&2 || true
        exit 1
      fi
      sleep 3
      continue
    fi

    for _ in $(seq 1 40); do
      if python3 -c "import json; d=json.load(open('$diag_path')); assert d.get('renderStatsAvailable') == '1'" 2>/dev/null; then
        break
      fi
      sleep 0.5
    done

    printf '{"readyPath":"%s","displayIDPath":"%s","donePath":"%s","logPath":"%s"}\n' \
      "$display_ready" "$display_id_path" "$display_done" "$helper_log" > "$manifest_path"
    printf '{"diagnosticsPath":"%s"}\n' "$diag_path" > "$prelaunch_path"
    cp "$manifest_path" /tmp/cmux-ui-test-display-harness.json
    cp "$prelaunch_path" /tmp/cmux-ui-test-prelaunch.json

    if run_with_timeout "$xcodebuild_timeout" xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
      -derivedDataPath "$derived" \
      -clonedSourcePackagesDirPath "$spm" \
      -disableAutomaticPackageResolution \
      -destination "platform=macOS" \
      -only-testing:cmuxUITests/DisplayResolutionRegressionUITests \
      test-without-building; then
      break
    fi

    pkill -x "cmux DEV" 2>/dev/null || true
    kill "$helper_pid" >/dev/null 2>&1 || true
    untrack_pid "$helper_pid"
    if [ "$attempt" -eq 2 ]; then
      echo "Display resolution UI regression failed after 2 attempts" >&2
      exit 1
    fi
    sleep 3
  done

  run_with_timeout "$xcodebuild_timeout" xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
    -derivedDataPath "$derived" \
    -clonedSourcePackagesDirPath "$spm" \
    -disableAutomaticPackageResolution \
    -destination "platform=macOS" \
    -maximum-test-execution-time-allowance 180 \
    -only-testing:cmuxUITests/BrowserPaneNavigationKeybindUITests/testCmdFOpensBrowserFindAfterCmdDCmdLNavigation \
    test-without-building

  pkill -x "cmux DEV" 2>/dev/null || true
  if [ -n "${app_pid:-}" ]; then
    untrack_pid "$app_pid"
  fi
  if [ -n "${helper_pid:-}" ]; then
    untrack_pid "$helper_pid"
  fi
  kill "$persistent_pid" >/dev/null 2>&1 || true
  untrack_pid "$persistent_pid"
  rm -f "$persistent_ready" "$persistent_id" /tmp/cmux-ui-test-display-harness.json /tmp/cmux-ui-test-prelaunch.json
}

workflow_guards() {
  ./tests/test_ci_self_hosted_guard.sh
  ./tests/test_ci_create_dmg_pinned.sh
  ./tests/test_ci_unit_test_spm_retry.sh
  ./tests/test_ci_scheme_testaction_debug.sh
  ./tests/test_ci_ghosttykit_checksum_verification.sh
  ./tests/test_ci_ghosttykit_checksum_present.sh
  ./tests/test_ci_swift_warning_budget.sh
  ./tests/test_ci_swift_file_length_budget.sh
  ./tests/test_ci_auxiliary_window_close_shortcuts.sh
  node scripts/release_asset_guard.test.js
}

remote_daemon_tests() {
  (cd daemon/remote && go test ./...)
  ./tests/test_remote_daemon_release_assets.sh
}

web_typecheck() {
  (cd web && bun install --frozen-lockfile && bun tsc --noEmit && bun test)
}

start_postgres() {
  command -v initdb >/dev/null || {
    echo "postgresql@16 is not installed on $(hostname)" >&2
    exit 1
  }

  mkdir -p "$tmp_root" "$postgres_sock"
  if [ ! -d "$postgres_data/base" ]; then
    rm -rf "$postgres_data"
    initdb -D "$postgres_data" -U "$(id -un)" --auth=trust >/dev/null
  fi

  pg_ctl -D "$postgres_data" -m fast -w stop >/dev/null 2>&1 || true
  pg_ctl -D "$postgres_data" \
    -o "-p $postgres_port -h 127.0.0.1 -k $postgres_sock" \
    -l "$postgres_log" \
    -w start

  psql -h 127.0.0.1 -p "$postgres_port" -d postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cmux') THEN
    CREATE ROLE cmux LOGIN PASSWORD 'cmux';
  END IF;
END
\$\$;
SQL
  dropdb -h 127.0.0.1 -p "$postgres_port" -U "$(id -un)" --if-exists cmux_test >/dev/null 2>&1 || true
  createdb -h 127.0.0.1 -p "$postgres_port" -U "$(id -un)" -O cmux cmux_test
}

web_db_migrations() {
  start_postgres
  (
    cd web
    bun install --frozen-lockfile
    export DATABASE_URL="postgres://cmux:cmux@127.0.0.1:$postgres_port/cmux_test"
    export DIRECT_DATABASE_URL="$DATABASE_URL"
    bunx drizzle-kit migrate --config drizzle.config.ts
    bunx drizzle-kit migrate --config drizzle.config.ts
    CMUX_DB_TEST=1 bun test tests/db-schema.test.ts
    CMUX_DB_TEST=1 bun test tests/drizzle-effect.test.ts
    CMUX_DB_TEST=1 bun test tests/vm-db-read-model.test.ts
  )
}

core_ci() {
  workflow_guards
  remote_daemon_tests
  web_typecheck
  web_db_migrations
}

full_ci() {
  require_gui_session
  core_ci
  ci_tests_job
  tests_build_and_lag
  release_build
  ui_regressions
}

if [ "$mode" = "cleanup" ]; then
  if [ -x /opt/cmux/macfleet-cleanup.sh ]; then
    /opt/cmux/macfleet-cleanup.sh
  else
    "$script_dir/macfleet-cleanup.sh"
  fi
  exit 0
fi

ensure_checkout

case "$mode" in
  workflow-guards)
    workflow_guards
    ;;
  remote-daemon)
    remote_daemon_tests
    ;;
  web)
    web_typecheck
    ;;
  web-db-migrations)
    web_db_migrations
    ;;
  core-ci)
    core_ci
    ;;
  debug-build)
    ensure_toolchain
    debug_build
    ;;
  release-build)
    ensure_toolchain
    release_build
    ;;
  unit-test)
    ensure_toolchain
    unit_test
    ;;
  tests)
    ci_tests_job
    ;;
  tests-build-and-lag)
    tests_build_and_lag
    ;;
  ui-regressions)
    ui_regressions
    ;;
  full-ci)
    full_ci
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac

echo "CMUX_CI_OK host=$(hostname) user=$(id -un) mode=$mode ref=$ref derived=$derived"
