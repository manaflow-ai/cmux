#!/usr/bin/env bash
set -euo pipefail

die() { echo "error: $*" >&2; exit 2; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "$1 is required for hosted artifact retention"; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "shasum or sha256sum is required for hosted artifact retention"
  fi
}

mtime() {
  local path="$1" value=""
  value="$(stat -f '%m' "$path" 2>/dev/null || true)"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    value="$(stat -c '%Y' "$path" 2>/dev/null || true)"
  fi
  [[ "$value" =~ ^[0-9]+$ ]] || die "could not read a numeric modification time for $path"
  printf '%s\n' "$value"
}

plan() {
  [[ $# -eq 3 ]] || die "usage: $0 plan <hosted-dir> <count> <current-commit>"
  local hosted_dir="$1" count="$2" current="$3"
  [[ "$count" =~ ^[1-9][0-9]{0,3}$ ]] || die "retention count must be an integer from 1 through 1000"
  (( 10#$count <= 1000 )) || die "retention count must be at most 1000"
  [[ "$current" =~ ^[0-9a-f]{40}$ ]] || die "current commit must be a lowercase 40-character SHA"
  [[ -d "$hosted_dir" ]] || die "hosted artifact directory does not exist: $hosted_dir"
  for prerequisite in find id sort stat lsof; do require_command "$prerequisite"; done

  local hosted_identity candidate_dir candidate_commit candidate_mtime candidate_binary retained=0
  hosted_identity="$(cd -- "$hosted_dir" && pwd -P)" || die "could not resolve hosted artifact directory: $hosted_dir"
  local -a order=()
  while IFS= read -r -d '' candidate_dir; do
    candidate_commit="${candidate_dir##*/}"
    [[ "$candidate_commit" =~ ^[0-9a-f]{40}$ ]] || continue
    candidate_mtime="$(mtime "$candidate_dir")"
    order+=("$candidate_mtime"$'\t'"$candidate_commit")
  done < <(find "$hosted_dir" -mindepth 1 -maxdepth 1 -type d -user "$(id -u)" -print0)

  printf 'schema\t1\nhosted-dir\t%s\ncount\t%s\ncurrent\t%s\n' "$hosted_identity" "$count" "$current"
  while IFS=$'\t' read -r _ candidate_commit; do
    [[ -n "$candidate_commit" ]] || continue
    if [[ "$candidate_commit" == "$current" ]]; then
      printf 'current-candidate\t%s\n' "$candidate_commit"
      continue
    fi
    if (( retained < 10#$count )); then
      retained=$((retained + 1))
      printf 'candidate\t%s\n' "$candidate_commit"
      continue
    fi
    candidate_binary="$hosted_dir/$candidate_commit/cmux-tui"
    if [[ -f "$candidate_binary" ]] && lsof -t -- "$candidate_binary" >/dev/null 2>&1; then
      printf 'active\t%s\n' "$candidate_commit"
    else
      printf 'victim\t%s\n' "$candidate_commit"
    fi
  done < <(if ((${#order[@]})); then printf '%s\n' "${order[@]}" | sort -t $'\t' -k1,1nr -k2,2r; fi)
}

token() {
  [[ $# -eq 2 ]] || die "usage: $0 token <plan-file> <unix-time>"
  local plan_file="$1" now="$2"
  [[ -s "$plan_file" ]] || die "retention plan is absent or empty"
  [[ "$now" =~ ^[0-9]+$ ]] || die "token time must be a non-negative integer"
  require_command awk
  printf 'schema\t1\nplan-sha256\t%s\ncreated-at\t%s\n' "$(sha256_file "$plan_file")" "$now"
}

validate() {
  [[ $# -eq 4 ]] || die "usage: $0 validate <plan-file> <token-file> <unix-time> <max-age>"
  local plan_file="$1" token_file="$2" now="$3" max_age="$4" schema hash created expected_hash
  [[ -s "$plan_file" && -s "$token_file" ]] || die "retention plan or preview token is absent"
  [[ "$now" =~ ^[0-9]+$ && "$max_age" =~ ^[1-9][0-9]*$ ]] || die "validation times must be bounded integers"
  schema="$(awk -F '\t' '$1 == "schema" {print $2}' "$token_file")"
  hash="$(awk -F '\t' '$1 == "plan-sha256" {print $2}' "$token_file")"
  created="$(awk -F '\t' '$1 == "created-at" {print $2}' "$token_file")"
  [[ "$schema" == 1 && "$hash" =~ ^[0-9a-f]{64}$ && "$created" =~ ^[0-9]+$ ]] || die "preview token is malformed"
  expected_hash="$(sha256_file "$plan_file")"
  [[ "$hash" == "$expected_hash" ]] || die "preview token does not match the current retention plan"
  (( 10#$now >= 10#$created && 10#$now - 10#$created <= 10#$max_age )) || die "preview token is stale or from the future"
}

remove() {
  [[ $# -eq 5 ]] || die "usage: $0 remove <hosted-dir> <commit> <plan-file> <token-file> <current-commit>"
  local hosted_dir="$1" candidate_commit="$2" plan_file="$3" token_file="$4" current="$5"
  local candidate_binary plan_current plan_hosted_dir hosted_identity
  [[ -d "$hosted_dir" ]] || die "hosted artifact directory does not exist: $hosted_dir"
  [[ "$candidate_commit" =~ ^[0-9a-f]{40}$ ]] || die "artifact commit must be a lowercase 40-character SHA"
  [[ "$current" =~ ^[0-9a-f]{40}$ ]] || die "current commit must be a lowercase 40-character SHA"
  [[ "${CMUX_TUI_HOSTED_RETENTION_CONFIRM:-0}" == 1 ]] || die "destructive retention requires CMUX_TUI_HOSTED_RETENTION_CONFIRM=1"
  validate "$plan_file" "$token_file" "$(date +%s)" 600
  hosted_identity="$(cd -- "$hosted_dir" && pwd -P)" || die "could not resolve hosted artifact directory: $hosted_dir"
  plan_hosted_dir="$(awk -F '\t' '$1 == "hosted-dir" {print $2}' "$plan_file")"
  [[ "$plan_hosted_dir" == "$hosted_identity" ]] || die "retention plan hosted directory does not match removal request"
  plan_current="$(awk -F '\t' '$1 == "current" {print $2}' "$plan_file")"
  [[ "$plan_current" == "$current" ]] || die "retention plan current commit does not match removal request"
  awk -F '\t' -v candidate="$candidate_commit" '$1 == "victim" && $2 == candidate {found = 1} END {exit !found}' "$plan_file" \
    || die "artifact is not a victim in the validated retention plan"
  require_command lsof
  candidate_binary="$hosted_dir/$candidate_commit/cmux-tui"
  if [[ -f "$candidate_binary" ]] && lsof -t -- "$candidate_binary" >/dev/null 2>&1; then
    printf 'active\t%s\n' "$candidate_commit"
    return 0
  fi
  rm -rf -- "${hosted_dir:?}/$candidate_commit"
  printf 'removed\t%s\n' "$candidate_commit"
}

case "${1:-}" in
  plan) shift; plan "$@" ;;
  token) shift; token "$@" ;;
  validate) shift; validate "$@" ;;
  remove) shift; remove "$@" ;;
  *) die "usage: $0 <plan|token|validate|remove> ..." ;;
esac
