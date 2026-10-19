#!/usr/bin/env bash
set -euo pipefail

files=(
  tests/runtime-model.test.ts
  tests/persistent-workspace.test.ts
  tests/persistent-workspace-route.test.ts
  tests/run-attempt-promotion.test.ts
)
for file in "${files[@]}"; do
  echo "==> bun test $file"
  bun test "$file"
done
