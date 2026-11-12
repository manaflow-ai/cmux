#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/cmux-portal-reconciliation.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

# Compile the actual app-owned scheduler and its actual regression tests in a
# headless module. AppKit/Ghostty integration remains in the hosted app suite.
python3 - "$repo_root" "$fixture" <<'PY'
import json
from pathlib import Path
import sys

root, fixture = map(Path, sys.argv[1:])
sources, tests = fixture / "Sources", fixture / "Tests"
sources.mkdir()
tests.mkdir()
for name in ("Reasons", "Request", "Scheduler"):
    path = root / f"Sources/TerminalPortalReconciliation{name}.swift"
    (sources / path.name).symlink_to(path)
path = root / "cmuxTests/TerminalPortalReconciliationReentrancyTests.swift"
(tests / path.name).symlink_to(path)
dependency = json.dumps(str(root / "Packages/Shared/CMUXMobileCore"))
(fixture / "Package.swift").write_text(f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "PortalReconciliationFixture",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: {dependency})],
    targets: [
        .target(name: "cmux", dependencies: ["CMUXMobileCore"], path: "Sources"),
        .testTarget(name: "ReconciliationTests", dependencies: ["cmux", "CMUXMobileCore"], path: "Tests")
    ]
)
''')
PY

swift test --package-path "$fixture" --jobs 2 2>&1 | tee "$fixture/test.log"
grep -Eq 'Test run with [1-9][0-9]* tests? .*passed' "$fixture/test.log"
