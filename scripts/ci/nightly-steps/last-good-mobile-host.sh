#!/usr/bin/env bash
# last-good-mobile-host.sh ARCH_KEY: print the newest cmux-mobile-host this Mac built before, for ARCH_KEY
# ("arm64" or "arm64-x86_64"), from build-mobile-host.sh's cache (cmux-next-ios/rust/target/hosted/
# cmux-mobile-host/<source key>/<arch key>/cmux-mobile-host); exit 1 when there is none.
# app-bundle-chief-and-mobile-host.sh bundles it when this run's iPhone host failed to build.
set -euo pipefail
arch_key="${1:?arch key}"
root="${CMUX_NEXT_MOBILE_HOST_CACHE:-cmux-next-ios/rust/target/hosted/cmux-mobile-host}"
best=""
best_mtime=0
for bin in "$root"/*/"$arch_key"/cmux-mobile-host; do
  [ -x "$bin" ] || continue
  mtime="$(stat -c %Y "$bin" 2>/dev/null || stat -f %m "$bin")"
  if [ "$mtime" -gt "$best_mtime" ]; then best="$bin"; best_mtime="$mtime"; fi
done
[ -n "$best" ] || exit 1
printf '%s\n' "$best"
