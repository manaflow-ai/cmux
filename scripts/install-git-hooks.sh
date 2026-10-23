#!/usr/bin/env bash
# Point this clone's git at scripts/git-hooks/ for tracked, reviewed hooks.
# Installs tracked pre-commit checks and the post-merge merge-driver refresh
# without hiding custom hooks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

NAMESPACE_FIX=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace-fix) NAMESPACE_FIX=1 ;;
        -h|--help)
            echo "usage: $0 [--namespace-fix]"
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            exit 2
            ;;
    esac
    shift
done

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
# pre-push always runs the web lint and the cmux-next checks gate; its namespace autofix part runs only when
# the --namespace-fix helpers below are installed.
install -m 0755 scripts/git-hooks/pre-push "$TRUSTED_HOOK_DIR/pre-push"
install -m 0644 scripts/web_lint_prepush.py "$TRUSTED_HOOK_DIR/web_lint_prepush.py"
install -m 0644 scripts/cmux-next/prepush-gate.py "$TRUSTED_HOOK_DIR/cmux_next_prepush_gate.py"
# The gate loads its git helper from its own folder (guardrails.py loads the snapshot's copy below).
install -m 0644 scripts/cmux-next/git_batch.py "$TRUSTED_HOOK_DIR/git_batch.py"
install -m 0644 scripts/ci/base_merge_warning.py "$TRUSTED_HOOK_DIR/base_merge_warning.py"
# The hooks are per clone: every worktree of it (main-based ones too) runs these copies. A push in another
# worktree can run while this installs, so each install writes a new versioned copy and points the
# cmux-next-checks symlink at it with one rename: the checks are never missing (a missing guardrails.py
# would let a push through unchecked). The gate resolves the link once when it starts.
TRUSTED_CHECKS_DIR="$TRUSTED_HOOK_DIR/cmux-next-checks"
CHECKS_VERSION="cmux-next-checks.v$(date +%s).$$"
TRUSTED_CHECKS_STAGE="$TRUSTED_HOOK_DIR/$CHECKS_VERSION.partial"
rm -rf "$TRUSTED_CHECKS_STAGE"
mkdir -p "$TRUSTED_CHECKS_STAGE"
while IFS= read -r -d '' checker; do
    relative="${checker#scripts/cmux-next/}"
    # lint/ holds the linters' configs; arch_rules/ holds the rule modules arch-ratchet.py loads from its
    # own directory (without it the installed ratchet runs no layer gate).
    case "$relative" in
        */*) [[ "$relative" == lint/* || "$relative" == arch_rules/* ]] || continue ;;
    esac
    mkdir -p "$TRUSTED_CHECKS_STAGE/$(dirname "$relative")"
    cp -p "$checker" "$TRUSTED_CHECKS_STAGE/$relative"
done < <(git ls-files -z scripts/cmux-next)
mv "$TRUSTED_CHECKS_STAGE" "$TRUSTED_HOOK_DIR/$CHECKS_VERSION"
PREVIOUS_CHECKS=""
if [[ -L "$TRUSTED_CHECKS_DIR" ]]; then
    PREVIOUS_CHECKS="$(readlink "$TRUSTED_CHECKS_DIR")"
elif [[ -e "$TRUSTED_CHECKS_DIR" ]]; then
    # Once, from the plain directory older installs wrote: the only moment it is briefly absent.
    PREVIOUS_CHECKS="cmux-next-checks.plain.$$"
    mv "$TRUSTED_CHECKS_DIR" "$TRUSTED_HOOK_DIR/$PREVIOUS_CHECKS"
fi
rm -f "$TRUSTED_CHECKS_DIR.link.$$"
ln -s "$CHECKS_VERSION" "$TRUSTED_CHECKS_DIR.link.$$"
"$PYTHON3_BIN" -I -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' \
    "$TRUSTED_CHECKS_DIR.link.$$" "$TRUSTED_CHECKS_DIR"
# Keep the copy just replaced (a push that started before the swap may still read it) and any copy younger
# than 10 minutes (another install may be about to link it, or a push started on it); remove older ones. That
# includes `.partial` stages and `.link.` temporaries older than 10 minutes: an install takes seconds, so those
# were left by a killed install (about 570 files each) and would otherwise stay forever.
while IFS= read -r -d '' old; do
    name="$(basename "$old")"
    case "$name" in
        "$CHECKS_VERSION"|"$PREVIOUS_CHECKS") continue ;;
    esac
    rm -rf "$old"
done < <(find "$TRUSTED_HOOK_DIR" -mindepth 1 -maxdepth 1 -name 'cmux-next-checks.*' -mmin +10 -print0)
if (( NAMESPACE_FIX )); then
    install -m 0755 scripts/lint_swift_namespaces.py "$TRUSTED_HOOK_DIR/lint_swift_namespaces.py"
    install -m 0644 scripts/swift_source_mask.py "$TRUSTED_HOOK_DIR/swift_source_mask.py"
fi
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
printf -v TRUSTED_PRE_PUSH '%q "$@" || exit $?' "$TRUSTED_HOOK_DIR/pre-push"
printf -v TRUSTED_HOOKS_CONFIG 'git config core.hooksPath %q' "$TRUSTED_HOOK_DIR"
warn_manual_wiring() {
    local hooks_dir="$1"
    {
        echo "To run cmux's tracked pre-commit checks (formatting, pbxproj normalization,"
        echo "test registration) alongside your hooks, add this line to $hooks_dir/pre-commit"
        echo "(create it with a #!/bin/sh line and chmod +x if it does not exist):"
        echo ""
        echo "    $TRUSTED_PRE_COMMIT"
        echo ""
        echo "To keep the trusted merge-driver copies current after pulling main, add"
        echo "this line to $hooks_dir/post-merge as well:"
        echo ""
        echo "    $TRUSTED_POST_MERGE"
        echo ""
        echo "To run the web lint before each push (the checks CI runs on feat-cmux-next),"
        echo "add this line to $hooks_dir/pre-push:"
        echo ""
        echo "    $TRUSTED_PRE_PUSH"
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
install -m 0755 scripts/merge-baseline.py "$MERGE_DRIVER_DIR/merge-baseline.py"
install -m 0755 scripts/merge-daemon-capabilities.py "$MERGE_DRIVER_DIR/merge-daemon-capabilities.py"
install -m 0644 scripts/ci/merge_main_resolver.py "$MERGE_DRIVER_DIR/ci/merge_main_resolver.py"
install -m 0755 scripts/normalize-pbxproj.py "$MERGE_DRIVER_DIR/normalize-pbxproj.py"
printf -v XCSTRINGS_DRIVER '%q -I %q %%O %%A %%B %%P %%L' \
    "$PYTHON3_BIN" "$MERGE_DRIVER_DIR/merge-xcstrings.py"
printf -v PBXPROJ_DRIVER '%q -I %q %%O %%A %%B %%P' \
    "$PYTHON3_BIN" "$MERGE_DRIVER_DIR/merge-pbxproj.py"
printf -v BASELINE_DRIVER '%q -I %q %%O %%A %%B %%P' \
    "$PYTHON3_BIN" "$MERGE_DRIVER_DIR/merge-baseline.py"
printf -v CAPABILITIES_DRIVER '%q -I %q %%O %%A %%B %%P' \
    "$PYTHON3_BIN" "$MERGE_DRIVER_DIR/merge-daemon-capabilities.py"
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
git config merge.cmux-baseline-v1.name "Ratchet baseline (trusted entry-wise three-way merge)"
git config merge.cmux-baseline-v1.driver "$BASELINE_DRIVER"
echo "==> ratchet baseline merge driver installed (merge.cmux-baseline-v1.driver)."
git config merge.cmux-capabilities-v1.name "Daemon capability export (trusted per-list set merge)"
git config merge.cmux-capabilities-v1.driver "$CAPABILITIES_DRIVER"
echo "==> daemon capability merge driver installed (merge.cmux-capabilities-v1.driver)."
# Generated web bundles keep the current branch's copy and are rebuilt by
# scripts/cmux-next/regenerate-web-bundles.sh. `true` is a git no-op, not a
# checkout path, so this driver needs no trusted copy.
git config merge.cmux-generated-v1.name "Generated web bundle (keep ours, then regenerate)"
git config merge.cmux-generated-v1.driver true
echo "==> generated web bundle merge driver installed (merge.cmux-generated-v1.driver)."
