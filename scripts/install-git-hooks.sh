#!/usr/bin/env bash
# Point this clone's git at scripts/git-hooks/ for tracked, reviewed hooks.
# Installs tracked pre-commit checks and the post-merge merge-driver refresh
# without hiding custom hooks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$REPO_ROOT"

GIT_COMMON_DIR="$(git rev-parse --git-common-dir)"
if [[ "$GIT_COMMON_DIR" != /* ]]; then
    GIT_COMMON_DIR="$REPO_ROOT/$GIT_COMMON_DIR"
fi
TRUSTED_HOOK_DIR="$GIT_COMMON_DIR/cmux-git-hooks"
mkdir -p "$TRUSTED_HOOK_DIR"

PYTHON3_BIN="$(command -v python3 || true)"
if [[ -z "$PYTHON3_BIN" || "$PYTHON3_BIN" != /* ]]; then
    echo "error: python3 must resolve to an absolute executable outside the checkout." >&2
    exit 1
fi
PYTHON3_BIN="$(/bin/realpath "$PYTHON3_BIN")"
case "$PYTHON3_BIN" in
    "$REPO_ROOT"|"$REPO_ROOT"/*)
        echo "error: python3 resolves inside the checkout; refusing to install an untrusted interpreter." >&2
        exit 1
        ;;
esac
install -m 0755 scripts/git-hooks/pre-commit "$TRUSTED_HOOK_DIR/pre-commit"
install -m 0755 scripts/git-hooks/post-merge "$TRUSTED_HOOK_DIR/post-merge"
install -m 0644 scripts/ci/validate_test_execution_registry.py "$TRUSTED_HOOK_DIR/validate_test_execution_registry.py"
install -m 0644 scripts/ci/test_execution_registry.py "$TRUSTED_HOOK_DIR/test_execution_registry.py"
install -m 0644 scripts/ci/workload_entrypoints.py "$TRUSTED_HOOK_DIR/workload_entrypoints.py"
install -m 0644 scripts/normalize-pbxproj.py "$TRUSTED_HOOK_DIR/normalize-pbxproj.py"
printf '%s\n' "$PYTHON3_BIN" > "$TRUSTED_HOOK_DIR/python3-path"
chmod 0644 "$TRUSTED_HOOK_DIR/python3-path"

# Hooks a contributor already has (a core.hooksPath set in any config scope, or
# executable hooks such as Git LFS's in .git/hooks) are left in place with a
# warning, not an error: setup.sh runs this last under `set -e`, and an existing
# hook setup is not a setup failure.
# shellcheck disable=SC2016 # printed literally, for the contributor's hook to expand
printf -v TRUSTED_PRE_COMMIT '%q "$@" || exit $?' "$TRUSTED_HOOK_DIR/pre-commit"
printf -v TRUSTED_POST_MERGE '%q "$@" || exit $?' "$TRUSTED_HOOK_DIR/post-merge"
printf -v TRUSTED_HOOKS_CONFIG 'git config core.hooksPath %q' "$TRUSTED_HOOK_DIR"
warn_manual_wiring() {
    local hooks_dir="$1"
    {
        echo "To run cmux's tracked pre-commit checks (pbxproj normalization, test"
        echo "registration) alongside your hooks, add this line to $hooks_dir/pre-commit"
        echo "(create it with a #!/bin/sh line and chmod +x if it does not exist):"
        echo ""
        echo "    $TRUSTED_PRE_COMMIT"
        echo ""
        echo "To keep the trusted merge-driver copies current after pulling main, add"
        echo "this line to $hooks_dir/post-merge as well:"
        echo ""
        echo "    $TRUSTED_POST_MERGE"
        echo ""
        echo "Or use only the trusted clone-local hooks in this clone (your existing"
        echo "hooks then stop running here): $TRUSTED_HOOKS_CONFIG"
    } >&2
}

CURRENT_HOOKS="$(git config --get core.hooksPath || true)"
if [[ -n "$CURRENT_HOOKS" && "$CURRENT_HOOKS" != scripts/git-hooks && "$CURRENT_HOOKS" != "$TRUSTED_HOOK_DIR" ]]; then
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
        git config core.hooksPath "$TRUSTED_HOOK_DIR"
        echo "==> Trusted Git hooks installed (core.hooksPath = $TRUSTED_HOOK_DIR)."
    fi
fi

# Merge drivers named by .gitattributes have to be defined per clone; git will
# not run a driver it cannot resolve, it just falls back to the default one.
# Install reviewed copies outside the checked-out tree. A merge can run after
# checking out a fork branch, so resolving a driver or helper from that branch
# would execute untrusted code with the contributor's credentials.
MERGE_DRIVER_DIR="$GIT_COMMON_DIR/cmux-merge-drivers"
mkdir -p "$MERGE_DRIVER_DIR/ci"
install -m 0755 scripts/merge-xcstrings.py "$MERGE_DRIVER_DIR/merge-xcstrings.py"
install -m 0755 scripts/merge-pbxproj.py "$MERGE_DRIVER_DIR/merge-pbxproj.py"
install -m 0644 scripts/ci/merge_main_resolver.py "$MERGE_DRIVER_DIR/ci/merge_main_resolver.py"
install -m 0755 scripts/normalize-pbxproj.py "$MERGE_DRIVER_DIR/normalize-pbxproj.py"
printf -v XCSTRINGS_DRIVER '%q -I %q %%O %%A %%B %%P %%L' \
    "$PYTHON3_BIN" "$MERGE_DRIVER_DIR/merge-xcstrings.py"
printf -v PBXPROJ_DRIVER '%q -I %q %%O %%A %%B %%P' \
    "$PYTHON3_BIN" "$MERGE_DRIVER_DIR/merge-pbxproj.py"
git config merge.xcstrings-v2.name "Xcode string catalog (trusted key-wise three-way merge)"
git config merge.xcstrings-v2.driver "$XCSTRINGS_DRIVER"
# Neutralize the checkout-relative command installed by older setup versions.
# A fork controls .gitattributes and could otherwise reactivate that legacy
# driver name even though current main uses xcstrings-v2.
git config merge.xcstrings.name "Xcode string catalog (trusted compatibility driver)"
git config merge.xcstrings.driver "$XCSTRINGS_DRIVER"
echo "==> .xcstrings merge driver installed (merge.xcstrings-v2.driver)."
git config merge.pbxproj-v1.name "Xcode project file (trusted union of added entries)"
git config merge.pbxproj-v1.driver "$PBXPROJ_DRIVER"
git config merge.pbxproj.name "Xcode project file (trusted compatibility driver)"
git config merge.pbxproj.driver "$PBXPROJ_DRIVER"
echo "==> project.pbxproj merge driver installed (merge.pbxproj-v1.driver)."
