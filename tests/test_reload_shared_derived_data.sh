#!/usr/bin/env bash
# reload.sh gives every tag its own DerivedData unless the checkout's owner names a warm
# one through CMUX_DERIVED_DATA. A tag is not a compiler input, so tags that share a warm
# DerivedData do not recompile; a fresh per-tag directory is always a cold build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Use the real functions, not copies.
eval "$(awk '/^tagged_derived_data_path\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
eval "$(awk '/^default_tagged_derived_data\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
declare -F default_tagged_derived_data >/dev/null || fail "default_tagged_derived_data not found in reload.sh"

unset CMUX_DERIVED_DATA
[[ "$(default_tagged_derived_data one)" == "$HOME/Library/Developer/Xcode/DerivedData/cmux-one" ]] \
  || fail "without CMUX_DERIVED_DATA the default must stay one directory per tag"
[[ "$(default_tagged_derived_data one)" != "$(default_tagged_derived_data two)" ]] \
  || fail "two tags must not share a DerivedData by default"

export CMUX_DERIVED_DATA="/tmp/cmux warm/DerivedData"
[[ "$(default_tagged_derived_data one)" == "/tmp/cmux warm/DerivedData" ]] || fail "CMUX_DERIVED_DATA ignored"
[[ "$(default_tagged_derived_data one)" == "$(default_tagged_derived_data two)" ]] \
  || fail "tags must share the warm DerivedData when CMUX_DERIVED_DATA is set"

# A relative path would resolve differently per caller directory: refuse it.
export CMUX_DERIVED_DATA="relative/DerivedData"
if output="$(default_tagged_derived_data one 2>&1)"; then
  fail "a relative CMUX_DERIVED_DATA must be rejected, got: $output"
fi
[[ "$output" == *"must be an absolute path"* ]] || fail "unclear error for a relative path: $output"

# --derived-data still wins: the default is only consulted when the flag was not given.
grep -q 'if \[\[ "\$DERIVED_SET" -eq 0 \]\]; then' "$ROOT/scripts/reload.sh" || fail "DERIVED_SET guard is gone"
grep -A1 'if \[\[ "\$DERIVED_SET" -eq 0 \]\]; then' "$ROOT/scripts/reload.sh" | grep -q 'default_tagged_derived_data' \
  || fail "reload.sh does not use default_tagged_derived_data for the tag default"

echo "PASS: reload.sh shared DerivedData default"
