#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep this check about executable dependencies. Documentation may mention the
# forbidden systems when it explains the boundary.
if rg -n --glob '*.ts' --glob '*.toml' \
  'CMUX_WEB_BASE_URL|Hyperdrive|cloudDb|from .*web/services|import\(.*web/services|from .*vercel' \
  workers/presence/src workers/presence/wrangler.toml workers/presence/wrangler.dev.toml; then
  echo "presence Worker has a forbidden Vercel or external database dependency" >&2
  exit 1
fi
echo "presence Worker boundary OK"
