#!/usr/bin/env bash
set -euo pipefail
task_root="$PWD"
show_frames() {
  TASK_CAPTURE_PATH="$1" TASK_CAPTURE_PHASE="$2" python3 - <<'PY'
import hashlib, json, os
from pathlib import Path
root = Path(os.environ['TASK_CAPTURE_PATH'])
frames = []
for p in sorted(root.glob('page-*-frame-*.png')):
    frames.append({"phase": os.environ["TASK_CAPTURE_PHASE"], "name": p.name, "bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()})
print("CMUX_PAGING_CAPTURE_SUMMARY=" + json.dumps({"phase": os.environ["TASK_CAPTURE_PHASE"], "count": len(frames), "frames": frames}, separators=(",", ":")), flush=True)
PY
}
base_sha=1295f1ce27080bcb4139965eb537bbec770b7eba
# The baseline must fail the regression assertions; capture its measured receipts and continue.
git fetch --no-tags origin "$base_sha"
task_red=$(mktemp -d)
cleanup() { git worktree remove --force "$task_red" >/dev/null 2>&1 || true; }
trap cleanup EXIT
git worktree add --detach "$task_red" "$base_sha"
ln -s "$task_root/webviews/node_modules" "$task_red/webviews/node_modules"
cp "$task_root/webviews/scripts/agent-pane/backward-anchor.harness.ts" "$task_red/webviews/scripts/agent-pane/backward-anchor.harness.ts"
cd "$task_red/webviews"
bun scripts/pages/gen-strings.mjs --best-effort
set +e
CMUX_BROWSER_TESTS=1 CMUX_PAGING_CAPTURE_DIR="$task_root/paging-before" bun scripts/agent-pane/backward-anchor.harness.ts > "$task_root/paging-before.log" 2>&1
before_status=$?
set -e
printf 'PAGING_BEFORE_STATUS=%s\n' "$before_status"
cat "$task_root/paging-before.log"
show_frames "$task_root/paging-before" before
if [ "$before_status" -eq 0 ]; then
  echo 'expected the untouched baseline to fail the paging assertions' >&2
  exit 1
fi
if ! grep -q '"receipts"' "$task_root/paging-before.log"; then
  echo 'baseline did not emit paging receipts' >&2
  exit 1
fi
cd "$task_root/webviews"
bun scripts/pages/gen-strings.mjs --best-effort
set +e
CMUX_BROWSER_TESTS=1 CMUX_PAGING_CAPTURE_DIR="$task_root/paging-after" bun scripts/agent-pane/backward-anchor.harness.ts > "$task_root/paging-after.log" 2>&1
after_status=$?
set -e
printf 'PAGING_AFTER_STATUS=%s\n' "$after_status"
cat "$task_root/paging-after.log"
show_frames "$task_root/paging-after" after
if [ "$after_status" -ne 0 ]; then
  echo 'paging repair did not pass the harness' >&2
  exit "$after_status"
fi
bun scripts/agent-pane/scroll-anchor.pure.ts
bun test src/agent-session/acpmux/conversation/scrollAnchor.test.ts
bun test test/transcript-older-history-at-top.test.tsx
bun test test/transcript-older-history-retry.test.tsx
bun test test/transcript-older-history-once.test.tsx
CMUX_BROWSER_TESTS=1 bun test test/agent-pane-history-paging.test.ts
CMUX_BROWSER_TESTS=1 bun test test/agent-pane-jump-latest-motion.test.ts
# Compare the focused top-page regression on untouched base and the repaired source; preserve both statuses.
base_test_out="$task_root/history-top-before.log"
current_test_out="$task_root/history-top-after.log"
cd "$task_red/webviews"
set +e
CMUX_BROWSER_TESTS=1 bun test test/transcript-older-history-at-top.test.tsx > "$base_test_out" 2>&1
base_test_status=$?
set -e
printf 'HISTORY_TOP_BEFORE_STATUS=%s\n' "$base_test_status"
tail -80 "$base_test_out"
cd "$task_root/webviews"
set +e
CMUX_BROWSER_TESTS=1 bun test test/transcript-older-history-at-top.test.tsx > "$current_test_out" 2>&1
current_test_status=$?
set -e
printf 'HISTORY_TOP_AFTER_STATUS=%s\n' "$current_test_status"
tail -80 "$current_test_out"
if [ "$current_test_status" -ne 0 ]; then
  echo 'focused history top regression remains red on the repaired source' >&2
  exit "$current_test_status"
fi
