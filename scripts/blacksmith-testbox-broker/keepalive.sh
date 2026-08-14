#!/usr/bin/env bash
set -euo pipefail

# This helper is broker-owned. It reads only the state written by the pinned
# Begin Testbox action and never sources code from candidate-source.

die() {
  echo "::error::$*" >&2
  exit 1
}

state_dir=/tmp/.testbox
job_status="${JOB_STATUS:-failure}"
expected_testbox_id="${TESTBOX_ID:-}"
workspace="${GITHUB_WORKSPACE:-$PWD}"

[[ -d "$state_dir" && ! -L "$state_dir" ]] || die "Testbox registration state is absent"
state_mode="$(stat -c '%a' "$state_dir" 2>/dev/null || stat -f '%Lp' "$state_dir")"
[[ "$state_mode" == "700" ]] || die "Testbox registration state directory is not private"

read_state() {
  local name="$1"
  local path="$state_dir/$name"
  [[ -f "$path" && ! -L "$path" ]] || die "missing Testbox registration state file: $name"
  local value
  value="$(<"$path")"
  [[ -n "$value" ]] || die "empty Testbox registration state file: $name"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "unsafe newline in Testbox registration state: $name"
  printf '%s' "$value"
}

testbox_id="$(read_state testbox_id)"
installation_model_id="$(read_state installation_model_id)"
auth_token="$(read_state auth_token)"
api_url="$(read_state api_url)"
runner_host="$(read_state runner_host)"
runner_ssh_port="$(read_state runner_ssh_port)"
working_directory="$(read_state working_directory)"
adopted_run_id="$(read_state adopted_run_id)"

[[ "$testbox_id" =~ ^tbx_[A-Za-z0-9_-]+$ ]] || die "malformed Testbox ID in registration state"
if [[ -n "$expected_testbox_id" && "$testbox_id" != "$expected_testbox_id" ]]; then
  die "Testbox registration state does not match inputs.testbox_id"
fi
[[ "$installation_model_id" =~ ^[0-9]+$ ]] || die "malformed Testbox installation model ID"
[[ "$api_url" =~ ^https://[^[:space:]]+$ ]] || die "Testbox API URL is not HTTPS"
[[ "$runner_host" != *[[:space:]]* ]] || die "Testbox runner host contains whitespace"
[[ "$runner_ssh_port" =~ ^[0-9]{1,5}$ ]] || die "malformed Testbox SSH port"
port_value=$((10#$runner_ssh_port))
(( port_value >= 1 && port_value <= 65535 )) || die "Testbox SSH port is outside the valid range"
workspace_real="$(cd "$workspace" 2>/dev/null && pwd -P)" || die "GITHUB_WORKSPACE does not exist"
[[ "$working_directory" == "$workspace_real" ]] || die "Testbox working directory is not the trusted workspace"
[[ "$adopted_run_id" =~ ^[0-9]+$ ]] || die "malformed Testbox adopted run ID"
if [[ -n "${GITHUB_RUN_ID:-}" && "$adopted_run_id" != "$GITHUB_RUN_ID" ]]; then
  die "Testbox registration belongs to a different workflow run"
fi

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
  phone_home_with_retry hydration_failed || die "could not report hydration_failed"
  echo "Testbox hydration failed; no ready state was published" >&2
  exit 0
fi

if ! phone_home_with_retry ready; then
  echo "ready phone-home failed after bounded retries" >&2
  phone_home_with_retry hydration_failed || true
  exit 1
fi

printf 'Testbox ready: %s (%s)\n' "$testbox_id" "$runner_host"
idle_timeout_minutes=10
if [[ -f "$state_dir/idle_timeout" && ! -L "$state_dir/idle_timeout" ]]; then
  candidate_timeout="$(<"$state_dir/idle_timeout")"
  if [[ "$candidate_timeout" =~ ^[0-9]{1,4}$ ]] && (( 10#$candidate_timeout > 0 )); then
    idle_timeout_minutes="$candidate_timeout"
  fi
fi
idle_timeout_seconds=$((10#$idle_timeout_minutes * 60))
last_activity="$(date +%s)"

while :; do
  sleep 30
  now="$(date +%s)"
  if ss -tnp 2>/dev/null | grep -Eq ":${runner_ssh_port}([^0-9]|$)"; then
    last_activity="$now"
  elif [[ -f "$HOME/.testbox-last-activity" && ! -L "$HOME/.testbox-last-activity" ]]; then
    marker_mtime="$(stat -c %Y "$HOME/.testbox-last-activity" 2>/dev/null || stat -f %m "$HOME/.testbox-last-activity")"
    if [[ "$marker_mtime" =~ ^[0-9]+$ && "$marker_mtime" -gt "$last_activity" ]]; then
      last_activity="$marker_mtime"
    fi
  fi
  if (( now - last_activity >= idle_timeout_seconds )); then
    phone_home_with_retry completed || die "could not report completed"
    exit 0
  fi
done
