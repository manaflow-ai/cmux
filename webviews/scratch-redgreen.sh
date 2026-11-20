#!/usr/bin/env bash
# Scratch, not committed: the row-arm regression test red on the old SubagentTray, then green with the
# relevant composer-hat and subagent-tray suites.
set -o pipefail
cd "$(dirname "$0")"
F=src/agent-session/acpmux/subagents/SubagentTray.tsx
cp "$F" /tmp/fixed.tsx
cp scratch-SubagentTray.old.tsx "$F"
echo "=== RED (SubagentTray.tsx at 2317086)"
bun test test/composer-hat-open-row.test.tsx 2>&1 | grep -v "^ *at \|^[0-9]* |" | tail -40
cp /tmp/fixed.tsx "$F"
echo "=== GREEN own"
bun test test/composer-hat-open-row.test.tsx 2>&1 | grep -v "^ *at \|^[0-9]* |" | tail -40
if [ "${1:-}" = all ]; then
  echo "=== GREEN suites"
  CMUX_BROWSER_TESTS=1 bun test $(ls test/composer-hat-*.test.ts* test/subagent-tray*.test.ts*) 2>&1 | grep -E "^\(fail\)|^ *[0-9]+ (pass|fail|skip)|^Ran |error:" | tail -40
fi
exit 0
