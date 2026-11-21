set -u
cd "$(dirname "$0")/.."
echo "=== new test, fixed CSS"; bun test test/typography-baseline-browser.test.ts 2>&1 | tail -25
echo "=== unit tests"; bun test src/agent-session/acpmux/hostLineHandover.test.tsx src/agent-session/acpmux/TaskGoalStrip.test.tsx src/ui/Typography.test.tsx src/agent-session/acpmux/HostError.test.tsx 2>&1 | tail -8
echo "=== lanes"; bun run check:browser-lanes 2>&1 | tail -5
echo "=== tsc"; bunx tsc --noEmit -p . 2>&1 | grep -E "Typography|ForkPending|typography-baseline" | head
echo "=== after probe"; bun .scratch-clock/probe.mjs 2>&1 | grep '"engine"' 
mkdir -p "$FAST_CHECKS_OUT/after" && for f in "$FAST_CHECKS_OUT"/*.png; do mv "$f" "$FAST_CHECKS_OUT/after/"; done
echo "=== new test, OLD CSS (must fail)"
python3 - <<'PY'
p='src/ui/typography.css'; s=open(p).read(); s=s.replace('.ui-clock::before {','.ui-clock::after {'); open(p,'w').write(s)
PY
bun test test/typography-baseline-browser.test.ts 2>&1 | grep -E "pass|fail|Expected|Received" | head -30
exit 0
