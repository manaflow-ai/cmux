#!/usr/bin/env bash
# The legacy filename stays wired into workflow-guard-tests. Its contract now
# protects the build-once/test-many path: SwiftPM resolution belongs to compile
# admission, while app-host shards execute only the restored compiled product.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import re

workflow = Path(".github/workflows/ci-macos.yml").read_text(encoding="utf-8")

def job(name: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        workflow,
    )
    if match is None:
        raise AssertionError(f"missing workflow job {name}")
    return match.group(0)

admission = job("macos-compile-admission")
consumer = job("app-host-unit-tests")
restore = Path("scripts/ci/restore-app-host-test-product.sh").read_text(encoding="utf-8")

assert "scripts/ci/compile-app-host-test-product.sh resolve" in admission
assert "scripts/ci/compile-app-host-test-product.sh build" in admission
assert "Restore compiled app-host test product" in consumer
assert "test-without-building" in consumer

for forbidden in (
    "-resolvePackageDependencies",
    ".ci-source-packages",
    "-project cmux.xcodeproj",
):
    assert forbidden not in consumer, f"app-host consumer reintroduced {forbidden}"

assert "PackageFrameworks" in restore
assert "app_host_test_products.py restore" in restore

print(
    "PASS: SwiftPM resolution stays in compile admission; "
    "app-host shards consume restored compiled products"
)
PY
