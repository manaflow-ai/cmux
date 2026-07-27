#!/usr/bin/env bash
set -euo pipefail

: "${CMUX_DERIVED_DATA_PATH:?CMUX_DERIVED_DATA_PATH is required}"
SOURCE_PACKAGES_DIR="${CMUX_SOURCE_PACKAGES_DIR:-$PWD/.ci-source-packages}"

DRC_HELPER_PATH=""
DRC_DIAG_PATH=""
DRC_DISPLAY_READY=""
DRC_DISPLAY_ID_PATH=""
DRC_DISPLAY_START=""
DRC_DISPLAY_DONE=""
DRC_HELPER_LOG=""
DRC_XCODEBUILD_LOG=""
DRC_HELPER_PID=""
DRC_START_SIGNAL_PID=""
DRC_DISPLAY_LOCK_DIR=""
DRC_DISPLAY_LOCK_TOKEN=""

PERSISTENT_HELPER_PATH=""
PERSISTENT_READY=""
PERSISTENT_ID_PATH=""
PERSISTENT_LOG=""
PERSISTENT_PID=""
PERSISTENT_LOCK_DIR=""
PERSISTENT_LOCK_TOKEN=""

release_lock() {
  local lock_dir="$1"
  local lock_token="$2"
  if [ -n "$lock_dir" ]; then
    CMUX_VDISPLAY_LOCK_DIR="$lock_dir" \
      CMUX_VDISPLAY_LOCK_TOKEN="$lock_token" \
      scripts/ci/virtual-display-lock.sh release || true
  fi
}

cleanup_display_churn() {
  if [ -n "${DRC_START_SIGNAL_PID:-}" ]; then
    kill "$DRC_START_SIGNAL_PID" 2>/dev/null || true
    wait "$DRC_START_SIGNAL_PID" 2>/dev/null || true
    DRC_START_SIGNAL_PID=""
  fi
  if [ -n "${DRC_HELPER_PID:-}" ]; then
    kill "$DRC_HELPER_PID" 2>/dev/null || true
    wait "$DRC_HELPER_PID" 2>/dev/null || true
    DRC_HELPER_PID=""
  fi
  release_lock "$DRC_DISPLAY_LOCK_DIR" "$DRC_DISPLAY_LOCK_TOKEN"
  DRC_DISPLAY_LOCK_DIR=""
  DRC_DISPLAY_LOCK_TOKEN=""
  pkill -x "cmux DEV" 2>/dev/null || true
  rm -f "$DRC_DIAG_PATH" "$DRC_DISPLAY_READY" "$DRC_DISPLAY_ID_PATH" "$DRC_DISPLAY_START" "$DRC_DISPLAY_DONE" "$DRC_HELPER_LOG" "$DRC_XCODEBUILD_LOG"
  rm -f /tmp/cmux-ui-test-prelaunch.json /tmp/cmux-ui-test-display-harness.json
}

cleanup_persistent_display() {
  if [ -n "${PERSISTENT_PID:-}" ]; then
    kill "$PERSISTENT_PID" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
      kill -0 "$PERSISTENT_PID" >/dev/null 2>&1 || break
      sleep 0.1
    done
    PERSISTENT_PID=""
  fi
  release_lock "$PERSISTENT_LOCK_DIR" "$PERSISTENT_LOCK_TOKEN"
  PERSISTENT_LOCK_DIR=""
  PERSISTENT_LOCK_TOKEN=""
  rm -f "$PERSISTENT_HELPER_PATH" "$PERSISTENT_READY" "$PERSISTENT_ID_PATH" "$PERSISTENT_LOG"
}

cleanup_all() {
  cleanup_display_churn
  cleanup_persistent_display
  rm -f "$DRC_HELPER_PATH"
}
trap cleanup_all EXIT

enable_xctest_automation_mode() {
  if ! command -v automationmodetool >/dev/null 2>&1; then
    echo "::warning::automationmodetool is unavailable; XCTest will use its default automation-mode setup"
    return 0
  fi

  if sudo -n true 2>/dev/null; then
    sudo -n automationmodetool enable-automationmode-without-authentication
  else
    echo "::warning::Passwordless sudo unavailable; XCTest will use its default automation-mode setup"
  fi
}

find_app_binary() {
  find "$CMUX_DERIVED_DATA_PATH" -path "*/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV" -print -quit 2>/dev/null || true
}

run_display_resolution_churn() {
  local token app_binary display_id app_pid app_ready render_ready xcodebuild_ok
  token="$(uuidgen)"
  DRC_HELPER_PATH="$RUNNER_TEMP/create-virtual-display-display-churn-${token}"
  DRC_DIAG_PATH="/tmp/cmux-ui-test-display-churn-${token}.json"
  DRC_DISPLAY_READY="/tmp/cmux-ui-test-display-${token}.ready"
  DRC_DISPLAY_ID_PATH="/tmp/cmux-ui-test-display-${token}.id"
  DRC_DISPLAY_START="/tmp/cmux-ui-test-display-${token}.start"
  DRC_DISPLAY_DONE="/tmp/cmux-ui-test-display-${token}.done"
  DRC_HELPER_LOG="/tmp/cmux-ui-test-display-${token}-helper.log"
  DRC_XCODEBUILD_LOG="/tmp/cmux-ui-test-display-${token}-xcodebuild.log"
  local baseline_ready_marker="CMUX_DISPLAY_CHURN_BASELINE_READY_${token}"

  clang -framework Foundation -framework CoreGraphics \
    -o "$DRC_HELPER_PATH" scripts/create-virtual-display.m

  app_binary="$(find_app_binary)"
  if [ -z "$app_binary" ]; then
    echo "ERROR: App binary not found in DerivedData" >&2
    exit 1
  fi
  echo "App binary: $app_binary"

  for attempt in 1 2; do
    cleanup_display_churn 2>/dev/null || true

    local lock_env
    lock_env="$(scripts/ci/virtual-display-lock.sh acquire)"
    eval "$lock_env"
    export CMUX_VDISPLAY_LOCK_DIR CMUX_VDISPLAY_LOCK_TOKEN
    DRC_DISPLAY_LOCK_DIR="$CMUX_VDISPLAY_LOCK_DIR"
    DRC_DISPLAY_LOCK_TOKEN="$CMUX_VDISPLAY_LOCK_TOKEN"

    scripts/ci/virtual-display-lock.sh reap-strays || true

    "$DRC_HELPER_PATH" \
      --modes "1920x1080,1728x1117,1600x900,1440x810" \
      --ready-path "$DRC_DISPLAY_READY" \
      --display-id-path "$DRC_DISPLAY_ID_PATH" \
      --start-path "$DRC_DISPLAY_START" \
      --done-path "$DRC_DISPLAY_DONE" \
      --iterations 40 \
      --interval-ms 40 \
      > "$DRC_HELPER_LOG" 2>&1 &
    DRC_HELPER_PID=$!
    scripts/ci/virtual-display-lock.sh set-owner "$DRC_HELPER_PID"

    echo "Waiting for virtual display..."
    local display_ready_ok=false
    for _ in $(seq 1 100); do
      if [ -s "$DRC_DISPLAY_READY" ] && [ -s "$DRC_DISPLAY_ID_PATH" ]; then
        display_ready_ok=true
        break
      fi
      if ! kill -0 "$DRC_HELPER_PID" 2>/dev/null; then
        echo "ERROR: Virtual display helper exited before readiness" >&2
        cat "$DRC_HELPER_LOG" 2>/dev/null || true
        break
      fi
      sleep 0.1
    done
    if [ "$display_ready_ok" != "true" ]; then
      echo "ERROR: Virtual display not ready after 10s" >&2
      cat "$DRC_HELPER_LOG" 2>/dev/null || true
      cleanup_display_churn
      if [ "$attempt" -eq 2 ]; then
        echo "Display resolution UI regression failed after 2 virtual display setup attempts" >&2
        exit 1
      fi
      sleep 3
      continue
    fi

    display_id="$(tr -d '\n' < "$DRC_DISPLAY_ID_PATH")"
    echo "Virtual display ready: ID=$display_id"

    CMUX_UI_TEST_MODE=1 \
      CMUX_UI_TEST_DIAGNOSTICS_PATH="$DRC_DIAG_PATH" \
      CMUX_UI_TEST_DISPLAY_RENDER_STATS=1 \
      CMUX_UI_TEST_TARGET_DISPLAY_ID="$display_id" \
      CMUX_TAG="ui-tests-display-resolution" \
      "$app_binary" > /tmp/cmux-ui-test-app.log 2>&1 &
    app_pid=$!
    echo "App launched: PID=$app_pid"

    echo "Waiting for app diagnostics..."
    app_ready=false
    for _ in $(seq 1 30); do
      if [ -f "$DRC_DIAG_PATH" ]; then
        if python3 -c "import json; d=json.load(open('$DRC_DIAG_PATH')); assert d.get('pid')" 2>/dev/null; then
          app_ready=true
          break
        fi
      fi
      if ! kill -0 "$app_pid" 2>/dev/null; then
        echo "ERROR: App crashed during startup"
        cat /tmp/cmux-ui-test-app.log 2>/dev/null | tail -30 || true
        break
      fi
      sleep 0.5
    done

    if [ "$app_ready" != "true" ]; then
      echo "Attempt $attempt: App not ready after 15s"
      pkill -x "cmux DEV" 2>/dev/null || true
      kill "$DRC_HELPER_PID" 2>/dev/null || true
      if [ "$attempt" -eq 2 ]; then
        echo "Display resolution UI regression failed after 2 attempts" >&2
        echo "--- App log ---"
        cat /tmp/cmux-ui-test-app.log 2>/dev/null | tail -50 || true
        echo "--- Helper log ---"
        cat "$DRC_HELPER_LOG" 2>/dev/null | tail -20 || true
        echo "--- Diagnostics ---"
        cat "$DRC_DIAG_PATH" 2>/dev/null || echo "(not found)"
        exit 1
      fi
      sleep 3
      continue
    fi

    echo "App started. Diagnostics:"
    cat "$DRC_DIAG_PATH"

    echo "Waiting for render stats..."
    render_ready=false
    for i in $(seq 1 40); do
      if python3 -c "import json; d=json.load(open('$DRC_DIAG_PATH')); assert d.get('renderStatsAvailable') == '1'" 2>/dev/null; then
        render_ready=true
        echo "Render stats available after $((i / 2))s"
        break
      fi
      sleep 0.5
    done
    if [ "$render_ready" != "true" ]; then
      echo "WARNING: Render stats not available after 20s. Diagnostics:"
      cat "$DRC_DIAG_PATH" 2>/dev/null || true
      echo "--- App log ---"
      cat /tmp/cmux-ui-test-app.log 2>/dev/null | tail -30 || true
    fi

    cat >"/tmp/cmux-ui-test-display-harness.json" <<MANIFEST_EOF
{"readyPath":"$DRC_DISPLAY_READY","displayIDPath":"$DRC_DISPLAY_ID_PATH","startPath":"$DRC_DISPLAY_START","donePath":"$DRC_DISPLAY_DONE","logPath":"$DRC_HELPER_LOG"}
MANIFEST_EOF

    cat >"/tmp/cmux-ui-test-prelaunch.json" <<PRELAUNCH_EOF
{"diagnosticsPath":"$DRC_DIAG_PATH","baselineReadyMarker":"$baseline_ready_marker"}
PRELAUNCH_EOF

    (
      for _ in $(seq 1 480); do
        if grep -Fq "$baseline_ready_marker" "$DRC_XCODEBUILD_LOG" 2>/dev/null; then
          echo "XCTest baseline marker observed; starting display churn"
          printf 'start\n' > "$DRC_DISPLAY_START"
          exit 0
        fi
        sleep 0.25
      done
      echo "ERROR: XCTest baseline marker not observed before display-churn start timeout" >&2
      echo "--- xcodebuild log tail ---" >&2
      tail -80 "$DRC_XCODEBUILD_LOG" >&2 2>/dev/null || true
      echo "--- diagnostics ---" >&2
      cat "$DRC_DIAG_PATH" >&2 2>/dev/null || true
      exit 1
    ) &
    DRC_START_SIGNAL_PID=$!

    xcodebuild_ok=false
    if xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
      -derivedDataPath "$CMUX_DERIVED_DATA_PATH" \
      -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
      -disableAutomaticPackageResolution \
      -destination "platform=macOS" \
      -only-testing:cmuxUITests/DisplayResolutionRegressionUITests \
      test-without-building 2>&1 | tee "$DRC_XCODEBUILD_LOG"; then
      xcodebuild_ok=true
    fi

    if [ -n "${DRC_START_SIGNAL_PID:-}" ]; then
      kill "$DRC_START_SIGNAL_PID" 2>/dev/null || true
      wait "$DRC_START_SIGNAL_PID" 2>/dev/null || true
      DRC_START_SIGNAL_PID=""
    fi

    if [ "$xcodebuild_ok" = "true" ]; then
      cleanup_display_churn
      return 0
    fi

    cleanup_display_churn

    if [ "$attempt" -eq 2 ]; then
      echo "Display resolution UI regression failed after 2 attempts" >&2
      exit 1
    fi
    echo "Attempt $attempt failed, retrying..."
    sleep 3
  done
}

create_persistent_display() {
  local lock_env
  lock_env="$(scripts/ci/virtual-display-lock.sh acquire)"
  eval "$lock_env"
  export CMUX_VDISPLAY_LOCK_DIR CMUX_VDISPLAY_LOCK_TOKEN
  PERSISTENT_LOCK_DIR="$CMUX_VDISPLAY_LOCK_DIR"
  PERSISTENT_LOCK_TOKEN="$CMUX_VDISPLAY_LOCK_TOKEN"

  PERSISTENT_HELPER_PATH="$RUNNER_TEMP/create-virtual-display-persistent"
  clang -framework Foundation -framework CoreGraphics \
    -o "$PERSISTENT_HELPER_PATH" scripts/create-virtual-display.m

  PERSISTENT_READY="$RUNNER_TEMP/cmux-vdisplay-persistent.ready"
  PERSISTENT_ID_PATH="$RUNNER_TEMP/cmux-vdisplay-persistent.id"
  PERSISTENT_LOG="$RUNNER_TEMP/cmux-vdisplay-persistent.log"
  rm -f "$PERSISTENT_READY" "$PERSISTENT_ID_PATH" "$PERSISTENT_LOG"

  scripts/ci/virtual-display-lock.sh reap-strays || true

  "$PERSISTENT_HELPER_PATH" \
    --modes "1920x1080" \
    --ready-path "$PERSISTENT_READY" \
    --display-id-path "$PERSISTENT_ID_PATH" \
    >"$PERSISTENT_LOG" 2>&1 &
  PERSISTENT_PID=$!
  scripts/ci/virtual-display-lock.sh set-owner "$PERSISTENT_PID"

  echo "Waiting for persistent virtual display..."
  for _ in $(seq 1 100); do
    if [ -s "$PERSISTENT_READY" ] && [ -s "$PERSISTENT_ID_PATH" ]; then
      break
    fi
    if ! kill -0 "$PERSISTENT_PID" 2>/dev/null; then
      echo "Persistent virtual display helper exited before readiness" >&2
      cat "$PERSISTENT_LOG" >&2 || true
      exit 1
    fi
    sleep 0.1
  done

  if [ ! -s "$PERSISTENT_READY" ] || [ ! -s "$PERSISTENT_ID_PATH" ]; then
    echo "ERROR: Persistent virtual display not ready after 10s" >&2
    cat "$PERSISTENT_LOG" >&2 || true
    exit 1
  fi

  echo "Persistent virtual display ready: ID=$(tr -d '\n' < "$PERSISTENT_ID_PATH")"
  cat "$PERSISTENT_LOG"
}

run_browser_find_focus() {
  local persistent_display_id
  if [ -n "${PERSISTENT_PID:-}" ] && ! kill -0 "$PERSISTENT_PID" 2>/dev/null; then
    echo "Persistent virtual display exited before browser find UI regression" >&2
    cat "${PERSISTENT_LOG:-/dev/null}" >&2 || true
    exit 1
  fi
  if [ ! -s "${PERSISTENT_ID_PATH:-}" ]; then
    echo "Persistent virtual display ID missing before browser find UI regression" >&2
    exit 1
  fi
  persistent_display_id="$(tr -d '\n' < "$PERSISTENT_ID_PATH")"

  CMUX_UI_TEST_TARGET_DISPLAY_ID="$persistent_display_id" \
    xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
    -derivedDataPath "$CMUX_DERIVED_DATA_PATH" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
    -disableAutomaticPackageResolution \
    -destination "platform=macOS" \
    -maximum-test-execution-time-allowance 180 \
    -only-testing:cmuxUITests/BrowserPaneNavigationKeybindUITests/testCmdFOpensBrowserFindAfterCmdDCmdLNavigation \
    test-without-building
}

enable_xctest_automation_mode
run_display_resolution_churn
create_persistent_display
run_browser_find_focus
