#!/usr/bin/env bash
set -euo pipefail

ci_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/app-host-isolation.sh
source "$ci_script_dir/app-host-isolation.sh"

if [ -z "${GITHUB_ENV:-}" ]; then
  echo "FAIL: app-host preparation requires GITHUB_ENV" >&2
  exit 1
fi

cmux_resolve_app_host_identity
app_host_key="$CMUX_RESOLVED_APP_HOST_KEY"
app_host_home="$CMUX_RESOLVED_APP_HOST_HOME_INPUT"
app_host_xdg_config_home="$CMUX_RESOLVED_APP_HOST_XDG_CONFIG_HOME_INPUT"
app_host_receipt_dir="$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR"
app_host_cleanup_confirmation="$CMUX_RESOLVED_APP_HOST_CLEANUP_CONFIRMATION"
app_host_confirmation_file="$CMUX_RESOLVED_APP_HOST_CONFIRMATION_FILE"
app_host_config_sentinel="$app_host_home/Library/Application Support/com.mitchellh.ghostty/config.ghostty"

# Publish every derived identity field before the first filesystem mutation so
# always-running teardown can validate any partial setup without guessing.
{
  echo "CMUX_APP_HOST_KEY=$app_host_key"
  echo "CMUX_APP_HOST_HOME=$app_host_home"
  echo "CMUX_APP_HOST_XDG_CONFIG_HOME=$app_host_xdg_config_home"
  echo "CMUX_APP_HOST_RECEIPT_DIR=$app_host_receipt_dir"
  echo "CMUX_APP_HOST_CLEANUP_CONFIRMATION=$app_host_cleanup_confirmation"
  echo "CMUX_APP_HOST_CONFIRMATION_FILE=$app_host_confirmation_file"
} >> "$GITHUB_ENV"

if [ -e "$app_host_home" ] \
  || [ -L "$app_host_home" ] \
  || [ -e "$app_host_receipt_dir" ] \
  || [ -L "$app_host_receipt_dir" ] \
  || [ -e "$app_host_confirmation_file" ] \
  || [ -L "$app_host_confirmation_file" ]; then
  echo "FAIL: app-host isolation scope already exists; verified cleanup is required" >&2
  exit 1
fi

# Publish deletion authority before claiming either mutable root. If setup is
# interrupted after this point, always-running teardown can authenticate and
# remove the exact partial scope. The final hard link is exclusive, so a
# concurrent or reused run key cannot replace an existing claim.
confirmation_tmp="$(mktemp "${app_host_confirmation_file}.tmp.XXXXXX")"
trap 'rm -f -- "$confirmation_tmp"' EXIT
cmux_app_host_confirmation_record > "$confirmation_tmp"
chmod 600 "$confirmation_tmp"
if ! ln -- "$confirmation_tmp" "$app_host_confirmation_file"; then
  echo "FAIL: app-host cleanup confirmation already exists" >&2
  exit 1
fi
rm -f -- "$confirmation_tmp"
trap - EXIT

# Claim the receipt root first. Once the home exists, every later partial setup
# therefore retains both the external confirmation and the receipt boundary
# needed for fail-closed process inspection.
mkdir -m 700 "$app_host_receipt_dir"
mkdir -m 700 "$app_host_home"
mkdir -p \
  "$app_host_xdg_config_home/cmux" \
  "$app_host_xdg_config_home/ghostty" \
  "$app_host_home/Library/Application Support/com.mitchellh.ghostty" \
  "$app_host_home/Library/Caches" \
  "$app_host_home/Library/Logs/DiagnosticReports" \
  "$app_host_home/Library/Preferences"
printf '# cmux CI app-host isolation sentinel\n' > "$app_host_config_sentinel"
chmod -R u+rwX,go-rwx "$app_host_home"
chmod 700 "$app_host_receipt_dir"
