#!/usr/bin/env bash
# Whether the PR autofix repairs this pull request's stale generated cmux-next files, so the
# "cmux-next generated files" checks report them as autofixed instead of red (cmux #48531's clippy
# pattern). Run in the checkout of a pull_request run's merge commit (fetch-depth 2: HEAD^1 is the
# base, HEAD^2 the head); the workflow calls it only for a same-repo feat-cmux-next pull request while
# vars.CMUX_PR_AUTOFIX_PUSH is 1 (the PR autofix pushes its repair as a commit,
# cmux-next-pr-autofix-push.yml).
#
# Yes (exit 0) when the head is not itself an autofix commit (an Autofix-Run trailer: that run judges
# the repair, strictly) and the pull request's own changes turn on the PR autofix's action or settings
# exports repair (autofix-areas.sh, as cmux-next-pr-autofix.yml's action-areas job and the exports
# pack step decide it). Stale files the pull request inherits from its base are the base autofix's,
# not this pull request's repair: no. A catalog failure (fresh exports fail too) never reaches here.
# Prints one line saying why, either way.
#
# Usage: scripts/cmux-next/generated-autofixable.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! head="$(git rev-parse -q --verify 'HEAD^2^{commit}' 2>/dev/null)"; then
  echo "not a merge commit (no pull request head): stale files are red"
  exit 1
fi
if git log -1 --format=%B "$head" | grep -q '^Autofix-Run: '; then
  echo "the head ${head:0:12} is a PR autofix commit: its stale files are red"
  exit 1
fi
if ! areas="$(git diff --no-renames --name-only 'HEAD^1' HEAD | "$here/autofix-areas.sh")"; then
  echo "the changed areas are unreadable: stale files are red"
  exit 1
fi
if ! grep -qE '^(actions|settings)=true$' <<<"$areas"; then
  echo "this pull request changes no action or settings export input: the stale files come from the base (the base autofix's)"
  exit 1
fi
echo "the PR autofix regenerates them from this pull request's own changes and pushes them as a commit, checked strictly there"
