#!/usr/bin/env bash
# The paths base autofix's "Changed areas" steps map to repairs (cmux-next-base-autofix.yml): what
# SINCE..HEAD changed, for scripts/cmux-next/autofix-areas.sh. Fails when SINCE is empty or can't be
# fetched; the caller then runs every repair.
#
# SINCE is fetched into a scratch repository that borrows the checkout's objects, never into the
# checkout. The checkout is depth 1, and when SINCE is newer than HEAD (a later run went green while
# this one waited) `git fetch --depth=1 origin SINCE` there grafted SINCE as a shallow root: the tip
# fetched later stopped at it, HEAD was no longer its ancestor, and base-autofix-push.sh held every
# Mac export as "not a commit between" (run 39617667536, 2026-10-21).
#
# The settings area comes from these paths alone. A committed source stamp once also turned it on
# when the tip's exports were stale; the stamp is derived now (defaults_guard.py source-stamp), not
# committed, and a held settings export fails its run, so the next run's SINCE still covers it.
#
# Usage: scripts/cmux-next/base-autofix-changed.sh SINCE   (run in the checkout)
set -euo pipefail
since="${1:-}"
[[ -n "$since" ]] || { echo "no commit to diff from" >&2; exit 1; }
root="$(git rev-parse --show-toplevel)"
head="$(git -C "$root" rev-parse HEAD)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q --bare "$scratch"
git -C "$root" rev-parse --path-format=absolute --git-common-dir | sed 's#$#/objects#' > "$scratch/objects/info/alternates"
# core.alternateRefsCommand=true: the checkout's refs (actions/checkout makes a remote ref and a branch) are
# not offered as commits the scratch repository has; it has none of their history, and the remote would
# leave out objects it needs ("remote did not send all necessary objects"). --filter=blob:none: with no
# commits to offer, the whole snapshot would come down (about 550 MB); the path diff reads trees only.
git -C "$scratch" -c core.alternateRefsCommand=true fetch --quiet --no-tags --depth=1 --filter=blob:none "$(git -C "$root" remote get-url origin)" "$since" \
  || { echo "cannot fetch ${since:0:12}" >&2; exit 1; }
git -C "$scratch" diff --name-only --no-renames "$since" "$head"
