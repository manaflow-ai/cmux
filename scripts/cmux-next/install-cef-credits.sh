#!/usr/bin/env bash
# install-cef-credits.sh <cef dist dir> <framework Resources dir> <chromium version>
# Writes Chromium's CREDITS.html (license notices for Chromium and its
# third-party components) into the embedded CEF framework's Resources. The
# artifact's own CREDITS.html (framework Resources or dist root) is used when it
# has one. Otherwise the INTERIM stock CEF credits for the pinned Chromium
# version (chromium-credits/README.md) are used, with a header comment that says
# so. Exits 1 when neither exists.
set -euo pipefail
[[ $# -eq 3 ]] || { echo "usage: $0 <cef dist dir> <framework Resources dir> <chromium version>" >&2; exit 2; }
dist="$1" resources="$2" chromium="$3"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fw="Chromium Embedded Framework.framework"
out="$resources/CREDITS.html"
for candidate in "$dist/$fw/Resources/CREDITS.html" "$dist/CREDITS.html"; do
  if [[ -f "$candidate" ]]; then
    [[ "$candidate" -ef "$out" ]] || { rm -f "$out"; cp "$candidate" "$out"; }
    exit 0
  fi
done
stock="$here/chromium-credits/$chromium.html.gz"
if [[ ! "$chromium" =~ ^[0-9]+(\.[0-9]+){3}$ || ! -f "$stock" ]]; then
  echo "error: the CEF artifact has no CREDITS.html and no stock credits exist for Chromium $chromium ($stock); see scripts/cmux-next/chromium-credits/README.md" >&2
  exit 1
fi
tmp="$out.tmp.$$"
{
  printf '<!-- INTERIM: stock CEF CREDITS.html for Chromium %s (cef_binary 154.0.28 minimal distribution), shipped until the manaflow-ai/cef fork artifact carries its own generated file. Source: scripts/cmux-next/chromium-credits/README.md -->\n' "$chromium"
  gunzip -c "$stock"
} > "$tmp"
mv -f "$tmp" "$out"
