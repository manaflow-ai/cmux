set -o pipefail
cd webviews
rc=0
for f in test/reload-first-frame-folds.test.tsx test/chat-sim.test.ts test/restore-monotonic-trace.test.tsx test/agent-pane-cached-chat-open.test.ts test/agent-pane-new-tab-cached-chat.test.ts test/agent-pane-turn-end-keeps-place.test.ts; do
  echo "== FIX: $f"
  bun test "$f" > /tmp/out.txt 2>&1 || rc=1
  grep -E "^\(fail\)|^ *[0-9]+ (pass|fail)" /tmp/out.txt
  grep -B2 -A40 -m3 "^error:" /tmp/out.txt | head -150
done
echo "== FIX: typecheck"
bun run typecheck 2>&1 | tail -30
echo "== FIX: fmt"
FILES="src/agent-session/acpmux/App.tsx src/agent-session/acpmux/direct.ts src/agent-session/acpmux/tailCache.ts src/agent-session/acpmux/model.ts src/agent-session/acpmux/sim/scenarios.ts test/chat-sim.test.ts test/reload-first-frame-folds.test.tsx"
mkdir -p /tmp/prefmt
for f in $FILES; do mkdir -p "/tmp/prefmt/$(dirname $f)"; cp "$f" "/tmp/prefmt/$f"; done
bun run fmt $FILES 2>&1 | tail -5
for f in $FILES; do diff -u "/tmp/prefmt/$f" "$f" | sed "s|^|FMTPATCH|"; cp "/tmp/prefmt/$f" "$f"; done
echo "== BASELINE (fix reverted)"
git -C .. apply -R webviews/scratch-remount-fix.patch || exit 9
for f in test/reload-first-frame-folds.test.tsx; do
  echo "== BASE: $f"
  bun test "$f" > /tmp/out.txt 2>&1
  grep -E "^\(fail\)|^ *[0-9]+ (pass|fail)" /tmp/out.txt
  grep -B2 -A30 -m2 "^error:" /tmp/out.txt | head -80
done
exit $rc
