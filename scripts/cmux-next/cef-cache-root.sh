#!/usr/bin/env bash
# Prints the CEF cache root that ensure-cef.sh, embed-cef.sh and CI share:
#   1. CMUX_CEF_CACHE_DIR when set (the fleet recipe sets it);
#   2. the fleet host cache /Users/Shared/cmux-build-fleet/cache/cef when its
#      parent is a directory this user owns and can write (the Mac minis, where
#      fleet builds and GitHub runner jobs run as one build user), so one
#      verified copy per host serves every slot and job;
#   3. ~/Library/Caches/cmux/cef otherwise (developer Macs).
# ensure-cef.sh still checks every cache entry against the manifest sha256.
set -euo pipefail
if [[ -n "${CMUX_CEF_CACHE_DIR:-}" ]]; then
  printf '%s\n' "$CMUX_CEF_CACHE_DIR"
  exit 0
fi
fleet="${CMUX_CEF_FLEET_CACHE_PARENT:-/Users/Shared/cmux-build-fleet/cache}"
if [[ -d "$fleet" && ! -L "$fleet" && -O "$fleet" && -w "$fleet" ]]; then
  printf '%s\n' "$fleet/cef"
else
  printf '%s\n' "$HOME/Library/Caches/cmux/cef"
fi
