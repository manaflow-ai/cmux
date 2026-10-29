#!/usr/bin/env bash
set -euo pipefail

# The canonical Workers are renamed in place so their Durable Object data is
# retained. These aliases preserve old app builds until they age out.
cd "$(dirname "$0")/.."
bun scripts/check-compatibility-aliases.ts

for pair in \
  "cmux-iroh-v2:cmux-v2" \
  "cmux-iroh-v2-staging:cmux-v2-staging" \
  "cmux-iroh-v2-development:cmux-v2-development"; do
  old_name="${pair%%:*}"
  canonical_name="${pair##*:}"
  config_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-v2-alias.XXXXXX")"
  config="$config_dir/wrangler.jsonc"
  cat >"$config" <<JSON
{
  "\$schema": "$(pwd)/node_modules/wrangler/config-schema.json",
  "name": "$old_name",
  "main": "$(pwd)/aliases/index.ts",
  "compatibility_date": "2026-09-10",
  "workers_dev": true,
  "preview_urls": false,
  "services": [{ "binding": "CANONICAL", "service": "$canonical_name" }]
}
JSON
  echo "Deploying compatibility alias: $old_name -> $canonical_name"
  bunx wrangler deploy --config "$config"
done
