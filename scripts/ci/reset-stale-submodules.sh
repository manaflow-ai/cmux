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
# `git submodule deinit --force --all` empties each submodule directory and
# drops its config but keeps .git/modules, so a later job that checks out
# with submodules re-inits from the kept objects at its own gitlink.
#
# Usage: scripts/ci/reset-stale-submodules.sh [repo]  (default: $GITHUB_WORKSPACE or .)
set -euo pipefail

repo="${1:-${GITHUB_WORKSPACE:-$PWD}}"
[[ -f "$repo/.gitmodules" ]] || exit 0
# Initialized submodules; an uninitialized one (status prefix '-') is already clean.
stale="$(git -C "$repo" submodule status 2>/dev/null | grep -v '^-' || true)"
[[ -n "$stale" ]] || exit 0
echo "reset-stale-submodules: dropping submodule checkouts a previous job left:"
printf '%s\n' "$stale" | sed 's/^/  /'
git -C "$repo" submodule deinit --force --all --quiet
