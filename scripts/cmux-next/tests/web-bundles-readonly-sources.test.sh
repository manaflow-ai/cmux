#!/usr/bin/env bash
# A web bundle build never modifies tracked sources (cx-t3e5). The strings
# tables (webviews/src/**/generated/) and the optchat memory inspector page are
# generated files that stay committed. A build on a commit whose committed copy
# is stale must fail and name the regenerate command; it must not rewrite the
# file in the build tree, where a fleet or nx-remote build would ship a source
# that no commit holds.
# Each case commits one stale file in a scratch worktree of HEAD (with this
# checkout's build scripts copied in), runs a build with no stamp (a cache
# miss), and checks the exit code, the message and `git status --porcelain`.
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
  webviews/scripts/pages/gen-strings.mjs; do
  cp "$ROOT/$f" "$src/$f"
done
git_q -C "$src" add -A
git_q -C "$src" commit --allow-empty -m "scripts under test"
base=$(git -C "$src" rev-parse HEAD)

STRINGS=webviews/src/pages/cloud/generated/strings.json
INSPECTOR=Native/OptChat/optchat-chief/inspector/index.html

# Commits a stale copy of one generated file on top of $base.
stale_commit() {
  git_q -C "$src" checkout --force --detach "$base"
  git_q -C "$src" clean -ffdx -e webviews/node_modules
  case "$1" in
    strings)
      python3 - "$src/$STRINGS" <<'PY'
import json, sys
path = sys.argv[1]
tables = json.load(open(path))
key = sorted(tables["en"])[0]
tables["en"][key] = tables["en"][key] + " (stale)"
open(path, "w").write(json.dumps(tables, indent=2) + "\n")
PY
      ;;
    inspector) printf '<!-- stale -->\n' >> "$src/$INSPECTOR" ;;
  esac
  git_q -C "$src" commit -am "stale $1"
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

stale_commit strings
[[ ! -e "$src/.web-bundles.key" ]] || fail "the scratch tree has a stamp; the case would not be a cache miss"
run_case bundles-strings ./scripts/cmux-next/build-web-bundles.sh
grep -q "$STRINGS" "$TMP/bundles-strings.log" || fail "bundles-strings: the message does not name $STRINGS"
run_case pages-strings ./scripts/cmux-next/build-pages-web.sh --out "$TMP/pages-out"

stale_commit inspector
run_case bundles-inspector ./scripts/cmux-next/build-web-bundles.sh
grep -q "$INSPECTOR" "$TMP/bundles-inspector.log" || fail "bundles-inspector: the message does not name $INSPECTOR"

echo "web-bundles-readonly-sources: ok"
