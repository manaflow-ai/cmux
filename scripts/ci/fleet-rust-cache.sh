#!/usr/bin/env bash
# Resolve a stable Cargo target directory for a managed fleet build.
#
# This helper is intentionally credential-free. HQ injects sccache and the
# worker-only R2 configuration in the managed worker recipe. Source checkouts
# use this file only to derive a target path from the toolchain selected by the
# manifest and the requested target triple.
#
# Source this file, then call:
#   fleet_rust_target_dir PROJECT [TARGET_TRIPLE] [MANIFEST_DIR]
#
# PROJECT is a short workspace name (for example acpmux, chief, or cmux-tui).
# MANIFEST_DIR is the directory Cargo/rustup should inspect for its manifest;
# it defaults to the caller's current directory.

fleet_rust_cache_slug() {
  local value="${1:-}"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 2
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "$value"
}

fleet_rust_target_dir() {
  local project="${1:-}"
  local requested_target="${2:-}"
  local manifest_dir="${3:-$PWD}"
  local toolchain rust_release rust_host target root project_key toolchain_key target_key

  project_key="$(fleet_rust_cache_slug "$project")" || {
    echo "fleet-rust-cache: invalid project name" >&2
    return 2
  }
  [[ -d "$manifest_dir" ]] || {
    echo "fleet-rust-cache: manifest directory does not exist: $manifest_dir" >&2
    return 2
  }

  # Resolve both values from the manifest's working directory. `rustc` and
  # `rustup` proxies honor rust-toolchain.toml only after changing into it.
  toolchain="$(cd "$manifest_dir" && rustup show active-toolchain 2>/dev/null | awk 'NR == 1 {print $1}')" || true
  rust_release="$(cd "$manifest_dir" && rustc -Vv 2>/dev/null | awk -F': ' '$1 == "release" {print $2; exit}')" || true
  rust_host="$(cd "$manifest_dir" && rustc -Vv 2>/dev/null | awk -F': ' '$1 == "host" {print $2; exit}')" || true
  [[ -n "$toolchain" && -n "$rust_release" && -n "$rust_host" ]] || {
    echo "fleet-rust-cache: cannot identify the manifest Rust toolchain in $manifest_dir" >&2
    return 78
  }
  target="${requested_target:-${CARGO_BUILD_TARGET:-$rust_host}}"
  target_key="$(fleet_rust_cache_slug "$target")" || {
    echo "fleet-rust-cache: invalid target triple" >&2
    return 2
  }
  toolchain_key="$(fleet_rust_cache_slug "${toolchain}-${rust_release}-${rust_host}")" || {
    echo "fleet-rust-cache: invalid toolchain identity" >&2
    return 2
  }
  root="${CMUX_FLEET_RUST_TARGET_ROOT:-${CI_SHARED_CACHE_DIR:-$HOME/.cache/cmux-build-fleet}/rust-targets}"
  [[ -n "$root" && "$root" != */.. && "$root" != *$'\n'* ]] || {
    echo "fleet-rust-cache: invalid target root" >&2
    return 2
  }
  root="${root%/}"
  printf '%s/%s/%s/%s\n' "$root" "$project_key" "$toolchain_key" "$target_key"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --target-dir)
      [[ $# -ge 2 && $# -le 4 ]] || {
        echo "usage: $0 --target-dir PROJECT [TARGET_TRIPLE] [MANIFEST_DIR]" >&2
        exit 2
      }
      fleet_rust_target_dir "$2" "${3:-}" "${4:-$PWD}"
      ;;
    -h|--help)
      sed -n '2,17p' "$0" | sed 's/^# //'
      ;;
    *)
      echo "usage: $0 --target-dir PROJECT [TARGET_TRIPLE] [MANIFEST_DIR]" >&2
      exit 2
      ;;
  esac
fi
