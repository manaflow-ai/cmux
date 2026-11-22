#!/usr/bin/env bash
# Applies cargo clippy's machine-applicable fixes (cargo clippy --fix applies
# no other kind) to the cmux-tui workspace crates that own the changed .rs
# files read on stdin, then formats those crates. Linux only: macOS-only lints
# stay with the pull request's macOS clippy. Run by cmux-next-pr-autofix.yml
# before base-autofix.sh; it never commits. Prints "fixed: ..." per changed
# file, or "left: ..." when the crates do not build (their errors are a
# person's to fix).
#
# --affected (the base autofix, base-autofix-repair.sh): the crates those paths can
# affect instead (scripts/ci/cargo_affected.py: the owners and every crate that
# depends on them, or the workspace), close to what the required clippy gate
# checks (.github/scripts/cmux-tui-clippy-changed.py), so a machine-applicable base
# clippy red is repaired on feat-cmux-next once, not by hand in every pull
# request it blocks (#48173, #48184 and #48186 each removed the same
# std::time:: qualification on 2026-11-20).
#
# A stale Cargo.lock (cargo's --locked refusal) is named as such, with its fix,
# by cargo-locks.py explain, instead of "could not build".
#
# Usage: gh pr diff N --name-only | scripts/cmux-next/autofix-clippy.sh [--affected] REPO
set -euo pipefail
affected=0
if [[ "${1:-}" == --affected ]]; then affected=1; shift; fi
repo="$(cd "${1:?usage: $0 [--affected] REPO}" && pwd)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
changed="$(cat)"
grep -qE '^cmux-tui/.*\.rs$' <<<"$changed" || exit 0

log="$(mktemp)"
metadata="$(mktemp)"
metadata_err="$(mktemp)"
trap 'rm -f "$log" "$metadata" "$metadata_err"' EXIT
# stale_lock LOG: cargo-locks.py explain prints the cause and fix when LOG holds cargo's stale-lock refusal.
stale_lock() { python3 "$here/cargo-locks.py" explain "$1" --repo "$repo"; }

# cargo metadata's stderr is kept to explain a failure, and shown as before.
status=0
(cd "$repo/cmux-tui" && cargo metadata --no-deps --format-version 1 --locked >"$metadata" 2>"$metadata_err") || status=$?
cat "$metadata_err" >&2
if (( status != 0 )); then
  if stale_lock "$metadata_err"; then
    echo "left: cargo clippy --fix did not run: a stale Cargo.lock (see the job log for the fix)"
  fi
  exit 1  # as before, when the package lookup read cargo metadata's empty output
fi
if (( affected )); then
  # One package (or --workspace) per line (cargo_affected.py), from the metadata read above.
  packages="$(python3 -I "$here/../ci/cargo_affected.py" --root "$repo" --metadata "$metadata" --files - --format lines <<<"$changed")" || {
    echo "left: cargo clippy --fix did not run: scripts/ci/cargo_affected.py could not select the crates (see the job log)"
    exit 0
  }
else
# Owning crate: the workspace member whose directory is the longest prefix.
packages="$(CHANGED="$changed" REPO="$repo" python3 -I -c '
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
' <"$metadata")"
fi
[[ -n "$packages" ]] || exit 0
args=() fmt_args=()
while IFS= read -r package; do
  if [[ "$package" == --workspace ]]; then args+=(--workspace) fmt_args+=(--all); else args+=(-p "$package") fmt_args+=(-p "$package"); fi
done <<<"$packages"

if ! (cd "$repo/cmux-tui" && cargo clippy --fix --allow-dirty --allow-staged --locked --all-targets "${args[@]}" >"$log" 2>&1); then
  tail -n 40 "$log" >&2
  if stale_lock "$log"; then
    echo "left: cargo clippy --fix did not run on $(tr '\n' ' ' <<<"$packages")(a stale Cargo.lock; see the job log for the fix)"
  else
    echo "left: cargo clippy --fix could not build $(tr '\n' ' ' <<<"$packages")(see the job log)"
  fi
  git -C "$repo" checkout --quiet -- cmux-tui
  exit 0
fi
(cd "$repo/cmux-tui" && cargo fmt "${fmt_args[@]}")
git -C "$repo" diff --name-only -- cmux-tui | sed 's/^/fixed: cargo clippy --fix /'
