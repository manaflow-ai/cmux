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
# --only swift checks the Swift files and types; --only rust checks the cmux-tui
# Rust files. CI runs them as separate steps so one half never hides the other.
# --update-baseline rewrites the whole baseline, so it takes no --only.
#
# --base REF scopes the check to one change: an entry over its budget fails only
# when it is bigger than in REF's tree (pushed past its budget, grown further
# while over, or new). One already over budget in REF that this change did not
# grow is a note, so a god file on the base never fails an unrelated pull
# request. A pull request passes its merge commit's first parent (HEAD^1). An
# unknown REF checks every file, as without --base.
#
# --file PATH (repeatable, repository-relative) measures only those files: a
# Rust or Swift file's own limits, and each Swift type of the named Swift
# files' modules (a type spans all its extensions in its module). safe-push
# passes the files a push changes; CI scans everything.
#
# Usage: scripts/cmux-next/check-no-godfiles.sh [--update-baseline | --only swift|rust] [--base REF] [--file PATH]... [package-root]
set -euo pipefail

update=0
only=all
base_ref=""
files=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --update-baseline) update=1; shift ;;
    --base)
      [[ -n "${2:-}" ]] || { echo "--base takes a commit" >&2; exit 2; }
      base_ref="$2"
      shift 2 ;;
    --file)
      [[ -n "${2:-}" ]] || { echo "--file takes a repository-relative path" >&2; exit 2; }
      files+="$2"$'\n'
      shift 2 ;;
    --only)
      case "${2:-}" in
        swift | rust) only="$2" ;;
        *) echo "--only takes swift or rust, got '${2:-}'" >&2; exit 2 ;;
      esac
      shift 2 ;;
    *) break ;;
  esac
done
if (( update )) && [[ "$only" != all || -n "$base_ref" || -n "$files" ]]; then
  echo "--update-baseline rewrites every entry; run it without --only, --base or --file" >&2
  exit 2
fi
check_swift=0; check_rust=0
[[ "$only" != rust ]] && check_swift=1
[[ "$only" != swift ]] && check_rust=1
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
# A Rust function declaration line (free fn, method, trait item).
rust_fn_re='^[[:space:]]*(pub(\([a-z:_ ]+\))? +)?(default +)?(const +)?(async +)?(unsafe +)?(extern +"[A-Za-z]+" +)?fn +[A-Za-z_]'

status=0

# Measure ROOT's package and REPO's cmux-tui. REV names the tree the files come
# from when they are an archive of a commit (ls-tree), not a checkout (ls-files).
# Rows: "kind<TAB>key<TAB>lines<TAB>fns<TAB>line-limit<TAB>fn-limit"; for a
# swift-file row, fns is its top-level type count and fn-limit the type limit
# (0: no type limit, in tests).
# --file scoping. in_files keeps the stdin paths that are named (all without --file).
pkg_rel() { # root repo -> the package path relative to the repository (symlinks resolved)
  local r p
  r="$(cd "$1" && pwd -P)"; p="$(cd "$2" && pwd -P)"
  echo "${r#"$p"/}"
}
in_files() { if [[ -z "$files" ]]; then cat; else grep -xF -f <(printf '%s' "$files") || true; fi; }
swift_files() { # root repo -> NUL-separated Swift files to measure
  local root="$1" repo="$2" pkg rel
  if [[ -z "$files" ]]; then
    find "$root/Sources" "$root/Tests" -name '*.swift' -print0 2>/dev/null
    return 0
  fi
  pkg="$(pkg_rel "$root" "$repo")"
  while IFS= read -r rel; do
    [[ "$rel" == "$pkg"/Sources/*.swift || "$rel" == "$pkg"/Tests/*.swift ]] || continue
    [[ -f "$repo/$rel" ]] && printf '%s\0' "$repo/$rel"
  done <<<"$files"
  return 0
}
type_dirs() { # root repo -> module directories whose types to measure
  local root="$1" repo="$2" pkg rel module
  if [[ -z "$files" ]]; then echo "$root/Sources"; return 0; fi
  pkg="$(pkg_rel "$root" "$repo")"
  while IFS= read -r rel; do
    [[ "$rel" == "$pkg"/Sources/*.swift ]] || continue
    module="${rel#"$pkg"/Sources/}"; module="${module%%/*}"
    [[ -d "$root/Sources/$module" ]] && echo "$root/Sources/$module"
  done <<<"$files" | sort -u
  return 0
}
measure() {
  local root="$1" repo="$2" rev="${3:-}" file lines limit types tlimit rel fns
  # 1. Swift files: absolute limits.
  (( check_swift )) && while IFS= read -r -d '' file; do
    lines=$(wc -l < "$file" | tr -d ' ')
    limit=$swift_file_limit
    tlimit=3
    [[ "$file" == */Tests/* ]] && limit=$swift_test_file_limit && tlimit=0
    # Top-level primary declarations (extensions and small nested helpers are fine).
    types=$(grep -cE '^(public |internal |package |fileprivate |private |final |nonisolated |indirect |@MainActor |@Observable |@frozen )*(final )?(class|struct|enum|actor|protocol) ' "$file" || true)
    printf 'swift-file\t%s\t%d\t%d\t%d\t%d\n' "${file#"$root"/}" "$lines" "$types" "$limit" "$tlimit"
  done < <(swift_files "$root" "$repo")

  # 2. Ratcheted entries. Swift types: a top-level declaration starts at column 0
  # and ends at the next line that starts with "}" (the package is formatted that way).
  if (( check_swift )) && [[ -d "$root/Sources" ]] && [[ -n "$(type_dirs "$root" "$repo")" ]]; then
    type_dirs "$root" "$repo" | tr '\n' '\0' | xargs -0 -I{} find {} -name '*.swift' -print0 | xargs -0 awk '
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
      '
  fi

  # Rust files in cmux-tui (tracked only, so build output never counts).
  (( check_rust )) && while IFS= read -r rel; do
    [[ -f "$repo/$rel" ]] || continue
    lines=$(wc -l < "$repo/$rel" | tr -d ' ')
    fns=$(grep -cE "$rust_fn_re" "$repo/$rel" || true)
    if [[ "$rel" =~ /(tests|benches|examples)/ || "$rel" =~ (^|/|_)tests\.rs$ ]]; then
      printf 'rust-file\t%s\t%d\t%d\t%d\t%d\n' "$rel" "$lines" "$fns" "$rust_test_file_limit" "$rust_test_fn_limit"
    else
      printf 'rust-file\t%s\t%d\t%d\t%d\t%d\n' "$rel" "$lines" "$fns" "$rust_file_limit" "$rust_fn_limit"
    fi
  done < <(if [[ -n "$rev" ]]; then git -C "$script_repo" ls-tree -r --name-only "$rev" -- cmux-tui; else git -C "$repo" ls-files 'cmux-tui/*.rs'; fi \
    | grep -E '\.rs$' | grep -vE '^cmux-tui/(vendor/|bindings/rust/src/generated/)' | in_files)
  return 0
}

measurements="$(mktemp)"
base_measurements="$(mktemp)"
base_tree=""
cleanup() { rm -f "$measurements" "$base_measurements"; [[ -z "$base_tree" ]] || rm -rf "$base_tree"; }
trap cleanup EXIT
script_repo="$repo"
measure "$root" "$repo" > "$measurements"

# 3. Compare against the baseline, and with --base against REF's measurements
# (ARGV[2]; empty until it is measured). A swift-file row's fns is its type count.
[[ -f "$baseline" ]] || : > "$baseline"
evaluate() { # scoped (0 or 1) -> report lines
  awk -F'\t' -v update="$update" -v only="$only" -v scoped="$1" -v filescoped="${files:+1}" '
  FILENAME == ARGV[1] {
    if ($0 ~ /^#/ || NF < 4) next
    if (only == "swift" && $1 != "swift-type") next
    if (only == "rust" && $1 != "rust-file") next
    base_lines[$1 "\t" $2] = $3; base_fns[$1 "\t" $2] = $4
    next
  }
  FILENAME == ARGV[2] {
    was_lines[$1 "\t" $2] = $3; was_fns[$1 "\t" $2] = $4
    next
  }
  $1 == "swift-file" {
    # Absolute limits: lines (and, outside tests, top-level types) per Swift file.
    key = $1 "\t" $2; lines = $3; types = $4; limit = $5; tlimit = $6
    if (lines > limit) {
      if (scoped && (key in was_lines) && was_lines[key] >= lines)
        printf "NOTE\t%s has %d lines (limit %d), over budget on the base too; this change did not grow it\n", $2, lines, limit
      else
        printf "FAIL\tswift-file\t%s\tgod file: %s has %d lines (limit %d)\n", $2, $2, lines, limit
    }
    if (tlimit > 0 && types > tlimit) {
      if (scoped && (key in was_fns) && was_fns[key] >= types)
        printf "NOTE\t%s declares %d top-level types (limit %d), over budget on the base too\n", $2, types, tlimit
      else
        printf "FAIL\tswift-file\t%s\tgod file: %s declares %d top-level types (limit %d)\n", $2, $2, types, tlimit
    }
    next
  }
  {
    key = $1 "\t" $2; lines = $3; fns = $4; llim = $5; flim = $6
    # --base: an entry this change did not grow is the base'"'"'s, never this change'"'"'s failure.
    kept = scoped && (key in was_lines) && lines <= was_lines[key] && fns <= was_fns[key]
    over = (lines > llim) || (flim > 0 && fns > flim)
    what = ($1 == "swift-type") ? "god type" : "god file"
    unit = ($1 == "swift-type") ? "type " $2 " spans" : $2 " has"
    if (!(key in base_lines)) {
      if (over && kept) {
        printf "NOTE\t%s: %d lines, %d fns, over budget on the base too; this change did not grow it\n", $2, lines, fns
      } else if (over) {
        printf "FAIL\t%s\t%s\t%s: %s %d lines, %d fns (limit %d lines, %s fns; not in baseline: split it)\n", $1, $2, what, unit, lines, fns, llim, (flim > 0 ? flim : "no")
      }
      next
    }
    seen[key] = 1
    bl = base_lines[key]; bf = base_fns[key]
    if ((lines > bl || fns > bf) && kept) {
      printf "NOTE\t%s: %d lines, %d fns, over its baseline on the base too; this change did not grow it\n", $2, lines, fns
      keep_lines[key] = bl; keep_fns[key] = bf
    } else if (lines > bl || fns > bf) {
      printf "FAIL\t%s\t%s\t%s: %s %d lines, %d fns; baseline allows %d lines, %d fns (+%d lines, +%d fns over; move new code to a new module or type)\n", $1, $2, what, unit, lines, fns, bl, bf, (lines > bl ? lines - bl : 0), (fns > bf ? fns - bf : 0)
      keep_lines[key] = bl; keep_fns[key] = bf
    } else if (!over) {
      printf "NOTE\t%s now meets the budget; run --update-baseline to drop it\n", $2
    } else {
      if (lines < bl || fns < bf) printf "NOTE\t%s shrank to %d lines, %d fns (baseline %d, %d); run --update-baseline\n", $2, lines, fns, bl, bf
      keep_lines[key] = lines; keep_fns[key] = fns
    }
  }
  END {
    if (!filescoped) for (key in base_lines) if (!(key in seen)) printf "NOTE\t%s is gone; run --update-baseline to drop it\n", key
    if (update) for (key in keep_lines) printf "KEEP\t%s\t%d\t%d\n", key, keep_lines[key], keep_fns[key]
  }
' "$baseline" "$base_measurements" "$measurements"
}
report="$(evaluate 0)"

# --base: measure REF's tree (an archive of it) only when something here would
# fail, then keep only the failures this change caused.
if [[ -n "$base_ref" ]] && grep -q '^FAIL' <<<"$report"; then
  if base_commit="$(git -C "$repo" rev-parse --verify --quiet "$base_ref^{commit}")"; then
    base_tree="$(mktemp -d)"
    package_rel="${root#"$repo"/}"
    git -C "$repo" archive "$base_commit" -- "$package_rel" cmux-tui 2>/dev/null | tar -x -C "$base_tree" 2>/dev/null || true
    measure "$base_tree/$package_rel" "$base_tree" "$base_commit" > "$base_measurements"
    report="$(evaluate 1)"
  else
    echo "::warning::--base $base_ref is not a commit here; checking every file"
  fi
fi


# Each Rust failure names the commit that pushed the file over its allowance
# (the oldest commit of the newest run of over-budget versions), so an agent
# can tell a failure it caused from one already on the branch. Everything is
# measured in this checkout's tree; history needs a non-shallow clone.
allowance() { # kind key -> "lines fns" from the baseline, else the budget
  local found
  found="$(awk -F'\t' -v k="$1" -v p="$2" '$1==k && $2==p {print $3, $4; exit}' "$baseline")"
  if [[ -n "$found" ]]; then echo "$found"
  elif [[ "$2" =~ /(tests|benches|examples)/ || "$2" =~ (^|/|_)tests\.rs$ ]]; then echo "$rust_test_file_limit $rust_test_fn_limit"
  else echo "$rust_file_limit $rust_fn_limit"; fi
}
grower() { # key allowed_lines allowed_fns
  local key="$1" allow_lines="$2" allow_fns="$3" commit lines fns culprit=""
  if [[ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" == true ]]; then
    echo "unknown in a shallow checkout; run the check in a full clone"
    return
  fi
  lines=$(git -C "$repo" show "HEAD:$key" 2>/dev/null | wc -l | tr -d ' ')
  fns=$(git -C "$repo" show "HEAD:$key" 2>/dev/null | grep -cE "$rust_fn_re" || true)
  if (( lines <= allow_lines && fns <= allow_fns )); then
    echo "uncommitted changes in this checkout"
    return
  fi
  while IFS= read -r commit; do
    lines=$(git -C "$repo" show "$commit:$key" 2>/dev/null | wc -l | tr -d ' ')
    fns=$(git -C "$repo" show "$commit:$key" 2>/dev/null | grep -cE "$rust_fn_re" || true)
    if (( lines > allow_lines || fns > allow_fns )); then culprit="$commit"; else break; fi
  done < <(git -C "$repo" log --format=%H -n 40 HEAD -- "$key")
  if [[ -n "$culprit" ]]; then
    git -C "$repo" log -1 --format='%h %an %ad: %s' --date=short "$culprit"
  else
    echo "unknown"
  fi
}
if grep -q '^FAIL' <<<"$report"; then
  while IFS=$'\t' read -r _ kind key message; do
    if [[ "$kind" == rust-file ]]; then
      read -r allow_lines allow_fns <<<"$(allowance "$kind" "$key")"
      echo "$message [grown past it by: $(grower "$key" "$allow_lines" "$allow_fns")]"
    else
      echo "$message"
    fi
  done < <(grep '^FAIL' <<<"$report")
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
