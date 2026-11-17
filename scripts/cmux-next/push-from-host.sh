#!/bin/bash
# Push a commit to manaflow-ai/cmux from another Mac, with that Mac's pre-push hook as the gate.
#
#   scripts/cmux-next/push-from-host.sh [--host HOST]... [--sha REV] [--rebase] BRANCH
#   scripts/cmux-next/push-from-host.sh [--host HOST]... --delete scratch/NAME   # a plain delete push, from HOST
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
# answers SSH and holds the clone is used. A host is HOST or HOST:REPO (REPO relative to HOST's home; without it,
# CMUX_PUSH_HOST_REPO). With none given, the hosts with the registry's mac-build role are tried in registry order.
# The registry's personal machines are never candidates, even when an environment variable names one. Not a Linux
# host: the hook runs SwiftFormat and SwiftLint. A hand-kept list beside the registry caused a fallback onto Leo's
# own machine when a fleet host's disk was full; the registry is now the only default source and personal markers are
# enforced for explicit overrides too.
# A host the fleet reserves for someone is skipped, whether it came from DEFAULT_HOSTS, CMUX_PUSH_HOST or --host:
# before SSH, each host goes to leo-workspace's tools/fleet_reservations.py (the registry's dated reservations, the
# build controller's pool holds, HQ's owner-only hosts), and when every host is reserved nothing is sent. A reader
# that answers neither free nor reserved skips the host too (fail closed). A Mac without the reader (no
# leo-workspace checkout) is warned once and not checked. On 2026-11-12 a helper pushed through a perf lead's mini
# from this list; a hardcoded list can't know who holds a host today.
# --delete deletes BRANCH, which must be under scratch/, with a plain `git push origin :refs/heads/BRANCH` from HOST's
# clone: the same hook gates it, never --no-verify (2026-11-16: an agent's scratch branches stayed because a delete
# from a loaded Mac runs that Mac's hook). Any other branch is refused before SSH.
# --which-host prints the host and repo it would use (`HOST REPO`) and exits 0, before anything is sent.
#
# Exit: 0 pushed (or already there), 1 refused by the hook or by GitHub (output above), 2 usage or setup (also: every
# host reserved or unreachable). Without --rebase a non-fast-forward is refused by GitHub as always. It never forces.
#
# Environment: CMUX_PUSH_HOST [registry candidates], CMUX_FLEET_REGISTRY [leo-workspace's fleet-registry.json, else
# this repo's scripts/cmux-next/push-hosts.json when that file is absent],
# CMUX_PUSH_HOST_REPO [fun/cmux, relative to HOST's home], CMUX_FLEET_RESERVATIONS
# [~/Projects/leo-workspace/tools/fleet_reservations.py, the reader reach uses],
# and the hook's own CMUX_WEB_LINT_SKIP_REASON / CMUX_NEXT_CHECKS_SKIP_REASON, passed through.
set -euo pipefail

# Defaults come from the registry's mac-build role. There is deliberately no hard-coded fallback: Leo, 2026-11-16,
# "cmux16 is not a fleet builder right now it runs MY stuff".
# Empty mac-build is intentional when only personal Macs remain. Verification then belongs on managed CI.
ci_next() {
    echo "next: cmux-ci test -- python3 scripts/cmux-next/prepush-gate.py" >&2
    echo "push-from-host: if a remaining gate requires macOS, use a cmux-ci exclusive step or lease an authorized fleet Mac with: cmux-ci lease take HOST --for 1h --reason 'macOS push gate' (release after)." >&2
}
# The fleet registry: CMUX_FLEET_REGISTRY, else leo-workspace's. With neither named nor present, the reviewed one in
# this repo (push-hosts.json: fleet builders only, today cmux-lawrence-2). On 2026-11-16 no Mac had leo-workspace's
# file, so every push stopped before SSH and agents pushed by hand through cmux-lawrence-2; one printed a gh token
# doing so. A registry that is named but missing, or present but malformed, still stops the push (fail closed).
REGISTRY="${CMUX_FLEET_REGISTRY:-$HOME/Projects/leo-workspace/machines/fleet-registry.json}"
if [[ -z "${CMUX_FLEET_REGISTRY:-}" && ! -e "$REGISTRY" ]]; then
    REGISTRY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/push-hosts.json"
    echo "push-from-host: no fleet registry at ~/Projects/leo-workspace; using scripts/cmux-next/push-hosts.json." >&2
fi
DEFAULT_HOSTS=()
HOSTS=()
WHICH_HOST=0
REBASE=0
DELETE=0
HOST_REPO="${CMUX_PUSH_HOST_REPO:-fun/cmux}"
REV="HEAD"
BRANCH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOSTS+=("${2:?--host needs a value}"); shift ;;
        --rebase) REBASE=1 ;;
        --delete) DELETE=1 ;;
        --which-host) WHICH_HOST=1 ;;
        --sha) REV="${2:?--sha needs a value}"; shift ;;
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
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
if (( DELETE )) && [[ "$BRANCH" != scratch/?* || "$BRANCH" == *..* ]]; then
    echo "push-from-host: --delete deletes only a scratch/ branch (got $BRANCH); nothing was sent." >&2
    exit 2
fi
if (( DELETE && REBASE )); then
    echo "push-from-host: --delete takes no --rebase" >&2
    exit 2
fi
# Read once before any SSH, including explicit overrides. Missing or malformed policy cannot authorize a host.
if ! REGISTRY_HOSTS="$(python3 - "$REGISTRY" <<'PYREG'
import json, sys
try:
    with open(sys.argv[1]) as source:
        machines = json.load(source)["machines"]
    for name, machine in machines.items():
        roles = set(machine.get("roles") or []) - set(machine.get("excluded_roles") or [])
        lanes = machine.get("lanes") or {}
        personal = (bool(machine.get("personal")) or bool(lanes.get("personal"))
                    or bool(set(machine.get("roles") or []) & {"leo-apps", "leo-mac"})
                    or machine.get("approval") == "leo-own")
        if "mac-build" in roles and not personal:
            print(name)
except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
    print(f"push-from-host: fleet registry cannot be read: {exc}", file=sys.stderr)
    raise SystemExit(2)
PYREG
)"; then
    ci_next
    exit 2
fi
while IFS= read -r candidate; do
    [[ -z "$candidate" ]] || DEFAULT_HOSTS+=("$candidate")
done <<< "$REGISTRY_HOSTS"
if (( ${#HOSTS[@]} == 0 )); then
    if [[ -n "${CMUX_PUSH_HOST:-}" ]]; then
        read -r -a HOSTS <<< "$CMUX_PUSH_HOST"
    elif (( ${#DEFAULT_HOSTS[@]} > 0 )); then
        HOSTS=("${DEFAULT_HOSTS[@]}")
    else
        echo "push-from-host: no eligible mac-build hosts in $REGISTRY; nothing was sent." >&2
        ci_next
        exit 2
    fi
fi
if [[ ! "$HOST_REPO" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "push-from-host: the repo path has characters this script does not pass to a shell" >&2
    exit 2
fi
RESERVATIONS="${CMUX_FLEET_RESERVATIONS:-$HOME/Projects/leo-workspace/tools/fleet_reservations.py}"
if [[ ! -f "$RESERVATIONS" ]]; then
    echo "push-from-host: no fleet reservation reader at $RESERVATIONS; hosts are not checked for reservations." >&2
    RESERVATIONS=""
fi
HOST=""
TRIED=()
RESERVED=()
for spec in "${HOSTS[@]}"; do
    candidate="${spec%%:*}"
    repo="$HOST_REPO"
    [[ "$spec" != *:* ]] || repo="${spec#*:}"
    if [[ ! "$candidate" =~ ^[A-Za-z0-9._@-]+$ || ! "$repo" =~ ^[A-Za-z0-9._/-]+$ ]]; then
        echo "push-from-host: host '$spec' has characters this script does not pass to a shell" >&2
        exit 2
    fi
    # Explicit host lists choose among the same registry-authorized builders; they cannot grant eligibility.
    eligible=0
    for registered in $REGISTRY_HOSTS; do
        if [[ "${candidate#*@}" == "$registered" ]]; then
            eligible=1
            break
        fi
    done
    if (( ! eligible )); then
        echo "push-from-host: skipping $candidate: not an eligible mac-build host in the fleet registry (personal, excluded or unknown)." >&2
        RESERVED+=("$candidate")
        continue
    fi
    if [[ -n "$RESERVATIONS" ]]; then
        # The reader exits 0 for a free host and 1 for a reserved one, printing who holds it. ssh's user@ is not
        # part of the machine's name.
        STATUS=0
        HELD="$(python3 -I "$RESERVATIONS" "${candidate#*@}" 2>&1)" || STATUS=$?
        if (( STATUS == 1 )); then
            echo "push-from-host: skipping $candidate: $HELD" >&2
            RESERVED+=("$candidate")
            continue
        elif (( STATUS != 0 )); then
            echo "push-from-host: skipping $candidate: its reservation can't be read (exit $STATUS): $HELD" >&2
            RESERVED+=("$candidate")
            continue
        fi
    fi
    TRIED+=("$candidate")
    # Answering SSH is not enough: a host without the clone would fail later, after the bundle. ssh's own failure
    # (no answer) is 255; the remote test's is 1.
    STATUS=0
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$candidate" "test -e \"\$HOME/$repo/.git\"" 2>/dev/null || STATUS=$?
    if (( STATUS == 0 )); then
        HOST="$candidate"
        HOST_REPO="$repo"
        break
    elif (( STATUS == 255 )); then
        echo "push-from-host: $candidate does not answer SSH; trying the next host." >&2
    else
        echo "push-from-host: $candidate has no clone at ~/$repo; trying the next host." >&2
    fi
done
if [[ -z "$HOST" ]]; then
    if (( ${#TRIED[@]} == 0 )); then
        echo "push-from-host: no candidate is eligible and unreserved (${RESERVED[*]}); nothing was sent." >&2
        ci_next
    else
        # Not ${RESERVED[*]} on an empty array: macOS's bash 3.2 calls that unbound under set -u.
        SKIPPED=""
        (( ${#RESERVED[@]} == 0 )) || SKIPPED="; skipped as reserved: ${RESERVED[*]}"
        echo "push-from-host: no host answers SSH (${TRIED[*]})$SKIPPED; name another with --host HOST[:REPO]." >&2
    fi
    exit 2
fi
if (( WHICH_HOST )); then
    echo "$HOST $HOST_REPO"
    exit 0
fi
SHA="$(git rev-parse --verify --quiet "$REV^{commit}")" || { echo "push-from-host: $REV is not a commit" >&2; exit 2; }
# No `git status` here: on the loaded Mac this script is for, it alone took minutes. Only commits are pushed.

TOKEN="$(gh auth token 2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
    echo "push-from-host: \`gh auth token\` gave nothing; sign in with \`gh auth login\` on this Mac." >&2
    exit 2
fi

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 "$HOST")
if (( DELETE )); then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/push-from-host.XXXXXX")"
    trap 'rm -rf "$WORK"' EXIT
    RDIR="$("${SSH[@]}" "mktemp -d /tmp/push-from-host-delete-XXXXXX")" || RDIR=""
    if [[ ! "$RDIR" =~ ^/tmp/push-from-host-delete-[A-Za-z0-9]+$ ]]; then
        echo "push-from-host: could not make a private folder on $HOST; nothing was deleted." >&2
        exit 2
    fi
    # HOST's step: its clone's own hook gates the delete; the token is stdin's only line, as for a push.
    {
        echo 'set -euo pipefail'
        echo 'REPO="$HOME/$1" BRANCH="$2" RDIR="$3"'
        echo 'trap '"'"'rm -rf "$RDIR"'"'"' EXIT'
        echo 'IFS= read -r CMUX_PUSH_TOKEN'
        echo 'cd "$REPO"'
        sed -n '/^# BEGIN gate_hook_runs$/,/^# END gate_hook_runs$/p' "${BASH_SOURCE[0]}"
        cat <<'REMOTE'
if ! gate_hook_runs; then
    echo "push-from-host: $HOSTNAME's clone would run no cmux pre-push gate; nothing was deleted." >&2
    exit 2
fi
STATUS=0
CMUX_PUSH_TOKEN="$CMUX_PUSH_TOKEN" GIT_TERMINAL_PROMPT=0 \
    GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
    GIT_CONFIG_KEY_1=credential.helper \
    GIT_CONFIG_VALUE_1='!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$CMUX_PUSH_TOKEN"; }; f' \
    git push -q origin ":refs/heads/$BRANCH" >&2 || STATUS=$?
unset CMUX_PUSH_TOKEN
if [[ -n "$(git ls-remote origin "refs/heads/$BRANCH")" ]]; then
    echo "push-from-host: not deleted (git push exit $STATUS): $BRANCH is still on the remote." >&2
    exit 1
fi
echo "push-from-host: deleted: $BRANCH (gate ran on $HOSTNAME)." >&2
REMOTE
    } > "$WORK/delete.sh"
    "${SSH[@]}" "cat > '$RDIR/delete.sh'" < "$WORK/delete.sh"
    STATUS=0
    printf '%s\n' "$TOKEN" | "${SSH[@]}" bash "$RDIR/delete.sh" "$HOST_REPO" "$BRANCH" "$RDIR" || STATUS=$?
    exit "$STATUS"
fi
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
# The gate is cmux's own pre-push hook (scripts/git-hooks/pre-push, which runs prepush-gate), installed in the clone's
# cmux-git-hooks. Git runs it when core.hooksPath is that folder, or when core.hooksPath is a shared hooks folder whose
# pre-push runs each repo's own hooks (run_repo_hooks). Any other executable pre-push is not the gate: on 2026-11-16
# cmux16's clones had a shared hooks folder's pre-push and no cmux pre-push in cmux-git-hooks (installed 2026-10-18),
# so every push from there ran no prepush-gate, and a merge that dropped five settings exports' keys
# (cmux#43562 885211f5) was pushed as "gate ran on cmux16". A clone without it gets the reviewed hooks from the
# fetched feat-cmux-next, never from the commit being pushed.
# BEGIN gate_hook_runs
gate_hook_runs() {
    local hooks common own
    # --type=path: git expands a `~/...` value the same way when it runs the hook.
    hooks="$(git config --type=path --get core.hooksPath || true)"
    common="$(git rev-parse --path-format=absolute --git-common-dir)" || return 1
    own="$common/cmux-git-hooks"
    [[ -x "$own/pre-push" ]] && grep -q 'prepush[-_]gate' "$own/pre-push" || return 1
    # A relative core.hooksPath is resolved where the hook runs, the pushed tree, so a check made here would read
    # other files than the ones git runs: refused.
    [[ "$hooks" == /* && -x "$hooks/pre-push" ]] || return 1
    [[ "$(cd "$hooks" && pwd -P)" == "$(cd "$own" && pwd -P)" ]] && return 0
    # The wiring install-git-hooks.sh prints for a clone with hooks of its own: a pre-push that calls this one. Its
    # path may name the clone another way than git does (macOS: /var/folders is /private/var/folders; a symlinked
    # ~/fun), so each .../cmux-git-hooks/pre-push it names is compared by real folder, not by text.
    grep -qF "$own/pre-push" "$hooks/pre-push" && return 0
    local named own_real
    own_real="$(cd "$own" && pwd -P)"
    while IFS= read -r named; do
        named="${named%/pre-push}"
        [[ "$named" == /* && -d "$named" && "$(cd "$named" && pwd -P)" == "$own_real" ]] && return 0
    done < <(grep -oE "/[^'\" ]*/cmux-git-hooks/pre-push" "$hooks/pre-push" || true)
    # A shared hooks folder that runs each repo's own hooks (run_repo_hooks, defined in the repo-hook beside it).
    [[ -f "$hooks/repo-hook" ]] && grep -q 'run_repo_hooks' "$hooks/pre-push" && grep -q '^run_repo_hooks()' "$hooks/repo-hook"
}
# END gate_hook_runs
if ! gate_hook_runs; then
    echo "push-from-host: $HOSTNAME's clone would run no cmux pre-push gate; installing the hooks from" \
        "origin/feat-cmux-next." >&2
    git -c core.hooksPath=/dev/null worktree add --quiet --detach "$TREE.hooks" refs/remotes/origin/feat-cmux-next
    "$TREE.hooks/scripts/install-git-hooks.sh" >&2
    git worktree remove --force "$TREE.hooks"
    if ! gate_hook_runs; then
        echo "push-from-host: $HOSTNAME's clone still would not run cmux's pre-push gate (core.hooksPath:" \
            "$(git config --type=path --get core.hooksPath || echo none)); nothing was pushed. Point it at the clone's" \
            "cmux-git-hooks or at a hooks folder that runs each repo's own hooks." >&2
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
