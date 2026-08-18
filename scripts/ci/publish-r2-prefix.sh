#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 DIRECTORY KEY_PREFIX CACHE_CONTROL" >&2
  exit 2
fi

directory=$1
prefix=$2
cache_control=$3
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
uploader="$script_dir/upload-r2-object.py"

if [[ ! -d "$directory" ]]; then
  echo "R2 upload directory does not exist: $directory" >&2
  exit 1
fi

shopt -s nullglob
files=("$directory"/*)
manifest=""
for file in "${files[@]}"; do
  if [[ "$(basename "$file")" == manifest.json ]]; then
    manifest=$file
    continue
  fi
  python3 "$uploader" \
    --file "$file" \
    --endpoint-url "$R2_ENDPOINT" \
    --bucket cmux-binaries \
    --key "$prefix/$(basename "$file")" \
    --cache-control "$cache_control"
done

if [[ -n "$manifest" ]]; then
  python3 "$uploader" \
    --file "$manifest" \
    --endpoint-url "$R2_ENDPOINT" \
    --bucket cmux-binaries \
    --key "$prefix/manifest.json" \
    --cache-control "$cache_control"
fi
