#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
F="src/agent-session/acpmux/composer/LazyPromptEditor.tsx src/agent-session/acpmux/markdownFieldFrame.tsx src/pages/home-channels/styles.css test/home-composer-lazy-editor.test.tsx"
echo "=== new test"; timeout 200 bun test test/home-composer-lazy-editor.test.tsx 2>&1 | grep -avE "^\s*$" | tail -60; echo "new test rc=${PIPESTATUS[0]}"
bun run typecheck 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "×|⚠|╭─|Found"; echo "typecheck done"
bunx vp fmt $F >/dev/null 2>&1; echo "=== fmt diff"; git -C .. diff -- webviews/src webviews/test | head -80; echo "=== fmt diff end"
bunx vp lint $F 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -30; echo "lint rc=${PIPESTATUS[0]}"
python3 ../scripts/cmux-next/check-focus-routes.py 2>&1 | tail -5; echo "focus-routes rc=${PIPESTATUS[0]}"
echo "=== related"
CMUX_WEB_TEST_FILES="$(ls test/home-*.test.tsx test/composer-*.test.tsx test/web-sources-follow-ups.test.tsx test/keybindings-page.test.tsx)" CMUX_WEB_TEST_RETRIES=0 bash ../scripts/ci/run-webviews-tests.sh > /tmp/rel.log 2>&1; echo "related rc=$?"
grep -aE "^(FAIL|TIMEOUT) |### webviews" /tmp/rel.log
echo "=== hat-plan AFTER"; timeout 150 bun test test/composer-hat-plan.test.tsx 2>&1 | grep -aE "\(fail\)|error:|Expected|Received| pass$| fail$" | head -20
git -C .. checkout -- webviews/src webviews/test/preload.ts webviews/test/support; git -C .. apply -R webviews/bench/.lazy-cut.patch; echo "revert rc=$?"
echo "=== hat-plan BEFORE"; timeout 150 bun test test/composer-hat-plan.test.tsx 2>&1 | grep -aE "\(fail\)|error:|Expected|Received| pass$| fail$" | head -20
echo "checks9 done"
