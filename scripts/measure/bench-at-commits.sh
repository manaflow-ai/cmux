#!/usr/bin/env bash
# One webviews bench of this checkout, run against the pane source of other commits: the same harness for a
# merged change's before and after (CMUX-571). Each commit's webviews/ goes to a scratch tree with its own
# packages; this checkout's bench file (and its bench/ helpers when the commit lacks them) is copied in.
#   cmux-ci test -- bash -c 'scripts/measure/bench-at-commits.sh bench/million-event-chat.bench.ts SHA1 SHA2 -- ARGS; echo rc=$?'
# Prints "BENCH-AT <sha>" before each run's output; ENV=VAR=VALUE,... sets the bench's environment.
set -uo pipefail
bench="${1:?usage: bench-at-commits.sh BENCH SHA... [-- ARGS]}"
shift
shas=()
while [[ $# -gt 0 && "$1" != "--" ]]; do shas+=("$1"); shift; done
[[ "${1:-}" == "--" ]] && shift
root="$(git rev-parse --show-toplevel)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
status=0
for sha in "${shas[@]}"; do
  git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$root" fetch -q --no-tags --depth=1 origin "$sha"
  full="$(git -C "$root" rev-parse "$sha^{commit}")"
  tree="$scratch/${full:0:12}"
  mkdir -p "$tree"
  # webviews/ and what its source imports from outside it (the schemas, icons and question fixtures).
  paths=()
  for p in webviews schemas design/icons Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures; do
    git -C "$root" cat-file -e "$full:$p" 2>/dev/null && paths+=("$p")
  done
  git -C "$root" archive "$full" "${paths[@]}" | tar -x -C "$tree"
  for helper in "$root"/webviews/bench/*.ts; do
    [ -e "$tree/webviews/bench/$(basename "$helper")" ] || cp "$helper" "$tree/webviews/bench/"
  done
  cp "$root/webviews/$bench" "$tree/webviews/$bench"
  echo "BENCH-AT $full $(git -C "$root" log -1 --format=%s "$full" 2>/dev/null | cut -c1-80)"
  (cd "$tree/webviews" && bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null 2>&1
   env ${ENV:+$(tr ',' ' ' <<< "$ENV")} bun "$bench" "$@") || status=$?
done
exit "$status"
