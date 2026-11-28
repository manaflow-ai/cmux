#!/usr/bin/env bash
# RFD 0163 row 34, the one client check: verify a Worker bundle directory against the SHA256SUMS the
# cloudflare-relay run published (artifact cmux-cloudflare-relay-edge-hashes-<sha>).
# usage: check-edge-hashes.sh BUNDLE_DIR SHA256SUMS
set -euo pipefail
[[ $# -eq 2 && -d $1 && -s $2 ]] || { echo "usage: $0 BUNDLE_DIR SHA256SUMS" >&2; exit 2; }
sums="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
cd "$1"
sha256sum --check --strict "$sums"
# No bundle file may be missing from the published list.
extra="$(find . -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.wasm' \) | sort | while read -r f; do grep -qF -- "  $f" "$sums" || echo "$f"; done)"
[[ -z "$extra" ]] || { echo "not in SHA256SUMS: $extra" >&2; exit 1; }
