#!/usr/bin/env bash
# Guards scripts/ci/resolve-cmux-tui-client-commit.sh, which the nightly and release
# workflows use to pick the cmux-tui client build to bundle.
#
# Regression: actions/checkout clones with depth 1. In a one-commit history the grafted
# root shows every file as added, so `git log -1 -- cmux-tui` answers HEAD whether or
# not HEAD touched cmux-tui. HEAD only has a published client when it touched cmux-tui,
# so the manifest download returned 404 on almost every push (nightly runs 33941558929
# and 33943122606 died in "Bundle the cmux-tui client" with `curl: (56) ... 404`).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$ROOT_DIR/scripts/ci/resolve-cmux-tui-client-commit.sh"
if [[ ! -x "$RESOLVER" ]]; then
  echo "FAIL: missing executable $RESOLVER"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=cmux-test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=cmux-test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

git init -q "$TMP/src"
git -C "$TMP/src" checkout -q -b main
commit_touching() {
  mkdir -p "$(dirname "$TMP/src/$2")"
  echo "$1" >"$TMP/src/$2"
  git -C "$TMP/src" add -A
  git -C "$TMP/src" commit -q -m "$1"
  git -C "$TMP/src" rev-parse HEAD
}
C1="$(commit_touching "tui one" cmux-tui/src/main.rs)"
C2="$(commit_touching "app change" Sources/App.swift)"
C3="$(commit_touching "tui two" cmux-tui/src/lib.rs)"
C4="$(commit_touching "docs" docs/notes.md)"
C5="$(commit_touching "web" web/app.ts)"
: "$C2" "$C4"

# The artifact store: only C1 and C3 have a published client, like main after an
# artifacts run that only exists for commits touching cmux-tui.
STORE="$TMP/store"
mkdir -p "$STORE/$C1" "$STORE/$C3"
printf '{"commit":"%s"}\n' "$C1" >"$STORE/$C1/manifest.json"
printf '{"commit":"%s"}\n' "$C3" >"$STORE/$C3/manifest.json"
export CMUX_TUI_CLIENT_MANIFEST_BASE="file://$STORE"

git clone -q --depth 1 "file://$TMP/src" "$TMP/work"

# This is the bug the resolver exists for: a depth-1 clone answers HEAD.
naive="$(git -C "$TMP/work" log -1 --format=%H -- cmux-tui)"
if [[ "$naive" != "$C5" ]]; then
  echo "FAIL: expected the depth-1 clone to answer HEAD ($C5) for the naive query, got $naive"
  exit 1
fi

got="$(cd "$TMP/work" && "$RESOLVER")"
if [[ "$got" != "$C3" ]]; then
  echo "FAIL: shallow clone must resolve the newest published cmux-tui commit $C3, got '$got'"
  exit 1
fi

# The newest cmux-tui commit lost its artifacts (failed or still-running artifacts run).
rm "$STORE/$C3/manifest.json"
if (cd "$TMP/work" && "$RESOLVER" >/dev/null 2>&1); then
  echo "FAIL: exact mode must fail when the newest cmux-tui commit has no published client"
  exit 1
fi
got="$(cd "$TMP/work" && "$RESOLVER" --max-fallback 3 2>"$TMP/fallback.err")"
if [[ "$got" != "$C1" ]]; then
  echo "FAIL: fallback must pick the previous published commit $C1, got '$got'"
  exit 1
fi
if ! grep -q '^::warning' "$TMP/fallback.err"; then
  echo "FAIL: a fallback must annotate the run with a ::warning"
  exit 1
fi

# A leading zero is decimal, not octal: 08 means eight, not a Bash arithmetic error.
got="$(cd "$TMP/work" && "$RESOLVER" --max-fallback 08 2>/dev/null)"
if [[ "$got" != "$C1" ]]; then
  echo "FAIL: --max-fallback 08 must be read as decimal 8 and resolve $C1, got '$got'"
  exit 1
fi

# A full clone takes the same decision without deepening.
git clone -q "file://$TMP/src" "$TMP/full"
got="$(cd "$TMP/full" && "$RESOLVER" --max-fallback 3 2>/dev/null)"
if [[ "$got" != "$C1" ]]; then
  echo "FAIL: full clone must resolve $C1, got '$got'"
  exit 1
fi

echo "PASS: resolve-cmux-tui-client-commit picks the newest published cmux-tui commit, shallow or not"
