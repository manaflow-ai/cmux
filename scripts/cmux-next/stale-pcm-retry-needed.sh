#!/usr/bin/env bash
# Return success when an Xcode log contains a stale explicit-module failure.
set -euo pipefail

log="${1:?usage: stale-pcm-retry-needed.sh LOG}"
grep -qE "has been modified since the (module|precompiled) file '|Failed to query serialized dependencies at '|fatal error: module file '[^']+' not found" "$log"
