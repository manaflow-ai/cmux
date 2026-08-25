#!/usr/bin/env bash
set -euo pipefail

# This is the trusted-main replacement for the upstream keepalive composite.
# It deliberately reads the Testbox token only after GitHub has evaluated the
# protected environment and the workflow's main/repository guard.
state=/tmp/.testbox
job_status="${JOB_STATUS:-failure}"

if [[ ! -d "$state" ]]; then
  if [[ "$job_status" == "success" ]]; then
    echo "Testbox validation passed, but no registration state was returned" >&2
    exit 1
  fi
  echo "Testbox registration state is absent after a failed setup; no phone-home is possible" >&2
  exit 0
fi

for required_file in testbox_id installation_model_id auth_token api_url runner_host runner_ssh_port adopted_run_id working_directory; do
  test -s "$state/$required_file" || {
    echo "missing Testbox state file: $state/$required_file" >&2
    exit 1
  }
done

testbox_id="$(<"$state/testbox_id")"
installation_model_id="$(<"$state/installation_model_id")"
auth_token="$(<"$state/auth_token")"
api_url="$(<"$state/api_url")"
runner_host="$(<"$state/runner_host")"
runner_ssh_port="$(<"$state/runner_ssh_port")"
working_directory="$(<"$state/working_directory")"
adopted_run_id="$(<"$state/adopted_run_id")"
[[ "$testbox_id" =~ ^tbx_[A-Za-z0-9_-]+$ ]]
[[ "$installation_model_id" =~ ^[0-9]+$ ]]

phone_home() {
  local status="$1"
  local payload
  payload="$(jq -n \
    --arg testbox_id "$testbox_id" \
    --arg runner_host "$runner_host" \
    --arg runner_ssh_port "$runner_ssh_port" \
    --arg working_directory "$working_directory" \
    --arg adopted_run_id "$adopted_run_id" \
    --arg status "$status" \
    --argjson installation_model_id "$installation_model_id" \
    '{testbox_id: $testbox_id, installation_model_id: $installation_model_id, status: $status, ip_address: $runner_host, ssh_port: $runner_ssh_port, working_directory: $working_directory, adopted_run_id: $adopted_run_id, metadata: {}}')"
  curl --fail --silent --show-error --connect-timeout 2 --max-time 10 \
    -X POST "$api_url/api/testbox/phone-home" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $auth_token" \
    --data "$payload" >/dev/null
}

phone_home_with_retry() {
  local status="$1"
  local attempt
  for attempt in 1 2 3 4 5; do
    if phone_home "$status"; then
      return 0
    fi
    if (( attempt < 5 )); then
      sleep $((attempt * 2))
    fi
  done
  return 1
}

if [[ "$job_status" != "success" ]]; then
  if ! phone_home_with_retry hydration_failed; then
    echo "warning: could not report hydration_failed" >&2
  fi
  echo "Testbox hydration failed; no ready state was published" >&2
  exit 0
fi

if ! phone_home_with_retry ready; then
  echo "ready phone-home failed after bounded retries" >&2
  phone_home_with_retry hydration_failed || echo "warning: could not report hydration_failed" >&2
  exit 1
fi

printf 'Testbox ready: %s (%s)\n' "$testbox_id" "$runner_host"
idle_timeout_minutes="10"
if [[ -s "$state/idle_timeout" ]]; then
  idle_timeout_minutes="$(cat "$state/idle_timeout")"
fi
[[ "$idle_timeout_minutes" =~ ^[0-9]+$ ]] || idle_timeout_minutes=10
last_activity="$(date +%s)"
idle_timeout_seconds=$((idle_timeout_minutes * 60))

while :; do
  sleep 30
  now="$(date +%s)"
  if ss -tnp 2>/dev/null | grep -Eq ":${runner_ssh_port}([^0-9]|$)"; then
    last_activity="$now"
  elif [[ -f "$HOME/.testbox-last-activity" ]]; then
    marker_mtime="$(stat -c %Y "$HOME/.testbox-last-activity" 2>/dev/null || stat -f %m "$HOME/.testbox-last-activity")"
    if [[ "$marker_mtime" -gt "$last_activity" ]]; then
      last_activity="$marker_mtime"
    fi
  fi
  if (( now - last_activity >= idle_timeout_seconds )); then
    phone_home_with_retry completed || echo "warning: could not report completed" >&2
    exit 0
  fi
done
