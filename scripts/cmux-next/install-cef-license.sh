#!/usr/bin/env bash
# install-cef-license.sh <cef dist dir> <framework Resources dir>
# Writes CEF's own LICENSE.txt (BSD-3-Clause) into the embedded CEF framework's
# Resources. The artifact's own LICENSE.txt (dist root or framework Resources) is
# used when it has one. Otherwise the stock copy from the CEF binary distribution
# that our fork is based on (cef-license/README.md), after its sha256 matches.
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: $0 <cef dist dir> <framework Resources dir>" >&2; exit 2; }
dist="$1" resources="$2"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fw="Chromium Embedded Framework.framework"
out="$resources/LICENSE.txt"
stock_sha256="058c3827ffb827ff3edda471ae7e1bb1d1aa5931985f0126043ccd33409e792f"
for candidate in "$dist/LICENSE.txt" "$dist/$fw/Resources/LICENSE.txt"; do
  if [[ -f "$candidate" ]]; then
    [[ "$candidate" -ef "$out" ]] || { rm -f "$out"; cp "$candidate" "$out"; }
    exit 0
  fi
done
stock="$here/cef-license/LICENSE.txt"
if [[ ! -f "$stock" || "$(shasum -a 256 "$stock" | cut -d' ' -f1)" != "$stock_sha256" ]]; then
  echo "error: $stock is missing or is not the pinned CEF LICENSE.txt (sha256 $stock_sha256); see scripts/cmux-next/cef-license/README.md" >&2
  exit 1
fi
rm -f "$out"
cp "$stock" "$out"
