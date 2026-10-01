#!/usr/bin/env bash
# Gather an app-host test job's captures, result bundles and crash reports into
# $RUNNER_TEMP/cmux-app-host-diagnostics-shard-<shard>-run-<attempt> for upload.
# Shared by the app-host unit-test shards and compile admission's changed-suites
# run. Best effort: the caller marks the step continue-on-error.
set -eo pipefail
set -u
diagnostics="$RUNNER_TEMP/cmux-app-host-diagnostics-shard-${CMUX_APP_HOST_SHARD}-run-${GITHUB_RUN_ATTEMPT}"
rm -rf -- "$diagnostics"
mkdir -p "$diagnostics/captures"

{
  echo "run_id=${GITHUB_RUN_ID}"
  echo "run_attempt=${GITHUB_RUN_ATTEMPT}"
  echo "sha=${GITHUB_SHA}"
  echo "physical_shard=${CMUX_APP_HOST_SHARD}"
  echo "derived_data=${CMUX_DERIVED_DATA_PATH:-}"
  echo "result_bundle_root=${CMUX_APP_HOST_RESULT_BUNDLE_ROOT:-${RUNNER_TEMP:-/tmp}/cmux-app-host-xcresults}"
} >"$diagnostics/manifest.txt"

shopt -s nullglob
capture_files=(
  "$RUNNER_TEMP"/cmux-app-host-xcodebuild-*.log
  "$RUNNER_TEMP"/cmux-app-host-xcodebuild-*.meta
  "$RUNNER_TEMP"/cmux-unit-output-*.txt
  "$RUNNER_TEMP"/cmux-unit-unfinished-*.txt
  "$RUNNER_TEMP"/cmux-unit-shard-*.args
  "$RUNNER_TEMP"/app-host-hang-sample-*.txt
  "$RUNNER_TEMP"/cmux-remote-tmux-mirror-*.txt
  "$RUNNER_TEMP"/cmux-main-window-zoom-placement.txt
  "$RUNNER_TEMP"/cmux-global-search-shortcuts.txt
  "$RUNNER_TEMP"/cmux-cloud-ordering-*.txt
  "$RUNNER_TEMP"/cmux-notification-*.txt
)
if [ "${#capture_files[@]}" -gt 0 ]; then
  cp "${capture_files[@]}" "$diagnostics/captures/" || true
fi

result_bundle_root="${CMUX_APP_HOST_RESULT_BUNDLE_ROOT:-${RUNNER_TEMP:-/tmp}/cmux-app-host-xcresults}"
if [ -d "$result_bundle_root" ]; then
  cp -R "$result_bundle_root" "$diagnostics/xcresults" || true
fi

# Preserve reports from the isolated XCTest HOME before the always-
# running cleanup removes that run scope.
if [ -n "${CMUX_APP_HOST_HOME:-}" ]; then
  ci_script_dir="${GITHUB_WORKSPACE:-$PWD}/scripts/ci"
  # shellcheck source=scripts/ci/app-host-isolation.sh
  source "$ci_script_dir/app-host-isolation.sh"
  if cmux_validate_published_app_host_identity_values; then
    for crash_relative in ".local/state/cmux/crash" "Library/Logs/DiagnosticReports"; do
      crash_source="$CMUX_RESOLVED_APP_HOST_HOME/$crash_relative"
      case "$crash_relative" in
        .local/*) crash_destination="$diagnostics/ghostty-crash-reports" ;;
        *) crash_destination="$diagnostics/macos-diagnostic-reports" ;;
      esac
      if [ -d "$crash_source" ] \
        || sudo -n test -d "$crash_source" 2>/dev/null; then
        rm -rf -- "$crash_destination"
        if cp -R "$crash_source" "$crash_destination" 2>/dev/null; then
          :
        elif sudo -n true 2>/dev/null; then
          if sudo -n cp -R "$crash_source" "$crash_destination"; then
            sudo -n chown -R "$(id -u):$(id -g)" "$crash_destination" || true
          fi
        fi
      fi
    done
  else
    echo "::warning::app-host identity validation failed; crash reports were not collected" >&2
  fi
fi

find "$diagnostics" -type f -print | sort || true
