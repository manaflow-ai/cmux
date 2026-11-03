#!/usr/bin/env bash
# A web bundle build never modifies tracked sources (cx-t3e5). The optchat
# memory inspector page is a generated file that stays committed. A build on a
# commit whose committed copy is stale must fail and name the regenerate
# command; it must not rewrite the file in the build tree, where a fleet or
# nx-remote build would ship a source that no commit holds.
# The strings tables (webviews/src/**/generated/) are build output since
# #21946: the build writes them, ignored by git, from the commit's catalogs.
# The case commits the stale file in a scratch worktree of HEAD (with this
# checkout's build scripts copied in), runs a build with no stamp (a cache
# miss), and checks the exit code, the message, the strings tables and
# `git status --porcelain`.
# Needs the pinned bun and node 22.18+ (the fleet hosts and the web bundles CI
# job have both).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d)
src="$TMP/src"
cleanup() { git -C "$ROOT" worktree remove --force "$src" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT
fail() { printf '%s\n' "$@" >&2; exit 1; }
git_q() { git -c user.name=t -c user.email=t@example.com -c core.hooksPath=/dev/null "$@" >/dev/null 2>&1; }

git_q -C "$ROOT" worktree add --detach "$src" HEAD || fail "cannot add a scratch worktree of HEAD"
# The scripts under test come from this checkout, committed or not.
for f in scripts/cmux-next/build-web-bundles.sh scripts/cmux-next/build-pages-web.sh \
  scripts/cmux-next/build-optchat-inspector-web.sh scripts/cmux-next/web-bundle-key.py \
  scripts/check-webviews-bun-version.sh \
  webviews/scripts/pages/gen-strings.mjs .gitignore; do
  cp "$ROOT/$f" "$src/$f"
done
# Untrack the tables the way this checkout does (a no-op once HEAD has #21946).
git -C "$src" ls-files -z -- ':(glob)webviews/src/**/generated/strings.json' \
  webviews/src/pages/home-channels/generated/pane-strings.json \
  webviews/src/pages/diff/generated/locales webviews/src/pages/diff/generated/localeLoaders.ts \
  | git -C "$src" rm -q --cached --pathspec-from-file=- --pathspec-file-nul >/dev/null 2>&1 || true
git_q -C "$src" add -A
git_q -C "$src" commit --allow-empty -m "scripts under test"
base=$(git -C "$src" rev-parse HEAD)

STRINGS=webviews/src/pages/cloud/generated/strings.json
INSPECTOR=Native/OptChat/optchat-chief/inspector/index.html

# Commits a stale copy of the inspector page on top of $base, with no strings tables in the tree.
stale_commit() {
  git_q -C "$src" checkout --force --detach "$base"
  git_q -C "$src" clean -ffdx -e webviews/node_modules
  printf '<!-- stale -->\n' >> "$src/$INSPECTOR"
  git_q -C "$src" commit -am "stale inspector"
  [[ ! -e "$src/$STRINGS" ]] || fail "fixture: $STRINGS is still in the scratch tree"
}

# run_case NAME COMMAND...: the build must fail loudly and leave the tree clean.
run_case() {
  local name="$1"; shift
  local log="$TMP/$name.log"
  if (cd "$src" && env CMUX_WEB_BUNDLES_TOOLS_OPTIONAL=0 "$@") >"$log" 2>&1; then
    fail "$name: the build passed on a stale committed generated file" "$(tail -20 "$log")"
  fi
  grep -q "generated file is stale" "$log" || fail "$name: no 'generated file is stale' message" "$(tail -20 "$log")"
  local dirty
  dirty=$(git -C "$src" status --porcelain --untracked-files=no)
  [[ -z "$dirty" ]] || fail "$name: the build modified tracked files:" "$dirty"
}

stale_commit
[[ ! -e "$src/.web-bundles.key" ]] || fail "the scratch tree has a stamp; the case would not be a cache miss"
run_case bundles-inspector ./scripts/cmux-next/build-web-bundles.sh
grep -q "$INSPECTOR" "$TMP/bundles-inspector.log" || fail "bundles-inspector: the message does not name $INSPECTOR"
# The strings tables were written before the inspector check, fresh and ignored.
(cd "$src/webviews" && node scripts/pages/gen-strings.mjs --check) || fail "the build did not write fresh strings tables"
git -C "$src" check-ignore -q "$STRINGS" || fail "$STRINGS is not ignored"

echo "web-bundles-readonly-sources: ok"
