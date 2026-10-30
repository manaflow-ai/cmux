#!/usr/bin/env bash
# Applies cargo clippy's machine-applicable fixes (cargo clippy --fix applies
# no other kind) to the cmux-tui workspace crates that own the changed .rs
# files read on stdin, then formats those crates. Linux only: macOS-only lints
# stay with the pull request's macOS clippy. Run by cmux-next-pr-autofix.yml
# before base-autofix.sh; it never commits. Prints "fixed: ..." per changed
# file, or "left: ..." when the crates do not build (their errors are a
# person's to fix).
#
# Usage: gh pr diff N --name-only | scripts/cmux-next/autofix-clippy.sh REPO
set -euo pipefail
repo="$(cd "${1:?usage: $0 REPO}" && pwd)"
changed="$(cat)"
grep -qE '^cmux-tui/.*\.rs$' <<<"$changed" || exit 0

# Owning crate: the workspace member whose directory is the longest prefix.
packages="$(cd "$repo/cmux-tui" && cargo metadata --no-deps --format-version 1 --locked | CHANGED="$changed" REPO="$repo" python3 -I -c '
import json, os, sys
meta = json.load(sys.stdin)
members = set(meta["workspace_members"])
dirs = sorted(((os.path.relpath(os.path.dirname(p["manifest_path"]), os.environ["REPO"]), p["name"])
               for p in meta["packages"] if p["id"] in members), key=lambda d: -len(d[0]))
names = set()
for path in os.environ["CHANGED"].splitlines():
    if path.startswith("cmux-tui/") and path.endswith(".rs"):
        for directory, name in dirs:
            if path.startswith(directory + "/"):
                names.add(name)
                break
print("\n".join(sorted(names)))
')"
[[ -n "$packages" ]] || exit 0
args=()
while IFS= read -r package; do args+=(-p "$package"); done <<<"$packages"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
if ! (cd "$repo/cmux-tui" && cargo clippy --fix --allow-dirty --allow-staged --locked --all-targets "${args[@]}" >"$log" 2>&1); then
  tail -n 40 "$log" >&2
  echo "left: cargo clippy --fix could not build $(tr '\n' ' ' <<<"$packages")(see the job log)"
  git -C "$repo" checkout --quiet -- cmux-tui
  exit 0
fi
(cd "$repo/cmux-tui" && cargo fmt "${args[@]}")
git -C "$repo" diff --name-only -- cmux-tui | sed 's/^/fixed: cargo clippy --fix /'
