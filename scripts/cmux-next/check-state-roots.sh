#!/usr/bin/env bash
# STATE-ROOTS ratchet (per-build isolation S7, cx-is1kf.8;
# .cmux-scratch DESIGN section 2: "a lint refuses new literal roots").
#
# Each build's state lives under roots that one resolver names from the
# build's identity: BuildIdentity (Swift CmuxNextCompat, Rust
# cmux_agent_pane_policy::build_identity), ChiefHome / cli/chief/home.rs and
# AcpmuxEnvironment / environment.rs. A new literal state root in product code
# (`~/.cmux/chief`, `~/.cmux/mux`, `~/.acpmux`, `Application Support/cmux`,
# `cmux/tags/`, `cmux/builds/`, `cmux-next/tags/`, `cmux-next/builds/`)
# bypasses them and lets one build read or write another build's state.
# Ask the resolver for the path instead.
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
# Second check, per line, on the NEXT-vs-Classic axis (goal
# next-zero-classic-footprint-all-surfaces): cmux NEXT never names cmux
# Classic's paths or ids. Per matched text (not per line number) it flags
# `.config/cmux`, `.local/state/cmux`, `Library/Caches/cmux`, `.cache/cmux`,
# `Library/Logs/cmux` (each not followed by `-next` or another name char),
# `/tmp/cmux*.sock` (not `/tmp/cmux-next*`), the bare `com.cmuxterm.app` id
# (not followed by `.`; so `com.cmuxterm.app.next` passes, and a UserDefaults
# suite or CFPreferences domain naming Classic is caught by its literal), and
# an assembled `appendingPathComponent("cmux")` / `.join("cmux")`. Scope:
# Swift under Packages/macOS, Rust under cmux-tui/crates, webviews/ and
# scripts/cmux-next, without tests and fixtures; comment lines do not count.
# Allowed texts are rows of scripts/cmux-next/classic-ids-baseline.tsv:
# path<TAB>matched text<TAB>count<TAB>keep|move<TAB>reason. `keep` = a reviewed
# Classic read by design (session transfer, MDM forced prefs, the Classic
# importer, harnesses that drive Classic); `move` = reason starts `lane A`
# (state roots, lane/next-own-state-roots) or `lane B` (reads behind consent,
# lane/classic-reads-behind-consent), whose PR deletes the row. More
# occurrences than a row, an unlisted text, or a row with fewer fail.
#
# Usage: scripts/cmux-next/check-state-roots.sh [repo-root] [--list]
#   --list  print every matching line and exit 0.
set -euo pipefail

root=""
list=0
for arg in "$@"; do
  case "$arg" in
    --list) list=1 ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) root="$arg" ;;
  esac
done
root="${root:-$(git rev-parse --show-toplevel)}"
baseline="$root/scripts/cmux-next/state-roots-baseline.tsv"
pattern='\.cmux/(chief|mux)|["/]\.acpmux(["/]|$)|"\.cmux"|Application Support/cmux([^A-Za-z0-9_-]|$)|cmux(-next)?/(tags|builds)(["/]|$)'
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
done < <(files | tr '\n' '\0' | (cd "$root" && xargs -0 grep -lE "$pattern" 2>/dev/null) | LC_ALL=C sort)
while (( ! list )) && IFS=$'\t' read -r path count; do
  [[ -z "$path" ]] && continue
  if (( count > 0 )) && ! printf '%s' "$counted" | awk -F'\t' -v f="$path" '$1 == f { hit = 1 } END { exit !hit }'; then
    echo "check-state-roots: $path has no literal state root left: delete its row in scripts/cmux-next/state-roots-baseline.tsv" >&2
    status=1
  fi
done <<< "$rows"
# ---- Classic ids and paths, per matched text --------------------------------
ids_baseline="$root/scripts/cmux-next/classic-ids-baseline.tsv"
ids_awk='
BEGIN {
  FS = "\t"
  suf = "([^A-Za-z0-9_-]|$)"
  re = "(\\.config|\\.local/state|Library/Caches|\\.cache|Library/Logs)/cmux" suf \
    "|/tmp/cmux[^\"\047 ]*\\.sock" \
    "|com\\.cmuxterm\\.app([^.]|$)" \
    "|(appendingPathComponent|appending|push)\\((path: |component: )?\"cmux\"[,)]" \
    "|join\\([^()]*\"cmux\"[,)]"
}
FNR == 1 { hash = (FILENAME ~ /\.(sh|py)$/) }
{
  line = $0
  if (line ~ /^[ \t]*(\/\/|\/\*|\*([ \t]|$))/) next
  if (hash && line ~ /^[ \t]*#/) next
  while (match(line, re)) {
    m = substr(line, RSTART, RLENGTH)
    line = substr(line, RSTART + RLENGTH)
    if (m ~ /^\/tmp\/cmux-next/) continue
    print FILENAME "\t" m
  }
}'

ids_files() {
  local scope ext
  for pair in "Packages/macOS:swift" "cmux-tui/crates:rs" "webviews:ts tsx js mjs" "scripts/cmux-next:sh py ts js mjs swift"; do
    scope="${pair%%:*}"; ext="${pair##*:}"
    [[ -d "$root/$scope" ]] || continue
    local names=()
    for e in $ext; do names+=(-o -name "*.$e"); done
    (cd "$root" && find "$scope" \
      \( -type d \( -name target -o -name .build -o -name tests -o -name Tests -o -name __tests__ -o -name node_modules \
         -o -name fixtures -o -name benches -o -name dist \) -prune \) \
      -o \( -type f \( -name '*.NONE' "${names[@]}" \) ! -name '*tests.rs' ! -name '*Tests.swift' ! -name '*.test.*' \
         ! -name '*.spec.*' ! -name '*_test.*' ! -name 'test_*' ! -name 'check-state-roots.sh' -print \))
  done | LC_ALL=C sort
}

ids_found() {
  # The awk program reads each file by its repo-relative path.
  (cd "$root" && ids_files | tr '\n' '\0' | xargs -0 awk "$ids_awk" 2>/dev/null) | LC_ALL=C sort | uniq -c \
    | awk '{ n = $1; sub(/^ *[0-9]+ /, ""); print $0 "\t" n }'
}

if (( list )); then
  ids_found | awk -F'\t' '{ print $1 ": " $2 " (x" $3 ")" }'
  exit 0
fi
if [[ -f "$ids_baseline" ]]; then
  # Validate rows before comparing.
  bad="$(awk -F'\t' '/^#/ || NF == 0 { next }
    NF < 5 || $3 !~ /^[0-9]+$/ || ($4 != "keep" && $4 != "move") || ($4 == "move" && $5 !~ /^lane [AB]/) { print; next }
    seen[$1 FS $2]++ { print "duplicate\t" $1 "\t" $2 }' "$ids_baseline")"
  if [[ -n "$bad" ]]; then
    echo "check-state-roots: bad classic-ids baseline row(s) (path, text, count, keep|move, reason; move names lane A or B):" >&2
    printf '%s\n' "$bad" >&2
    exit 2
  fi
fi
ids_report="$( { [[ -f "$ids_baseline" ]] && sed 's/^/B\t/' "$ids_baseline" | grep -vE '^B	(#|$)' || true; ids_found | sed 's/^/F\t/'; } \
  | awk -F'\t' '
    $1 == "B" { lim[$2 FS $3] = $4; next }
    $1 == "F" { key = $2 FS $3; seen[key] = 1
      l = (key in lim) ? lim[key] : 0
      if ($4 > l) printf "  %s has %d x %s, baseline %d (names a Classic path or id)\n", $2, $4, $3, l
      else if ($4 < l) printf "  %s has %d x %s, baseline %d: lower its row in scripts/cmux-next/classic-ids-baseline.tsv\n", $2, $4, $3, l }
    END { for (k in lim) if (!(k in seen) && lim[k] > 0) { split(k, p, FS); printf "  %s no longer has %s: delete its row in scripts/cmux-next/classic-ids-baseline.tsv\n", p[1], p[2] } }' )"
if [[ -n "$ids_report" ]]; then
  echo "check-state-roots: cmux NEXT must not name cmux Classic's paths or ids (.config/cmux, .local/state/cmux, Library/Caches/cmux, .cache/cmux, Library/Logs/cmux, /tmp/cmux*.sock, com.cmuxterm.app, an assembled \"cmux\" folder):" >&2
  printf '%s\n' "$ids_report" | LC_ALL=C sort >&2
  echo "check-state-roots: use com.cmuxterm.app.next and the cmux-next roots from the build's resolver; a reviewed Classic read is a row in scripts/cmux-next/classic-ids-baseline.tsv." >&2
  status=1
fi

if (( status )); then
  echo "check-state-roots: ask the build's resolver for state paths (BuildIdentity, ChiefHome, AcpmuxEnvironment; Rust build_identity, cli/chief/home.rs, environment.rs), never a literal root." >&2
else
  echo "check-state-roots: ok"
fi
exit "$status"
