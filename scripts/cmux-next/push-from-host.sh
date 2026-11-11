#!/bin/bash
# Push a commit to manaflow-ai/cmux from another Mac, with that Mac's pre-push hook as the gate.
#
#   scripts/cmux-next/push-from-host.sh [--host HOST] [--sha REV] BRANCH
#   scripts/cmux-next/push-from-host.sh feat-cmux-next            # HEAD -> origin/feat-cmux-next
#
# For a Mac too loaded to finish its own gate. On 2026-11-10 this Mac's load average was 300-770 with about
# nine pushes in the hook at once: `git worktree add` of the lint tree alone took 2-6 minutes, the gate ran
# past its limit, and a Swift-only push that takes 21 s on an idle Mac did not finish in 10 minutes. This
# script is not a bypass: the same reviewed hook (scripts/git-hooks/pre-push, installed by
# scripts/install-git-hooks.sh) runs on HOST and refuses there exactly as it would here.
#
# What it does:
# 1. Reads this clone's GitHub token from `gh auth token` (HOST's own keychain is locked over SSH).
# 2. Sends the commits HOST lacks as a git bundle over SSH. Not `git push HOST`: that would run this Mac's
#    pre-push hook, which is the step that cannot finish here.
# 3. On HOST: fetches BRANCH's remote head, installs the hooks from the fetched feat-cmux-next when the clone
#    has none, and runs a plain `git push -q origin SHA:refs/heads/BRANCH` from a detached worktree at SHA.
#    The token goes over SSH stdin into the environment of that one git process: never an argument, a file,
#    a git config value or a log line.
# 4. Checks that the remote branch now is SHA.
#
# Exit: 0 pushed (or already there), 1 refused by the hook or by GitHub (output above), 2 usage or setup.
# A non-fast-forward is refused by GitHub as always: fetch, rebase and run this again. It never forces.
#
# Environment: CMUX_PUSH_HOST [cmux-lawrence-2], CMUX_PUSH_HOST_REPO [fun/cmux, relative to HOST's home],
# and the hook's own CMUX_WEB_LINT_SKIP_REASON / CMUX_NEXT_CHECKS_SKIP_REASON, passed through.
set -euo pipefail

HOST="${CMUX_PUSH_HOST:-cmux-lawrence-2}"
HOST_REPO="${CMUX_PUSH_HOST_REPO:-fun/cmux}"
REV="HEAD"
BRANCH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="${2:?--host needs a value}"; shift ;;
        --sha) REV="${2:?--sha needs a value}"; shift ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "push-from-host: unknown option $1" >&2; exit 2 ;;
        *) [[ -z "$BRANCH" ]] || { echo "push-from-host: one BRANCH only" >&2; exit 2; }; BRANCH="$1" ;;
    esac
    shift
done
BRANCH="${BRANCH#refs/heads/}"
if [[ -z "$BRANCH" ]] || ! git check-ref-format "refs/heads/$BRANCH" || [[ ! "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "push-from-host: give the branch to push to, for example: $0 feat-cmux-next" >&2
    exit 2
fi
if [[ ! "$HOST" =~ ^[A-Za-z0-9._@-]+$ || ! "$HOST_REPO" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "push-from-host: host or repo path has characters this script does not pass to a shell" >&2
    exit 2
fi
SHA="$(git rev-parse --verify --quiet "$REV^{commit}")" || { echo "push-from-host: $REV is not a commit" >&2; exit 2; }
# No `git status` here: on the loaded Mac this script is for, it alone took minutes. Only commits are pushed.

TOKEN="$(gh auth token 2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
    echo "push-from-host: \`gh auth token\` gave nothing; sign in with \`gh auth login\` on this Mac." >&2
    exit 2
fi

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 "$HOST")
NAME="push-from-host-${SHA:0:12}-$$"

# What HOST already has: its remote-tracking feat-cmux-next and BRANCH after a fetch. The bundle leaves those out.
echo "push-from-host: $SHA -> $BRANCH through $HOST" >&2
HAVE="$("${SSH[@]}" bash -s -- "$HOST_REPO" "$BRANCH" <<'REMOTE'
set -euo pipefail
cd "$HOME/$1"
git fetch -q --no-tags origin "+refs/heads/feat-cmux-next:refs/remotes/origin/feat-cmux-next" >&2
git fetch -q --no-tags origin "+refs/heads/$2:refs/remotes/origin/$2" >&2 2>/dev/null || true
for ref in refs/remotes/origin/feat-cmux-next "refs/remotes/origin/$2"; do
    git rev-parse --verify --quiet "$ref^{commit}" || true
done
REMOTE
)"
EXCLUDE=()
for have in $HAVE; do
    # Only commits this clone has too can bound the bundle; HOST's newer tip is usually not here yet.
    if git cat-file -e "$have^{commit}" 2>/dev/null; then
        EXCLUDE+=("^$have")
    fi
done
if (( ${#EXCLUDE[@]} == 0 )); then
    for ref in refs/remotes/origin/feat-cmux-next "refs/remotes/origin/$BRANCH"; do
        if base="$(git merge-base "$SHA" "$ref" 2>/dev/null)"; then
            EXCLUDE+=("^$base")
        fi
    done
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/push-from-host.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
git update-ref "refs/push-from-host/$NAME" "$SHA"
BUNDLED=0
# An empty bundle is refused by git: then HOST already has every commit of SHA.
git bundle create -q "$WORK/bundle" "refs/push-from-host/$NAME" ${EXCLUDE[@]+"${EXCLUDE[@]}"} 2>/dev/null && BUNDLED=1
git update-ref -d "refs/push-from-host/$NAME"
if (( BUNDLED )); then
    "${SSH[@]}" "cat > /tmp/$NAME.bundle" < "$WORK/bundle"
fi

# The step that runs on HOST. Sent as a file, so SSH stdin is free to carry the token (its only line).
cat > "$WORK/remote.sh" <<'REMOTE'
set -euo pipefail
REPO="$HOME/$1" BRANCH="$2" SHA="$3" NAME="$4"
[[ -z "$5" ]] || export CMUX_WEB_LINT_SKIP_REASON="$5"
[[ -z "$6" ]] || export CMUX_NEXT_CHECKS_SKIP_REASON="$6"
IFS= read -r CMUX_PUSH_TOKEN
TREE="/tmp/$NAME.tree"
cd "$REPO"
cleanup() {
    cd "$REPO"
    git worktree remove --force "$TREE" >/dev/null 2>&1 || true
    git worktree remove --force "$TREE.hooks" >/dev/null 2>&1 || true
    rm -f "/tmp/$NAME.bundle" "/tmp/$NAME.sh"
}
trap cleanup EXIT
if [[ -f "/tmp/$NAME.bundle" ]]; then
    git fetch -q --no-tags "/tmp/$NAME.bundle" "refs/push-from-host/$NAME"
fi
if ! git cat-file -e "$SHA^{commit}" 2>/dev/null; then
    echo "push-from-host: $HOSTNAME does not have $SHA after the bundle; nothing was pushed." >&2
    exit 2
fi
# The gate is this clone's installed hook. A clone with none gets the reviewed one, from the fetched
# feat-cmux-next, never from the commit being pushed.
HOOKS="$(git config --get core.hooksPath || true)"
if [[ -z "$HOOKS" || ! -x "$HOOKS/pre-push" ]]; then
    echo "push-from-host: $HOSTNAME has no cmux hooks; installing them from origin/feat-cmux-next." >&2
    git -c core.hooksPath=/dev/null worktree add --quiet --detach "$TREE.hooks" refs/remotes/origin/feat-cmux-next
    "$TREE.hooks/scripts/install-git-hooks.sh" >&2
    git worktree remove --force "$TREE.hooks"
    HOOKS="$(git config --get core.hooksPath || true)"
    if [[ -z "$HOOKS" || ! -x "$HOOKS/pre-push" ]]; then
        echo "push-from-host: the hooks did not install on $HOSTNAME; nothing was pushed." >&2
        exit 2
    fi
fi
# A tree that is exactly SHA: the web lint then runs in it and writes no second tree.
git -c core.hooksPath=/dev/null worktree add --quiet --detach "$TREE" "$SHA"
cd "$TREE"
# The token lives in this git process's environment only. The helper line holds the variable's name, not its value.
STATUS=0
CMUX_PUSH_TOKEN="$CMUX_PUSH_TOKEN" GIT_TERMINAL_PROMPT=0 \
    GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
    GIT_CONFIG_KEY_1=credential.helper \
    GIT_CONFIG_VALUE_1='!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$CMUX_PUSH_TOKEN"; }; f' \
    git push -q origin "$SHA:refs/heads/$BRANCH" || STATUS=$?
unset CMUX_PUSH_TOKEN
NOW="$(git ls-remote origin "refs/heads/$BRANCH" | cut -f1)"
if [[ "$NOW" == "$SHA" ]]; then
    echo "push-from-host: pushed: $BRANCH is $SHA (gate ran on $HOSTNAME)." >&2
    exit 0
fi
echo "push-from-host: not pushed (git push exit $STATUS): $BRANCH is ${NOW:-absent} on the remote." >&2
exit 1
REMOTE
"${SSH[@]}" "cat > /tmp/$NAME.sh" < "$WORK/remote.sh"

STATUS=0
printf '%s\n' "$TOKEN" | "${SSH[@]}" bash "/tmp/$NAME.sh" "'$HOST_REPO'" "'$BRANCH'" "$SHA" "$NAME" \
    "$(printf '%q' "${CMUX_WEB_LINT_SKIP_REASON:-}")" "$(printf '%q' "${CMUX_NEXT_CHECKS_SKIP_REASON:-}")" || STATUS=$?
unset TOKEN
if (( STATUS == 0 )); then
    # This clone's view of the branch, so `git status` and the next rebase see the push.
    git update-ref "refs/remotes/origin/$BRANCH" "$SHA" 2>/dev/null || true
fi
exit "$STATUS"
