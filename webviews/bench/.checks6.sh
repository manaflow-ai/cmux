#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
F="src/agent-session/acpmux/composer/LazyPromptEditor.tsx"
bun run typecheck 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "×|╭─|Found"; echo "typecheck done"
bunx vp fmt --check $F; echo "fmt rc=$?"
bunx vp lint $F 2>&1 | tail -3; echo "lint rc=${PIPESTATUS[0]}"
python3 ../scripts/cmux-next/check-focus-routes.py --help >/dev/null 2>&1; echo "focus-routes present"
CMUX_WEB_TEST_FILES="$(ls test/home-*.test.tsx test/composer-*.test.tsx test/web-sources-follow-ups.test.tsx test/keybindings-page.test.tsx)" CMUX_WEB_TEST_RETRIES=0 bash ../scripts/ci/run-webviews-tests.sh 2>&1 | grep -aE "^(FAIL|TIMEOUT) |### webviews"
echo "checks6 done"
