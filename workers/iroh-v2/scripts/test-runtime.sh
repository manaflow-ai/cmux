#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Each suite owns workerd processes and persistent test storage. Separate Bun
# processes prevent a disposed Miniflare runtime from affecting the next suite.
for test_file in e2e/*.test.ts; do
  bun test "$test_file"
done
