#!/usr/bin/env bash
# Packs the cmux-next Swift exports (swift-exports-key.py --list) for a cache
# keyed by their source key, and installs a pack into a checkout.
#
#   pack DIR      copy every export into DIR at its repository path, with the
#                 tree's stamp (source key and output digest) in
#                 DIR/.swift-exports.key
#   install DIR   copy a pack's exports into this checkout. Refused, writing
#                 nothing, when the pack was built from other sources or its
#                 exports no longer match the digest it was packed with.
#
# Usage: scripts/cmux-next/swift-exports-cache.sh pack|install DIR
set -euo pipefail

if [[ $# -ne 2 || ( "$1" != pack && "$1" != install ) ]]; then
  echo "usage: $0 pack|install DIR" >&2
  exit 2
fi
mode="$1"
dir="$2"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
key="$root/scripts/cmux-next/swift-exports-key.py"
exports=()
while IFS= read -r rel; do exports+=("$rel"); done < <(python3 "$key" "$root" --list)

if [[ "$mode" == pack ]]; then
  for rel in "${exports[@]}"; do
    [[ -f "$root/$rel" ]] || { echo "error: export $rel is missing" >&2; exit 1; }
  done
  rm -rf "$dir"
  for rel in "${exports[@]}"; do
    mkdir -p "$dir/$(dirname "$rel")"
    cp "$root/$rel" "$dir/$rel"
  done
  python3 "$key" "$root" --stamp > "$dir/.swift-exports.key"
  echo "Swift exports packed: $(cut -d' ' -f1 "$dir/.swift-exports.key")"
  exit 0
fi

[[ -f "$dir/.swift-exports.key" ]] || { echo "error: $dir has no .swift-exports.key" >&2; exit 1; }
read -r packed_source packed_outputs < "$dir/.swift-exports.key"
source_key="$(python3 "$key" "$root" --source)"
if [[ "$packed_source" != "$source_key" ]]; then
  echo "error: the pack's source key $packed_source is not this checkout's $source_key" >&2
  exit 1
fi
# The digest of the pack's own files, computed as if they were installed.
staged="$(mktemp -d)"
trap 'rm -rf "$staged"' EXIT
for rel in "${exports[@]}"; do
  [[ -f "$dir/$rel" ]] || { echo "error: the pack has no $rel" >&2; exit 1; }
  mkdir -p "$staged/$(dirname "$rel")"
  cp "$dir/$rel" "$staged/$rel"
done
if [[ "$(python3 "$key" "$staged" --outputs)" != "$packed_outputs" ]]; then
  echo "error: the pack's exports do not match the digest it was packed with" >&2
  exit 1
fi
for rel in "${exports[@]}"; do
  mkdir -p "$root/$(dirname "$rel")"
  cp "$staged/$rel" "$root/$rel"
done
echo "Swift exports restored: $source_key"
