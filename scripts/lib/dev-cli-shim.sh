#!/usr/bin/env bash

# Publish the shared cmux-dev helper without exposing partial contents to
# concurrent reloads. The temporary file lives beside the target so the final
# rename is atomic on the target filesystem.
cmux_publish_dev_cli_shim() {
  local target="$1"
  local template="$2"
  local target_dir tmp

  [[ -f "$template" ]] || {
    echo "missing cmux-dev shim template: $template" >&2
    return 1
  }

  target_dir="$(dirname "$target")"
  mkdir -p "$target_dir"
  tmp="$(mktemp "$target_dir/.cmux-dev.XXXXXX")"

  if ! cp "$template" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! bash -n "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! chmod 0755 "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
}
