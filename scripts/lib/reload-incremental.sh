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

# Digest of a fixed list of files: each file's path and bytes, in the order given.
# A missing file is part of the digest, so deleting one changes it.
reload_incremental_files_digest() {
  python3 - "$@" <<'PY'
import hashlib
import os
import sys

hash_value = hashlib.sha256()
for path in sys.argv[1:]:
    hash_value.update(path.encode() + b"\0")
    if not os.path.isfile(path):
        hash_value.update(b"MISSING\0")
        continue
    with open(path, "rb") as handle:
        while chunk := handle.read(1024 * 1024):
            hash_value.update(chunk)
    hash_value.update(b"\0")
print(hash_value.hexdigest())
PY
}

# Cheap fingerprint of a signed app bundle. _CodeSignature/CodeResources is the
# seal codesign writes: it lists a hash for every resource and nested code item,
# so it changes whenever anything in the bundle does. The executables are not in
# that list, so they are hashed directly. An unsigned bundle falls back to
# hashing the whole tree.
reload_incremental_app_digest() {
  local app="$1"
  local seal="$app/Contents/_CodeSignature/CodeResources"
  if [[ ! -f "$seal" ]]; then
    reload_incremental_tree_digest "$app"
    return
  fi
  local digest_inputs=("$app/Contents/Info.plist" "$seal")
  local path
  while IFS= read -r -d '' path; do
    digest_inputs+=("$path")
  done < <(find "$app/Contents/MacOS" "$app/Contents/Resources/bin" -type f -print0 2>/dev/null | LC_ALL=C sort -z)
  reload_incremental_files_digest "${digest_inputs[@]}"
}

# Identity of the cmux-tui client a reload would bundle, so a reuse key follows the
# client itself rather than the path or URL it comes from. A client preserved from
# the built app is already covered by that app's digest. Fails when the source
# cannot be resolved; the caller must then redo the install instead of reusing.
# A manifest the identity was computed from is kept at manifest_snapshot, which exists
# afterwards only in that case. Installing from it keeps the identity and the bundled
# client on one manifest even when the URL is republished in between.
reload_incremental_tui_client_identity() {
  local installer="$1"
  local built_app="$2"
  local manifest_url="${3:-}"
  local manifest_snapshot="${4:-}"
  if [[ -n "$manifest_snapshot" ]]; then
    rm -f "$manifest_snapshot"
  fi
  if [[ "${CMUX_SKIP_CMUX_TUI_CLIENT:-}" == "1" && -x "$built_app/Contents/Resources/bin/cmux-tui" ]]; then
    printf 'preserved\n'
    return 0
  fi
  local installer_args=(--print-source-identity)
  if [[ -n "$manifest_url" ]]; then
    installer_args+=(--manifest-url "$manifest_url")
  fi
  if [[ -n "$manifest_snapshot" ]]; then
    installer_args+=(--save-manifest "$manifest_snapshot")
  fi
  "$installer" "${installer_args[@]}"
}

reload_incremental_output_digest() {
  local output="$1"
  if [[ -f "$output" ]]; then
    reload_incremental_sha256_file "$output"
    return
  fi
  if [[ "$output" == *.app && -d "$output/Contents" ]]; then
    reload_incremental_app_digest "$output"
    return
  fi
  reload_incremental_tree_digest "$output"
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
