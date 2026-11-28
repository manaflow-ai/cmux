#!/usr/bin/env bash
# Report only the iOS convention violations a change introduces.
#
# scripts/lint-ios-package-conventions.sh scans the whole repository, so running
# it on pull requests sends every open PR red whenever main carries one
# unrelated violation. That is the complaint in #10409, and it is why the check
# now lives only in the dispatch-only iOS lane, where nothing sees it until a
# violation has already landed. This compares the violations at HEAD against
# those at the base commit and fails only on the difference, so a pull request
# is judged on what it adds rather than on the state of main.
#
# Findings are keyed by (rule, file, text), not line number, so code that moves
# without changing is not reported as new.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BASE_SHA="${1:-}"
if [ -z "$BASE_SHA" ]; then
  echo "usage: $(basename "$0") <base-sha>" >&2
  exit 2
fi

# ERROR lines are "ERROR   <rule>   <path>:<line>  <text>". Both the shell
# rules and lint_swift_namespaces.py emit that shape on stdout.
fingerprints() {
  ./scripts/lint-ios-package-conventions.sh 2>/dev/null | awk '
    $1 == "ERROR" {
      rule = $2; loc = $3
      $1 = ""; $2 = ""; $3 = ""
      sub(/^[[:space:]]+/, "")
      split(loc, parts, ":")
      print rule "\t" parts[1] "\t" $0
    }' | sort -u
}

# Lists that hide their entries from the lint; each may only shrink.
SHRINK_ONLY_LISTS=(
  scripts/lint-ios-package-conventions-baseline.txt
  scripts/lint-namespace-types-baseline.txt
  scripts/lint-namespace-types-ratchet.txt
)

base_tree=""
head_list="$(mktemp)"
base_list="$(mktemp)"
cleanup() {
  rm -f "$head_list" "$base_list"
  if [ -n "$base_tree" ]; then
    git worktree remove --force "$base_tree" >/dev/null 2>&1 || rm -rf "$base_tree"
    git worktree prune >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

fingerprints > "$head_list"

if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  git fetch --no-tags --depth=1 origin "$BASE_SHA" >/dev/null 2>&1 || true
fi
if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  # Without a base to compare against, judging "new" is not possible. Report
  # the current state rather than passing silently on an unknown comparison.
  echo "::warning::base $BASE_SHA unavailable; reporting all current violations"
  echo "::warning::shrink-only lists (${SHRINK_ONLY_LISTS[*]}) cannot be checked for growth without the base"
  if [ -s "$head_list" ]; then
    cut -f1,2 "$head_list" | sed 's/^/NEW  /'
    exit 1
  fi
  exit 0
fi

base_tree="$(mktemp -d)/base"
git worktree add --detach "$base_tree" "$BASE_SHA" >/dev/null 2>&1 || {
  echo "::error::could not check out base $BASE_SHA"
  exit 2
}
( cd "$base_tree" && ./scripts/lint-ios-package-conventions.sh 2>/dev/null | awk '
    $1 == "ERROR" {
      rule = $2; loc = $3
      $1 = ""; $2 = ""; $3 = ""
      sub(/^[[:space:]]+/, "")
      split(loc, parts, ":")
      print rule "\t" parts[1] "\t" $0
    }' | sort -u ) > "$base_list"

# Shrink-only lists hide their entries from both sides of the comparison
# above, so an entry added to one would pass as "no new violations". Fail
# on any entry the base did not have. A list the base lacks is being seeded.
grown=0
for list in "${SHRINK_ONLY_LISTS[@]}"; do
  [ -f "$list" ] || continue
  git cat-file -e "$BASE_SHA:$list" 2>/dev/null || continue
  while IFS= read -r entry; do
    printf 'GREW %s  %s\n' "$list" "$entry"
    grown=$((grown + 1))
  done < <(comm -13 <(git show "$BASE_SHA:$list" | grep -v '^#' | grep -v '^[[:space:]]*$' | sort -u) \
                    <(grep -v '^#' "$list" | grep -v '^[[:space:]]*$' | sort -u))
done
if [ "$grown" -gt 0 ]; then
  echo
  echo "FAIL: $grown entry/entries added to a shrink-only list. Fix the type instead."
  exit 1
fi

new_count=0
while IFS=$'\t' read -r rule file text; do
  [ -z "$rule" ] && continue
  printf 'NEW  %-24s %s  %s\n' "$rule" "$file" "$text"
  new_count=$((new_count + 1))
done < <(comm -13 "$base_list" "$head_list")

carried="$(wc -l < "$base_list" | tr -d ' ')"
if [ "$new_count" -gt 0 ]; then
  echo
  echo "FAIL: $new_count convention violation(s) introduced by this change."
  echo "($carried pre-existing violation(s) on the base are not this change's to fix.)"
  exit 1
fi

echo "OK: no new convention violations ($carried pre-existing on the base)."
exit 0
