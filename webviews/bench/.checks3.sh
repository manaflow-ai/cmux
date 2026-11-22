#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
F="src/agent-session/acpmux/chips/FactsCard.tsx src/agent-session/acpmux/chips/FactsHoverCard.tsx src/agent-session/acpmux/composer/LazyPromptEditor.tsx src/agent-session/acpmux/markdownFieldFrame.tsx src/agent-session/acpmux/MarkdownField.tsx src/pages/home-channels/Composer.tsx src/pages/home-channels/styles.css src/lazyChunk.ts test/preload.ts test/support/factsCard.ts"
bun run typecheck 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "×|⚠|╭─|Found"; echo "typecheck done"
bunx vp fmt $F >/dev/null 2>&1; echo "=== fmt diff"; git -C .. diff -- webviews/src; echo "=== fmt diff end"
bunx vp lint $F 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -30; echo "lint rc=${PIPESTATUS[0]}"
echo "=== AFTER related tests"
CMUX_WEB_TEST_FILES="$(cat bench/.tests.txt)" CMUX_WEB_TEST_RETRIES=0 bash ../scripts/ci/run-webviews-tests.sh > /tmp/after.log 2>&1
grep -aE "^(PASS|FAIL|TIMEOUT) |### webviews" /tmp/after.log | grep -v PASS
for f in $(grep -aE "^FAIL .*limit" /tmp/after.log | awk '{print $2}'); do
  grep -qxF "$f" bench/.basefailed.txt && continue
  echo "=== NEW FAIL $f"; timeout 150 bun test "$f" 2>&1 | grep -aE "\(fail\)|error|Expected|Received|^\s+at .*test" | head -40
done
echo "=== session-info-placement AFTER"
CMUX_WEB_TEST_FILES="test/agent-pane-attach-huge-files.test.ts" CMUX_WEB_TEST_RETRIES=0 bash ../scripts/ci/run-webviews-tests.sh 2>&1 | grep -aE "^(PASS|FAIL|TIMEOUT) |### webviews"
git -C .. checkout -- webviews/src webviews/test; git -C .. apply -R webviews/bench/.lazy-cut.patch; echo "revert rc=$?"
echo "=== session-info-placement BEFORE"
CMUX_WEB_TEST_FILES="test/agent-pane-attach-huge-files.test.ts" CMUX_WEB_TEST_RETRIES=0 bash ../scripts/ci/run-webviews-tests.sh 2>&1 | grep -aE "^(PASS|FAIL|TIMEOUT) |### webviews"
echo "checks3 done"
