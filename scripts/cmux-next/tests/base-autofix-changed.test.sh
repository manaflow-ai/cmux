#!/usr/bin/env bash
# What base autofix's "Changed areas" steps diff (base-autofix-changed.sh). The checkout is depth 1 at
# the run's commit. When the last successful run's head ("since") is newer than that commit, a
# `git fetch --depth=1 origin $since` grafted it as a shallow root: the later tip fetch stopped there,
# the run's commit was no longer an ancestor of the tip, and base-autofix-push.sh held every Mac export
# as "not a commit between" (run 39617667536, 2026-10-21; #22740's settings export was lost). Found by
# app-store-features-22.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../base-autofix-changed.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*" >&2; exit 1; }

# A remote with the run's commit A, then B and C on top; the bot's checkout is depth 1 at A.
setup() {
  rm -rf "$tmp/remote.git" "$tmp/lane" "$tmp/bot"
  git init -q --bare -b feat "$tmp/remote.git"
  git clone -q "$tmp/remote.git" "$tmp/lane" 2>/dev/null
  (cd "$tmp/lane" && git checkout -q -b feat && echo a > a.txt \
    && git add -A && git commit -q -m A && git push -q origin feat)
  a="$(git -C "$tmp/lane" rev-parse HEAD)"
  (cd "$tmp/lane" && echo b > b.txt && git add -A && git commit -q -m B \
    && echo c > c.txt && git add -A && git commit -q -m C && git push -q origin feat)
  c="$(git -C "$tmp/lane" rev-parse HEAD)"
  # Like actions/checkout: the run's commit A alone, depth 1, with its remote ref and local branch. The
  # scratch fetch must not offer those refs as commits it has (it has none of their history).
  git init -q "$tmp/bot"
  git -C "$tmp/bot" remote add origin "file://$tmp/remote.git"
  git -C "$tmp/bot" fetch -q --depth=1 origin "+$a:refs/remotes/origin/feat"
  git -C "$tmp/bot" checkout -q -B feat refs/remotes/origin/feat
  [[ "$(git -C "$tmp/bot" rev-parse --is-shallow-repository)" == true ]] || fail "setup: the bot checkout is not shallow"
}
changed() { (cd "$tmp/bot" && bash "$script" "$@"); }

# 1. since newer than the run's commit (a later run went green while this one waited): the diff is
#    since..HEAD, and the tip fetched afterwards still reaches the run's commit.
setup
changed "$c" > "$tmp/out" 2>"$tmp/err" || fail "a since newer than HEAD was not read: $(cat "$tmp/err")"
[[ "$(sort "$tmp/out" | tr '\n' ' ')" == "b.txt c.txt " ]] || fail "since..HEAD names the wrong paths: $(cat "$tmp/out")"
(cd "$tmp/lane" && echo d > d.txt && git add -A && git commit -q -m D && git push -q origin feat)
git -C "$tmp/bot" fetch -q --no-tags origin refs/heads/feat
git -C "$tmp/bot" merge-base --is-ancestor "$a" FETCH_HEAD \
  || fail "reading since grafted it as a shallow root: the run's commit is no longer an ancestor of the tip"
grep -qx "$c" "$tmp/bot/.git/shallow" 2>/dev/null && fail "since is in the checkout's shallow list"

# 2. since older than the run's commit: the diff is since..HEAD, as before.
setup
(cd "$tmp/lane" && echo e > e.txt && git add -A && git commit -q -m E && git push -q origin feat)
e="$(git -C "$tmp/lane" rev-parse HEAD)"
git -C "$tmp/bot" fetch -q --depth=1 origin "+$e:refs/remotes/origin/feat" && git -C "$tmp/bot" checkout -q -B feat refs/remotes/origin/feat
changed "$a" > "$tmp/out" 2>"$tmp/err" || fail "an older since was not read: $(cat "$tmp/err")"
[[ "$(sort "$tmp/out" | tr '\n' ' ')" == "b.txt c.txt e.txt " ]] || fail "an older since names the wrong paths: $(cat "$tmp/out")"

# 3. No since, or one the remote does not have: it fails, and the caller runs every repair.
changed "" > /dev/null 2>&1 && fail "an empty since did not fail"
changed 0123456789abcdef0123456789abcdef01234567 > /dev/null 2>&1 && fail "an unknown since did not fail"

echo "base-autofix-changed: PASS: since..HEAD is read without grafting since into the checkout"
