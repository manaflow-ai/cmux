#!/usr/bin/env bash
# scripts/ci/tests/package-test-lane-probe-host.test.sh: `package-test-lane.sh
# probe-host` prints every readiness key, exits 0 on a host without Xcode or
# simctl (Linux CI), and changes nothing in the checkout.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$ROOT"
before=$(git status --porcelain)
out=$(bash scripts/ci/package-test-lane.sh probe-host)
fails=0
for key in host os ram_gib work_volume_free_gib work_volume_total_gib xcode_apps xcode_select developer_dir xcodebuild runtime_builds simslim; do
  if ! grep -q "^probe-host $key=" <<<"$out"; then
    echo "FAIL: probe-host printed no $key line; output: $out" >&2; fails=$((fails + 1))
  fi
done
if ! grep -Eq '^probe-host work_volume_free_gib=[0-9]+$' <<<"$out"; then
  echo "FAIL: work_volume_free_gib is not a number; output: $out" >&2; fails=$((fails + 1))
fi
if [ "$(git status --porcelain)" != "$before" ]; then
  echo "FAIL: probe-host changed the checkout" >&2; fails=$((fails + 1))
fi
if [ "$fails" -ne 0 ]; then exit 1; fi
echo "package-test-lane probe-host: ok"
