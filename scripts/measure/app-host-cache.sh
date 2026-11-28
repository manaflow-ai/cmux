#!/usr/bin/env bash
# Measures one app-host cache-off/cache-on compile pair with restored local
# seeds and the same comment-only edit; no production or cross-host savings.
# Reviewed fleet entrypoint; merge before submitting at the merged SHA:
# cmux-ci run --class exclusive --os macos --measurement \
#   --script scripts/measure/app-host-cache.sh --ref SHA --timeout 10800 --key KEY
# No GUI, production cache writes, or global cache/default changes.
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
exec python3 "$root/scripts/ci/app_host_cache_measure.py" "$@"
