#!/usr/bin/env bash
set -euo pipefail

# This helper is checked out from the protected broker commit. It must run
# before and after Begin Testbox, while the checkout is still the trusted root.

die() {
  echo "::error::$*" >&2
  exit 1
}

usage() {
  echo "usage: $0 --phase pre|post" >&2
  exit 2
}

[[ $# -eq 2 && "$1" == "--phase" ]] || usage
phase="$2"
[[ "$phase" == "pre" || "$phase" == "post" ]] || usage

repository="${REPOSITORY:-${GITHUB_REPOSITORY:-}}"
event_name="${EVENT_NAME:-${GITHUB_EVENT_NAME:-}}"
dispatch_ref="${DISPATCH_REF:-${GITHUB_REF:-}}"
dispatch_sha="${DISPATCH_SHA:-${GITHUB_SHA:-}}"
broker_sha="${BLACKSMITH_TESTBOX_BROKER_SHA:-}"
reviewed_ref="${BLACKSMITH_TESTBOX_REVIEWED_REF:-}"
reviewed_sha="${BLACKSMITH_TESTBOX_REVIEWED_SHA:-}"
testbox_id="${TESTBOX_ID:-}"
expected_source_sha="${EXPECTED_INPUT_SHA:-}"
state_dir=/tmp/.testbox

[[ "$repository" == "manaflow-ai/cmux" ]] || die "repository is not manaflow-ai/cmux"
[[ "$event_name" == "workflow_dispatch" ]] || die "event is not workflow_dispatch"
[[ "$dispatch_ref" == "refs/heads/main" ]] || die "broker must be dispatched from refs/heads/main"
[[ "$broker_sha" =~ ^[0-9a-f]{40}$ ]] || die "BLACKSMITH_TESTBOX_BROKER_SHA is not a full lowercase SHA"
[[ "$dispatch_sha" =~ ^[0-9a-f]{40}$ ]] || die "github.sha is not a full lowercase SHA"
[[ "$dispatch_sha" == "$broker_sha" ]] || die "github.sha does not equal the protected broker SHA"

if [[ -n "${GITHUB_SHA:-}" && "$GITHUB_SHA" != "$dispatch_sha" ]]; then
  die "GITHUB_SHA does not equal github.sha"
fi
if [[ -n "${GITHUB_REF:-}" && "$GITHUB_REF" != "$dispatch_ref" ]]; then
  die "GITHUB_REF does not equal github.ref"
fi
if [[ -n "${GITHUB_REPOSITORY:-}" && "$GITHUB_REPOSITORY" != "$repository" ]]; then
  die "GITHUB_REPOSITORY does not equal github.repository"
fi

[[ "$reviewed_ref" =~ ^[A-Za-z0-9._/-]+$ ]] || die "protected reviewed ref is malformed"
[[ ! "$reviewed_ref" =~ ^[0-9a-f]{40}$ ]] || die "reviewed ref must not be a raw SHA"
[[ "$reviewed_ref" != refs/* ]] || die "reviewed ref must be a branch name, not a full ref"
[[ "$reviewed_ref" != /* && "$reviewed_ref" != */ ]] || die "reviewed ref has an empty path component"
[[ "$reviewed_ref" != *//* && "$reviewed_ref" != *..* ]] || die "reviewed ref contains an unsafe path component"
[[ "$reviewed_ref" != -* ]] || die "reviewed ref must not start with a dash"
git check-ref-format --branch "$reviewed_ref" >/dev/null 2>&1 || die "protected reviewed ref is not a Git branch"
[[ "$reviewed_sha" =~ ^[0-9a-f]{40}$ ]] || die "protected reviewed SHA is not a full lowercase SHA"
[[ "$testbox_id" =~ ^tbx_[A-Za-z0-9_-]+$ ]] || die "malformed Testbox ID"

if [[ -n "$expected_source_sha" ]]; then
  [[ "$expected_source_sha" =~ ^[0-9a-f]{40}$ ]] || die "source_sha assertion is not a full lowercase SHA"
  [[ "$expected_source_sha" == "$reviewed_sha" ]] || die "source_sha assertion does not equal the protected reviewed SHA"
fi

workspace="${GITHUB_WORKSPACE:-$PWD}"
git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "trusted broker checkout is not a Git worktree"
workspace_real="$(cd "$workspace" 2>/dev/null && pwd -P)" || die "GITHUB_WORKSPACE does not exist"
git_root_real="$(cd "$git_root" 2>/dev/null && pwd -P)" || die "trusted Git root does not exist"
[[ "$git_root_real" == "$workspace_real" ]] || die "current Git root is not the trusted workspace"
local_sha="$(git rev-parse --verify HEAD 2>/dev/null)" || die "trusted broker checkout has no HEAD"
[[ "$local_sha" == "$broker_sha" ]] || die "trusted checkout SHA does not equal the protected broker SHA"
[[ -z "$(git status --porcelain=v1 --untracked-files=normal)" ]] || die "trusted broker checkout is dirty"

repository_url="https://github.com/${repository}.git"
if ! remote_sha="$(git ls-remote --exit-code "$repository_url" refs/heads/main | awk 'NR == 1 { print $1 }')"; then
  die "could not read the remote SHA for refs/heads/main"
fi
[[ "$remote_sha" == "$broker_sha" ]] || die "remote SHA for refs/heads/main does not equal the protected broker SHA"

if ! reviewed_remote_sha="$(git ls-remote --exit-code "$repository_url" "refs/heads/$reviewed_ref" | awk 'NR == 1 { print $1 }')"; then
  die "could not read the remote SHA for the protected reviewed ref"
fi
[[ "$reviewed_remote_sha" == "$reviewed_sha" ]] || die "remote SHA for the reviewed ref does not equal the protected reviewed SHA"

if [[ "$phase" == "pre" ]]; then
  if [[ -e "$state_dir" || -L "$state_dir" ]]; then
    die "stale Testbox registration state exists before Begin Testbox"
  fi
  printf 'preflight passed: broker SHA %s, reviewed ref %s at remote SHA %s\n' \
    "$broker_sha" "$reviewed_ref" "$reviewed_remote_sha"
  exit 0
fi

[[ -d "$state_dir" && ! -L "$state_dir" ]] || die "Testbox registration state is absent after Begin Testbox"
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

state_testbox_id="$(read_state testbox_id)"
state_model_id="$(read_state installation_model_id)"
state_auth_token="$(read_state auth_token)"
state_api_url="$(read_state api_url)"
state_runner_host="$(read_state runner_host)"
state_runner_port="$(read_state runner_ssh_port)"
state_working_directory="$(read_state working_directory)"
state_run_id="$(read_state adopted_run_id)"

[[ "$state_testbox_id" == "$testbox_id" ]] || die "Testbox registration state names a different testbox_id"
[[ "$state_model_id" =~ ^[0-9]+$ ]] || die "Testbox installation model ID is malformed"
[[ "$state_auth_token" != *$'\n'* && "$state_auth_token" != *$'\r'* ]] || die "Testbox auth token contains a newline"
[[ "$state_api_url" =~ ^https://[^[:space:]]+$ ]] || die "Testbox API URL is not HTTPS"
[[ "$state_runner_host" != *[[:space:]]* ]] || die "Testbox runner host contains whitespace"
[[ "$state_runner_port" =~ ^[0-9]{1,5}$ ]] || die "Testbox SSH port is malformed"
port_value=$((10#$state_runner_port))
(( port_value >= 1 && port_value <= 65535 )) || die "Testbox SSH port is outside the valid range"
[[ "$state_working_directory" == "$workspace_real" ]] || die "Testbox working directory is not the trusted workspace"
[[ "$state_run_id" =~ ^[0-9]+$ ]] || die "Testbox adopted run ID is malformed"
if [[ -n "${GITHUB_RUN_ID:-}" && "$state_run_id" != "$GITHUB_RUN_ID" ]]; then
  die "Testbox registration belongs to a different workflow run"
fi

printf 'postflight passed: broker SHA %s, reviewed ref %s at remote SHA %s, testbox_id %s\n' \
  "$broker_sha" "$reviewed_ref" "$reviewed_remote_sha" "$state_testbox_id"
