#!/usr/bin/env bash
set -euo pipefail

ci_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/app-host-isolation.sh
source "$ci_script_dir/app-host-isolation.sh"
# shellcheck source=scripts/ci/app-host-processes.sh
source "$ci_script_dir/app-host-processes.sh"

if [ "${CMUX_CI_APP_HOST_ISOLATION_REQUIRED:-0}" != "1" ]; then
  echo "FAIL: refusing app-host cleanup without the mandatory CI isolation marker" >&2
  exit 1
fi

published_identity_count=0
for published_name in \
  CMUX_APP_HOST_KEY \
  CMUX_APP_HOST_HOME \
  CMUX_APP_HOST_XDG_CONFIG_HOME \
  CMUX_APP_HOST_RECEIPT_DIR \
  CMUX_APP_HOST_CLEANUP_CONFIRMATION \
  CMUX_APP_HOST_CONFIRMATION_FILE
do
  if [ -n "${!published_name:-}" ]; then
    published_identity_count=$((published_identity_count + 1))
  fi
done

cmux_resolve_app_host_identity
if [ "$published_identity_count" -eq 0 ]; then
  if [ ! -e "$CMUX_RESOLVED_APP_HOST_HOME" ] \
    && [ ! -L "$CMUX_RESOLVED_APP_HOST_HOME" ] \
    && [ ! -e "$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR" ] \
    && [ ! -L "$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR" ] \
    && [ ! -e "$CMUX_RESOLVED_APP_HOST_CONFIRMATION_FILE" ] \
    && [ ! -L "$CMUX_RESOLVED_APP_HOST_CONFIRMATION_FILE" ]; then
    echo "App-host isolation identity was not published and no derived target exists; cleanup skipped"
    exit 0
  fi
  echo "FAIL: derived app-host cleanup target exists without published identity" >&2
  exit 1
fi
if [ "$published_identity_count" -ne 6 ]; then
  echo "FAIL: refusing app-host cleanup with incomplete published identity" >&2
  exit 1
fi

cmux_validate_published_app_host_identity_values
app_host_home="$CMUX_RESOLVED_APP_HOST_HOME"
app_host_xdg_config_home="$CMUX_RESOLVED_APP_HOST_XDG_CONFIG_HOME"
app_host_receipt_dir="$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR"
app_host_confirmation_file="$CMUX_RESOLVED_APP_HOST_CONFIRMATION_FILE"
app_host_key="$CMUX_RESOLVED_APP_HOST_KEY"

if [ ! -e "$app_host_home" ] \
  && [ ! -L "$app_host_home" ] \
  && [ ! -e "$app_host_receipt_dir" ] \
  && [ ! -L "$app_host_receipt_dir" ] \
  && [ ! -e "$app_host_confirmation_file" ] \
  && [ ! -L "$app_host_confirmation_file" ]; then
  echo "App-host isolation targets are already absent"
  exit 0
fi

if [ -L "$app_host_home" ]; then
  echo "FAIL: refusing app-host cleanup through a home symlink" >&2
  exit 1
fi
if [ -L "$app_host_receipt_dir" ]; then
  echo "FAIL: refusing app-host cleanup through a receipt symlink" >&2
  exit 1
fi
cmux_validate_app_host_cleanup_confirmation

# Preparation publishes the external confirmation before either mutable root.
# If interruption happens in that narrow window, the authenticated claim is the
# only target and no app host could have launched without a receipt directory.
if [ ! -e "$app_host_home" ] \
  && [ ! -L "$app_host_home" ] \
  && [ ! -e "$app_host_receipt_dir" ] \
  && [ ! -L "$app_host_receipt_dir" ]; then
  rm -f -- "$app_host_confirmation_file"
  if [ -e "$app_host_confirmation_file" ] \
    || [ -L "$app_host_confirmation_file" ]; then
    echo "FAIL: partial app-host confirmation remains after cleanup" >&2
    exit 1
  fi
  echo "Removed confirmation-only partial app-host scope: $app_host_confirmation_file"
  exit 0
fi

if [ -e "$app_host_home" ]; then
  resolved_home="$(cd "$app_host_home" 2>/dev/null && pwd -P)" || {
    echo "FAIL: app-host isolation directory is unavailable" >&2
    exit 1
  }
  if [ "$resolved_home" != "$app_host_home" ]; then
    echo "FAIL: app-host isolation directory changed identity" >&2
    exit 1
  fi

  # The app host may replace .config with a file, a dangling symlink, or
  # nothing. Validate only its immutable parent and remove the leaf with the
  # already confirmed home instead of traversing it.
  xdg_target="${app_host_xdg_config_home%/}"
  if [ "${xdg_target##*/}" != ".config" ]; then
    echo "FAIL: app-host XDG configuration must name the isolated home .config directory" >&2
    exit 1
  fi
  xdg_parent="$(dirname "$xdg_target")"
  xdg_parent="$(cd "$xdg_parent" 2>/dev/null && pwd -P)" || {
    echo "FAIL: app-host XDG configuration parent is unavailable" >&2
    exit 1
  }
  if [ "$xdg_parent" != "$app_host_home" ]; then
    echo "FAIL: app-host XDG configuration must be inside the isolated home" >&2
    exit 1
  fi
fi

if [ -e "$app_host_receipt_dir" ]; then
  resolved_receipt_dir="$(cd "$app_host_receipt_dir" 2>/dev/null && pwd -P)" || {
    echo "FAIL: app-host process receipt directory is unavailable" >&2
    exit 1
  }
  if [ "$resolved_receipt_dir" != "$app_host_receipt_dir" ]; then
    echo "FAIL: app-host process receipt directory changed identity" >&2
    exit 1
  fi
fi

# Exercise the complete launch validator when both mutable directories retain
# their expected directory shape. Cleanup's parent-only checks above handle the
# deliberate corrupt-leaf regressions without weakening identity validation.
if [ -d "$app_host_home" ] \
  && [ -d "$app_host_xdg_config_home" ] \
  && [ ! -L "$app_host_xdg_config_home" ] \
  && [ -d "$app_host_receipt_dir" ]; then
  cmux_validate_published_app_host_identity
fi

if [ -z "${CMUX_DERIVED_DATA_PATH:-}" ]; then
  echo "FAIL: app-host cleanup requires the shard DerivedData path" >&2
  exit 1
fi
runner_temp="$CMUX_RESOLVED_RUNNER_TEMP"
cmux_validate_app_host_derived_data "$CMUX_DERIVED_DATA_PATH"
derived_data_path="$CMUX_VALIDATED_APP_HOST_DERIVED_DATA"
case "$derived_data_path" in
  "$runner_temp"/*) ;;
  *)
    echo "FAIL: refusing to inspect app hosts outside runner temp" >&2
    exit 1
    ;;
esac

# The process helper cross-checks every receipt against lsof's executable vnode
# and fails if a live target in this DerivedData tree lacks a receipt.
cmux_terminate_verified_app_hosts \
  "$app_host_receipt_dir" "$app_host_key" "$derived_data_path"

rm -rf -- "$app_host_home"
if [ -e "$app_host_home" ] || [ -L "$app_host_home" ]; then
  echo "FAIL: isolated app-host home still exists after cleanup" >&2
  exit 1
fi
rm -rf -- "$app_host_receipt_dir"
rm -f -- "$app_host_confirmation_file"
echo "Removed isolated app-host home: $app_host_home"
