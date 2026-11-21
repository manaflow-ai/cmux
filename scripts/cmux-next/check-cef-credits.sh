#!/usr/bin/env bash
# check-cef-credits.sh <CREDITS.html[.gz] | app bundle>
# Release-bundle gate: Chromium's credits must be present and real. Given an
# app, it checks the embedded CEF framework's Resources/CREDITS.html.gz (what
# install-cef-credits.sh writes; an app without CEF passes: it ships no
# Chromium). A given file ending in .gz is read decompressed. Fails on a missing
# file, a .gz that does not decompress, CEF's "sample credits page" placeholder,
# or text too small to hold the notices (the real one is several MB; 100 KB is a
# floor, not an estimate).
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 <CREDITS.html[.gz] | app bundle>" >&2; exit 2; }
target="$1"
if [[ -d "$target" ]]; then
  fw="$target/Contents/Frameworks/Chromium Embedded Framework.framework"
  if [[ ! -d "$fw" ]]; then
    echo "no embedded CEF in $target; no Chromium credits needed"
    exit 0
  fi
  target="$fw/Resources/CREDITS.html.gz"
fi
if [[ ! -f "$target" ]]; then
  echo "error: Chromium credits missing: $target" >&2
  exit 1
fi
text="$target"
if [[ "$target" == *.gz ]]; then
  text="$(mktemp)"
  trap 'rm -f "$text"' EXIT
  if ! gzip -dc "$target" > "$text" 2>/dev/null; then
    echo "error: $target is not a readable gzip file" >&2
    exit 1
  fi
fi
if grep -qi 'sample credits' "$text"; then
  echo "error: $target is CEF's sample credits placeholder, not Chromium's credits" >&2
  exit 1
fi
size=$(wc -c < "$text" | tr -d ' ')
if (( size < 100000 )); then
  echo "error: $target holds $size bytes of text; too small to be Chromium's credits" >&2
  exit 1
fi
interim=""
head -c 300 "$text" | grep -q 'INTERIM' && interim=" (INTERIM stock CEF credits)"
echo "Chromium credits: $target, $size bytes of text$interim"
