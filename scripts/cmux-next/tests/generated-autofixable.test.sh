#!/usr/bin/env bash
# generated-autofixable.sh: stale generated cmux-next files report as autofixed only when the pull
# request's own changes turn on the PR autofix's exports repair and the head is not an autofix commit.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../generated-autofixable.sh"
tmp="$(mktemp -d)"
git_fixture_trap_exit 'rm -rf "$tmp"'
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*" >&2; exit 1; }

# A base, a pull request commit changing PATH (message MSG), and the run's merge commit.
merge() { # path msg
  rm -rf "$tmp/r"
  git_fixture_init -b base "$tmp/r"
  (cd "$tmp/r" && echo a > README && git add -A && git commit -qm base \
    && git checkout -qb pr && mkdir -p "$(dirname "$1")" && echo x >> "$1" && git add -A && git commit -qm "$2" \
    && git checkout -q --detach base && git merge -q --no-ff -m merge pr)
}
run() { (cd "$tmp/r" && "$script"); }

merge Packages/macOS/CmuxNext/Sources/CmuxNextActions/A.swift "feat: an action"
out="$(run)" || fail "an action input change is the PR autofix's: $out"

merge Packages/macOS/CmuxNext/Sources/CmuxNextSettings/S.swift "feat: a setting"
run >/dev/null || fail "a settings input change is the PR autofix's"

merge README.md "docs: readme"
if out="$(run)"; then fail "stale files a pull request inherits are red: $out"; fi
grep -q "from the base" <<<"$out" || fail "names the base: $out"

merge Packages/macOS/CmuxNext/Sources/CmuxNextActions/A.swift "$(printf 'chore(next): PR autofix at 0123456789ab\n\nAutofix-Run: https://x/1')"
if out="$(run)"; then fail "an autofix head is checked strictly: $out"; fi

(cd "$tmp/r" && git checkout -q base)
if run >/dev/null; then fail "no merge commit is red"; fi
echo "generated-autofixable: ok"
