#!/usr/bin/env bash
# Staging deployment: the same checks as production, plus the published
# source revision the health route reports.
set -euo pipefail
cd "$(dirname "$0")/.."

bun run check
bun run test:runtime
# shellcheck disable=SC2046
wrangler deploy --env staging $(bash scripts/source-revision-vars.sh)
echo "staging deployed; verify with: curl -sS https://cmux-iroh-v2-staging.debussy.workers.dev/v2/health"
