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
# The requester picks --idle-timeout, but every idle minute holds a 32 vCPU
# runner. Clamp it so a crashed or forgetful agent leaks at most this long.
# Activity (an open SSH session or a `testbox run`) still resets the timer, so
# long builds and active sessions are unaffected.
max_idle_timeout_minutes=15
if (( idle_timeout_minutes > max_idle_timeout_minutes )); then
  printf 'clamping requested idle timeout %s min to %s min\n' "$idle_timeout_minutes" "$max_idle_timeout_minutes"
  idle_timeout_minutes="$max_idle_timeout_minutes"
fi
(( idle_timeout_minutes >= 1 )) || idle_timeout_minutes=1
printf 'idle timeout: %s min\n' "$idle_timeout_minutes"
busy_check="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/blacksmith-testbox-busy.sh"
# Run through bash, so a lost exec bit cannot read as "not busy"; say so at
# startup when the helper is missing (the keepalive then counts only SSH and
# the activity marker).
[[ -f "$busy_check" ]] || printf 'warning: %s is missing; commands in the checkout do not count as use\n' "$busy_check" >&2
last_activity="$(date +%s)"
idle_timeout_seconds=$((idle_timeout_minutes * 60))
# The owner ends a box with scripts/blacksmith-testbox-release.sh, which writes
# this marker. `blacksmith testbox stop` destroys the VM before any post step
# runs, so the warm target dir sticky disk is never committed on that path. A
# clean exit here lets the job succeed and the sticky disk post step commit.
release_marker="$HOME/.testbox-release"
rm -f "$release_marker"
repo_root="${GITHUB_WORKSPACE:-$working_directory}"
# Copy the release helpers now: `blacksmith testbox run` later syncs a
# candidate worktree over scripts/, which may lack or change them.
script_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/testbox-release.XXXXXX")"
for helper in blacksmith-testbox-target-prune.sh blacksmith-testbox-source-mtimes.py; do
  cp "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$helper" "$script_dir/" \
    || echo "warning: missing $helper; the warm target dir is committed unpruned" >&2
done

release_runner() {
  printf '%s; releasing the Testbox runner\n' "$1"
  # Bound the commit size. A prune failure must not fail the job: the
  # sticky disk would then skip the commit and keep the previous snapshot.
  local target_dir="$repo_root/cmux-tui/target"
  timeout 900 bash "$script_dir/blacksmith-testbox-target-prune.sh" "$target_dir" \
    || echo "warning: target prune failed; committing as is" >&2
  # Record source mtimes next to the artifacts, so the next box can treat
  # unchanged sources as unchanged. Without it the next box rebuilds every
  # workspace crate; that is slower, never wrong.
  if [[ -d "$target_dir" ]]; then
    timeout 300 python3 -I "$script_dir/blacksmith-testbox-source-mtimes.py" record \
      "$repo_root" "$target_dir/.cmux-testbox-source-mtimes.tsv" \
      || echo "warning: could not record source mtimes" >&2
  fi
  sync || true
  phone_home_with_retry completed || echo "warning: could not report completed" >&2
  exit 0
}

while :; do
  sleep 30
  now="$(date +%s)"
  if [[ -e "$release_marker" ]]; then
    release_runner "release requested"
  fi
  if ss -tnp 2>/dev/null | grep -Eq ":${runner_ssh_port}([^0-9]|$)"; then
    last_activity="$now"
  elif bash "$busy_check" "$working_directory" "$$"; then
    # A command still runs in the checkout after its SSH session ended (a
    # detached cargo test): run 37105812136 released such a box mid-test.
    last_activity="$now"
  elif [[ -f "$HOME/.testbox-last-activity" ]]; then
    marker_mtime="$(stat -c %Y "$HOME/.testbox-last-activity" 2>/dev/null || stat -f %m "$HOME/.testbox-last-activity")"
    if [[ "$marker_mtime" -gt "$last_activity" ]]; then
      last_activity="$marker_mtime"
    fi
  fi
  if (( now - last_activity >= idle_timeout_seconds )); then
    release_runner "idle for $((now - last_activity)) s"
  fi
done
