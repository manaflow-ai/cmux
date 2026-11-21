set -u
cd "$(dirname "$0")/.."
echo "=== new test"; bun test test/typography-baseline-browser.test.ts 2>&1 | grep -E "^\(pass\)|^\(fail\)|Expected|Received| pass| fail"
echo "=== lanes"; bun run check:browser-lanes 2>&1 | tail -3
echo "=== biome"; bunx biome check src/ui/typography.css src/ui/Typography.gallery.tsx src/agent-session/acpmux/ForkPendingLine.tsx test/typography-baseline-browser.test.ts test/browser/typography-baseline.harness.tsx 2>&1 | tail -20
echo "=== tsc"; bunx tsc --noEmit -p . 2>&1 | grep -E "Typography|ForkPending|typography-baseline" | head
echo "=== tsc test"; ls tsconfig*.json; for c in tsconfig*.json; do bunx tsc --noEmit -p $c 2>&1 | grep -E "typography-baseline|Typography.gallery" | head -5; done
echo "=== gallery capture"; bun scripts/gallery/capture-states.mjs .scratch-clock/shots.json "$FAST_CHECKS_OUT" 2>&1 | tail -20
exit 0
