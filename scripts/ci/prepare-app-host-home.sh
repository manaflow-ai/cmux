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
  echo "CARGO_HOME=${HOME}/.cargo"
  echo "RUSTUP_HOME=${HOME}/.rustup"
} >> "$GITHUB_ENV"

rm -rf -- "$app_host_home"
rm -rf -- "$app_host_receipt_dir"
rm -f -- "$app_host_confirmation_file"
mkdir -p \
  "$app_host_xdg_config_home/cmux" \
  "$app_host_xdg_config_home/ghostty" \
  "$app_host_home/Library/Application Support/com.mitchellh.ghostty" \
  "$app_host_home/Library/Caches" \
  "$app_host_home/Library/Logs/DiagnosticReports" \
  "$app_host_home/Library/Preferences" \
  "$app_host_receipt_dir"
printf '# cmux CI app-host isolation sentinel\n' > "$app_host_config_sentinel"
chmod -R u+rwX,go-rwx "$app_host_home"
chmod 700 "$app_host_receipt_dir"

confirmation_tmp="$(mktemp "${app_host_confirmation_file}.tmp.XXXXXX")"
trap 'rm -f -- "$confirmation_tmp"' EXIT
printf 'version=1\nkey=%s\nhome=%s\nreceipt_dir=%s\nconfirmation=%s\n' \
  "$app_host_key" \
  "$CMUX_RESOLVED_APP_HOST_HOME" \
  "$app_host_receipt_dir" \
  "$app_host_cleanup_confirmation" \
  > "$confirmation_tmp"
chmod 600 "$confirmation_tmp"
mv -f -- "$confirmation_tmp" "$app_host_confirmation_file"
trap - EXIT
