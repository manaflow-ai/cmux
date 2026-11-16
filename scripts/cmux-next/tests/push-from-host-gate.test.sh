#!/usr/bin/env bash
# push-from-host.sh pushes only from a clone whose pre-push runs cmux's own gate (prepush-gate). Before this check it
# accepted any executable pre-push in core.hooksPath: on 2026-11-16 cmux16's clones had a shared hooks folder whose
# pre-push ran no prepush-gate (no cmux pre-push in cmux-git-hooks), and a merge that dropped settings exports' keys
# was pushed from there unchecked (cmux#43562 885211f5).
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../push-from-host.sh"
tmp="$(mktemp -d)"
git_fixture_trap_exit 'rm -rf "$tmp"'
fail() { echo "FAIL: $*" >&2; exit 1; }

# The function under test, exactly as the host runs it.
fn="$tmp/gate_hook_runs.sh"
sed -n '/^# BEGIN gate_hook_runs$/,/^# END gate_hook_runs$/p' "$script" >"$fn"
grep -q '^gate_hook_runs()' "$fn" || fail "gate_hook_runs not found in push-from-host.sh"

repo="$tmp/repo"
git init -q "$repo"
own="$repo/.git/cmux-git-hooks"
shared="$tmp/shared-hooks"
mkdir -p "$own" "$shared"
hook() { printf '#!/bin/sh\n%s\n' "$2" >"$1"; chmod +x "$1"; }
runs() { (cd "$repo" && source "$fn" && gate_hook_runs); }

# cmux16 on 2026-11-16: a shared hooks folder, no cmux pre-push in cmux-git-hooks.
hook "$shared/pre-push" 'run_repo_hooks pre-push "$@"'
git -C "$repo" config core.hooksPath "$shared"
runs && fail "a clone with no cmux pre-push passed"

# A shared hooks folder whose pre-push does not run the repo's hooks: cmux's gate never runs.
hook "$own/pre-push" 'python3 scripts/cmux-next/prepush-gate.py --pre-push "$@"'
hook "$shared/pre-push" 'exit 0'
runs && fail "a shared pre-push that skips the repo's hooks passed"

# The shared folder runs each repo's own hooks: the gate runs.
hook "$shared/pre-push" 'run_repo_hooks pre-push "$@"'
runs || fail "a shared pre-push that runs the repo's hooks was refused"

# core.hooksPath is cmux-git-hooks itself (scripts/install-git-hooks.sh with no global hooks).
git -C "$repo" config core.hooksPath "$own"
runs || fail "core.hooksPath = cmux-git-hooks was refused"

# A cmux-git-hooks pre-push that is not cmux's gate.
hook "$own/pre-push" 'exit 0'
runs && fail "a cmux-git-hooks pre-push without prepush-gate passed"

# No core.hooksPath: git would run .git/hooks, not cmux-git-hooks.
hook "$own/pre-push" 'python3 scripts/cmux-next/prepush-gate.py --pre-push "$@"'
git -C "$repo" config --unset core.hooksPath
runs && fail "a clone with no core.hooksPath passed"

echo "push-from-host gate: ok"
