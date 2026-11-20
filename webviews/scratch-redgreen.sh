#!/usr/bin/env bash
# Scratch, not committed: the row-arm regression test red on the old SubagentTray, then green with the
# relevant composer-hat and subagent-tray suites.
cd "$(dirname "$0")"
F=src/agent-session/acpmux/subagents/SubagentTray.tsx
cp "$F" /tmp/fixed.tsx
git show 23170868abb3f8eda47d1541da8375f32d795a19:webviews/"$F" > "$F"
echo "=== RED (SubagentTray.tsx at 2317086)"
bun test test/composer-hat-open-row.test.tsx 2>&1 | tail -25
cp /tmp/fixed.tsx "$F"
echo "=== GREEN"
files=$(ls test/composer-hat-*.test.ts* test/subagent-tray*.test.ts*)
CMUX_BROWSER_TESTS=1 bun test $files 2>&1 | grep -E "^\(fail\)|^ *[0-9]+ (pass|fail|skip)|^Ran |error:" | tail -40
