#!/usr/bin/env python3
"""Inventory every Swift target and test suite and classify how far each is from building on Linux.

Writes plans/cmux-next/swift-linux-inventory.md (or checks it is current with --check). Sources:
every Package.swift in the repo (SwiftPM targets, test targets, executables, macros, C and binary
targets), the native targets of every .xcodeproj, and the Linux receipts in CI:
scripts/ci/swift-linux-packages.txt and .github/workflows/swift-packages-linux.yml.

Classes, in Leo's words (ask-64314e2230):
  linux    builds on Linux today. "CI" in the proof column means a Linux job builds and tests the
           package on every change; "scan" means nothing it imports needs an Apple-only module
           but no Linux job proves it yet.
  shims    builds with small shims: it imports something with a Linux stand-in (Darwin -> Glibc,
           CryptoKit -> swift-crypto, os/OSLog -> print, CoreGraphics geometry, Combine, a binary
           FFI framework that needs a Linux build of its Rust library), or an unknown module.
  mac      Mac-only (Apple-only): it imports AppKit, SwiftUI, WebKit, UIKit or another Apple
           framework with no Linux counterpart without a #if canImport/os guard, or imports a
           local module that does. Xcode app, extension and UI-test targets are always here.

The scan is per target: an import counts only outside #if blocks that test canImport, os(),
targetEnvironment or arch, and a target inherits the worst class of the local modules it imports.
Manifests are read with regexes, not `swift package dump-package`, so this runs on any host.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "plans/cmux-next/swift-linux-inventory.md"
LINUX_LIST = ROOT / "scripts/ci/swift-linux-packages.txt"
PORTABLE_WORKFLOW = ROOT / ".github/workflows/swift-packages-linux.yml"

LINUX, SHIMS, MAC = 0, 1, 2
CLASS_NAMES = {LINUX: "linux", SHIMS: "shims", MAC: "mac"}

# Ships with the Swift toolchain on Linux, or is a portable package we depend on.
PORTABLE = {
    "Foundation", "FoundationEssentials", "FoundationInternationalization", "FoundationNetworking",
    "Dispatch", "XCTest", "Testing", "Swift", "_Concurrency", "Synchronization", "Observation",
    "RegexBuilder", "Distributed", "CoreFoundation", "Glibc", "Musl", "PackageDescription",
    "Crypto", "Atomics", "NIOCore", "NIOPosix", "NIOSSH", "NIOEmbedded", "NIOHTTP1", "NIOSSL",
    "NIOFoundationCompat", "Logging", "ArgumentParser", "Collections", "Algorithms",
    "OpenAPIRuntime", "OpenAPIURLSession", "HTTPTypes", "StackAuth",
}
# Apple modules with a small Linux stand-in.
SHIMMABLE = {
    "Darwin", "os", "OSLog", "CoreGraphics", "CryptoKit", "CommonCrypto", "Combine",
    "UniformTypeIdentifiers", "SQLite3", "zlib", "Compression", "dnssd", "NIOTransportServices",
}
# Apple frameworks with no Linux counterpart; UI first, then system services.
APPLE_ONLY = {
    "AppKit", "Cocoa", "SwiftUI", "WebKit", "UIKit", "Carbon", "Quartz", "QuartzCore", "Metal",
    "MetalKit", "CoreImage", "CoreText", "CoreVideo", "CoreMedia", "AVFoundation", "AVKit",
    "VideoToolbox", "AudioToolbox", "MediaPlayer", "ScreenCaptureKit", "ImageIO", "IOSurface",
    "ApplicationServices", "CoreServices", "IOKit", "Security", "Network", "CFNetwork",
    "SystemConfiguration", "ServiceManagement", "LocalAuthentication", "AuthenticationServices",
    "UserNotifications", "UserNotificationsUI", "Speech", "Vision", "VisionKit", "NaturalLanguage",
    "Translation", "PhotosUI", "Photos", "QuickLook", "QuickLookThumbnailing", "PDFKit",
    "LinkPresentation", "ContactsUI", "Contacts", "AppIntents", "GameController", "DeviceCheck",
    "JavaScriptCore", "Accelerate", "ObjectiveC", "MachO", "XPC", "Sentry", "Sparkle", "WebRTC",
}
GUARD = re.compile(r"canImport|\bos\(|targetEnvironment|\barch\(")
IMPORT = re.compile(
    r"^\s*(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*import\s+"
    r"(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][A-Za-z0-9_]*)"
)
DECL = re.compile(r"\.(target|testTarget|executableTarget|macro|binaryTarget|systemLibrary)\s*\(")
SKIP_DIRS = {".build", "node_modules", ".git", "DerivedData", ".swiftpm"}


@dataclass
class Target:
    package: str  # repo-relative dir of the Package.swift or .xcodeproj
    name: str
    kind: str
    src: Path | None
    level: int = LINUX
    reasons: list[str] = field(default_factory=list)
    local_imports: set[str] = field(default_factory=set)
    guarded_apple: set[str] = field(default_factory=set)
    proof: str = "scan"


def balanced(text: str, start: int) -> str:
    """The text inside the parenthesis that opens at text[start - 1]."""
    depth, i, in_str = 1, start, False
    while i < len(text) and depth:
        c = text[i]
        if c == "\\" and in_str:
            i += 2
            continue
        if c == '"':
            in_str = not in_str
        elif not in_str:
            depth += c == "("
            depth -= c == ")"
        i += 1
    return text[start : i - 1]


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    # `//` starts a comment only outside a string literal ("https://..." stays).
    return re.sub(r'(?m)^((?:[^"\n/]|"(?:\\.|[^"\\\n])*"|/(?!/))*)//.*$', r"\1", text)


def manifest_targets(manifest: Path) -> list[Target]:
    pkg = manifest.parent
    rel = pkg.relative_to(ROOT).as_posix()
    text = strip_comments(manifest.read_text(errors="replace"))
    out, pos = [], 0
    while m := DECL.search(text, pos):
        body = balanced(text, m.end())
        pos = m.end() + len(body)
        name = re.match(r'\s*name:\s*"([^"]+)"', body)
        if not name:
            continue
        kind = m.group(1)
        path = re.search(r'\bpath:\s*"([^"]+)"', body)
        if kind == "binaryTarget":
            src = None
        elif path:
            src = pkg / path.group(1)
        else:
            src = pkg / ("Tests" if kind == "testTarget" else "Sources") / name.group(1)
        out.append(Target(rel, name.group(1), kind, src))
    # A target made by a helper function: any Sources/Tests dir the regexes did not name.
    named = {t.src.resolve() for t in out if t.src}
    for sub, kind in (("Sources", "target"), ("Tests", "testTarget")):
        for d in sorted((pkg / sub).glob("*/")) if (pkg / sub).is_dir() else []:
            if d.is_dir() and any(d.rglob("*.swift")) and d.resolve() not in named and not any(
                d.resolve().is_relative_to(n) or n.is_relative_to(d.resolve()) for n in named
            ):
                out.append(Target(rel, d.name, kind + " (by dir)", d))
    return out


XCODE_TARGET = re.compile(
    r"/\* (?P<name>[^*]+?) \*/ = \{\s*isa = PBXNativeTarget;.*?productType = \"(?P<type>[^\"]+)\";",
    re.S,
)


def xcode_targets(pbxproj: Path) -> list[Target]:
    rel = pbxproj.parent.relative_to(ROOT).as_posix()
    sdk = "iOS" if "IPHONEOS_DEPLOYMENT_TARGET" in pbxproj.read_text(errors="replace") and (
        "ios" in rel.lower() or "Keyboard" in rel
    ) else "macOS"
    out = []
    for m in XCODE_TARGET.finditer(pbxproj.read_text(errors="replace")):
        kind = m.group("type").removeprefix("com.apple.product-type.")
        t = Target(rel, m.group("name"), f"xcode {kind}", None, MAC)
        t.reasons.append(f"Xcode {sdk} {kind}")
        t.proof = "project"
        out.append(t)
    return out


APPLE_C_HEADER = re.compile(
    r"^\s*#\s*(?:include|import)\s*<(malloc/malloc|mach[-/]|mach-o/|libproc|objc/|os/|"
    r"CoreFoundation/|Foundation/|AppKit/|Cocoa/|IOKit/|Security/|QuartzCore/|Metal/|CoreGraphics/|dispatch/private)",
    re.M,
)


def scan_c_sources(t: Target) -> None:
    files = [p for p in sorted(t.src.rglob("*")) if p.suffix in {".c", ".h", ".m", ".mm", ".cpp", ".cc"}]
    objc = sorted({p.suffix for p in files if p.suffix in {".m", ".mm"}})
    headers = sorted({m.group(1).rstrip("/-") for p in files for m in APPLE_C_HEADER.finditer(p.read_text(errors="replace"))})
    if objc or headers:
        t.level = MAC
        t.reasons.append("C/ObjC: " + ", ".join(objc + [f"<{h}>" for h in headers]))
    else:
        t.reasons.append("C sources only" if files else "no sources (system library or resources)")


def scan_sources(t: Target, local_modules: set[str]) -> None:
    if t.kind == "binaryTarget":
        t.level = SHIMS
        t.reasons.append("binary framework (needs a Linux build of its library)")
        return
    if not t.src or not t.src.exists():
        t.level = SHIMS
        t.reasons.append("sources not in the repo (generated at build time)")
        return
    files = [t.src] if t.src.is_file() else [
        p for p in sorted(t.src.rglob("*.swift")) if not SKIP_DIRS & set(p.relative_to(t.src).parts)
    ]
    hard, soft, unknown = set(), set(), set()
    for f in files:
        stack: list[bool] = []
        in_multiline = False
        for line in f.read_text(errors="replace").splitlines():
            if line.count('"""') % 2:
                in_multiline = not in_multiline
                continue
            if in_multiline:
                continue
            s = line.strip()
            if s.startswith("#if"):
                stack.append(bool(GUARD.search(s)))
                continue
            if s.startswith("#elseif") and stack:
                stack[-1] = stack[-1] or bool(GUARD.search(s))
                continue
            if s.startswith("#endif") and stack:
                stack.pop()
                continue
            m = IMPORT.match(line)
            if not m:
                continue
            mod, guarded = m.group(1), any(stack)
            if mod == t.name:
                continue
            if mod in APPLE_ONLY:
                (t.guarded_apple if guarded else hard).add(mod)
            elif guarded:
                continue
            elif mod in local_modules:
                t.local_imports.add(mod)
            elif mod in SHIMMABLE:
                soft.add(mod)
            elif mod not in PORTABLE and mod[0].isupper():
                unknown.add(mod)
    if hard:
        t.level = MAC
        t.reasons.append("imports " + ", ".join(sorted(hard)))
    if soft:
        t.level = max(t.level, SHIMS)
        t.reasons.append("shim " + ", ".join(sorted(soft)))
    if unknown:
        t.level = max(t.level, SHIMS)
        t.reasons.append("unknown module " + ", ".join(sorted(unknown)))
    if not files:
        scan_c_sources(t)
    elif t.guarded_apple and not hard:
        t.reasons.append("its Apple code sits behind #if, so a Linux build compiles only the rest")


def ci_linux_packages() -> dict[str, tuple[str, set[str] | None]]:
    """Package dir -> (the Linux job, the test targets it runs there, or None for the whole package)."""
    proven: dict[str, tuple[str, set[str] | None]] = {}
    text = PORTABLE_WORKFLOW.read_text()
    for block in re.findall(r"packages:\s*>-?\s*\n((?:\s+\S+\n)+)", text):
        for p in block.split():
            proven[p] = ("CI swift-packages-linux", None)
    for p in re.findall(r"packages:\s*(\S+/\S+)\s*$", text, flags=re.M):
        proven[p] = ("CI swift-packages-linux", None)
    for line in LINUX_LIST.read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            dir_, tests = line.split()[:2]
            proven.setdefault(dir_, ("CI swift-linux-packages", set(tests.split(","))))
    return proven


def tracked(pattern: str) -> list[Path]:
    out = subprocess.run(["git", "ls-files", pattern], cwd=ROOT, capture_output=True, text=True, check=True)
    return [ROOT / p for p in out.stdout.split()]


def inventory() -> list[Target]:
    targets: list[Target] = []
    for m in tracked("*Package.swift"):
        if m.name == "Package.swift":
            targets += manifest_targets(m)
    for p in tracked("*.xcodeproj/project.pbxproj"):
        targets += xcode_targets(p)
    seen: set[tuple[str, str]] = set()
    targets = [t for t in targets if (t.package, t.name) not in seen and not seen.add((t.package, t.name))]
    local = {t.name for t in targets}
    for t in targets:
        if t.proof != "project":
            scan_sources(t, local)
    by_name: dict[str, list[Target]] = {}
    for t in targets:
        by_name.setdefault(t.name, []).append(t)

    def worst(name: str) -> Target:
        return max(by_name[name], key=lambda x: x.level)

    changed = True
    while changed:  # a target is as far from Linux as the worst local module it imports
        changed = False
        for t in targets:
            for dep in sorted(t.local_imports):
                d = worst(dep)
                if d.level > t.level:
                    t.level = d.level
                    t.reasons = [r for r in t.reasons if not r.startswith("via ")] + [f"via {dep}"]
                    changed = True
    # Proof: a Linux CI job builds the target. A row of swift-linux-packages.txt builds its test
    # targets and the package modules they import; swift-packages-linux.yml builds whole packages.
    for pkg, (job, tests) in ci_linux_packages().items():
        mine = {t.name: t for t in targets if t.package == pkg}
        built = set(mine) if tests is None else set()
        todo = [] if tests is None else sorted(tests)
        while todo:
            name = todo.pop()
            if name in mine and name not in built:
                built.add(name)
                todo += sorted(mine[name].local_imports)
        for t in targets:
            if t.package == pkg and t.name in built and t.level == LINUX:
                t.proof = job
    return targets


def render(targets: list[Target]) -> str:
    proven = {pkg: job for pkg, (job, _) in ci_linux_packages().items()}
    pkgs: dict[str, list[Target]] = {}
    for t in targets:
        pkgs.setdefault(t.package, []).append(t)
    counts = {c: 0 for c in CLASS_NAMES}
    for t in targets:
        counts[t.level] += 1
    tests = [t for t in targets if t.kind.startswith("testTarget")]
    tcounts = {c: sum(t.level == c for t in tests) for c in CLASS_NAMES}
    lines = [
        "# Swift on Linux: every target and test suite",
        "",
        "Generated by `scripts/ci/swift_linux_inventory.py`; do not edit by hand. Run it after adding,",
        "moving or re-importing a Swift target; `--check` exits 1 when this file is stale.",
        "Leo-ask: ask-64314e2230.",
        "",
        "Classes: **linux** builds on Linux today (proof `CI` = a Linux job builds and tests it on every",
        "change; `scan` = nothing it imports needs an Apple-only module, no Linux job yet). **shims**",
        "builds with small shims (Darwin, CryptoKit, os/OSLog, CoreGraphics geometry, Combine, a binary",
        "FFI framework, an unknown module). **mac** is Mac-only (Apple-only): an unguarded AppKit,",
        "SwiftUI, WebKit, UIKit or other Apple framework import, directly or through a local module it",
        "imports. Imports inside `#if canImport/os()/targetEnvironment/arch` blocks do not count; the",
        "`guarded` column lists them.",
        "",
        "## Totals",
        "",
        "| | linux | shims | mac | all |",
        "| --- | ---: | ---: | ---: | ---: |",
        f"| targets | {counts[LINUX]} | {counts[SHIMS]} | {counts[MAC]} | {len(targets)} |",
        f"| of them test suites | {tcounts[LINUX]} | {tcounts[SHIMS]} | {tcounts[MAC]} | {len(tests)} |",
        "",
        "## Packages and projects",
        "",
        "| Package or project | linux | shims | mac | Linux CI |",
        "| --- | ---: | ---: | ---: | --- |",
    ]
    for pkg in sorted(pkgs):
        ts = pkgs[pkg]
        c = [sum(t.level == lv for t in ts) for lv in CLASS_NAMES]
        lines.append(f"| `{pkg}` | {c[0]} | {c[1]} | {c[2]} | {proven.get(pkg, '-')} |")
    for pkg in sorted(pkgs):
        lines += ["", f"## `{pkg}`", "", "| Target | Kind | Class | Proof | Why | Guarded |",
                  "| --- | --- | --- | --- | --- | --- |"]
        for t in sorted(pkgs[pkg], key=lambda t: (t.kind.startswith("testTarget"), t.name)):
            why = "; ".join(t.reasons) or "-"
            guarded = ", ".join(sorted(t.guarded_apple)) or "-"
            lines.append(f"| {t.name} | {t.kind} | {CLASS_NAMES[t.level]} | {t.proof} | {why} | {guarded} |")
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--check", action="store_true", help="fail if the inventory file is stale")
    args = ap.parse_args()
    text = render(inventory())
    if args.check:
        if not OUT.exists() or OUT.read_text() != text:
            print(f"{OUT.relative_to(ROOT)} is stale: run python3 scripts/ci/swift_linux_inventory.py",
                  file=sys.stderr)
            return 1
        return 0
    OUT.write_text(text)
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
