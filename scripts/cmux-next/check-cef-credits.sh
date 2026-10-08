#!/usr/bin/env bash
# check-cef-credits.sh <CREDITS.html | app bundle>
# Release-bundle gate: Chromium's CREDITS.html must be present and real. Given an
# app, it checks the embedded CEF framework's Resources/CREDITS.html (an app
# without CEF passes: it ships no Chromium). Fails on a missing file, CEF's
# "sample credits page" placeholder, or a file too small to hold the notices
# (the real one is several MB; 100 KB is a floor, not an estimate).
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 <CREDITS.html | app bundle>" >&2; exit 2; }
target="$1"
if [[ -d "$target" ]]; then
  fw="$target/Contents/Frameworks/Chromium Embedded Framework.framework"
  if [[ ! -d "$fw" ]]; then
    echo "no embedded CEF in $target; no Chromium credits needed"
    exit 0
  fi
  target="$fw/Resources/CREDITS.html"
fi
if [[ ! -f "$target" ]]; then
  echo "error: Chromium credits missing: $target" >&2
  exit 1
fi
if grep -qi 'sample credits' "$target"; then
  echo "error: $target is CEF's sample credits placeholder, not Chromium's credits" >&2
  exit 1
fi
size=$(wc -c < "$target" | tr -d ' ')
if (( size < 100000 )); then
  echo "error: $target is $size bytes; too small to be Chromium's credits" >&2
  exit 1
fi
interim=""
head -c 300 "$target" | grep -q 'INTERIM' && interim=" (INTERIM stock CEF credits)"
echo "Chromium credits: $target, $size bytes$interim"
