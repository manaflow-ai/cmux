#!/usr/bin/env bash
# A reused self-hosted runner workspace (a glaeda mini) keeps the previous
# job's submodule checkouts: actions/checkout with `submodules: false` moves
# the superproject to this commit but leaves a submodule at the last branch's
# commit, so `git status` reports ` M ghostty-next` and pin-cmux-tui.sh fetch
# refuses the checkout as dirty (run 37198483749, job 111425574861). A fresh
# Blacksmith checkout has no submodule checkouts and passes.
# scripts/ci/reset-stale-submodules.sh must make the reused workspace match a
# fresh checkout, while a real cmux-tui edit is still refused.
# No network: the CDN base is unreachable, so a fetch that gets past the dirty
# check stops at "is not published".
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
RESET="$ROOT/scripts/ci/reset-stale-submodules.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main -c protocol.file.allow=always "$@" >/dev/null 2>&1; }
fail() { printf '%s\n' "$@" >&2; exit 1; }

# ghostty-next (the submodule cmux-tui builds from, CMUX-TUI-TREE-KEY-V2):
# two commits; the superproject pins the second (B).
git_q init "$TMP/ghostty-src"
echo a > "$TMP/ghostty-src/f"; git_q -C "$TMP/ghostty-src" add f; git_q -C "$TMP/ghostty-src" commit -m A
commit_a=$(git -C "$TMP/ghostty-src" rev-parse HEAD)
echo b > "$TMP/ghostty-src/f"; git_q -C "$TMP/ghostty-src" commit -am B
commit_b=$(git -C "$TMP/ghostty-src" rev-parse HEAD)

ws="$TMP/ws"
git_q init "$ws"
mkdir -p "$ws/cmux-tui" "$ws/scripts/cmux-next"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$ws/scripts/cmux-next/"
mkdir -p "$ws/scripts/ci"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$ws/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$ws/scripts/cmux-next/"
echo reducer > "$ws/scripts/cmux-next/build-layout-reducer-ffi.sh"
"$ROOT/scripts/cmux-next/tests/lib/tree-inputs-fixture.sh" "$ws"
echo one > "$ws/cmux-tui/a"
git_q -C "$ws" submodule add "$TMP/ghostty-src" ghostty-next
git_q -C "$ws" add -A
git_q -C "$ws" commit -m superproject
[[ "$(git -C "$ws" rev-parse HEAD:ghostty-next)" == "$commit_b" ]] || fail "setup: gitlink is not B"

# What the previous job on the runner left: ghostty-next checked out at another commit.
git_q -C "$ws/ghostty-next" checkout --detach "$commit_a"

dirty() { git -C "$ws" status --porcelain --ignore-submodules=dirty -- cmux-tui ghostty-next; }
# The CI job's own event and tree settings would change which path fetch takes:
# on a feat-cmux-next push the checkout is its own publisher, so fetch read the
# real artifacts runs and fetched each active run's commit from the public
# repository into this toy repo (all of cmux; 188 s, then past the job's 10 min
# timeout once that fetch kept full depth). The GitHub API and the public git
# fallback are unreachable here, as in pin-cmux-tui.test.sh.
fetch() { # -> "<status> <output>"
  local status=0 out
  out=$(cd "$ws" && env -u CI_JOB_DIR -u CMUX_NEXT_TUI_ALLOW_DIRTY -u GH_TOKEN -u GITHUB_EVENT_NAME -u GITHUB_REF \
    -u CMUX_TUI_TREE_PUBLISHER_SHA -u CMUX_TUI_TREE_KEY -u CMUX_TUI_TREE_DISPATCH GITHUB_ACTIONS=true \
    GITHUB_API_URL=https://127.0.0.1:9 CMUX_TUI_PUBLIC_GIT_URL="$TMP/no-public-repo.git" \
    CMUX_TUI_PIN_BASE=https://127.0.0.1:9/cmux-tui CMUX_TUI_TREE_WAIT_SECONDS=0 \
    bash scripts/cmux-next/pin-cmux-tui.sh fetch 2>&1) || status=$?
  printf '%s %s' "$status" "$out"
}

[[ "$(dirty)" == " M ghostty-next" ]] || fail "setup: stale ghostty-next is not reported as ' M ghostty-next':" "$(dirty)"
out=$(fetch)
grep -q 'uncommitted cmux-tui source changes' <<<"$out" || fail "setup: the stale workspace was not refused:" "$out"

# The fast tier only needs ghostty-next. Reuse mode must clean a previous
# job's source edit and reconcile the checkout to the superproject gitlink
# without deinitializing its object database or warm working tree.
echo stale > "$ws/ghostty-next/generated-source"
"$RESET" "$ws" --reuse ghostty-next || fail "reuse reset failed"
[[ "$(git -C "$ws/ghostty-next" rev-parse HEAD)" == "$commit_b" ]] \
  || fail "reuse reset did not check out the gitlink"
[[ ! -e "$ws/ghostty-next/generated-source" ]] || fail "reuse reset left an untracked source file"
[[ -d "$ws/.git/modules/ghostty-next/objects" ]] \
  || fail "reuse reset dropped the submodule object database"
[[ -z "$(dirty)" ]] || fail "reuse reset left the workspace dirty:" "$(dirty)"

# The reset drops the stale submodule checkout, as on a fresh checkout.
[[ -x "$RESET" ]] || fail "missing $RESET"
"$RESET" "$ws" || fail "reset-stale-submodules.sh failed on a stale workspace"
[[ -z "$(dirty)" ]] || fail "the reset left the workspace dirty:" "$(dirty)"
out=$(fetch)
if grep -q 'uncommitted cmux-tui source changes' <<<"$out"; then fail "pin-cmux-tui still refused the reset workspace:" "$out"; fi
grep -q 'is not published' <<<"$out" || fail "fetch did not reach the published-tree check:" "$out"

# Idempotent on a workspace with no initialized submodule (a fresh checkout).
"$RESET" "$ws" || fail "a second reset failed"
git_q init "$TMP/plain"; git_q -C "$TMP/plain" commit --allow-empty -m empty
"$RESET" "$TMP/plain" || fail "reset failed on a repository without submodules"

# A later checkout that wants ghostty-next re-inits it at the gitlink from the kept objects.
git_q -C "$ws" submodule update --init ghostty-next || fail "re-init after the reset failed"
[[ "$(git -C "$ws/ghostty-next" rev-parse HEAD)" == "$commit_b" ]] || fail "re-init did not check out the gitlink"

# A real cmux-tui edit is still refused after the reset.
"$RESET" "$ws"
echo dirty > "$ws/cmux-tui/a"
out=$(fetch)
[[ "$out" == "1 "* ]] && grep -q 'uncommitted cmux-tui source changes' <<<"$out" \
  || fail "a real cmux-tui edit was not refused after the reset:" "$out"

# A workspace that lost .git/modules (2026-10-28, the warm nightly-next
# builder): the checkout's .git file names nothing. The reset drops it to an
# empty directory instead of failing in `git submodule status`, and a later
# update clones it again.
"$RESET" "$ws"
git_q -C "$ws" submodule update --init ghostty-next || fail "setup: init before losing .git/modules failed"
rm -rf "$ws/.git/modules"
git -C "$ws" submodule status >/dev/null 2>&1 && fail "setup: submodule status passed on a dangling checkout"
out=$("$RESET" "$ws" 2>&1) || fail "reset failed on a dangling submodule checkout:" "$out"
grep -q 'ghostty-next: its .git names' <<<"$out" || fail "the reset did not say it dropped the dangling checkout:" "$out"
[[ -d "$ws/ghostty-next" && -z "$(ls -A "$ws/ghostty-next")" ]] || fail "the dangling checkout was not emptied"
git_q -C "$ws" submodule update --init ghostty-next || fail "re-init after dropping the dangling checkout failed"
[[ "$(git -C "$ws/ghostty-next" rev-parse HEAD)" == "$commit_b" ]] || fail "re-init did not check out the gitlink"

# A half-made git dir (no HEAD) goes with its checkout, so the update clones afresh.
mkdir -p "$ws/.git/modules/ghostty-next/objects"
rm -f "$ws/.git/modules/ghostty-next/HEAD"
"$RESET" "$ws" >/dev/null || fail "reset failed on a half-made submodule git dir"
[[ ! -e "$ws/.git/modules/ghostty-next" ]] || fail "the half-made git dir was kept"
git_q -C "$ws" submodule update --init ghostty-next || fail "re-init after dropping a half-made git dir failed"
printf 'reset-stale-submodules tests: ok\n'
