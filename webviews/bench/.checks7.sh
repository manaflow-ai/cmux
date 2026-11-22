#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
echo "=== AFTER"; timeout 150 bun test test/composer-hat-plan.test.tsx 2>&1 | grep -aE "\(fail\)|error:|Expected|Received| pass| fail" | head -20
git -C .. apply -R webviews/bench/.lazy-cut.patch; echo "revert rc=$?"
echo "=== BEFORE"; timeout 150 bun test test/composer-hat-plan.test.tsx 2>&1 | grep -aE "\(fail\)|error:|Expected|Received| pass| fail" | head -20
echo "checks7 done"
