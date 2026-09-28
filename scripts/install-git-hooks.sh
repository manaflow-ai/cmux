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
# Install reviewed copies outside the checked-out tree. A merge can run after
# checking out a fork branch, so resolving a driver or helper from that branch
# would execute untrusted code with the contributor's credentials.
GIT_COMMON_DIR="$(git rev-parse --git-common-dir)"
if [[ "$GIT_COMMON_DIR" != /* ]]; then
    GIT_COMMON_DIR="$REPO_ROOT/$GIT_COMMON_DIR"
fi
MERGE_DRIVER_DIR="$GIT_COMMON_DIR/cmux-merge-drivers"
mkdir -p "$MERGE_DRIVER_DIR/ci"
install -m 0755 scripts/merge-xcstrings.py "$MERGE_DRIVER_DIR/merge-xcstrings.py"
install -m 0755 scripts/merge-pbxproj.py "$MERGE_DRIVER_DIR/merge-pbxproj.py"
install -m 0644 scripts/ci/catch_up_pr.py "$MERGE_DRIVER_DIR/ci/catch_up_pr.py"
install -m 0755 scripts/normalize-pbxproj.py "$MERGE_DRIVER_DIR/normalize-pbxproj.py"
PYTHON3_BIN="$(command -v python3)"
printf -v XCSTRINGS_DRIVER '%q %q %%O %%A %%B %%P' \
    "$PYTHON3_BIN" "$MERGE_DRIVER_DIR/merge-xcstrings.py"
printf -v PBXPROJ_DRIVER '%q %q %%O %%A %%B %%P' \
    "$PYTHON3_BIN" "$MERGE_DRIVER_DIR/merge-pbxproj.py"
git config merge.xcstrings.name "Xcode string catalog (key-wise three-way merge)"
git config merge.xcstrings.driver "$XCSTRINGS_DRIVER"
echo "==> .xcstrings merge driver installed (merge.xcstrings.driver)."
git config merge.pbxproj.name "Xcode project file (three-way union of added entries)"
git config merge.pbxproj.driver "$PBXPROJ_DRIVER"
echo "==> project.pbxproj merge driver installed (merge.pbxproj.driver)."
