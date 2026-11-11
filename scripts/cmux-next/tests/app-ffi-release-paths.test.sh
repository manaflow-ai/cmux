#!/usr/bin/env bash
# The app FFI release workflow builds on a push that changes an FFI input, and
# only then: its push paths are exactly the inputs that
# scripts/cmux-next/check-app-ffi-pin.sh lists (--list-inputs: each crate
# cmux-app-ffi reaches as a whole directory except its tests/, benches/ and
# examples/, every path a scanned source names, the cargo configs, toolchain
# files, build-app-ffi.sh and this workflow itself, which the list holds). The hand list lacked cmux-remote-browser, so the
# rb-client push cf25b525a03b started no build (2026-10-07); a whole-crate glob
# built a release, and the repin bot opened a repin, for a change only a test
# reads (#39027, 2026-11-09).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
workflow="$root/.github/workflows/app-ffi-release.yml"
want="$(
  while IFS= read -r input; do
    # Each input is a `:(literal)` pathspec (no glob or magic in a found path); an excluded one, `:(exclude,literal)`, is a
    # negative pattern (the workflow lists them after every positive one).
    negate=""
    case "$input" in
      ":(exclude,literal)"*) negate="!"; input="${input#":(exclude,literal)"}" ;;
      ":(literal)"*) input="${input#":(literal)"}" ;;
      ":"*) echo "FAIL: --list-inputs printed a pathspec with other magic: $input" >&2; exit 1 ;;
    esac
    # A directory input is a prefix (a crate, .cargo), whether or not it exists yet.
    case "${input##*/}" in
      .cargo) echo "\"$negate$input/**\"" ;;
      *) [[ -d "$root/$input" ]] && echo "\"$negate$input/**\"" || echo "\"$negate$input\"" ;;
    esac
  done < <(bash "$root/scripts/cmux-next/check-app-ffi-pin.sh" --list-inputs)
)"
# The push paths: the list under `on: push: paths:`, up to the next key.
have="$(awk '/^on:/ {on=1} on && /^    paths:/ {in_paths=1; next} in_paths && /^      - / {sub(/^      - /, ""); print; next}
  in_paths {exit}' "$workflow")"
# GitHub applies the patterns in order: a negative one before a positive one would not exclude.
last_positive="$(grep -n '^"[^!]' <<<"$have" | tail -1 | cut -d: -f1)"
first_negative="$(grep -n '^"!' <<<"$have" | head -1 | cut -d: -f1)"
if [[ -n "$first_negative" && "$first_negative" -lt "$last_positive" ]]; then
  echo "FAIL: .github/workflows/app-ffi-release.yml push paths: a negative pattern comes before a positive one" >&2
  exit 1
fi
missing="$(comm -23 <(sort -u <<<"$want") <(sort -u <<<"$have"))"
extra="$(comm -13 <(sort -u <<<"$want") <(sort -u <<<"$have"))"
if [[ -n "$missing" || -n "$extra" ]]; then
  [[ -n "$missing" ]] && echo "FAIL: .github/workflows/app-ffi-release.yml push paths lack FFI inputs:"$'\n'"$missing" >&2
  [[ -n "$extra" ]] && echo "FAIL: .github/workflows/app-ffi-release.yml push paths name non-inputs:"$'\n'"$extra" >&2
  exit 1
fi
echo "app-ffi-release-paths.test.sh: ok"
