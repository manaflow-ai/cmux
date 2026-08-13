#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <testbox-id> <evidence-directory>" >&2
  exit 64
fi

testbox_id="$1"
evidence_dir="$2"
if [[ ! "$testbox_id" =~ ^tbx_[A-Za-z0-9_-]+$ ]]; then
  echo "invalid Testbox ID: $testbox_id" >&2
  exit 64
fi

mkdir -p "$evidence_dir"
stop_log="$evidence_dir/stop.log"
status_log="$evidence_dir/status-after-stop.log"
list_log="$evidence_dir/list-after-stop.log"
cleanup_status=0

set +e
blacksmith testbox stop --id "$testbox_id" >"$stop_log" 2>&1
stop_status=$?
set -e
if (( stop_status != 0 )); then
  # A completed Testbox can race the explicit stop call. Tolerate only the
  # documented terminal-state response, never an arbitrary stop failure.
  if grep -Eiq 'already[[:space:]]+(stopped|completed)' "$stop_log"; then
    printf 'stop already reached a terminal state for %s; continuing\n' "$testbox_id" >&2
  else
    echo "failed to stop Testbox $testbox_id; see $stop_log" >&2
    cleanup_status=$stop_status
  fi
fi

# Status is diagnostic. The authoritative cleanup check below is the specific
# ID in `list --all`, because Blacksmith may remove completed boxes immediately.
set +e
blacksmith testbox status --id "$testbox_id" >"$status_log" 2>&1
status_status=$?
set -e
if (( status_status == 0 )); then
  status_value="$(awk -v id="$testbox_id" '$1 == id { print tolower($2); exit }' "$status_log")"
  case "$status_value" in
    completed|stopped|cancelled|failed|terminated)
      ;;
    ready|running|hydrating|in_progress|queued)
      echo "Testbox $testbox_id is still active after cleanup" >&2
      (( cleanup_status == 0 )) && cleanup_status=1
      ;;
    *)
      if grep -Eiq 'status:[[:space:]]*(completed|stopped|cancelled|failed|terminated)' "$status_log"; then
        :
      else
        echo "could not establish a terminal status for Testbox $testbox_id; see $status_log" >&2
        (( cleanup_status == 0 )) && cleanup_status=1
      fi
      ;;
  esac
elif ! grep -Eiq '(not found|already[[:space:]]+(stopped|completed)|HTTP[[:space:]]+409|status[[:space:]]+code[[:space:]]+409)' "$status_log"; then
  echo "failed to inspect Testbox $testbox_id; see $status_log" >&2
  (( cleanup_status == 0 )) && cleanup_status=$status_status
fi

set +e
blacksmith testbox list --all >"$list_log" 2>&1
list_status=$?
set -e
if (( list_status != 0 )); then
  echo "failed to list Testboxes after stopping $testbox_id; see $list_log" >&2
  (( cleanup_status == 0 )) && cleanup_status=$list_status
elif grep -Fq -- "$testbox_id" "$list_log"; then
  echo "Testbox $testbox_id is still present in the active inventory; see $list_log" >&2
  (( cleanup_status == 0 )) && cleanup_status=1
fi

if (( cleanup_status != 0 )); then
  exit "$cleanup_status"
fi
printf 'verified Testbox %s is no longer active\n' "$testbox_id"
