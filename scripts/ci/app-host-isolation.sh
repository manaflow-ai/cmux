#!/usr/bin/env bash

cmux_app_host_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

cmux_require_app_host_identity_number() {
  local name="$1"
  local value="$2"
  case "$value" in
    ''|*[!0-9]*)
      echo "FAIL: app-host identity $name must be a decimal integer" >&2
      return 1
      ;;
  esac
}

# Derive every app-host path and cleanup capability from GitHub's immutable run
# tuple. Published paths are assertions checked against these outputs, never an
# authority from which the expected boundary is inferred.
cmux_resolve_app_host_identity() {
  cmux_require_app_host_identity_number \
    GITHUB_RUN_ID "${GITHUB_RUN_ID:-}" || return 1
  cmux_require_app_host_identity_number \
    GITHUB_RUN_ATTEMPT "${GITHUB_RUN_ATTEMPT:-}" || return 1
  cmux_require_app_host_identity_number \
    CMUX_APP_HOST_SHARD "${CMUX_APP_HOST_SHARD:-}" || return 1

  if [ -z "${RUNNER_TEMP:-}" ]; then
    echo "FAIL: app-host identity requires the runner temporary directory" >&2
    return 1
  fi

  local system_temp_root runner_temp app_host_key confirmation_material
  system_temp_root="$(cd /tmp 2>/dev/null && pwd -P)" || {
    echo "FAIL: system temporary directory is unavailable" >&2
    return 1
  }
  runner_temp="$(cd "$RUNNER_TEMP" 2>/dev/null && pwd -P)" || {
    echo "FAIL: runner temporary directory is unavailable" >&2
    return 1
  }
  app_host_key="$(
    printf '%s' \
      "${GITHUB_RUN_ID}:${GITHUB_RUN_ATTEMPT}:${CMUX_APP_HOST_SHARD}" \
      | cmux_app_host_sha256 \
      | cut -c1-12
  )"
  case "$app_host_key" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *)
      echo "FAIL: app-host identity key is invalid" >&2
      return 1
      ;;
  esac

  CMUX_RESOLVED_APP_HOST_KEY="$app_host_key"
  # shellcheck disable=SC2034 # consumed by callers after sourcing this helper
  CMUX_RESOLVED_RUNNER_TEMP="$runner_temp"
  CMUX_RESOLVED_APP_HOST_HOME_INPUT="/tmp/cmux-ah-$app_host_key"
  CMUX_RESOLVED_APP_HOST_HOME="${system_temp_root%/}/cmux-ah-$app_host_key"
  CMUX_RESOLVED_APP_HOST_XDG_CONFIG_HOME_INPUT="${CMUX_RESOLVED_APP_HOST_HOME_INPUT%/}/.config"
  CMUX_RESOLVED_APP_HOST_XDG_CONFIG_HOME="${CMUX_RESOLVED_APP_HOST_HOME%/}/.config"
  CMUX_RESOLVED_APP_HOST_RECEIPT_DIR="${runner_temp%/}/cmux-app-host-$app_host_key-receipts"
  CMUX_RESOLVED_APP_HOST_CONFIRMATION_FILE="${runner_temp%/}/cmux-app-host-$app_host_key.confirm"

  confirmation_material="cmux-app-host-cleanup-v1
${GITHUB_RUN_ID}
${GITHUB_RUN_ATTEMPT}
${CMUX_APP_HOST_SHARD}
${CMUX_RESOLVED_APP_HOST_HOME}
${CMUX_RESOLVED_APP_HOST_RECEIPT_DIR}"
  CMUX_RESOLVED_APP_HOST_CLEANUP_CONFIRMATION="$(
    printf '%s' "$confirmation_material" | cmux_app_host_sha256
  )"
}

# Require XDG configuration to be the derived .config directory inside the
# independently derived home. Callers receive the validated paths through the
# CMUX_RESOLVED_* outputs above.
cmux_validate_resolved_app_host_isolation() {
  local resolved_home="$1"
  local resolved_xdg_config_home="$2"

  cmux_resolve_app_host_identity || return 1
  if [ "$resolved_home" != "$CMUX_RESOLVED_APP_HOST_HOME" ]; then
    echo "FAIL: app-host isolation home does not match the run identity" >&2
    return 1
  fi
  if [ "$resolved_xdg_config_home" != "$CMUX_RESOLVED_APP_HOST_XDG_CONFIG_HOME" ]; then
    echo "FAIL: app-host XDG configuration does not match the run identity" >&2
    return 1
  fi
}

# Resolve launch redirects through the filesystem, but compare them to the run
# identity rather than to each other.
cmux_resolve_app_host_isolation() {
  local requested_home="$1"
  local requested_xdg_config_home="$2"

  cmux_resolve_app_host_identity || return 1
  if [ "$requested_home" != "$CMUX_RESOLVED_APP_HOST_HOME_INPUT" ]; then
    echo "FAIL: app-host isolation home does not match the run identity" >&2
    return 1
  fi
  if [ "$requested_xdg_config_home" != "$CMUX_RESOLVED_APP_HOST_XDG_CONFIG_HOME_INPUT" ]; then
    echo "FAIL: app-host XDG configuration does not match the run identity" >&2
    return 1
  fi
  if [ -L "$requested_home" ]; then
    echo "FAIL: refusing app-host isolation through a home symlink" >&2
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

cmux_validate_published_app_host_identity_values() {
  cmux_resolve_app_host_identity || return 1

  local published_name published_value expected_value
  for published_name in \
    CMUX_APP_HOST_KEY \
    CMUX_APP_HOST_HOME \
    CMUX_APP_HOST_XDG_CONFIG_HOME \
    CMUX_APP_HOST_RECEIPT_DIR \
    CMUX_APP_HOST_CLEANUP_CONFIRMATION \
    CMUX_APP_HOST_CONFIRMATION_FILE
  do
    published_value="${!published_name:-}"
    case "$published_name" in
      CMUX_APP_HOST_KEY) expected_value="$CMUX_RESOLVED_APP_HOST_KEY" ;;
      CMUX_APP_HOST_HOME) expected_value="$CMUX_RESOLVED_APP_HOST_HOME_INPUT" ;;
      CMUX_APP_HOST_XDG_CONFIG_HOME) expected_value="$CMUX_RESOLVED_APP_HOST_XDG_CONFIG_HOME_INPUT" ;;
      CMUX_APP_HOST_RECEIPT_DIR) expected_value="$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR" ;;
      CMUX_APP_HOST_CLEANUP_CONFIRMATION) expected_value="$CMUX_RESOLVED_APP_HOST_CLEANUP_CONFIRMATION" ;;
      CMUX_APP_HOST_CONFIRMATION_FILE) expected_value="$CMUX_RESOLVED_APP_HOST_CONFIRMATION_FILE" ;;
    esac
    if [ "$published_value" != "$expected_value" ]; then
      echo "FAIL: published $published_name does not match the run identity" >&2
      return 1
    fi
  done
}

cmux_validate_published_app_host_identity() {
  cmux_validate_published_app_host_identity_values || return 1

  cmux_resolve_app_host_isolation \
    "$CMUX_APP_HOST_HOME" "$CMUX_APP_HOST_XDG_CONFIG_HOME" || return 1
  if [ -L "$CMUX_APP_HOST_RECEIPT_DIR" ]; then
    echo "FAIL: refusing app-host process receipts through a symlink" >&2
    return 1
  fi
  local resolved_receipt_dir
  resolved_receipt_dir="$(cd "$CMUX_APP_HOST_RECEIPT_DIR" 2>/dev/null && pwd -P)" || {
    echo "FAIL: app-host process receipt directory is unavailable" >&2
    return 1
  }
  if [ "$resolved_receipt_dir" != "$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR" ]; then
    echo "FAIL: app-host process receipt directory changed identity" >&2
    return 1
  fi
}

cmux_validate_app_host_cleanup_confirmation() {
  cmux_resolve_app_host_identity || return 1
  if [ "${CMUX_APP_HOST_CLEANUP_CONFIRMATION:-}" != "$CMUX_RESOLVED_APP_HOST_CLEANUP_CONFIRMATION" ]; then
    echo "FAIL: app-host cleanup confirmation does not match the deletion target" >&2
    return 1
  fi
  if [ "${CMUX_APP_HOST_CONFIRMATION_FILE:-}" != "$CMUX_RESOLVED_APP_HOST_CONFIRMATION_FILE" ]; then
    echo "FAIL: app-host confirmation record does not match the run identity" >&2
    return 1
  fi
  if [ -L "$CMUX_APP_HOST_CONFIRMATION_FILE" ] || [ ! -f "$CMUX_APP_HOST_CONFIRMATION_FILE" ]; then
    echo "FAIL: app-host cleanup confirmation record is unavailable" >&2
    return 1
  fi

  local expected_confirmation actual_confirmation
  expected_confirmation="$(printf 'version=1\nkey=%s\nhome=%s\nreceipt_dir=%s\nconfirmation=%s' \
    "$CMUX_RESOLVED_APP_HOST_KEY" \
    "$CMUX_RESOLVED_APP_HOST_HOME" \
    "$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR" \
    "$CMUX_RESOLVED_APP_HOST_CLEANUP_CONFIRMATION")"
  actual_confirmation="$(cat "$CMUX_APP_HOST_CONFIRMATION_FILE" 2>/dev/null)" || {
    echo "FAIL: app-host cleanup confirmation record could not be read" >&2
    return 1
  }
  if [ "$actual_confirmation" != "$expected_confirmation" ]; then
    echo "FAIL: app-host cleanup confirmation record does not match the deletion target" >&2
    return 1
  fi
  echo "Confirmed app-host cleanup target: $CMUX_RESOLVED_APP_HOST_HOME"
}
