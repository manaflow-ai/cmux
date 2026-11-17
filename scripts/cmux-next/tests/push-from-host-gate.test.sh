#!/usr/bin/env bash
# push-from-host.sh pushes only from a clone whose pre-push runs cmux's own gate (prepush-gate). Before this check it
# accepted any executable pre-push in core.hooksPath: on 2026-11-16 cmux16's clones had a shared hooks folder whose
# pre-push ran no prepush-gate (no cmux pre-push in cmux-git-hooks), and a merge that dropped settings exports' keys
# was pushed from there unchecked (cmux#43562 885211f5).
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../push-from-host.sh"
tmp="$(mktemp -d)"
git_fixture_trap_exit 'rm -rf "$tmp"'
fail() { echo "FAIL: $*" >&2; exit 1; }

# Host selection is registry-owned. A hand-kept fallback once sent work to Leo's cmux16 when the fleet host was full.
grep -q 'CMUX_FLEET_REGISTRY' "$script" || fail "push-from-host.sh does not read the fleet registry"
if grep -Eq 'DEFAULT_HOSTS=.*cmux16|cmux16:Projects/cmux' "$script"; then
  fail "push-from-host.sh still hard-codes cmux16 as a fallback"
fi
# Only the fixture's own config: a global core.hooksPath (a shared hooks folder on this machine) would answer the
# "no core.hooksPath" case below. HOME too, for the `~/...` case.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="$tmp/home" \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME"

# The function under test, exactly as the host runs it.
fn="$tmp/gate_hook_runs.sh"
sed -n '/^# BEGIN gate_hook_runs$/,/^# END gate_hook_runs$/p' "$script" >"$fn"
grep -q '^gate_hook_runs()' "$fn" || fail "gate_hook_runs not found in push-from-host.sh"

repo="$tmp/repo"
git init -q "$repo"
own="$repo/.git/cmux-git-hooks"
shared="$HOME/shared-hooks"
mkdir -p "$own" "$shared"
hook() { printf '#!/bin/sh\n%s\n' "$2" >"$1"; chmod +x "$1"; }
runs() { (cd "$repo" && source "$fn" && gate_hook_runs); }
set_hooks() { git -C "$repo" config core.hooksPath "$1"; }
printf 'run_repo_hooks() {\n  :\n}\n' >"$shared/repo-hook"
gate_line='python3 scripts/cmux-next/prepush-gate.py --pre-push'
shared_line='. "$(dirname "$0")/repo-hook"; run_repo_hooks pre-push'

# cmux16 on 2026-11-16: a shared hooks folder, no cmux pre-push in cmux-git-hooks.
hook "$shared/pre-push" "$shared_line"
set_hooks "$shared"
runs && fail "a clone with no cmux pre-push passed"

# A shared hooks folder whose pre-push does not run the repo's hooks: cmux's gate never runs.
hook "$own/pre-push" "$gate_line"
hook "$shared/pre-push" 'exit 0'
runs && fail "a shared pre-push that skips the repo's hooks passed"

# The shared folder runs each repo's own hooks: the gate runs.
hook "$shared/pre-push" "$shared_line"
runs || fail "a shared pre-push that runs the repo's hooks was refused"

# The same folder written with a leading tilde: git expands it when it runs the hook, so the check must too.
set_hooks "~/shared-hooks"
runs || fail "a tilde core.hooksPath was refused"

# A shared pre-push that names run_repo_hooks with no repo-hook beside it defining it runs nothing.
mv "$shared/repo-hook" "$shared/repo-hook.off"
runs && fail "a shared pre-push with no repo-hook passed"
mv "$shared/repo-hook.off" "$shared/repo-hook"

# A relative core.hooksPath is resolved in the pushed tree, not where this check runs.
mkdir -p "$repo/hooks"
cp "$shared/pre-push" "$shared/repo-hook" "$repo/hooks/"
set_hooks hooks
runs && fail "a relative core.hooksPath passed"

# The wiring install-git-hooks.sh prints for a clone with hooks of its own: a pre-push calling cmux's.
direct="$tmp/direct-hooks"
mkdir -p "$direct"
hook "$direct/pre-push" "'$own/pre-push' || exit 1"
set_hooks "$direct"
runs || fail "a pre-push that calls cmux-git-hooks/pre-push directly was refused"

# The same call with the clone named through a symlink (macOS's /var/folders is /private/var/folders; a symlinked
# ~/fun): git reports the real path, so a text match refused it. It is the same folder: it passes.
ln -s "$repo" "$tmp/repo-link"
hook "$direct/pre-push" "'$tmp/repo-link/.git/cmux-git-hooks/pre-push' || exit 1"
runs || fail "a pre-push that calls cmux-git-hooks/pre-push through a symlinked path was refused"

# Another clone's cmux-git-hooks is not this clone's gate.
mkdir -p "$tmp/other/.git/cmux-git-hooks"
hook "$tmp/other/.git/cmux-git-hooks/pre-push" "$gate_line"
hook "$direct/pre-push" "'$tmp/other/.git/cmux-git-hooks/pre-push' || exit 1"
runs && fail "a pre-push that calls another clone's cmux-git-hooks/pre-push passed"
hook "$direct/pre-push" "'$own/pre-push' || exit 1"

# A symlink to cmux-git-hooks is that folder.
ln -s "$own" "$tmp/own-link"
set_hooks "$tmp/own-link"
runs || fail "a symlink to cmux-git-hooks was refused"

# core.hooksPath is cmux-git-hooks itself (scripts/install-git-hooks.sh with no global hooks).
set_hooks "$own"
runs || fail "core.hooksPath = cmux-git-hooks was refused"

# A linked worktree shares the clone's cmux-git-hooks.
git -C "$repo" commit -q --allow-empty -m init
git -C "$repo" worktree add -q --detach "$tmp/linked"
(cd "$tmp/linked" && source "$fn" && gate_hook_runs) || fail "a linked worktree was refused"

# A cmux-git-hooks pre-push that is not cmux's gate.
hook "$own/pre-push" 'exit 0'
runs && fail "a cmux-git-hooks pre-push without prepush-gate passed"

# No core.hooksPath: git would run .git/hooks, not cmux-git-hooks.
hook "$own/pre-push" "$gate_line"
git -C "$repo" config --unset core.hooksPath
runs && fail "a clone with no core.hooksPath passed"

echo "push-from-host gate: ok"
