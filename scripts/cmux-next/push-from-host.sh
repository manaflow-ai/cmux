#!/bin/bash
# Push a commit to manaflow-ai/cmux from another Mac, with that Mac's pre-push hook as the gate.
#
#   scripts/cmux-next/push-from-host.sh [--host HOST]... [--sha REV] [--rebase] BRANCH
#   scripts/cmux-next/push-from-host.sh --rebase feat-cmux-next   # HEAD, rebased on the branch there, -> origin
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
# --rebase: HOST rebases the commits onto BRANCH's newest remote head before it pushes, and again (3 tries) when
# the branch moved in between. For a busy branch from a loaded Mac: the local steps here took 278 s on 2026-11-10
# and feat-cmux-next moved in that time, so a push without it was refused as a non-fast-forward. The pushed
# commits then have new ids (printed last): fetch and rebase this clone before more work. A conflict stops it;
# nothing is pushed.
# --host may be given more than once (or CMUX_PUSH_HOST may list several, space-separated): the first host that
# answers SSH is used.
#
# Exit: 0 pushed (or already there), 1 refused by the hook or by GitHub (output above), 2 usage or setup.
# Without --rebase a non-fast-forward is refused by GitHub as always. It never forces.
#
# Environment: CMUX_PUSH_HOST [cmux-lawrence-2], CMUX_PUSH_HOST_REPO [fun/cmux, relative to HOST's home],
# and the hook's own CMUX_WEB_LINT_SKIP_REASON / CMUX_NEXT_CHECKS_SKIP_REASON, passed through.
set -euo pipefail

HOSTS=()
REBASE=0
HOST_REPO="${CMUX_PUSH_HOST_REPO:-fun/cmux}"
REV="HEAD"
BRANCH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOSTS+=("${2:?--host needs a value}"); shift ;;
        --rebase) REBASE=1 ;;
        --sha) REV="${2:?--sha needs a value}"; shift ;;
        -h|--help) sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
if (( ${#HOSTS[@]} == 0 )); then
    read -r -a HOSTS <<< "${CMUX_PUSH_HOST:-cmux-lawrence-2}"
fi
if [[ ! "$HOST_REPO" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "push-from-host: the repo path has characters this script does not pass to a shell" >&2
    exit 2
fi
HOST=""
for candidate in "${HOSTS[@]}"; do
    if [[ ! "$candidate" =~ ^[A-Za-z0-9._@-]+$ ]]; then
        echo "push-from-host: host '$candidate' has characters this script does not pass to a shell" >&2
        exit 2
    fi
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "$candidate" true 2>/dev/null; then
        HOST="$candidate"
        break
    fi
    echo "push-from-host: $candidate does not answer SSH." >&2
done
if [[ -z "$HOST" ]]; then
    echo "push-from-host: no host answers SSH (${HOSTS[*]}); name another with --host." >&2
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
# HOST's files for this push (the bundle, the script it runs with the token on stdin, the checkout) sit in one folder
# mktemp makes there, never at a name another account on HOST could guess and plant first.
RDIR="$("${SSH[@]}" "mktemp -d /tmp/$NAME-XXXXXX")" || RDIR=""
if [[ ! "$RDIR" =~ ^/tmp/push-from-host-[0-9a-f]+-[0-9]+-[A-Za-z0-9]+$ ]]; then
    echo "push-from-host: could not make a private folder on $HOST; nothing was pushed." >&2
    exit 2
fi
if (( BUNDLED )); then
    "${SSH[@]}" "cat > '$RDIR/bundle'" < "$WORK/bundle"
fi

# The step that runs on HOST. Sent as a file, so SSH stdin is free to carry the token (its only line).
cat > "$WORK/remote.sh" <<'REMOTE'
set -euo pipefail
REPO="$HOME/$1" BRANCH="$2" SHA="$3" NAME="$4" REBASE="$7" WHO="$8" MAIL="$9" RDIR="${10}"
# A non-login SSH shell has the system PATH only; the web lint needs bun. Appended, so nothing here comes first.
export PATH="$PATH:/opt/homebrew/bin:$HOME/.bun/bin"
[[ -z "$5" ]] || export CMUX_WEB_LINT_SKIP_REASON="$5"
[[ -z "$6" ]] || export CMUX_NEXT_CHECKS_SKIP_REASON="$6"
IFS= read -r CMUX_PUSH_TOKEN
TREE="$RDIR/tree"
cd "$REPO"
# Set before any step that can exit (the disk check below did, and left this push's bundle and script in /tmp).
cleanup() {
    cd "$REPO"
    git worktree remove --force "$TREE" >/dev/null 2>&1 || true
    git worktree remove --force "$TREE.hooks" >/dev/null 2>&1 || true
    rm -rf "$RDIR"
}
trap cleanup EXIT
# Leftovers of runs that were killed, whose EXIT trap never ran: a tree is a full checkout (about 2 GB). Only this
# script's own names, and only those older than 2 hours, so a push that runs now keeps its files. On 2026-11-10
# this host went offline at 99% full.
STALE=0
while IFS= read -r old; do
    case "$old" in
        *.tree|*.tree.hooks) git worktree remove --force "$old" >/dev/null 2>&1 || rm -rf "$old" ;;
        *)
            if [[ -d "$old" && ! -L "$old" ]]; then
                git worktree remove --force "$old/tree" >/dev/null 2>&1 || true
                git worktree remove --force "$old/tree.hooks" >/dev/null 2>&1 || true
                rm -rf "$old"
            else
                rm -f "$old"
            fi
            ;;
    esac
    STALE=$((STALE + 1))
done < <(find /tmp/ -maxdepth 1 -name 'push-from-host-*' -user "$(id -u)" -mmin +120 2>/dev/null)
git worktree prune >/dev/null 2>&1 || true
(( STALE == 0 )) || echo "push-from-host: removed $STALE leftover file(s) of earlier pushes from /tmp on $HOSTNAME." >&2
# The checkout below needs about 2 GB. Under 3 GB free it would stop half-written: refuse first. Under 20 GB: say
# so on every push, while there is still room to act.
FREE_KB="$(df -Pk /tmp 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ "$FREE_KB" =~ ^[0-9]+$ ]]; then
    FREE_GB=$((FREE_KB / 1048576))
    if (( FREE_KB < 3 * 1048576 )); then
        echo "push-from-host: $HOSTNAME has $FREE_GB GB of disk free and a push needs a 2 GB checkout; nothing was" \
            "pushed. Free disk there, or name another Mac with --host." >&2
        exit 2
    fi
    if (( FREE_KB < 20 * 1048576 )); then
        echo "push-from-host: WARNING: $HOSTNAME has only $FREE_GB GB of disk free (under 20 GB). This push goes on;" \
            "free disk there before the pushes stop." >&2
    fi
fi
if [[ -f "$RDIR/bundle" ]]; then
    git fetch -q --no-tags "$RDIR/bundle" "refs/push-from-host/$NAME"
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
# The token lives in the git push process's environment only. The helper line holds the variable's name, not its
# value.
ASKED="$SHA"
TRIES=1
(( REBASE )) && TRIES=3
for (( TRY = 1; TRY <= TRIES; TRY++ )); do
    if (( REBASE )); then
        # The branch's head now. A new branch has none: nothing to rebase on.
        if git fetch -q --no-tags origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null; then
            if ! git -c user.name="$WHO" -c user.email="$MAIL" -c core.hooksPath=/dev/null \
                    rebase -q "refs/remotes/origin/$BRANCH" >&2; then
                git rebase --abort >/dev/null 2>&1 || true
                echo "push-from-host: $ASKED does not rebase onto $BRANCH without a conflict; nothing was pushed." \
                    "Rebase it in your clone and run this again." >&2
                exit 1
            fi
            SHA="$(git rev-parse HEAD)"
        fi
    fi
    STATUS=0
    CMUX_PUSH_TOKEN="$CMUX_PUSH_TOKEN" GIT_TERMINAL_PROMPT=0 \
        GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
        GIT_CONFIG_KEY_1=credential.helper \
        GIT_CONFIG_VALUE_1='!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$CMUX_PUSH_TOKEN"; }; f' \
        git push -q origin "$SHA:refs/heads/$BRANCH" >&2 || STATUS=$?
    NOW="$(git ls-remote origin "refs/heads/$BRANCH" | cut -f1)"
    if [[ "$NOW" == "$SHA" ]]; then
        unset CMUX_PUSH_TOKEN
        echo "push-from-host: pushed: $BRANCH is $SHA (gate ran on $HOSTNAME)." >&2
        if [[ "$SHA" != "$ASKED" ]]; then
            echo "push-from-host: $ASKED was rebased there and is $SHA on the remote: fetch and rebase this clone" \
                "before more work." >&2
        fi
        echo "push-from-host-result $SHA"
        exit 0
    fi
    # Only a branch that moved is tried again; a refusal by the hook is final.
    if (( ! REBASE )) || [[ "$NOW" == "$(git rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" || true)" ]]; then
        break
    fi
    echo "push-from-host: $BRANCH moved to ${NOW:0:12} during the push; rebasing again (try $((TRY + 1)) of $TRIES)." >&2
done
unset CMUX_PUSH_TOKEN
echo "push-from-host: not pushed (git push exit $STATUS): $BRANCH is ${NOW:-absent} on the remote." >&2
exit 1
REMOTE
"${SSH[@]}" "cat > '$RDIR/run.sh'" < "$WORK/remote.sh"

# The committer of a commit HOST rebases: this clone's identity, as a rebase here would use.
WHO="$(git config user.name || true)"
MAIL="$(git config user.email || true)"
if (( REBASE )) && [[ -z "$WHO" || -z "$MAIL" ]]; then
    echo "push-from-host: --rebase needs user.name and user.email in this clone's git config." >&2
    exit 2
fi
# HOST's stdout carries only the result line (the pushed commit); everything a person reads is on stderr.
STATUS=0
printf '%s\n' "$TOKEN" | "${SSH[@]}" bash "$RDIR/run.sh" "'$HOST_REPO'" "'$BRANCH'" "$SHA" "$NAME" \
    "$(printf '%q' "${CMUX_WEB_LINT_SKIP_REASON:-}")" "$(printf '%q' "${CMUX_NEXT_CHECKS_SKIP_REASON:-}")" \
    "$REBASE" "$(printf '%q' "$WHO")" "$(printf '%q' "$MAIL")" "$RDIR" > "$WORK/out" || STATUS=$?
unset TOKEN
grep -v '^push-from-host-result ' "$WORK/out" >&2 || true
PUSHED="$(sed -n 's/^push-from-host-result \([0-9a-f]\{40\}\)$/\1/p' "$WORK/out" | tail -1)"
if (( STATUS == 0 )) && [[ "$PUSHED" == "$SHA" ]]; then
    # This clone's view of the branch, so `git status` and the next rebase see the push. A rebased commit is not
    # in this clone yet: the next fetch brings it.
    git update-ref "refs/remotes/origin/$BRANCH" "$SHA" 2>/dev/null || true
fi
[[ -z "$PUSHED" ]] || echo "$PUSHED"
exit "$STATUS"
