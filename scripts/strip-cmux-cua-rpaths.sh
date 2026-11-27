#!/usr/bin/env bash
# Remove linker search paths that point at the build machine's toolchain.
# The caller must re-sign the binary after this mutation.
set -euo pipefail

if [[ "$#" -lt 1 ]]; then
  echo "usage: $0 <mach-o>..." >&2
  exit 2
fi

OTOOL_TOOL="${OTOOL_TOOL:-/usr/bin/otool}"
INSTALL_NAME_TOOL="${INSTALL_NAME_TOOL:-/usr/bin/install_name_tool}"
LIPO_TOOL="${LIPO_TOOL:-/usr/bin/lipo}"
for tool in "$OTOOL_TOOL" "$INSTALL_NAME_TOOL" "$LIPO_TOOL"; do
  if [[ ! -x "$tool" ]]; then
    echo "error: required Mach-O tool not found or not executable: $tool" >&2
    exit 1
  fi
done

relative_rpath_is_inside_bundle() {
  local binary="$1"
  local rpath="$2"
  local base_dir
  local suffix
  case "$rpath" in
    @loader_path*)
      base_dir="$(dirname "$binary")"
      suffix="${rpath#@loader_path}"
      ;;
    @executable_path*)
      base_dir="$(dirname "$binary")"
      suffix="${rpath#@executable_path}"
      ;;
    *)
      return 1
      ;;
  esac

  /usr/bin/python3 - "$base_dir" "$suffix" <<'PY'
import os
import sys

base_dir, suffix = sys.argv[1:]
bundle_root = os.path.abspath(base_dir)
while bundle_root != os.path.dirname(bundle_root) and not bundle_root.endswith(".app"):
    bundle_root = os.path.dirname(bundle_root)
if not bundle_root.endswith(".app"):
    raise SystemExit(1)
candidate = os.path.abspath(os.path.join(base_dir, suffix.lstrip("/")))
try:
    inside = os.path.commonpath((bundle_root, candidate)) == bundle_root
except ValueError:
    inside = False
raise SystemExit(0 if inside else 1)
PY
}

rpath_is_allowed() {
  local binary="$1"
  local rpath="$2"
  if [[ "$rpath" == "/usr/lib/swift" ]]; then
    return 0
  fi
  relative_rpath_is_inside_bundle "$binary" "$rpath"
}

strip_thin_binary() {
  local binary="$1"
  local context_binary="${2:-$binary}"
  local rpaths
  if ! rpaths="$("$OTOOL_TOOL" -arch all -l "$binary" 2>&1)"; then
    echo "error: could not inspect Mach-O rpaths: $binary" >&2
    echo "$rpaths" >&2
    return 1
  fi
  while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue
    if ! rpath_is_allowed "$context_binary" "$rpath"; then
      echo "Removing non-bundled cmux-cua rpath from $binary: $rpath"
      "$INSTALL_NAME_TOOL" -delete_rpath "$rpath" "$binary"
    fi
  done < <(
    printf '%s\n' "$rpaths" | awk '
      $1 == "cmd" {
        command = $2
        next
      }
      command == "LC_RPATH" && $1 == "path" {
        value = $0
        sub(/^[[:space:]]+path[[:space:]]+/, "", value)
        sub(/[[:space:]]+\(offset [0-9]+\).*$/, "", value)
        print value
        command = ""
      }
    '
  )
}

strip_binary() {
  local binary="$1"
  local archs
  local mode
  local scratch
  local arch
  local slice
  local rebuilt
  local -a arch_list
  local -a slices

  if [[ ! -f "$binary" ]]; then
    echo "error: Mach-O binary not found: $binary" >&2
    return 1
  fi

  archs="$("$LIPO_TOOL" -archs "$binary")"
  mode="$(stat -f '%Lp' "$binary")"
  read -r -a arch_list <<<"$archs"
  if [[ "${#arch_list[@]}" -le 1 ]]; then
    strip_thin_binary "$binary" "$binary"
    return 0
  fi

  scratch="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cua-rpaths.XXXXXX")"
  for arch in "${arch_list[@]}"; do
    slice="$scratch/$arch"
    "$LIPO_TOOL" -thin "$arch" "$binary" -output "$slice"
    strip_thin_binary "$slice" "$binary"
    slices+=("$slice")
  done
  rebuilt="$scratch/rebuilt"
  "$LIPO_TOOL" -create "${slices[@]}" -output "$rebuilt"
  cp "$rebuilt" "$binary"
  chmod "$mode" "$binary"
  rm -rf "$scratch"
}

for binary in "$@"; do
  strip_binary "$binary"
done
