#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: skills.sh [options]

Install cmux agent skills into the Codex skills directory.

Options:
  --dest DIR       Destination directory. Default: ${CODEX_HOME:-$HOME/.codex}/skills
  --source DIR     Source checkout or skills directory. Default: local checkout, or GitHub when piped
  --ref REF        GitHub ref to download when no local skills directory is available. Default: main
  --skill NAME     Install one skill. Repeat to install multiple. Default: all skills
  --list           List available skills and exit
  --dry-run        Print what would be installed
  -h, --help       Show this help

Examples:
  ./skills.sh
  ./skills.sh --list
  ./skills.sh --skill cmux --skill cmux-browser
  curl -fsSL https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills.sh | bash
EOF
}

die() {
  printf 'skills.sh: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

normalize_source_dir() {
  local source="$1"
  if [[ -d "$source/skills" ]]; then
    source="$source/skills"
  fi
  printf '%s\n' "$source"
}

dest_dir="${CODEX_HOME:-$HOME/.codex}/skills"
source_dir=""
ref="${CMUX_SKILLS_REF:-main}"
list_only=0
dry_run=0
selected_skills=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ $# -ge 2 ]] || die "--dest requires a directory"
      dest_dir="$2"
      shift 2
      ;;
    --source)
      [[ $# -ge 2 ]] || die "--source requires a directory"
      source_dir="$(normalize_source_dir "$2")"
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || die "--ref requires a GitHub ref"
      ref="$2"
      shift 2
      ;;
    --skill)
      [[ $# -ge 2 ]] || die "--skill requires a skill name"
      selected_skills+=("$2")
      shift 2
      ;;
    --list)
      list_only=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

script_path="${BASH_SOURCE[0]:-}"
script_dir=""
if [[ -n "$script_path" && -f "$script_path" ]]; then
  script_dir="$(cd -- "$(dirname -- "$script_path")" >/dev/null 2>&1 && pwd || true)"
fi
if [[ -z "$source_dir" && -n "$script_dir" && -d "$script_dir/skills" ]]; then
  source_dir="$script_dir/skills"
fi

tmp_dir=""
cleanup() {
  if [[ -n "$tmp_dir" ]]; then
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT

if [[ -z "$source_dir" ]]; then
  need_cmd curl
  need_cmd tar
  need_cmd mktemp

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-skills.XXXXXX")"
  archive_url="https://codeload.github.com/manaflow-ai/cmux/tar.gz/${ref}"
  curl -fsSL "$archive_url" | tar -xz -C "$tmp_dir"
  checkout_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$checkout_dir" ]] || die "downloaded archive was empty"
  source_dir="$checkout_dir/skills"
fi

[[ -d "$source_dir" ]] || die "skills directory not found: $source_dir"

available_skills() {
  find "$source_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

if [[ "$list_only" -eq 1 ]]; then
  available_skills
  exit 0
fi

if [[ "${#selected_skills[@]}" -eq 0 ]]; then
  while IFS= read -r skill_name; do
    selected_skills+=("$skill_name")
  done < <(available_skills)
fi

[[ "${#selected_skills[@]}" -gt 0 ]] || die "no skills found in $source_dir"
[[ -n "$dest_dir" ]] || die "destination directory must not be empty"

for skill_name in "${selected_skills[@]}"; do
  [[ "$skill_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid skill name: $skill_name"
  [[ -d "$source_dir/$skill_name" ]] || die "skill not found: $skill_name"
done

if [[ "$dry_run" -eq 1 ]]; then
  printf 'Would install to %s:\n' "$dest_dir"
  for skill_name in "${selected_skills[@]}"; do
    printf '  %s\n' "$skill_name"
  done
  exit 0
fi

mkdir -p "$dest_dir"

for skill_name in "${selected_skills[@]}"; do
  src="$source_dir/$skill_name"
  tmp_target="${dest_dir:?}/.${skill_name}.tmp.$$"
  rm -rf "$tmp_target"
  cp -R "$src" "$tmp_target"
  rm -rf "${dest_dir:?}/$skill_name"
  mv "$tmp_target" "${dest_dir:?}/$skill_name"
  printf 'Installed %s -> %s\n' "$skill_name" "${dest_dir:?}/$skill_name"
done
