#!/usr/bin/env bash
# Fails when a CmuxNext target uses `Bundle.module` (or `bundle: .module`) or
# holds resource files (.xcstrings, Resources/) without declaring `resources:`
# in Package.swift. Without the declaration SwiftPM generates no module bundle
# and the build fails with "'module' is inaccessible" only after a full compile.
# Test targets that `@testable import` another module may use that module's
# bundle and are skipped when they hold no resource files of their own.
# Usage: scripts/cmux-next/check-module-resources.sh [package-dir]
set -euo pipefail
pkg="${1:-$(git rev-parse --show-toplevel)/Packages/macOS/CmuxNext}"
exec python3 - "$pkg" <<'PY'
import pathlib, re, sys

pkg = pathlib.Path(sys.argv[1])
manifest = (pkg / "Package.swift").read_text()
uses_module = re.compile(r"Bundle\.module|bundle:\s*\.module")


def code(path):
    """Source text without // comments, so doc comments that mention Bundle.module do not count."""
    return "\n".join(line.split("//", 1)[0] for line in path.read_text(errors="ignore").splitlines())
failures = []
for m in re.finditer(r'\.(target|testTarget)\(\s*name:\s*"([^"]+)"(.*?)\n        \)', manifest, re.S):
    kind, name, body = m.groups()
    src = pkg / ("Tests" if kind == "testTarget" else "Sources") / name
    if not src.is_dir() or "resources:" in body:
        continue
    files = [p for p in src.rglob("*") if p.is_file()]
    resources = [p for p in files if p.suffix == ".xcstrings" or "Resources" in p.relative_to(src).parts[:-1]]
    swift = [p for p in files if p.suffix == ".swift"]
    users = [p for p in swift if uses_module.search(code(p))]
    testable = kind == "testTarget" and any("@testable import" in code(p) for p in users)
    if resources or (users and not testable):
        what = ", ".join(sorted({str(p.relative_to(src)) for p in (resources or users)})[:4])
        failures.append(f"{name}: declares no resources: but has {what}")
for f in failures:
    print(f"check-module-resources: {f}", file=sys.stderr)
if failures:
    print("Add `resources: [.process(...)]` to these targets in Package.swift.", file=sys.stderr)
    sys.exit(1)
print("check-module-resources: ok")
PY
