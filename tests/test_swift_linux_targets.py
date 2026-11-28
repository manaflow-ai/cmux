#!/usr/bin/env python3
"""scripts/ci/swift_linux_targets.py: the Linux Swift target ratchet (B5 of the Linux map).

- the listed Linux targets (scripts/ci/swift-linux-targets.txt) number at least the floor
  (scripts/ci/swift-linux-targets-floor.txt), so the count only goes up;
- every listed row names a package a Linux job builds and a target its manifest declares, once;
- swift-linux-packages.yml's `linux-targets` job runs `--verify` (the dump-package receipt);
- the source scan counts only the imports a Linux debug build compiles (each `#if` evaluated for
  Linux) and an Apple-only one among them as the target's blocker, and a target that depends on a blocked one as blocked too.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/swift_linux_targets.py"

spec = importlib.util.spec_from_file_location("swift_linux_targets", SCRIPT)
mod = importlib.util.module_from_spec(spec)
assert spec.loader
sys.modules["swift_linux_targets"] = mod
spec.loader.exec_module(mod)


def check_floor(failures: list[str]) -> None:
    res = subprocess.run([sys.executable, str(SCRIPT), "--check"], capture_output=True, text=True)
    if res.returncode != 0:
        failures.append(f"--check failed: {res.stderr.strip()}")
    if mod.read_floor() <= 0:
        failures.append("the floor file has no count")


def check_rows(failures: list[str]) -> None:
    linux = mod.linux_packages()
    rows = [
        tuple(line.split()[:2])
        for line in mod.TARGETS.read_text().splitlines()
        if line.strip() and not line.startswith("#")
    ]
    if len(rows) != len(set(rows)):
        failures.append("swift-linux-targets.txt repeats a row")
    if rows != sorted(rows):
        failures.append("swift-linux-targets.txt is not sorted (regenerate it with --write-list)")
    declared: dict[str, set[str]] = {}
    for pkg, name in rows:
        if pkg not in linux:
            failures.append(f"{pkg} {name}: no Linux job builds {pkg} (swift-linux-packages.txt or the workflow)")
            continue
        if pkg not in declared:
            ts, _, _ = mod.parse_manifest(ROOT / pkg / "Package.swift")
            declared[pkg] = {t.name for t in ts}
        if name not in declared[pkg]:
            failures.append(f"{pkg} {name}: the manifest declares no such target")


def check_workflow(failures: list[str]) -> None:
    wf = mod.WORKFLOW.read_text()
    m = re.search(r"\n  linux-targets:\n(.*?)(?=\n  [a-z][\w-]*:\n|\Z)", wf, re.S)
    if not m:
        failures.append("swift-linux-packages.yml has no linux-targets job")
        return
    if "scripts/ci/swift_linux_targets.py --verify" not in m.group(1):
        failures.append("the linux-targets job does not run swift_linux_targets.py --verify")
    if "MAC_FALLBACK" in m.group(1) or "continue-on-error" in m.group(1):
        failures.append("the linux-targets job must fail on its own: no Mac fallback, no continue-on-error")
    for path in ("scripts/ci/swift-linux-targets.txt", "scripts/ci/swift_linux_targets.py"):
        if path not in wf:
            failures.append(f"swift-linux-packages.yml's paths filter lacks {path}")


def check_scan(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "Sources/A").mkdir(parents=True)
        (root / "Sources/B").mkdir(parents=True)
        (root / "Sources/C").mkdir(parents=True)
        (root / "Sources/A/a.swift").write_text(
            "import Foundation\n#if canImport(AppKit)\nimport AppKit\n#else\nimport Glibc\n#endif\n"
            "#if os(macOS)\n@preconcurrency import os\n#endif\n"
        )
        (root / "Sources/B/b.swift").write_text("import Foundation\n@_exported import struct SwiftUI.Color\n")
        (root / "Sources/C/c.swift").write_text(
            "public import AppKit\n#if os(macOS) || DEBUG\nimport Darwin\n#endif\n"
            "#if os(iOS)\nimport UIKit\n#elseif os(Linux)\nimport Glibc\n#else\nimport WebKit\n#endif\n"
        )
        old = mod.ROOT
        mod.ROOT = root
        try:
            a = mod.Target(package=".", name="A", type="target", path="Sources/A")
            b = mod.Target(package=".", name="B", type="target", path="Sources/B")
            c = mod.Target(package=".", name="C", type="target", path="Sources/C")
            for t in (a, b, c):
                mod.scan_imports(t)
        finally:
            mod.ROOT = old
        if any(mod.import_kind(m) for m in a.imports):
            failures.append(f"guarded imports counted as blockers: {sorted(a.imports)}")
        if "SwiftUI" not in b.imports or mod.import_kind("SwiftUI") != "swiftui":
            failures.append(f"`@_exported import struct SwiftUI.Color` not seen: {sorted(b.imports)}")
        if mod.import_kind("Darwin") != "darwin":
            failures.append("import Darwin is not the darwin class")
        # A Linux debug build compiles `public import`, an `#if ... || DEBUG` branch and `#elseif os(Linux)`.
        if set(c.imports) != {"AppKit", "Darwin", "Glibc"}:
            failures.append(f"imports a Linux debug build compiles: {sorted(c.imports)} != ['AppKit', 'Darwin', 'Glibc']")
    manifest = """
let package = Package(name: "P", targets: [
    .target(name: "Core", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
    .target(name: "UI", dependencies: ["Core", .target(name: "Extra")], path: "Sources/TheUI"),
    .testTarget(name: "CoreTests", dependencies: ["Core"]),
    // A `//` in a string (a binary target's URL) is not a comment: the targets after it count.
    .binaryTarget(name: "Bin", url: "https://example.com/Bin.xcframework.zip", checksum: "00"),
    .target(name: "AfterBin", dependencies: ["Bin"]),
    // A dependency only some other platform links is no Linux dependency; one that names .linux is.
    .target(name: "Gated", dependencies: ["Core", .target(name: "Bin", condition: .when(platforms: [.iOS])),
        .product(name: "Lx", package: "lx", condition: .when(platforms: [.linux, .macOS]))]),
])
"""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "Package.swift").write_text(manifest)
        old = mod.ROOT
        mod.ROOT = root
        try:
            ts, _, _ = mod.parse_manifest(root / "Package.swift")
        finally:
            mod.ROOT = old
        got = {t.name: (t.type, t.path, sorted(t.deps)) for t in ts}
        want = {
            "Core": ("target", "./Sources/Core", ["product:swift-crypto:Crypto"]),
            "UI": ("target", "./Sources/TheUI", ["Core", "Extra"]),
            "CoreTests": ("testTarget", "./Tests/CoreTests", ["Core"]),
            "Bin": ("binaryTarget", "./Sources/Bin", []),
            "AfterBin": ("target", "./Sources/AfterBin", ["Bin"]),
            "Gated": ("target", "./Sources/Gated", ["Core", "product:lx:Lx"]),
        }
        if got != want:
            failures.append(f"parse_manifest: {got} != {want}")


def main() -> int:
    failures: list[str] = []
    check_floor(failures)
    check_rows(failures)
    check_workflow(failures)
    check_scan(failures)
    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        return 1
    print("test_swift_linux_targets: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
