#!/usr/bin/env bash
# Repairs the mechanical reds of a feat-cmux-next checkout in place, without
# committing or pushing (cmux-next-base-autofix.yml does that):
#   - generated files: copies DIR's files (the cmux-next generated files job's
#     cmux-next-generated-patch artifact: the action contracts and the CI target
#     graph regenerated on a Mac, at their repository paths) over the checkout;
#   - the CI target graph: rewrites Packages/macOS/CmuxNext/ci-target-graph.json
#     from FILE, the package's `swift package dump-package` output (Swift 6.2
#     on Linux dumps the same manifest as the Mac);
#   - page strings: every React page's generated/strings.json from its xcstrings
#     catalogs (webviews/scripts/pages/gen-strings.mjs; with --strings);
#   - cmux-tui tree inputs: reports each embed check_cmux_tui_tree_inputs.py
#     finds missing (the fix edits a workflow file, which GITHUB_TOKEN cannot push);
#   - the app FFI pin: reports a stale pin (Package.swift is frozen; the
#     app-ffi-repin pull request carries it);
#   - formatting: cargo fmt over the cmux-tui workspace (unless --no-fmt).
# A path matching base-autofix-frozen.txt is never written; it is reported.
# Prints one line per change ("fixed: ..."), skip ("skipped (frozen): ...") or
# repair left to a person ("left: ...").
#
# Usage: scripts/cmux-next/base-autofix.sh [--generated DIR] [--package-dump FILE] [--strings] [--no-fmt] REPO
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
generated="" package_dump="" strings=0 fmt=1
while (( $# > 1 )); do
  case "$1" in
    --generated) generated="$2"; shift 2 ;;
    --package-dump) package_dump="$2"; shift 2 ;;
    --strings) strings=1; shift ;;
    --no-fmt) fmt=0; shift ;;
    *) echo "usage: $0 [--generated DIR] [--package-dump FILE] [--strings] [--no-fmt] REPO" >&2; exit 2 ;;
  esac
done
repo="$(cd "${1:?usage: $0 [--generated DIR] [--package-dump FILE] [--strings] [--no-fmt] REPO}" && pwd)"
frozen_list="$script_dir/base-autofix-frozen.txt"

frozen() { # repository-relative path -> 0 when frozen; a "!" line exempts a path
  local pattern hit=1
  while IFS= read -r pattern; do
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    # shellcheck disable=SC2053 # the pattern is a glob
    if [[ "$pattern" == !* ]]; then [[ "$1" == ${pattern#!} ]] && return 1
    elif [[ "$1" == $pattern ]]; then hit=0
    fi
  done < "$frozen_list"
  return "$hit"
}

# 1. Generated files.
if [[ -n "$generated" && -d "$generated" ]]; then
  while IFS= read -r -d '' file; do
    rel="${file#"$generated"/}"
    if cmp -s "$file" "$repo/$rel"; then continue; fi
    if frozen "$rel"; then echo "skipped (frozen): $rel"; continue; fi
    mkdir -p "$(dirname "$repo/$rel")"
    cp "$file" "$repo/$rel"
    echo "fixed: regenerated $rel"
  done < <(find "$generated" -type f -print0 | sort -z)
fi

# 1b. The CI target graph, from the checkout's own generator.
graph=Packages/macOS/CmuxNext/ci-target-graph.json
if [[ -n "$package_dump" ]]; then
  if frozen "$graph"; then
    echo "skipped (frozen): $graph"
  else
    before="$(cksum < "$repo/$graph" 2>/dev/null || true)"
    python3 -I "$repo/scripts/cmux-next/ci-target-graph.py" --dump "$package_dump" >/dev/null
    [[ "$before" == "$(cksum < "$repo/$graph")" ]] || echo "fixed: regenerated $graph"
  fi
fi

# 1c. Page strings. The generator writes every stale page; a frozen one is put
# back as it was and reported.
if (( strings )) && [[ -f "$repo/webviews/scripts/pages/gen-strings.mjs" ]]; then
  if ! (cd "$repo" && node webviews/scripts/pages/gen-strings.mjs --check >/dev/null 2>&1); then
    (cd "$repo" && node webviews/scripts/pages/gen-strings.mjs >/dev/null)
    changed="$(git -C "$repo" ls-files --modified --others --exclude-standard -- webviews)"
    while IFS= read -r rel; do
      [[ "$rel" == */generated/strings.json ]] || continue
      if frozen "$rel"; then
        git -C "$repo" checkout --quiet -- "$rel" 2>/dev/null || rm -f "$repo/$rel"
        echo "skipped (frozen): $rel (stale; node webviews/scripts/pages/gen-strings.mjs)"
      else
        echo "fixed: regenerated $rel"
      fi
    done <<<"$changed"
  fi
fi

# 2. cmux-tui tree inputs: reported only. Each must also be a pull_request_target
# path of cmux-tui-artifacts.yml, a workflow file GITHUB_TOKEN cannot push, and
# the two lists must change together.
missing="$(python3 -I "$script_dir/../ci/check_cmux_tui_tree_inputs.py" --root "$repo" 2>&1 >/dev/null | grep -E '^(blob|tree) ' || true)"
while IFS= read -r entry; do
  [[ -n "$entry" ]] && echo "left: cmux-tui tree input $entry (add it to scripts/cmux-next/cmux-tui-tree-inputs.txt and .github/workflows/cmux-tui-artifacts.yml by hand)"
done <<<"$missing"

# 3. The app FFI pin (reported only: Package.swift is frozen).
if [[ -f "$repo/Packages/macOS/CmuxNext/Package.swift" && -x "$repo/scripts/cmux-next/check-app-ffi-pin.sh" ]]; then
  if ! (cd "$repo" && scripts/cmux-next/check-app-ffi-pin.sh >/dev/null 2>&1); then
    if frozen Packages/macOS/CmuxNext/Package.swift; then
      echo "skipped (frozen): Packages/macOS/CmuxNext/Package.swift (stale app FFI pin; the app-ffi-repin pull request carries it)"
    else
      echo "left: stale app FFI pin; repin with scripts/cmux-next/repin-app-ffi.sh once its release is published"
    fi
  fi
fi

# 4. Formatting.
if (( fmt )) && [[ -f "$repo/cmux-tui/Cargo.toml" ]]; then
  before="$(git -C "$repo" status --porcelain -- cmux-tui)"
  (cd "$repo/cmux-tui" && cargo fmt --all)
  after="$(git -C "$repo" status --porcelain -- cmux-tui)"
  [[ "$before" == "$after" ]] || echo "fixed: cargo fmt in cmux-tui"
fi
exit 0
