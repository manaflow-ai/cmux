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

cmux_compute_app_host_key() {
  local run_id="$1"
  local run_attempt="$2"
  local shard="$3"
  local repository_id="$4"
  cmux_require_app_host_identity_number GITHUB_REPOSITORY_ID "$repository_id" || return 1
  cmux_require_app_host_identity_number GITHUB_RUN_ID "$run_id" || return 1
  cmux_require_app_host_identity_number GITHUB_RUN_ATTEMPT "$run_attempt" || return 1
  cmux_require_app_host_identity_number CMUX_APP_HOST_SHARD "$shard" || return 1
  CMUX_COMPUTED_APP_HOST_KEY="$(
    printf '%s' "${repository_id}:${run_id}:${run_attempt}:${shard}" \
      | cmux_app_host_sha256 \
      | cut -c1-12
  )"
  case "$CMUX_COMPUTED_APP_HOST_KEY" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *)
      echo "FAIL: app-host identity key is invalid" >&2
      return 1
      ;;
  esac
}

cmux_compute_app_host_cleanup_confirmation() {
  local run_id="$1"
  local run_attempt="$2"
  local shard="$3"
  local app_host_home="$4"
  local app_host_receipt_dir="$5"
  local repository_id="$6"
  cmux_require_app_host_identity_number GITHUB_REPOSITORY_ID "$repository_id" || return 1
  local confirmation_material
  confirmation_material="cmux-app-host-cleanup-v3
${repository_id}
${run_id}
${run_attempt}
${shard}
${app_host_home}
${app_host_receipt_dir}"
  CMUX_COMPUTED_APP_HOST_CLEANUP_CONFIRMATION="$(
    printf '%s' "$confirmation_material" | cmux_app_host_sha256
  )"
}

# Derive every app-host path and cleanup capability from GitHub's immutable run
# tuple. Published paths are assertions checked against these outputs, never an
# authority from which the expected boundary is inferred.
cmux_resolve_app_host_identity() {
  cmux_require_app_host_identity_number \
    GITHUB_REPOSITORY_ID "${GITHUB_REPOSITORY_ID:-}" || return 1
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

  local system_temp_root runner_temp runner_work_root app_host_key
  system_temp_root="$(cd /tmp 2>/dev/null && pwd -P)" || {
    echo "FAIL: system temporary directory is unavailable" >&2
    return 1
  }
  runner_temp="$(cd "$RUNNER_TEMP" 2>/dev/null && pwd -P)" || {
    echo "FAIL: runner temporary directory is unavailable" >&2
    return 1
  }
  runner_work_root="$(cd "$(dirname "$runner_temp")" 2>/dev/null && pwd -P)" || {
    echo "FAIL: runner work root is unavailable" >&2
    return 1
  }
  cmux_compute_app_host_key \
    "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$CMUX_APP_HOST_SHARD" \
    "$GITHUB_REPOSITORY_ID" || return 1
  app_host_key="$CMUX_COMPUTED_APP_HOST_KEY"

  CMUX_RESOLVED_APP_HOST_KEY="$app_host_key"
  # /private/tmp survives GitHub's per-job RUNNER_TEMP cleanup. Its sticky
  # ownership lets the console account delete only the exact targets that the
  # runner created and later transferred to it.
  # shellcheck disable=SC2034 # consumed by callers after sourcing this helper
  CMUX_RESOLVED_SYSTEM_TEMP_ROOT="$system_temp_root"
  # shellcheck disable=SC2034 # consumed by callers after sourcing this helper
  CMUX_RESOLVED_RUNNER_TEMP="$runner_temp"
  # shellcheck disable=SC2034 # consumed by callers after sourcing this helper
  CMUX_RESOLVED_RUNNER_WORK_ROOT="$runner_work_root"
  CMUX_RESOLVED_APP_HOST_HOME_INPUT="/tmp/cmux-ah-$app_host_key"
  CMUX_RESOLVED_APP_HOST_HOME="${system_temp_root%/}/cmux-ah-$app_host_key"
  CMUX_RESOLVED_APP_HOST_XDG_CONFIG_HOME_INPUT="${CMUX_RESOLVED_APP_HOST_HOME_INPUT%/}/.config"
  CMUX_RESOLVED_APP_HOST_XDG_CONFIG_HOME="${CMUX_RESOLVED_APP_HOST_HOME%/}/.config"
  CMUX_RESOLVED_APP_HOST_RECEIPT_DIR="${system_temp_root%/}/cmux-ah-$app_host_key-receipts"
  CMUX_RESOLVED_APP_HOST_CONFIRMATION_FILE="${system_temp_root%/}/cmux-ah-$app_host_key.confirm"

  cmux_compute_app_host_cleanup_confirmation \
    "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$CMUX_APP_HOST_SHARD" \
    "$CMUX_RESOLVED_APP_HOST_HOME" "$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR" \
    "$GITHUB_REPOSITORY_ID"
  CMUX_RESOLVED_APP_HOST_CLEANUP_CONFIRMATION="$CMUX_COMPUTED_APP_HOST_CLEANUP_CONFIRMATION"
}

cmux_app_host_confirmation_record() {
  printf 'version=3\nrepository_id=%s\nrun_id=%s\nrun_attempt=%s\nshard=%s\nkey=%s\nhome=%s\nreceipt_dir=%s\nconfirmation=%s\n' \
    "$GITHUB_REPOSITORY_ID" \
    "$GITHUB_RUN_ID" \
    "$GITHUB_RUN_ATTEMPT" \
    "$CMUX_APP_HOST_SHARD" \
    "$CMUX_RESOLVED_APP_HOST_KEY" \
    "$CMUX_RESOLVED_APP_HOST_HOME" \
    "$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR" \
    "$CMUX_RESOLVED_APP_HOST_CLEANUP_CONFIRMATION"
}

# Validate an old scope from its setup-authored record without sourcing it.
# Callers must also bind the scope to a verified process receipt before removal.
cmux_validate_stale_app_host_confirmation() {
  local confirmation_file="$1"
  local system_temp_root="${2%/}"
  local expected_key="$3"
  case "$system_temp_root" in
    /|"")
      echo "FAIL: stale app-host system temporary root is invalid" >&2
      return 1
      ;;
    /*) ;;
    *)
      echo "FAIL: stale app-host system temporary root must be absolute" >&2
      return 1
      ;;
  esac
  if [ -L "$system_temp_root" ] || [ ! -d "$system_temp_root" ]; then
    echo "FAIL: stale app-host system temporary root is unavailable" >&2
    return 1
  fi
  local resolved_system_temp_root
  resolved_system_temp_root="$(cd "$system_temp_root" 2>/dev/null && pwd -P)" || return 1
  if [ "$resolved_system_temp_root" != "$system_temp_root" ]; then
    echo "FAIL: stale app-host system temporary root changed identity" >&2
    return 1
  fi
  case "$expected_key" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *)
      echo "FAIL: stale app-host key is invalid" >&2
      return 1
      ;;
  esac

  local expected_confirmation_file
  expected_confirmation_file="$system_temp_root/cmux-ah-$expected_key.confirm"
  if [ "$confirmation_file" != "$expected_confirmation_file" ] \
    || [ -L "$confirmation_file" ] \
    || [ ! -f "$confirmation_file" ]; then
    echo "FAIL: stale app-host confirmation record is unavailable" >&2
    return 1
  fi

  local line line_number record_version record_repository_id record_run_id record_run_attempt
  local record_shard record_key record_home record_receipt_dir record_confirmation
  line_number=0
  record_version=""
  record_repository_id=""
  record_run_id=""
  record_run_attempt=""
  record_shard=""
  record_key=""
  record_home=""
  record_receipt_dir=""
  record_confirmation=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    case "$line_number" in
      1) record_version="${line#version=}"; [ "$line" != "$record_version" ] || record_version="" ;;
      2) record_repository_id="${line#repository_id=}"; [ "$line" != "$record_repository_id" ] || record_repository_id="" ;;
      3) record_run_id="${line#run_id=}"; [ "$line" != "$record_run_id" ] || record_run_id="" ;;
      4) record_run_attempt="${line#run_attempt=}"; [ "$line" != "$record_run_attempt" ] || record_run_attempt="" ;;
      5) record_shard="${line#shard=}"; [ "$line" != "$record_shard" ] || record_shard="" ;;
      6) record_key="${line#key=}"; [ "$line" != "$record_key" ] || record_key="" ;;
      7) record_home="${line#home=}"; [ "$line" != "$record_home" ] || record_home="" ;;
      8) record_receipt_dir="${line#receipt_dir=}"; [ "$line" != "$record_receipt_dir" ] || record_receipt_dir="" ;;
      9) record_confirmation="${line#confirmation=}"; [ "$line" != "$record_confirmation" ] || record_confirmation="" ;;
      *)
        echo "FAIL: stale app-host confirmation has unexpected fields" >&2
        return 1
        ;;
    esac
  done < "$confirmation_file"
  if [ "$line_number" -ne 9 ] || [ "$record_version" != "3" ]; then
    echo "FAIL: stale app-host confirmation version is invalid" >&2
    return 1
  fi

  cmux_require_app_host_identity_number \
    GITHUB_REPOSITORY_ID "$record_repository_id" || return 1
  cmux_compute_app_host_key \
    "$record_run_id" "$record_run_attempt" "$record_shard" \
    "$record_repository_id" || return 1
  if [ "$record_key" != "$expected_key" ] \
    || [ "$record_key" != "$CMUX_COMPUTED_APP_HOST_KEY" ]; then
    echo "FAIL: stale app-host confirmation key is invalid" >&2
    return 1
  fi
  local expected_home expected_receipt_dir
  expected_home="$system_temp_root/cmux-ah-$record_key"
  expected_receipt_dir="$system_temp_root/cmux-ah-$record_key-receipts"
  if [ "$record_home" != "$expected_home" ] \
    || [ "$record_receipt_dir" != "$expected_receipt_dir" ]; then
    echo "FAIL: stale app-host confirmation target is invalid" >&2
    return 1
  fi
  cmux_compute_app_host_cleanup_confirmation \
    "$record_run_id" "$record_run_attempt" "$record_shard" \
    "$record_home" "$record_receipt_dir" "$record_repository_id"
  if [ "$record_confirmation" != "$CMUX_COMPUTED_APP_HOST_CLEANUP_CONFIRMATION" ]; then
    echo "FAIL: stale app-host cleanup confirmation is invalid" >&2
    return 1
  fi

  # shellcheck disable=SC2034 # consumed by the process helper after sourcing
  CMUX_VALIDATED_STALE_APP_HOST_HOME="$record_home"
  # shellcheck disable=SC2034 # consumed by the process helper after sourcing
  CMUX_VALIDATED_STALE_APP_HOST_RECEIPT_DIR="$record_receipt_dir"
  # shellcheck disable=SC2034 # consumed by the process helper after sourcing
  CMUX_VALIDATED_STALE_APP_HOST_CONFIRMATION_FILE="$confirmation_file"
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
  expected_confirmation="$(cmux_app_host_confirmation_record)"
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
