#!/usr/bin/env bash
# Makes a reused runner workspace match a fresh checkout that has no
# submodule checkouts. Run it right after actions/checkout with
# `submodules: false` on a job that can run on a self-hosted runner.
#
# Why: a mini (glaeda-*) reuses its workspace, and checkout with
# `submodules: false` moves the superproject but leaves each submodule at the
# commit the previous job checked out (main's ghostty, say). git status then
# reports ` M ghostty`, and pin-cmux-tui.sh fetch refuses the checkout as
# uncommitted cmux-tui source (run 37198483749). Blacksmith starts with no
# submodule checkouts.
#
# By default `git submodule deinit --force --all` empties each submodule
# directory and drops its config but keeps .git/modules, so a later job that
# checks out with submodules re-inits from the kept objects at its own gitlink.
# The fast tier only needs ghostty-next, though. Passing `--reuse <path>...`
# reconciles selected checkouts in place, keeping their object database and
# warm working tree while forcing the exact gitlink.
#
# Usage: scripts/ci/reset-stale-submodules.sh [repo]
#        scripts/ci/reset-stale-submodules.sh [repo] --reuse <path>...
# (default repo: $GITHUB_WORKSPACE or .)
set -euo pipefail

repo="${GITHUB_WORKSPACE:-$PWD}"
mode=deinit
paths=()
if [[ $# -gt 0 && "$1" != --* ]]; then
  repo="$1"
  shift
fi
if [[ "${1:-}" == --reuse ]]; then
  mode=reuse
  shift
  (($# > 0)) || { echo "reset-stale-submodules: --reuse needs at least one submodule path" >&2; exit 2; }
  paths=("$@")
elif (($# > 0)); then
  echo "reset-stale-submodules: unknown arguments: $*" >&2
  exit 2
fi
[[ -f "$repo/.gitmodules" ]] || exit 0

# A reused workspace can lose .git/modules while its submodule checkouts stay
# (2026-10-28, the warm nightly-next builder: `fatal: not a git repository:
# ghostty/../.git/modules/ghostty`). Every git submodule command below fails on
# such a checkout, so drop it first (nested ones too, with any half-made git
# dir), as a fresh checkout leaves it: an empty, uninitialized directory. The
# consuming step clones it again. git_fetch_retry.py touches only paths inside
# the repository with no symlink on the way; --reuse drops only its own paths.
drop_dangling() {
  python3 "$(dirname "${BASH_SOURCE[0]}")/git_fetch_retry.py" --drop-dangling-submodules --repo "$repo" "$@" \
    | sed 's/^git_fetch_retry: /reset-stale-submodules: /'
}

if [[ "$mode" == reuse ]]; then
  for path in "${paths[@]}"; do
    # Refuse typos instead of silently skipping a path that was meant to be
    # reconciled. The .gitmodules file is the source of truth for valid paths.
    if ! git -C "$repo" config -f .gitmodules --get-regexp '^submodule\..*\.path$' \
      | awk -v want="$path" '$2 == want { found=1 } END { exit found ? 0 : 1 }'; then
      echo "reset-stale-submodules: unknown submodule path: $path" >&2
      exit 2
    fi
    drop_dangling --only "$path"
    status="$(git -C "$repo" submodule status -- "$path")"
    # A leading '-' means this checkout is already uninitialized. Leave the
    # object database alone; the consuming step will initialize the gitlink.
    [[ -n "$status" && "$status" != -* ]] || continue
    submodule="$repo/$path"
    echo "reset-stale-submodules: reusing $path at the superproject gitlink"
    # Clean tracked and untracked source edits left by the previous job before
    # forcing the exact commit. Keep ignored build caches for warm compilation.
    git -C "$submodule" reset --hard --quiet
    git -C "$submodule" clean -ffd --quiet
    # Keep the same bounded retry/low-speed behavior as cold initialization.
    if [[ -x "$repo/scripts/ci/init-submodule.sh" ]]; then
      (cd "$repo" && bash scripts/ci/init-submodule.sh "$path")
    else
      git -C "$repo" submodule update --init --force --depth 1 --filter=blob:none -- "$path"
    fi
    expected="$(git -C "$repo" rev-parse "HEAD:$path")"
    actual="$(git -C "$submodule" rev-parse HEAD)"
    [[ "$actual" == "$expected" ]] || {
      echo "reset-stale-submodules: $path is at $actual, expected $expected" >&2
      exit 1
    }
    [[ -z "$(git -C "$repo" status --porcelain -- "$path")" ]] || {
      echo "reset-stale-submodules: $path remains dirty after reuse" >&2
      exit 1
    }
  done
  exit 0
fi

# Initialized submodules; an uninitialized one (status prefix '-') is already clean.
# A failing status (dubious ownership, a corrupt .git/modules) fails here,
# not later as a confusing dirty-source refusal.
drop_dangling
status="$(git -C "$repo" submodule status)"
stale="$(printf '%s\n' "$status" | grep -v '^-' || true)"
[[ -n "$stale" ]] || exit 0
echo "reset-stale-submodules: dropping submodule checkouts a previous job left:"
printf '%s\n' "$stale" | sed 's/^/  /'
git -C "$repo" submodule deinit --force --all --quiet
