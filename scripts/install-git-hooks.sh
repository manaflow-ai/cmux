#!/usr/bin/env bash
# Point this clone's git at scripts/git-hooks/ for tracked, reviewed hooks.
# Installs the tracked pre-commit hook (pbxproj normalization and test
# registration) without hiding custom hooks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$REPO_ROOT"

# Hooks a contributor already has (a core.hooksPath set in any config scope, or
# executable hooks such as Git LFS's in .git/hooks) are left in place with a
# warning, not an error: setup.sh runs this last under `set -e`, and an existing
# hook setup is not a setup failure.
# shellcheck disable=SC2016 # printed literally, for the contributor's hook to expand
TRACKED_HOOK='"$(git rev-parse --show-toplevel)/scripts/git-hooks/pre-commit" "$@" || exit $?'
warn_manual_wiring() {
    local hooks_dir="$1"
    {
        echo "To run cmux's tracked pre-commit checks (pbxproj normalization, test"
        echo "registration) alongside your hooks, add this line to $hooks_dir/pre-commit"
        echo "(create it with a #!/bin/sh line and chmod +x if it does not exist):"
        echo ""
        echo "    $TRACKED_HOOK"
        echo ""
        echo "Or use only the tracked hooks in this clone (your existing hooks then stop"
        echo "running here): git config core.hooksPath scripts/git-hooks"
    } >&2
}

CURRENT_HOOKS="$(git config --get core.hooksPath || true)"
if [[ -n "$CURRENT_HOOKS" && "$CURRENT_HOOKS" != scripts/git-hooks ]]; then
    HOOKS_ORIGIN="$(git config --show-origin --get core.hooksPath | cut -f1 || true)"
    echo "warning: core.hooksPath is already $CURRENT_HOOKS${HOOKS_ORIGIN:+ (set in $HOOKS_ORIGIN)}; left unchanged." >&2
    warn_manual_wiring "$CURRENT_HOOKS"
else
    EXISTING_HOOKS=()
    if [[ -z "$CURRENT_HOOKS" ]]; then
        DEFAULT_HOOKS="$(git rev-parse --git-path hooks)"
        # Only names Git runs (githooks(5)); a pre-commit.bak is not a hook.
        for name in applypatch-msg pre-applypatch post-applypatch pre-commit \
            pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase \
            post-checkout post-merge pre-push pre-receive update proc-receive \
            post-receive post-update reference-transaction push-to-checkout \
            pre-auto-gc post-rewrite sendemail-validate fsmonitor-watchman \
            p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit \
            post-index-change; do
            hook="$DEFAULT_HOOKS/$name"
            [[ -f "$hook" && -x "$hook" ]] || continue
            EXISTING_HOOKS+=("$name")
        done
    fi
    if (( ${#EXISTING_HOOKS[@]} > 0 )); then
        echo "warning: $DEFAULT_HOOKS already has executable hooks (${EXISTING_HOOKS[*]}), which core.hooksPath would hide; left unchanged." >&2
        warn_manual_wiring "$DEFAULT_HOOKS"
    else
        git config core.hooksPath scripts/git-hooks
        chmod +x scripts/git-hooks/*
        echo "==> Git hooks installed (core.hooksPath = scripts/git-hooks)."
    fi
fi

# Merge drivers named by .gitattributes have to be defined per clone; git will
# not run a driver it cannot resolve, it just falls back to the default one.
git config merge.xcstrings.name "Xcode string catalog (key-wise three-way merge)"
git config merge.xcstrings.driver "python3 scripts/merge-xcstrings.py %O %A %B %P"
echo "==> .xcstrings merge driver installed (merge.xcstrings.driver)."
