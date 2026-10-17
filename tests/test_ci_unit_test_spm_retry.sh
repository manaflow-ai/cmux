#!/usr/bin/env bash
# The legacy filename stays wired into workflow-guard-tests. Its contract now
# protects the build-once/test-many path: SwiftPM resolution belongs to compile
# admission, while the product consumer (cli-product-tests, the shell
# regressions) only restores the compiled product.
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
consumer = job("cli-product-tests")
restore = Path("scripts/ci/restore-app-host-test-product.sh").read_text(encoding="utf-8")

acpmux_step = re.search(
    r"(?ms)^      - name: Build in-tree acpmux for compile admission\n(.*?)(?=^      - name: |\Z)",
    admission,
)
assert acpmux_step is not None, "compile admission must build acpmux before Xcode"
assert 'scripts/cmux-next/build-acpmux.sh --output "$acpmux_bin"' in acpmux_step.group(1)
assert 'echo "CMUX_NEXT_ACPMUX_BIN=$acpmux_bin" >> "$GITHUB_ENV"' in acpmux_step.group(1)
assert admission.index(acpmux_step.group(0)) < admission.index("Compile app-host test product")

# Admission drives the canonical-root recipes; the bare subcommands remain for
# callers that already sit at a stable source root.
assert "scripts/ci/compile-app-host-test-product.sh canonical-resolve" in admission
assert "scripts/ci/compile-app-host-test-product.sh canonical-build" in admission
assert "Restore compiled test product" in consumer

for forbidden in (
    "-resolvePackageDependencies",
    ".ci-source-packages",
    "-project cmux.xcodeproj",
):
    assert forbidden not in consumer, f"product consumer reintroduced {forbidden}"

assert "app_host_test_products.py restore" in restore

print(
    "PASS: SwiftPM resolution stays in compile admission; "
    "the product consumer restores compiled products"
)
PY
