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

  local candidate_dir candidate_commit candidate_mtime candidate_binary retained=0
  local -a order=()
  while IFS= read -r -d '' candidate_dir; do
    candidate_commit="${candidate_dir##*/}"
    [[ "$candidate_commit" =~ ^[0-9a-f]{40}$ ]] || continue
    candidate_mtime="$(mtime "$candidate_dir")"
    order+=("$candidate_mtime"$'\t'"$candidate_commit")
  done < <(find "$hosted_dir" -mindepth 1 -maxdepth 1 -type d -user "$(id -u)" -print0)

  printf 'schema\t1\ncount\t%s\ncurrent\t%s\n' "$count" "$current"
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

case "${1:-}" in
  plan) shift; plan "$@" ;;
  token) shift; token "$@" ;;
  validate) shift; validate "$@" ;;
  *) die "usage: $0 <plan|token|validate> ..." ;;
esac
