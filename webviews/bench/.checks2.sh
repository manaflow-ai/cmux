#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
F="src/agent-session/acpmux/chips/FactsCard.tsx src/agent-session/acpmux/chips/FactsHoverCard.tsx src/agent-session/acpmux/composer/LazyPromptEditor.tsx src/agent-session/acpmux/markdownFieldFrame.tsx src/agent-session/acpmux/MarkdownField.tsx src/pages/home-channels/Composer.tsx src/pages/home-channels/styles.css test/preload.ts"
bun run typecheck 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "×|⚠|╭─|Found"; echo "typecheck done"
bunx vp fmt --check $F; echo "fmt rc=$?"
bunx vp lint $F; echo "lint rc=$?"
echo "=== AFTER tests"
CMUX_WEB_TEST_FILES="$(cat bench/.failed.txt)" CMUX_WEB_TEST_RETRIES=0 bash ../scripts/ci/run-webviews-tests.sh 2>&1 | grep -aE "^(PASS|FAIL|TIMEOUT) |### webviews"
git -C .. apply -R webviews/bench/.lazy-cut.patch; echo "revert rc=$?"
echo "=== BEFORE tests"
CMUX_WEB_TEST_FILES="$(cat bench/.failed.txt)" CMUX_WEB_TEST_RETRIES=0 bash ../scripts/ci/run-webviews-tests.sh 2>&1 | grep -aE "^(PASS|FAIL|TIMEOUT) |### webviews"
echo "checks2 done"
