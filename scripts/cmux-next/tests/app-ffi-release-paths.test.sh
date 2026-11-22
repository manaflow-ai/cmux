#!/usr/bin/env bash
# The app FFI release workflow builds on a push that changes an FFI input:
# every input that scripts/cmux-next/check-app-ffi-pin.sh derives from the
# Cargo path dependencies of cmux-app-ffi must be one of its push paths. The
# hand list lacked cmux-remote-browser, so the rb-client push cf25b525a03b
# started no build (2026-10-07).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
workflow="$root/.github/workflows/app-ffi-release.yml"
missing=""
while IFS= read -r input; do
  if [[ -d "$root/$input" ]]; then
    want="\"$input/**\""
  else
    want="\"$input\""
  fi
  grep -qF -- "- $want" "$workflow" || missing+=" $want"
done < <(bash "$root/scripts/cmux-next/check-app-ffi-pin.sh" --list-inputs)

if [[ -n "$missing" ]]; then
  echo "FAIL: .github/workflows/app-ffi-release.yml push paths lack FFI inputs:$missing" >&2
  exit 1
fi
echo "app-ffi-release-paths.test.sh: ok"
