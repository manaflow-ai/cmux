#!/usr/bin/env bash
set -u
root="$PWD"
base_sha=1295f1ce27080bcb4139965eb537bbec770b7eba
git fetch --no-tags origin "$base_sha"
red=$(mktemp -d)
cleanup() { git worktree remove --force "$red" >/dev/null 2>&1 || true; }
trap cleanup EXIT
git worktree add --detach "$red" "$base_sha"
ln -s "$root/webviews/node_modules" "$red/webviews/node_modules"
for phase in before after; do
  if [ "$phase" = before ]; then dir="$red/webviews"; else dir="$root/webviews"; fi
  cd "$dir"
  CMUX_BROWSER_TESTS=1 bun test test/agent-pane-jump-latest-motion.test.ts > "$root/jump-latest-$phase.log" 2>&1
  status=$?
  printf 'JUMP_LATEST_%s_STATUS=%s\n' "$(printf '%s' "$phase" | tr '[:lower:]' '[:upper:]')" "$status"
  tail -100 "$root/jump-latest-$phase.log"
done
exit 1
