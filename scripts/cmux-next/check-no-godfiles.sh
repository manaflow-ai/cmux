#!/usr/bin/env bash
# Fails when cmux-next code grows into a god file or a god type.
#
# Swift (Packages/macOS/CmuxNext), absolute limits:
#   - 400 lines per file (tests 600), at most 3 top-level types per source file.
# Swift, ratcheted:
#   - 1000 lines per type: the sum of a type's top-level declaration and all of
#     its extensions in the same module (nested types count toward the outer
#     type). Extensions of types the module does not declare are not counted.
# Rust (cmux-tui/**/*.rs, tracked files), ratcheted:
#   - 1000 lines and 60 functions per file (test files: 1500 lines, 120 fns).
#
# Ratchet: scripts/cmux-next/godfile-baseline.tsv lists every type or file that
# was over budget when the rule landed. A listed entry may stay over budget but
# may never grow past its baseline numbers. Anything not listed must meet the
# budget. When a listed entry shrinks, lower its baseline with
#   scripts/cmux-next/check-no-godfiles.sh --update-baseline
# (it only lowers numbers and drops entries that now meet the budget; it never
# raises a number or adds an entry).
#
# Usage: scripts/cmux-next/check-no-godfiles.sh [--update-baseline] [package-root]
set -euo pipefail

update=0
if [[ "${1:-}" == "--update-baseline" ]]; then
  update=1
  shift
fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-$(git -C "$script_dir" rev-parse --show-toplevel)/Packages/macOS/CmuxNext}"
repo="$(git -C "$root" rev-parse --show-toplevel)"
baseline="$script_dir/godfile-baseline.tsv"

swift_file_limit=400
swift_test_file_limit=600
swift_type_limit=1000
rust_file_limit=1000
rust_fn_limit=60
rust_test_file_limit=1500
rust_test_fn_limit=120

status=0

# 1. Swift files: absolute limits.
while IFS= read -r -d '' file; do
  lines=$(wc -l < "$file" | tr -d ' ')
  limit=$swift_file_limit
  [[ "$file" == */Tests/* ]] && limit=$swift_test_file_limit
  if (( lines > limit )); then
    echo "god file: ${file#"$root"/} has $lines lines (limit $limit)"
    status=1
  fi
  # Top-level primary declarations (extensions and small nested helpers are fine).
  types=$(grep -cE '^(public |internal |package |fileprivate |private |final |nonisolated |indirect |@MainActor |@Observable |@frozen )*(final )?(class|struct|enum|actor|protocol) ' "$file" || true)
  if [[ "$file" != */Tests/* ]] && (( types > 3 )); then
    echo "god file: ${file#"$root"/} declares $types top-level types (limit 3)"
    status=1
  fi
done < <(find "$root/Sources" "$root/Tests" -name '*.swift' -print0 2>/dev/null)

# 2. Measure ratcheted entries: "kind<TAB>key<TAB>lines<TAB>fns<TAB>line-limit<TAB>fn-limit".
measurements="$(mktemp)"
trap 'rm -f "$measurements"' EXIT

# Swift types. A top-level declaration starts at column 0 and ends at the next
# line that starts with "}" (the package is formatted that way).
if [[ -d "$root/Sources" ]]; then
  find "$root/Sources" -name '*.swift' -print0 | xargs -0 awk '
    FNR == 1 {
      in_decl = 0
      module = FILENAME
      sub(/(^|.*\/)Sources\//, "", module)
      sub(/\/.*/, "", module)
    }
    {
      if (in_decl) {
        if ($0 ~ /^}/) { printf "%s\t%s\t%s\t%d\n", module, kind, name, FNR - start + 1; in_decl = 0 }
        next
      }
      if ($0 !~ /^[@a-z]/) next
      rest = $0
      while (match(rest, /^(@[A-Za-z_]+(\([^)]*\))?|public|internal|package|fileprivate|private|final|nonisolated|indirect|open) +/)) {
        rest = substr(rest, RLENGTH + 1)
      }
      if (match(rest, /^(class|struct|enum|actor|protocol|extension) +[A-Za-z_][A-Za-z0-9_]*/)) {
        split(substr(rest, 1, RLENGTH), parts, / +/)
        kind = (parts[1] == "extension") ? "ext" : "decl"
        name = parts[2]
        start = FNR
        line = $0
        opens = gsub(/{/, "{", line); closes = gsub(/}/, "}", line)
        if (opens > 0 && opens == closes) printf "%s\t%s\t%s\t%d\n", module, kind, name, 1
        else in_decl = 1
      }
    }' | awk -F'\t' -v limit="$swift_type_limit" '
      $2 == "decl" { declared[$1 "/" $3] = 1 }
      { total[$1 "/" $3] += $4 }
      END { for (k in total) if (k in declared) printf "swift-type\t%s\t%d\t0\t%d\t0\n", k, total[k], limit }
    ' >> "$measurements"
fi

# Rust files in cmux-tui (tracked only, so build output never counts).
while IFS= read -r rel; do
  [[ -f "$repo/$rel" ]] || continue
  lines=$(wc -l < "$repo/$rel" | tr -d ' ')
  fns=$(grep -cE '^[[:space:]]*(pub(\([a-z:_ ]+\))? +)?(default +)?(const +)?(async +)?(unsafe +)?(extern +"[A-Za-z]+" +)?fn +[A-Za-z_]' "$repo/$rel" || true)
  if [[ "$rel" =~ /(tests|benches|examples)/ || "$rel" =~ (^|/|_)tests\.rs$ ]]; then
    printf 'rust-file\t%s\t%d\t%d\t%d\t%d\n' "$rel" "$lines" "$fns" "$rust_test_file_limit" "$rust_test_fn_limit"
  else
    printf 'rust-file\t%s\t%d\t%d\t%d\t%d\n' "$rel" "$lines" "$fns" "$rust_file_limit" "$rust_fn_limit"
  fi
done < <(git -C "$repo" ls-files 'cmux-tui/*.rs' | grep -vE '^cmux-tui/(vendor/|bindings/rust/src/generated/)') >> "$measurements"

# 3. Compare against the baseline.
[[ -f "$baseline" ]] || : > "$baseline"
report="$(awk -F'\t' -v update="$update" '
  FILENAME == ARGV[1] {
    if ($0 ~ /^#/ || NF < 4) next
    base_lines[$1 "\t" $2] = $3; base_fns[$1 "\t" $2] = $4
    next
  }
  {
    key = $1 "\t" $2; lines = $3; fns = $4; llim = $5; flim = $6
    over = (lines > llim) || (flim > 0 && fns > flim)
    what = ($1 == "swift-type") ? "god type" : "god file"
    unit = ($1 == "swift-type") ? "type " $2 " spans" : $2 " has"
    if (!(key in base_lines)) {
      if (over) {
        printf "FAIL\t%s: %s %d lines, %d fns (limit %d lines, %s fns; not in baseline)\n", what, unit, lines, fns, llim, (flim > 0 ? flim : "no")
      }
      next
    }
    seen[key] = 1
    bl = base_lines[key]; bf = base_fns[key]
    if (lines > bl || fns > bf) {
      printf "FAIL\t%s: %s %d lines, %d fns; baseline allows %d lines, %d fns (shrink it, never grow it)\n", what, unit, lines, fns, bl, bf
      keep_lines[key] = bl; keep_fns[key] = bf
    } else if (!over) {
      printf "NOTE\t%s now meets the budget; run --update-baseline to drop it\n", $2
    } else {
      if (lines < bl || fns < bf) printf "NOTE\t%s shrank to %d lines, %d fns (baseline %d, %d); run --update-baseline\n", $2, lines, fns, bl, bf
      keep_lines[key] = lines; keep_fns[key] = fns
    }
  }
  END {
    for (key in base_lines) if (!(key in seen)) printf "NOTE\t%s is gone; run --update-baseline to drop it\n", key
    if (update) for (key in keep_lines) printf "KEEP\t%s\t%d\t%d\n", key, keep_lines[key], keep_fns[key]
  }
' "$baseline" "$measurements")"

if grep -q '^FAIL' <<<"$report"; then
  grep '^FAIL' <<<"$report" | cut -f2-
  status=1
fi
if (( update )); then
  if (( status != 0 )); then
    echo "not updating $baseline: fix the failures above first"
    exit "$status"
  fi
  {
    echo "# Ratchet for scripts/cmux-next/check-no-godfiles.sh: entries over budget that may only shrink."
    echo "# kind<TAB>key<TAB>lines<TAB>fns. Regenerate with --update-baseline (lowers only)."
    grep '^KEEP' <<<"$report" | cut -f2- | sort
  } > "$baseline"
  echo "updated $baseline"
elif grep -q '^NOTE' <<<"$report"; then
  grep '^NOTE' <<<"$report" | cut -f2-
fi
exit $status
