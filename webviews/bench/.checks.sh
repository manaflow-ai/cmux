#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
F="src/agent-session/acpmux/chips/FactsCard.tsx src/agent-session/acpmux/chips/FactsHoverCard.tsx src/agent-session/acpmux/composer/LazyPromptEditor.tsx src/agent-session/acpmux/markdownFieldFrame.tsx src/agent-session/acpmux/MarkdownField.tsx src/pages/home-channels/Composer.tsx test/preload.ts src/pages/home-channels/styles.css"
bun run typecheck; echo "typecheck rc=$?"
npx vp fmt --check $F; echo "fmt rc=$?"
npx vp lint $F; echo "lint rc=$?"
CMUX_WEB_TEST_FILES="$(cat bench/.tests.txt)" bash ../scripts/ci/run-webviews-tests.sh; echo "tests rc=$?"
