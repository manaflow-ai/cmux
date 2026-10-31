#!/usr/bin/env bash
# Point this clone's git at scripts/git-hooks/ for tracked, reviewed hooks.
# Installs tracked pre-commit checks and the post-merge merge-driver refresh
# without hiding custom hooks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

ORIGINAL_ARGS=("$@")
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
# One install at a time per clone. post-merge runs this in every worktree that pulls a hook change, and every
# worktree shares this hook folder and .git/config: two at once collide on `git config` (its lock file), and
# two cleanups would remove one tree together. The installer runs as the child of a python3 that holds an
# exclusive flock on install.lock until the child exits. Only that parent has the lock file open (Python opens
# it close-on-exec), so no process this install starts can keep the lock: a shell fd would be inherited by
# every child, and a daemon a git command detaches (`git fsmonitor--daemon` with core.fsmonitor=true) would
# hold it after the install exits, so every later install would wait forever. A waiting install names the
# holder's pid. The marker variable says this shell is that child; it is removed at once so no child of this
# install inherits it.
INSTALL_LOCK="$TRUSTED_HOOK_DIR/install.lock"
if [[ "${CMUX_HOOKS_INSTALL_LOCK_HELD:-}" != "$INSTALL_LOCK" ]]; then
    # The Python programs here are -c arguments, never here-documents: bash 5.1+ writes a short here-document
    # into a pipe before the command runs, and on a Mac short of pipe memory (git_batch.py) that write blocks
    # for good; for `read` the shell is its own reader, so the install hangs (seen with bash 5.3). Keep them
    # free of single quotes.
    LOCK_HOLDER='
import fcntl
import os
import signal
import subprocess
import sys

lock_path, command = sys.argv[1], sys.argv[2:]
lock = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)  # not inheritable (PEP 446)
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    # The holder is whoever has the file open now (a push refresh writes no pid), never the pid text a
    # finished install left in it: on 2026-10-28 that named pid 85305, gone for hours, while a stuck refresh held it.
    found = []
    if os.path.isdir("/proc/self/fd"):  # Linux: no lsof on CI runners
        real = os.path.realpath(lock_path)
        for entry in os.listdir("/proc"):
            if entry.isdigit():
                try:
                    fds = os.listdir(f"/proc/{entry}/fd")
                except OSError:
                    continue
                for fd in fds:
                    try:
                        if os.readlink(f"/proc/{entry}/fd/{fd}") == real:
                            found.append(entry)
                            break
                    except OSError:
                        pass
    else:
        try:
            found = subprocess.run(["lsof", "-t", "--", lock_path], capture_output=True, text=True,
                                   stdin=subprocess.DEVNULL, timeout=10,
                                   env={**os.environ, "PATH": "/usr/sbin:/usr/bin:/bin"}).stdout.split()
        except (OSError, subprocess.SubprocessError):
            found = []
    pids = [p for p in found if p != str(os.getpid())]
    holder = ", ".join(pids) or "unknown"
    try:
        wait = float(os.environ.get("CMUX_HOOKS_INSTALL_LOCK_WAIT_SECONDS") or 300)
    except ValueError:
        wait = 300.0
    print(f"install-git-hooks: another process holds {lock_path} (pid {holder}); waiting for it to finish (up to {wait:g}s).",
          file=sys.stderr, flush=True)

    def gave_up(number, frame):
        raise TimeoutError

    signal.signal(signal.SIGALRM, gave_up)
    signal.setitimer(signal.ITIMER_REAL, wait)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
    except TimeoutError:
        details = []
        for pid in pids:
            line = subprocess.run(["ps", "-o", "pid=,etime=,command=", "-p", pid], capture_output=True, text=True,
                                  stdin=subprocess.DEVNULL).stdout.strip()
            details.append(line[:200] or pid)
        print(f"install-git-hooks: gave up after {wait:g}s: pid {holder} still holds {lock_path}; the hooks were "
              "not installed. The holder: " + ("; ".join(details) or "unknown") + ". Stop it if it is stuck "
              "(a push refresh stuck before 9af05f03147 is), then run this again.", file=sys.stderr, flush=True)
        sys.exit(1)
    signal.setitimer(signal.ITIMER_REAL, 0)
os.ftruncate(lock, 0)
os.pwrite(lock, f"{os.getpid()}\n".encode(), 0)
# The lock must outlive the child: Ctrl-C reaches the child through the process group of the terminal, and a
# SIGTERM or SIGHUP sent to this holder goes on to the child (one that comes before the child exists is sent
# once it does). The handlers are caught dispositions, which exec resets: the child keeps the defaults.
children, pending = [], []


def forward(number, frame):
    if children:
        children[0].send_signal(number)
    else:
        pending.append(number)


signal.signal(signal.SIGINT, lambda number, frame: None)
signal.signal(signal.SIGTERM, forward)
signal.signal(signal.SIGHUP, forward)
child = subprocess.Popen(command, env={**os.environ, "CMUX_HOOKS_INSTALL_LOCK_HELD": lock_path})
children.append(child)
for number in pending:
    child.send_signal(number)
code = child.wait()
sys.exit(128 - code if code < 0 else code)
'
    exec "$PYTHON3_BIN" -I -c "$LOCK_HOLDER" "$INSTALL_LOCK" "$BASH" "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" \
        ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}
fi
unset CMUX_HOOKS_INSTALL_LOCK_HELD
install -m 0755 scripts/git-hooks/pre-commit "$TRUSTED_HOOK_DIR/pre-commit"
install -m 0755 scripts/git-hooks/post-merge "$TRUSTED_HOOK_DIR/post-merge"
# pre-push always runs the web lint and the cmux-next checks gate; its namespace autofix part runs only when
# the --namespace-fix helpers below are installed.
install -m 0755 scripts/git-hooks/pre-push "$TRUSTED_HOOK_DIR/pre-push"
install -m 0644 scripts/web_lint_prepush.py "$TRUSTED_HOOK_DIR/web_lint_prepush.py"
install -m 0644 scripts/cmux-next/prepush-gate.py "$TRUSTED_HOOK_DIR/cmux_next_prepush_gate.py"
# pre-push refreshes the checks copy below from the fetched feat-cmux-next (agents rebase, so post-merge never runs).
install -m 0644 scripts/git-hooks/refresh_checks.py "$TRUSTED_HOOK_DIR/refresh_checks.py"
# The gate loads its git helper from its own folder (guardrails.py loads the snapshot's copy below).
install -m 0644 scripts/cmux-next/git_batch.py "$TRUSTED_HOOK_DIR/git_batch.py"
install -m 0644 scripts/ci/base_merge_warning.py "$TRUSTED_HOOK_DIR/base_merge_warning.py"
# The hooks are per clone: every worktree of it (main-based ones too) runs these copies. A push in another
# worktree can run while this installs, so each install writes a new versioned copy and points the
# cmux-next-checks symlink at it with one rename: the checks are never missing (a missing guardrails.py
# would let a push through unchecked). The gate resolves the link once when it starts and holds the copy it
# resolved in use until it exits: a shared flock on the copy's .in-use file (prepush-gate.py,
# claim_trusted_scripts). No other install's cleanup runs while this one stages and links its copy (the
# install lock above).
TRUSTED_CHECKS_DIR="$TRUSTED_HOOK_DIR/cmux-next-checks"
CHECKS_VERSION="cmux-next-checks.v$(date +%s).$$"
TRUSTED_CHECKS_STAGE="$TRUSTED_HOOK_DIR/$CHECKS_VERSION.partial"
rm -rf "$TRUSTED_CHECKS_STAGE"
mkdir -p "$TRUSTED_CHECKS_STAGE"
: > "$TRUSTED_CHECKS_STAGE/.in-use"
while IFS= read -r -d '' checker; do
    relative="${checker#scripts/cmux-next/}"
    # lint/ holds the linters' configs; arch_rules/ holds the rule modules arch-ratchet.py loads from its
    # own directory (without it the installed ratchet runs no layer gate).
    case "$relative" in
        */*) [[ "$relative" == lint/* || "$relative" == arch_rules/* ]] || continue ;;
    esac
    # Folders only below the stage: a stage that is gone fails this install (cp, the mv below) instead of coming
    # back without its .in-use.
    folder="$(dirname "$relative")"
    [[ "$folder" == . ]] || (cd "$TRUSTED_CHECKS_STAGE" && mkdir -p "$folder")
    cp -p "$checker" "$TRUSTED_CHECKS_STAGE/$relative"
done < <(git ls-files -z scripts/cmux-next)
# check-package-dependency-lists.py imports the Swift source masker from scripts/; the installed copy reads it here.
if [[ -f scripts/swift_source_mask.py ]]; then
    cp -p scripts/swift_source_mask.py "$TRUSTED_CHECKS_STAGE/swift_source_mask.py"
fi
# The commit and tree the copy is made from, for refresh_checks.py; "worktree" when scripts/cmux-next differs from HEAD.
if git diff --quiet HEAD -- scripts/cmux-next && git rev-parse -q --verify HEAD >/dev/null; then
    printf '%s %s\n' "$(git rev-parse HEAD)" "$(git rev-parse HEAD:scripts/cmux-next)" > "$TRUSTED_CHECKS_STAGE/.source"
else
    echo worktree > "$TRUSTED_CHECKS_STAGE/.source"
fi
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

# Last, so a failure here never leaves the hooks half installed: remove every checks copy nobody holds. Only an
# install removes copies, and installs run one at a time (the install lock), so each tree has one remover: not
# the copy the link points at, and not one whose .in-use a push holds (an exclusive flock that fails). A removed
# copy is first renamed to `.deleting.` (while its lock is held), so a gate that resolved it before sees it gone
# and resolves the link again, and a killed install leaves only `.deleting.` trees, which the next one removes. Copies without .in-use come from installs before the
# lock (or a stage before its lock, seconds old): those keep the old rule (not the copy just replaced, nor any
# younger than 10 minutes). `.link.` temporaries older than 10 minutes were left by a killed install (an install
# takes seconds).
# A -c argument, not a here-document (the install lock above says why); keep it free of single quotes.
CLEANUP='
import fcntl
import os
import shutil
import sys
import time

hook_dir, previous = sys.argv[1], sys.argv[2]
link = os.path.join(hook_dir, "cmux-next-checks")
STALE_SECONDS = 600


def current():
    try:
        return os.readlink(link)
    except OSError:
        return None


def gone(error):
    # An install from before the install lock (the copy of this script in an older checkout) removes old copies without
    # it; what it removed first is gone either way. Anything else is raised.
    if not isinstance(error, FileNotFoundError):
        raise error


def remove(path):
    """Remove the tree PATH, which this cleanup claimed (renamed to its `.deleting.` name or found there)."""
    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=lambda function, name, error: gone(error))
    else:
        shutil.rmtree(path, onerror=lambda function, name, info: gone(info[1]))


def claim(path, name):
    """Rename PATH out of the way for removal; None when it is already gone."""
    target = os.path.join(hook_dir, f"cmux-next-checks.deleting.{os.getpid()}.{name}")
    try:
        os.rename(path, target)
    except FileNotFoundError:
        return None
    return target


for name in sorted(os.listdir(hook_dir)):
    path = os.path.join(hook_dir, name)
    if not name.startswith("cmux-next-checks.") or name == current():
        continue
    if os.path.islink(path):
        if ".link." in name and time.time() - os.lstat(path).st_mtime > STALE_SECONDS:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass  # removed by an install from before the install lock
    elif not os.path.isdir(path):
        continue
    elif ".deleting." in name:  # installs run one at a time, so its remover was killed
        remove(path)
    elif not os.path.exists(os.path.join(path, ".in-use")):
        if name != previous and time.time() - os.stat(path).st_mtime > STALE_SECONDS:
            claimed = claim(path, name)
            if claimed is not None:
                remove(claimed)
    else:
        try:
            lock = os.open(os.path.join(path, ".in-use"), os.O_RDONLY)
        except FileNotFoundError:
            continue  # removed by an install from before the install lock
        try:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue  # a push holds it
            if name == current():
                continue
            claimed = claim(path, name)
            if claimed is not None:
                remove(claimed)
        finally:
            os.close(lock)
'
"$PYTHON3_BIN" -I -c "$CLEANUP" "$TRUSTED_HOOK_DIR" "$PREVIOUS_CHECKS"
