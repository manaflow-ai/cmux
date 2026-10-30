#!/usr/bin/env bash
# STATE-ROOTS ratchet (per-build isolation S7, cx-is1kf.8;
# .cmux-scratch DESIGN section 2: "a lint refuses new literal roots").
#
# Each build's state lives under roots that one resolver names from the
# build's identity: BuildIdentity (Swift CmuxNextCompat, Rust
# cmux_agent_pane_policy::build_identity), ChiefHome / cli/chief/home.rs and
# AcpmuxEnvironment / environment.rs. A new literal state root in product code
# (`~/.cmux/chief`, `~/.cmux/mux`, `~/.acpmux`, `Application Support/cmux`,
# `cmux/tags/`, `cmux/builds/`) bypasses them and lets one build read or write
# another build's state. Ask the resolver for the path instead.
#
# Scope: Swift under Packages/macOS/CmuxNext and Packages/macOS/CmuxUpdater
# (the packages whose changes run cmux-next.yml), Rust under cmux-tui/crates,
# without test folders and *tests.rs / *Tests.swift files; lines that start
# with a comment do not count (inline #[cfg(test)] modules do).
# Existing sites are rows of scripts/cmux-next/state-roots-baseline.tsv:
# path<TAB>matching lines<TAB>keep|move<TAB>reason (`keep` = a resolver or a
# reviewed use, `move` = should ask a resolver). A file with more matches
# than its row, or matches and no row, fails; a file with fewer matches also
# fails until its row is lowered, so the ratchet only goes down.
#
# Usage: scripts/cmux-next/check-state-roots.sh [repo-root] [--list]
#   --list  print every matching line and exit 0.
set -euo pipefail

root=""
list=0
for arg in "$@"; do
  case "$arg" in
    --list) list=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) root="$arg" ;;
  esac
done
root="${root:-$(git rev-parse --show-toplevel)}"
baseline="$root/scripts/cmux-next/state-roots-baseline.tsv"
pattern='\.cmux/(chief|mux)|["/]\.acpmux(["/]|$)|"\.cmux"|Application Support/cmux([^A-Za-z0-9_-]|$)|cmux/(tags|builds)(["/]|$)'
comment='[[:space:]]*(//|/\*|\*([[:space:]]|$))'

# Product source files, repo-relative, sorted.
files() {
  local scope ext
  for pair in "cmux-tui/crates:rs" "Packages/macOS/CmuxNext:swift" "Packages/macOS/CmuxUpdater:swift"; do
    scope="${pair%%:*}"; ext="${pair##*:}"
    [[ -d "$root/$scope" ]] || continue
    (cd "$root" && find "$scope" \
      \( -type d \( -name target -o -name .build -o -name tests -o -name Tests -o -name node_modules \
         -o -name fixtures -o -name benches \) -prune \) \
      -o \( -type f -name "*.$ext" ! -name '*tests.rs' ! -name '*Tests.swift' -print \))
  done | LC_ALL=C sort
}

# Matching non-comment lines of one file, as "line:text".
matches() {
  grep -nE "$pattern" "$root/$1" 2>/dev/null | grep -vE "^[0-9]+:$comment" || true
}

# Bash 3.2 (macOS) compatible: no associative arrays.
rows=""
if [[ -f "$baseline" ]]; then
  while IFS=$'\t' read -r path count class reason || [[ -n "${path:-}" ]]; do
    [[ -z "$path" || "$path" == \#* ]] && continue
    if [[ ! "$count" =~ ^[0-9]+$ ]] || [[ "$class" != keep && "$class" != move ]] || [[ -z "${reason:-}" ]]; then
      echo "check-state-roots: bad baseline row: $path	$count	$class	${reason:-}" >&2
      exit 2
    fi
    if printf '%s' "$rows" | awk -F'\t' -v f="$path" '$1 == f { hit = 1 } END { exit !hit }'; then
      echo "check-state-roots: duplicate baseline row: $path" >&2
      exit 2
    fi
    rows+="$path	$count"$'\n'
  done < "$baseline"
fi

status=0
counted=""
while IFS= read -r file; do
  found="$(matches "$file")"
  [[ -z "$found" ]] && continue
  if (( list )); then
    printf '%s\n' "$found" | awk -v f="$file" '{ print f ":" $0 }'
    continue
  fi
  count="$(printf '%s\n' "$found" | wc -l | tr -d ' ')"
  counted+="$file	$count"$'\n'
  limit="$(printf '%s' "$rows" | awk -F'\t' -v f="$file" '$1 == f { print $2 }')"
  limit="${limit:-0}"
  if (( count > limit )); then
    echo "check-state-roots: $file has $count literal state root line(s), baseline $limit:" >&2
    printf '%s\n' "$found" | awk -v f="$file" '{ print "  " f ":" $0 }' >&2
    status=1
  elif (( count < limit )); then
    echo "check-state-roots: $file has $count line(s), baseline $limit: lower its row in scripts/cmux-next/state-roots-baseline.tsv" >&2
    status=1
  fi
done < <(files)
(( list )) && exit 0
while IFS=$'\t' read -r path count; do
  [[ -z "$path" ]] && continue
  if (( count > 0 )) && ! printf '%s' "$counted" | awk -F'\t' -v f="$path" '$1 == f { hit = 1 } END { exit !hit }'; then
    echo "check-state-roots: $path has no literal state root left: delete its row in scripts/cmux-next/state-roots-baseline.tsv" >&2
    status=1
  fi
done <<< "$rows"
if (( status )); then
  echo "check-state-roots: ask the build's resolver for state paths (BuildIdentity, ChiefHome, AcpmuxEnvironment; Rust build_identity, cli/chief/home.rs, environment.rs), never a literal root." >&2
else
  echo "check-state-roots: ok"
fi
exit "$status"
