#!/usr/bin/env bash
# Receipt helpers for reload.sh post-build artifacts.

reload_incremental_sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

reload_incremental_manifest_digest() {
  local value="$1"
  printf '%s' "$value" | if command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  else
    sha256sum
  fi | awk '{print $1}'
}

reload_incremental_tree_digest() {
  local root="$1"
  python3 - "$root" <<'PY'
import hashlib
import os
import stat
import sys

root = os.path.abspath(sys.argv[1])
hash_value = hashlib.sha256()
if not os.path.lexists(root):
    hash_value.update(b"MISSING\0")
else:
    paths = [root]
    if os.path.isdir(root) and not os.path.islink(root):
        for base, directories, files in os.walk(root):
            directories[:] = sorted(
                name for name in directories
                if name not in {".git", "zig-out", "zig-cache"}
            )
            paths.extend(os.path.join(base, name) for name in sorted(files))
            paths.extend(os.path.join(base, name) for name in sorted(directories))
    for path in sorted(set(paths)):
        metadata = os.lstat(path)
        relative = os.path.relpath(path, root)
        hash_value.update(relative.encode() + b"\0")
        hash_value.update(str(metadata.st_mode).encode() + b"\0")
        if stat.S_ISLNK(metadata.st_mode):
            hash_value.update(os.readlink(path).encode())
        elif stat.S_ISREG(metadata.st_mode):
            with open(path, "rb") as handle:
                while chunk := handle.read(1024 * 1024):
                    hash_value.update(chunk)
        hash_value.update(b"\0")
print(hash_value.hexdigest())
PY
}

reload_incremental_output_digest() {
  local output="$1"
  if [[ -f "$output" ]]; then
    reload_incremental_sha256_file "$output"
  else
    reload_incremental_tree_digest "$output"
  fi
}

reload_incremental_needs_update() {
  local receipt="$1"
  local input_digest="$2"
  local output="$3"
  local recorded_input=""
  local recorded_output=""

  [[ -e "$output" && -f "$receipt" ]] || return 0
  read -r recorded_input recorded_output < "$receipt" || return 0
  [[ "$recorded_input" == "$input_digest" ]] || return 0
  [[ "$recorded_output" == "$(reload_incremental_output_digest "$output")" ]] || return 0
  return 1
}

reload_incremental_record() {
  local receipt="$1"
  local input_digest="$2"
  local output="$3"
  local output_digest=""

  output_digest="$(reload_incremental_output_digest "$output")"
  mkdir -p "$(dirname "$receipt")"
  printf '%s %s\n' "$input_digest" "$output_digest" > "${receipt}.tmp.$$"
  mv -f "${receipt}.tmp.$$" "$receipt"
}
