#!/usr/bin/env bash
# Drop-to-ready and drop-to-dispatch in the production composer, using a loopback native host.
#   cmux-ci run --os linux --class exclusive --script scripts/measure/composer-attachment.sh --ref <sha>
#   cmux-ci test --setup webviews -- bash scripts/measure/composer-attachment.sh
# Compare another revision with scripts/measure/composer-attachment.sh /absolute/path/to/its/webviews.
# For duress, repeat both sizes while long-300 chat-sim runs on the same allocated Linux CPU:
#   CMUX_ATTACHMENT_DURESS=1 taskset -c CPU bash scripts/measure/composer-attachment.sh [WEBVIEWS]
set -euo pipefail
cd "$(dirname "$0")/../../webviews"
[[ -d node_modules/vite ]] || bun install --frozen-lockfile
exec bun bench/composer-attachment.bench.ts "$@"
