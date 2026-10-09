#!/usr/bin/env bash
# Repairs the mechanical reds of a feat-cmux-next checkout in place, without
# committing or pushing (cmux-next-base-autofix.yml does that):
#   - generated files: copies DIR's files (the cmux-next generated files job's
#     cmux-next-generated-patch artifact: the action contracts and the CI target
#     graph regenerated on a Mac, at their repository paths) over the checkout;
#   - cmux-tui tree inputs: adds each embed check_cmux_tui_tree_inputs.py finds
#     missing to cmux-tui-tree-inputs.txt and to cmux-tui-artifacts.yml's
#     pull_request_target paths;
#   - the app FFI pin: reports a stale pin (Package.swift is frozen; the
#     app-ffi-repin pull request carries it);
#   - formatting: cargo fmt over the cmux-tui workspace (unless --no-fmt).
# A path matching base-autofix-frozen.txt is never written; it is reported.
# Prints one line per change ("fixed: ...") or skip ("skipped (frozen): ...").
#
# Usage: scripts/cmux-next/base-autofix.sh [--generated DIR] [--no-fmt] REPO
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
generated="" fmt=1
while (( $# > 1 )); do
  case "$1" in
    --generated) generated="$2"; shift 2 ;;
    --no-fmt) fmt=0; shift ;;
    *) echo "usage: $0 [--generated DIR] [--no-fmt] REPO" >&2; exit 2 ;;
  esac
done
repo="$(cd "${1:?usage: $0 [--generated DIR] [--no-fmt] REPO}" && pwd)"
frozen_list="$script_dir/base-autofix-frozen.txt"

frozen() { # repository-relative path -> 0 when frozen
  local pattern
  while IFS= read -r pattern; do
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    # shellcheck disable=SC2053 # the pattern is a glob
    [[ "$1" == $pattern ]] && return 0
  done < "$frozen_list"
  return 1
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

# 2. cmux-tui tree inputs.
inputs="scripts/cmux-next/cmux-tui-tree-inputs.txt"
artifacts=".github/workflows/cmux-tui-artifacts.yml"
missing="$(python3 -I "$script_dir/../ci/check_cmux_tui_tree_inputs.py" --root "$repo" 2>&1 >/dev/null | grep -E '^(blob|tree) ' || true)"
if [[ -n "$missing" ]]; then
  if frozen "$inputs" || frozen "$artifacts"; then
    echo "skipped (frozen): $inputs"
  else
    printf '%s\n' "$missing" >> "$repo/$inputs"
    python3 -I - "$repo/$artifacts" "$missing" <<'PY'
import sys
path, missing = sys.argv[1], sys.argv[2].split("\n")
lines = open(path).read().split("\n")
start = next(i for i, l in enumerate(lines) if l.strip() == "pull_request_target:")
paths = next(i for i in range(start, len(lines)) if lines[i].strip() == "paths:")
end = paths + 1
while end < len(lines) and lines[end].startswith("      - "):
    end += 1
new = []
for entry in missing:
    kind, rel = entry.split(" ", 1)
    pattern = rel + "/**" if kind == "tree" else rel
    if f'      - "{pattern}"' not in lines[paths + 1:end]:
        new.append(f'      - "{pattern}"')
lines[end:end] = new
open(path, "w").write("\n".join(lines))
PY
    while IFS= read -r entry; do echo "fixed: tree input $entry"; done <<<"$missing"
  fi
fi

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
