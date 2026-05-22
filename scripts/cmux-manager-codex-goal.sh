#!/usr/bin/env bash
set -euo pipefail

apply=0
surface=""
goal_dir="${CMUX_MANAGER_GOAL_DIR:-$HOME/.cache/cmux-manager-loop/codex-goals}"

usage() {
  cat <<'USAGE'
Usage: scripts/cmux-manager-codex-goal.sh [--dry-run|--apply] [--surface <surface>] <command> <workspace> [prompt...]

Commands:
  set <workspace> <prompt...>     Send a fresh goal prompt to the Codex composer.
  pause <workspace>               Send Escape to stop/pause the current Codex turn.
  resume <workspace> [prompt...]  Resume with a prompt, or a default continue nudge.
  swap <workspace> <prompt...>    Ctrl-C the current turn, then send a new goal prompt.

Dry-run is the default. Use --apply to send keys.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

shell_join() {
  local first=1 part
  for part in "$@"; do
    if [[ "$first" -eq 0 ]]; then
      printf ' '
    fi
    first=0
    printf '%q' "$part"
  done
  printf '\n'
}

workspace_key() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.:-' '_'
}

marker_path() {
  local workspace="$1"
  local key
  key="$(workspace_key "$workspace")"
  printf '%s/%s.goal\n' "$goal_dir" "$key"
}

current_objective() {
  local workspace="$1"
  local marker
  marker="$(marker_path "$workspace")"
  if [[ -f "$marker" ]]; then
    sed -n 's/^objective=//p' "$marker" | tail -n 1
  fi
}

run_cmd() {
  if [[ "$apply" -eq 1 ]]; then
    "$@"
  else
    printf 'dry-run: '
    shell_join "$@"
  fi
}

resolve_surface() {
  local workspace="$1"

  if [[ -n "$surface" ]]; then
    printf '%s\n' "$surface"
    return
  fi

  command -v jq >/dev/null 2>&1 || die "jq is required when --surface is omitted"

  local json ref
  json="$(cmux list-pane-surfaces --workspace "$workspace" --json)"
  ref="$(
    jq -r '
      [.surfaces[] | select(.type == "terminal")] as $terms
      | (
          $terms
          | map(select(((.title // "") | ascii_downcase | contains("codex"))))
          | .[0].ref
        ) // ($terms[0].ref // empty)
    ' <<<"$json"
  )"

  [[ -n "$ref" ]] || die "no terminal surface found in $workspace"
  printf '%s\n' "$ref"
}

record_goal() {
  local workspace="$1"
  local state="$2"
  local objective="$3"
  local marker
  marker="$(marker_path "$workspace")"

  if [[ "$apply" -eq 1 ]]; then
    mkdir -p "$goal_dir"
    {
      printf 'workspace=%s\n' "$workspace"
      printf 'state=%s\n' "$state"
      printf 'objective=%s\n' "$objective"
      printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$marker"
  else
    printf 'dry-run: write %s state=%s objective=%q\n' "$marker" "$state" "$objective"
  fi
}

send_prompt() {
  local workspace="$1"
  local target_surface="$2"
  local prompt="$3"
  run_cmd cmux send --workspace "$workspace" --surface "$target_surface" "$prompt"
  run_cmd cmux send-key --workspace "$workspace" --surface "$target_surface" enter
}

[[ $# -gt 0 ]] || {
  usage
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      apply=1
      shift
      ;;
    --dry-run)
      apply=0
      shift
      ;;
    --surface)
      [[ $# -ge 2 ]] || die "--surface requires a value"
      surface="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -ge 2 ]] || {
  usage
  exit 2
}

command_name="$1"
workspace="$2"
shift 2
prompt="$*"
target_surface="$(resolve_surface "$workspace")"

case "$command_name" in
  set)
    [[ -n "$prompt" ]] || die "set requires a prompt"
    send_prompt "$workspace" "$target_surface" "$prompt"
    record_goal "$workspace" "active" "$prompt"
    ;;
  pause)
    [[ -z "$prompt" ]] || die "pause does not accept a prompt"
    run_cmd cmux send-key --workspace "$workspace" --surface "$target_surface" escape
    record_goal "$workspace" "paused" "$(current_objective "$workspace")"
    ;;
  resume)
    if [[ -z "$prompt" ]]; then
      prompt="continue with the current goal"
      objective="$(current_objective "$workspace")"
    else
      objective="$prompt"
    fi
    send_prompt "$workspace" "$target_surface" "$prompt"
    record_goal "$workspace" "active" "${objective:-$prompt}"
    ;;
  swap)
    [[ -n "$prompt" ]] || die "swap requires a prompt"
    run_cmd cmux send-key --workspace "$workspace" --surface "$target_surface" ctrl+c
    send_prompt "$workspace" "$target_surface" "$prompt"
    record_goal "$workspace" "active" "$prompt"
    ;;
  *)
    die "unknown command: $command_name"
    ;;
esac
