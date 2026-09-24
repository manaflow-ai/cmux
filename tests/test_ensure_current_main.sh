#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git init -q "$TMP/main"; git -C "$TMP/main" config user.email test@example.com; git -C "$TMP/main" config user.name test
git -C "$TMP/main" checkout -qb main; echo one > "$TMP/main/file"; git -C "$TMP/main" add file; git -C "$TMP/main" commit -qm one
mkdir "$TMP/remote.git"; git -C "$TMP/remote.git" init --bare -q; git -C "$TMP/main" remote add origin "$TMP/remote.git"; git -C "$TMP/main" push -qu origin main
git clone -q "$TMP/remote.git" "$TMP/build"; git -C "$TMP/build" checkout -qb feature
echo two > "$TMP/build/change"; git -C "$TMP/build" add change; git -C "$TMP/build" commit -qm feature
# Place helper beside a project checkout and provide the main worktree via linked worktree.
mkdir "$TMP/build/scripts"; cp "$ROOT/scripts/ensure-current-main.sh" "$TMP/build/scripts/"
git -C "$TMP/build" worktree add -q "$TMP/primary" main
echo latest > "$TMP/primary/latest"; git -C "$TMP/primary" add latest; git -C "$TMP/primary" commit -qm latest; git -C "$TMP/primary" push -qu origin main
if git -C "$TMP/build" rev-parse --show-toplevel >/dev/null; (cd "$TMP/build" && bash scripts/ensure-current-main.sh) >/tmp/ensure-current-main.out 2>&1; then
  echo 'FAIL: stale feature checkout was accepted' >&2; exit 1
fi
grep -q 'build checkout is stale' /tmp/ensure-current-main.out || { cat /tmp/ensure-current-main.out; exit 1; }
echo PASS
