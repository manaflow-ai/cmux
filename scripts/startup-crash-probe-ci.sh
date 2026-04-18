#!/usr/bin/env bash
set -euo pipefail

ITERATIONS="${ITERATIONS:-8}"
STABILITY_SECONDS="${STABILITY_SECONDS:-8}"
APP_ICON_MODES="${APP_ICON_MODES:-automatic light dark}"
LOG_DIR="${TMPDIR:-/tmp}/cmux-startup-crash-probe-logs"

mkdir -p "$LOG_DIR"

APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/cmux DEV.app" -print -quit 2>/dev/null || true)"
if [[ -z "$APP_PATH" ]]; then
  echo "ERROR: could not find built cmux DEV.app in DerivedData" >&2
  exit 1
fi

BINARY_PATH="$APP_PATH/Contents/MacOS/cmux DEV"
if [[ ! -x "$BINARY_PATH" ]]; then
  echo "ERROR: missing executable at $BINARY_PATH" >&2
  exit 1
fi

HOST_HOME="$HOME"

write_settings_fixture() {
  local target_home="$1"
  local mode="$2"
  local config_dir="$target_home/.config/cmux"
  local fallback_dir="$target_home/Library/Application Support/com.cmuxterm.app"

  mkdir -p "$config_dir" "$fallback_dir"

  cat > "$config_dir/settings.json" <<EOF
{
  "schemaVersion": 1,
  "app": {
    "appIcon": "$mode"
  }
}
EOF

  # Also write the fallback path that CmuxSettingsFileStore knows about.
  cp "$config_dir/settings.json" "$fallback_dir/settings.json"
}

print_crash_diagnostics() {
  local test_home="$1"

  echo "=== Recent DiagnosticReports in test HOME ==="
  ls -lt "$test_home/Library/Logs/DiagnosticReports" 2>/dev/null | head -n 5 || echo "(none)"

  echo "=== Recent DiagnosticReports in host HOME ==="
  ls -lt "$HOST_HOME/Library/Logs/DiagnosticReports" 2>/dev/null | head -n 5 || echo "(none)"

  local latest
  latest="$(
    ls -t \
      "$test_home"/Library/Logs/DiagnosticReports/*cmux* \
      "$HOST_HOME"/Library/Logs/DiagnosticReports/*cmux* 2>/dev/null | head -n 1 || true
  )"
  if [[ -n "$latest" ]]; then
    echo "=== Crash excerpt ($latest) ==="
    sed -n '1,120p' "$latest" || true
  fi
}

echo "=== Startup crash probe ==="
echo "App path: $APP_PATH"
echo "Iterations: $ITERATIONS"
echo "Modes: $APP_ICON_MODES"
echo "Stability seconds per launch: $STABILITY_SECONDS"

for iteration in $(seq 1 "$ITERATIONS"); do
  for mode in $APP_ICON_MODES; do
    probe_home="$(mktemp -d "${TMPDIR:-/tmp}/cmux-startup-probe-home.${iteration}.${mode}.XXXXXX")"
    write_settings_fixture "$probe_home" "$mode"

    tag="startup-probe-${mode}-${iteration}-${RANDOM}"
    log_file="$LOG_DIR/${iteration}-${mode}.log"

    echo "--- Launch iteration=$iteration mode=$mode tag=$tag ---"
    HOME="$probe_home" CMUX_TAG="$tag" CMUX_SOCKET_MODE=allowAll "$BINARY_PATH" >"$log_file" 2>&1 &
    app_pid=$!

    launch_failed=0
    deadline=$((SECONDS + STABILITY_SECONDS))
    while [[ $SECONDS -lt $deadline ]]; do
      if ! kill -0 "$app_pid" 2>/dev/null; then
        launch_failed=1
        break
      fi
      sleep 0.25
    done

    if [[ "$launch_failed" -eq 1 ]]; then
      echo "ERROR: app exited early for iteration=$iteration mode=$mode tag=$tag" >&2
      echo "=== App log ($log_file) ==="
      tail -n 200 "$log_file" || true
      print_crash_diagnostics "$probe_home"
      rm -rf "$probe_home"
      exit 1
    fi

    if kill -0 "$app_pid" 2>/dev/null; then
      kill "$app_pid" 2>/dev/null || true
      wait "$app_pid" 2>/dev/null || true
    fi

    rm -rf "$probe_home"
  done
done

echo "=== Startup crash probe passed ==="
