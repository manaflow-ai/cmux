#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
F="src/agent-session/acpmux/chips/FactsCard.tsx src/agent-session/acpmux/chips/FactsHoverCard.tsx src/lazyChunk.ts test/preload.ts test/support/factsCard.ts"
bun run typecheck 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "×|⚠|╭─|Found"; echo "typecheck done"
bunx vp fmt --check $F; echo "fmt rc=$?"
bunx vp lint $F 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -5; echo "lint rc=${PIPESTATUS[0]}"
TESTS="$(grep -rl 'support/factsCard' test | grep -v support/; ls test/home-*.test.tsx test/home-*.test.ts 2>/dev/null)"
TESTS="$(echo "$TESTS" | sort -u)"; echo "files: $(echo "$TESTS" | wc -l)"
CMUX_WEB_TEST_FILES="$TESTS" CMUX_WEB_TEST_RETRIES=0 bash ../scripts/ci/run-webviews-tests.sh > /tmp/a.log 2>&1; echo "after rc=$?"
grep -aE "^(FAIL|TIMEOUT) |### webviews" /tmp/a.log
git -C .. apply -R webviews/bench/.facts-cut.patch; echo "revert rc=$?"
FAILED="$(grep -aE '^(FAIL|TIMEOUT) .*limit' /tmp/a.log | awk '{print $2}' | sort -u)"
if [ -n "$FAILED" ]; then echo "=== the same files BEFORE"; CMUX_WEB_TEST_FILES="$FAILED" CMUX_WEB_TEST_RETRIES=0 bash ../scripts/ci/run-webviews-tests.sh 2>&1 | grep -aE "^(FAIL|TIMEOUT) |### webviews"; fi
echo "checks10 done"
