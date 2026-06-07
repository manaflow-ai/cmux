#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <derived-data-path>..." >&2
  exit 64
fi

for derived_data_path in "$@"; do
  if [ ! -d "$derived_data_path" ]; then
    continue
  fi

  find "$derived_data_path" \
    \( -name ModuleCache.noindex -o -name SDKStatCaches.noindex \) \
    -type d -prune -print -exec rm -rf {} +
done
