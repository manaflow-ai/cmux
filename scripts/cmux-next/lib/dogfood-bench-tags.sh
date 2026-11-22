# shellcheck shell=bash
# dogfood_bench_glob <tag> [conf]: is <tag> a dogfood tag whose `reload.sh --release` builds the bench configuration?
# Prints the release_bench_tags glob of the conf (default scripts/cmux-next/cmux-next.dogfood.conf) that <tag> matches
# and returns 0; returns 1 when no glob matches, the value is empty or the conf is absent. The globs match the tag
# only, never files. Bash 3.2 (macOS /bin/bash) compatible.
dogfood_bench_glob() {
  local tag="${1:-}"
  local conf="${2:-$(dirname "${BASH_SOURCE[0]}")/../cmux-next.dogfood.conf}"
  local value glob
  local -a globs=()
  [[ -n "$tag" && -f "$conf" ]] || return 1
  value="$(sed -n 's/^release_bench_tags=//p' "$conf" | tail -1)"
  read -r -a globs <<<"$value"
  for glob in ${globs[@]+"${globs[@]}"}; do
    # shellcheck disable=SC2053 # the conf's value is a glob
    if [[ "$tag" == $glob ]]; then
      printf '%s\n' "$glob"
      return 0
    fi
  done
  return 1
}
