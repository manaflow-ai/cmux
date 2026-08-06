#!/usr/bin/env bash
set -euo pipefail

ci_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/app-host-isolation.sh
source "$ci_script_dir/app-host-isolation.sh"

if [ "${CMUX_CI_APP_HOST_ISOLATION_REQUIRED:-0}" != "1" ]; then
  echo "FAIL: refusing app-host cleanup without the mandatory CI isolation marker" >&2
  exit 1
fi

app_host_home_input="${CMUX_APP_HOST_HOME:-}"
app_host_xdg_config_home_input="${CMUX_APP_HOST_XDG_CONFIG_HOME:-}"
if [ -n "$app_host_home_input" ] && [ -z "$app_host_xdg_config_home_input" ]; then
  app_host_xdg_config_home_input="${app_host_home_input%/}/.config"
fi

# The setup step may fail before publishing either neutral path. In that case it
# created no discoverable target, so there is nothing safe to remove.
if [ -z "$app_host_home_input" ] && [ -z "$app_host_xdg_config_home_input" ]; then
  echo "App-host isolation home was not published; cleanup skipped"
  exit 0
fi
if [ -z "$app_host_home_input" ] || [ -z "$app_host_xdg_config_home_input" ]; then
  echo "FAIL: refusing app-host cleanup with incomplete isolation paths" >&2
  exit 1
fi

# A prior cleanup or failed test may already have removed both paths.
if [ ! -e "$app_host_home_input" ] && [ ! -L "$app_host_home_input" ]; then
  if [ ! -e "$app_host_xdg_config_home_input" ] && [ ! -L "$app_host_xdg_config_home_input" ]; then
    echo "App-host isolation home is already absent"
    exit 0
  fi
  echo "FAIL: app-host home is absent while its XDG redirect remains" >&2
  exit 1
fi

app_host_home="$(cd "$app_host_home_input" 2>/dev/null && pwd -P)" || {
  echo "FAIL: app-host isolation directory is unavailable" >&2
  exit 1
}
# The app host owns this mutable leaf and may replace the directory with a file,
# a dangling symlink, or nothing. Never traverse the leaf during cleanup.
# Canonicalize its existing parent, require that parent to be the validated
# home, then reconstruct the exact .config path that rm will remove with it.
xdg_without_trailing_slash="${app_host_xdg_config_home_input%/}"
if [ -z "$xdg_without_trailing_slash" ] \
  || [ "${xdg_without_trailing_slash##*/}" != ".config" ]; then
  echo "FAIL: app-host XDG configuration must name the isolated home .config directory" >&2
  exit 1
fi
xdg_parent="$(dirname "$xdg_without_trailing_slash")"
xdg_parent="$(cd "$xdg_parent" 2>/dev/null && pwd -P)" || {
  echo "FAIL: app-host XDG configuration parent is unavailable" >&2
  exit 1
}
if [ "$xdg_parent" != "$app_host_home" ]; then
  echo "FAIL: app-host XDG configuration must be inside the isolated home" >&2
  exit 1
fi
app_host_xdg_config_home="${app_host_home%/}/.config"
cmux_validate_resolved_app_host_isolation \
  "$app_host_home" "$app_host_xdg_config_home" || exit 1
app_host_home="$CMUX_RESOLVED_APP_HOST_HOME"

if [ -z "${RUNNER_TEMP:-}" ]; then
  echo "FAIL: app-host cleanup requires the runner temporary directory" >&2
  exit 1
fi
runner_temp="$(cd "$RUNNER_TEMP" 2>/dev/null && pwd -P)" || {
  echo "FAIL: runner temporary directory is unavailable" >&2
  exit 1
}

case "$app_host_home" in
  "$runner_temp"/*) ;;
  *)
    echo "FAIL: refusing to clean an app-host home outside runner temp" >&2
    exit 1
    ;;
esac
case "${app_host_home##*/}" in
  ah-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *)
    echo "FAIL: refusing to clean a path without the app-host home name" >&2
    exit 1
    ;;
esac

if [ -z "${CMUX_DERIVED_DATA_PATH:-}" ]; then
  echo "FAIL: app-host cleanup requires the shard DerivedData path" >&2
  exit 1
fi
derived_data_path="$(cd "$CMUX_DERIVED_DATA_PATH" 2>/dev/null && pwd -P)" || {
  echo "FAIL: shard DerivedData directory is unavailable" >&2
  exit 1
}
case "$derived_data_path" in
  "$runner_temp"/*) ;;
  *)
    echo "FAIL: refusing to inspect app hosts outside runner temp" >&2
    exit 1
    ;;
esac

scoped_app_host_pids() {
  local pid command
  while read -r pid command; do
    case "$command" in
      "$derived_data_path"/Build/Products/*"/cmux DEV"*) printf '%s\n' "$pid" ;;
    esac
  done < <(ps -axww -o pid=,command=)
}

# Only terminate app hosts built by this shard. A broader RUNNER_TEMP match can
# race another workflow after it acquires the machine-wide app-host lock.
app_host_pids="$(scoped_app_host_pids)"
if [ -n "$app_host_pids" ]; then
  # shellcheck disable=SC2086
  kill $app_host_pids 2>/dev/null || true
  remaining_pids="$app_host_pids"
  attempts=0
  while [ -n "$remaining_pids" ] && [ "$attempts" -lt 20 ]; do
    sleep 0.1
    remaining_pids="$(scoped_app_host_pids)"
    attempts=$((attempts + 1))
  done
  if [ -n "$remaining_pids" ]; then
    # shellcheck disable=SC2086
    kill -KILL $remaining_pids 2>/dev/null || true
    sleep 0.1
  fi
  if [ -n "$(scoped_app_host_pids)" ]; then
    echo "FAIL: shard app-host processes did not stop before cleanup" >&2
    exit 1
  fi
fi

rm -rf -- "$app_host_home"
if [ -e "$app_host_home" ] || [ -L "$app_host_home" ]; then
  echo "FAIL: isolated app-host home still exists after cleanup" >&2
  exit 1
fi
echo "Removed isolated app-host home: $app_host_home"
