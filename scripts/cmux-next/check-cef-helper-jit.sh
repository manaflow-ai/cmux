#!/usr/bin/env bash
# Checks that the Chromium helpers in a signed cmux-next app can run V8.
#
#   scripts/cmux-next/check-cef-helper-jit.sh <app>
#
# Chromium starts its renderer, extension and GPU processes from
# "<name> Helper.app", "<name> Helper (Renderer).app" and
# "<name> Helper (GPU).app". Under the hardened runtime a helper without
# com.apple.security.cs.allow-jit cannot reserve V8's code range, and every
# page or extension process it starts dies with SIGTRAP in its first second
# (38 "cmux Helper" crash reports on NIGHTLY 4178064067101, fixed in
# e1869abf57c8). This check fails when one of those three helpers has the
# hardened runtime and no allow-jit, in Contents/Frameworks and in the
# Contents/Frameworks of each app under Contents/Helpers (the remote browser
# host). A helper without the hardened runtime needs no entitlement and passes.
# An app with no Chromium helpers passes with a note.
set -euo pipefail

app="${1:-}"
[[ $# -eq 1 && -d "$app/Contents" ]] || { echo "usage: $0 <app>" >&2; exit 2; }

checked=0
failed=0
check_dir() {
  local dir="$1" helper name flags ents value
  for helper in "$dir"/*" Helper.app" "$dir"/*" Helper (Renderer).app" "$dir"/*" Helper (GPU).app"; do
    [[ -d "$helper" ]] || continue
    name="${helper#"$app"/}"
    checked=$((checked + 1))
    flags="$(/usr/bin/codesign -dv "$helper" 2>&1 | sed -n 's/.*flags=0x[0-9a-f]*(\([^)]*\)).*/\1/p')"
    if [[ ",$flags," != *",runtime,"* ]]; then
      continue
    fi
    ents="$(/usr/bin/codesign -d --entitlements :- "$helper" 2>/dev/null || true)"
    value="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.cs.allow-jit" /dev/stdin <<<"$ents" 2>/dev/null || true)"
    if [[ "$value" != true ]]; then
      echo "error: $name has the hardened runtime and no com.apple.security.cs.allow-jit; its pages and extensions would crash with SIGTRAP" >&2
      failed=$((failed + 1))
    fi
  done
}

check_dir "$app/Contents/Frameworks"
for host in "$app/Contents/Helpers/"*.app; do
  [[ -d "$host/Contents/Frameworks" ]] && check_dir "$host/Contents/Frameworks"
done

if [[ $failed -gt 0 ]]; then
  exit 1
fi
if [[ $checked -eq 0 ]]; then
  echo "==> no Chromium helpers in this app"
else
  echo "==> Chromium helpers that run V8 can JIT ($checked checked)"
fi
