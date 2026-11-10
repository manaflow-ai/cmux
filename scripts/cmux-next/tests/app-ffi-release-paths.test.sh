#!/usr/bin/env bash
# The app FFI release workflow builds on a push that changes an FFI input, and
# only then: its push paths are exactly the inputs that
# scripts/cmux-next/check-app-ffi-pin.sh lists (--list-inputs: what the build
# reads of each crate cmux-app-ffi reaches through Cargo path dependencies),
# plus the workflow itself. The hand list lacked cmux-remote-browser, so the
# rb-client push cf25b525a03b started no build (2026-10-07); a whole-crate glob
# built a release, and the repin bot opened a repin, for a change only a test
# reads (#39027, 2026-11-09).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
workflow="$root/.github/workflows/app-ffi-release.yml"
want="$(
  while IFS= read -r input; do
    # A directory input is a prefix (src, build-support, include), whether or not it exists yet.
    case "${input##*/}" in
      src|build-support|include|.cargo) echo "\"$input/**\"" ;;
      *) [[ -d "$root/$input" ]] && echo "\"$input/**\"" || echo "\"$input\"" ;;
    esac
  done < <(bash "$root/scripts/cmux-next/check-app-ffi-pin.sh" --list-inputs)
  echo '".github/workflows/app-ffi-release.yml"'
)"
# The push paths: the list under `on: push: paths:`, up to the next key.
have="$(awk '/^on:/ {on=1} on && /^    paths:/ {in_paths=1; next} in_paths && /^      - / {sub(/^      - /, ""); print; next}
  in_paths {exit}' "$workflow")"
missing="$(comm -23 <(sort -u <<<"$want") <(sort -u <<<"$have"))"
extra="$(comm -13 <(sort -u <<<"$want") <(sort -u <<<"$have"))"
if [[ -n "$missing" || -n "$extra" ]]; then
  [[ -n "$missing" ]] && echo "FAIL: .github/workflows/app-ffi-release.yml push paths lack FFI inputs:"$'\n'"$missing" >&2
  [[ -n "$extra" ]] && echo "FAIL: .github/workflows/app-ffi-release.yml push paths name non-inputs:"$'\n'"$extra" >&2
  exit 1
fi
echo "app-ffi-release-paths.test.sh: ok"
