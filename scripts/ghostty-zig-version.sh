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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ghostty_minimum_zig_version "${1:-}"
fi
