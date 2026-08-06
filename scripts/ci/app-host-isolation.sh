#!/usr/bin/env bash

# Require XDG configuration to be the real .config directory inside a canonical
# isolated home. Callers receive the validated paths through CMUX_RESOLVED_*.
cmux_validate_resolved_app_host_isolation() {
  local resolved_home="$1"
  local resolved_xdg_config_home="$2"

  if [ -z "$resolved_home" ]; then
    echo "FAIL: app-host isolation home is missing" >&2
    return 1
  fi
  if [ -z "$resolved_xdg_config_home" ]; then
    echo "FAIL: app-host XDG configuration must be the isolated home .config directory" >&2
    return 1
  fi

  local expected_xdg_config_home
  expected_xdg_config_home="${resolved_home%/}/.config"
  if [ "$resolved_xdg_config_home" != "$expected_xdg_config_home" ]; then
    echo "FAIL: app-host XDG configuration must be the isolated home .config directory" >&2
    return 1
  fi

  # Outputs consumed by the scripts that source this shared validator.
  # shellcheck disable=SC2034
  CMUX_RESOLVED_APP_HOST_HOME="$resolved_home"
  # shellcheck disable=SC2034
  CMUX_RESOLVED_APP_HOST_XDG_CONFIG_HOME="$resolved_xdg_config_home"
}

# Resolve the two launch-home redirects through the filesystem before applying
# the shared boundary validation.
cmux_resolve_app_host_isolation() {
  local requested_home="$1"
  local requested_xdg_config_home="$2"

  if [ -z "$requested_home" ]; then
    echo "FAIL: app-host isolation home is missing" >&2
    return 1
  fi
  if [ -z "$requested_xdg_config_home" ]; then
    echo "FAIL: app-host XDG configuration must be the isolated home .config directory" >&2
    return 1
  fi

  local resolved_home resolved_xdg_config_home
  resolved_home="$(cd "$requested_home" 2>/dev/null && pwd -P)" || {
    echo "FAIL: app-host isolation directory is unavailable" >&2
    return 1
  }
  resolved_xdg_config_home="$(cd "$requested_xdg_config_home" 2>/dev/null && pwd -P)" || {
    echo "FAIL: app-host XDG configuration directory is unavailable" >&2
    return 1
  }
  cmux_validate_resolved_app_host_isolation \
    "$resolved_home" "$resolved_xdg_config_home"
}
