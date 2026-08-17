#!/usr/bin/env bash

ghostty_minimum_zig_version() {
  local repo_root="${1:-}"
  if [[ -z "$repo_root" ]]; then
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi

  local manifest="$repo_root/ghostty/build.zig.zon"
  if [[ ! -f "$manifest" ]]; then
    echo "error: Ghostty Zig manifest not found: $manifest" >&2
    return 1
  fi

  local version
  version="$(
    sed -nE 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
      "$manifest" | head -1
  )"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: invalid Ghostty minimum_zig_version in $manifest" >&2
    return 1
  fi

  printf '%s\n' "$version"
}

ghostty_zig_version_is_compatible() {
  local actual="${1:-}"
  local required="${2:-}"
  local actual_core="${actual%%[-+]*}"
  local required_core="${required%%[-+]*}"
  local actual_major actual_minor actual_patch actual_extra
  local required_major required_minor required_patch required_extra

  IFS=. read -r actual_major actual_minor actual_patch actual_extra <<< "$actual_core"
  IFS=. read -r required_major required_minor required_patch required_extra <<< "$required_core"

  if [[ -n "${actual_extra:-}" || -n "${required_extra:-}" ]] ||
     [[ ! "$actual_major" =~ ^[0-9]+$ || ! "$actual_minor" =~ ^[0-9]+$ || ! "$actual_patch" =~ ^[0-9]+$ ]] ||
     [[ ! "$required_major" =~ ^[0-9]+$ || ! "$required_minor" =~ ^[0-9]+$ || ! "$required_patch" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  (( 10#$actual_major == 10#$required_major &&
     10#$actual_minor == 10#$required_minor &&
     10#$actual_patch >= 10#$required_patch ))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ghostty_minimum_zig_version "${1:-}"
fi
