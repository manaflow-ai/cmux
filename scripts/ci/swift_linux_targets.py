#!/usr/bin/env python3
"""Every SwiftPM target in the tree, classified by what keeps it off Linux.

The B5 ratchet of the Linux map (cmuxterm-hq docs/findings/2026-11-25-linux-everything-map.md): of the
repository's Swift targets, how many build on Linux today, and for every other one the import that
blocks it, so the cheap unblocks (`#if canImport`, moving a platform shim out, splitting a file) are
easy to pick.

A target's state:

- `linux`: listed in scripts/ci/swift-linux-targets.txt, the targets of the packages
  .github/workflows/swift-linux-packages.yml builds on Linux (a row of scripts/ci/swift-linux-packages.txt,
  or a portable group), as `swift package dump-package` reads their Linux shape. The workflow's
  `linux-targets` job checks every listed target is still in that shape (`--verify`), so the list
  never claims a target Linux does not build.
- `dropped`: its package builds on Linux but the Linux shape leaves it out, though nothing in it
  imports an Apple-only module outside an `#if`: often a one-line manifest unblock.
- `clean`: no Apple-only import, but no Linux job builds its package yet: add the package to that
  workflow.
- `blocked`: it imports an Apple-only module in code a Linux debug build compiles, depends on a target that does, or is a
  binary target. `blocker` names the first import of the most common class, `kind` its class:
  `appkit`, `uikit`, `swiftui`, `webkit`, `darwin` (the `Darwin` C module alone: a `#if
  canImport(Darwin)` / `Glibc` shim fixes it), `apple` (another Apple-only framework), `binary`
  (an xcframework), or `dep` (only through a dependency).

The source scan needs no Swift toolchain; `--verify` and `--write-list` run `swift package
dump-package` (SWIFT, default `swift`).

Usage:
  swift_linux_targets.py                 the summary and the counts by class
  swift_linux_targets.py --json          every target as one JSON document
  swift_linux_targets.py --markdown      the table of every target (docs/ci/swift-linux-targets.md)
  swift_linux_targets.py --check         exit 1 when the listed Linux targets number fewer than the
                                         floor in scripts/ci/swift-linux-targets-floor.txt (the ratchet)
  swift_linux_targets.py --verify        exit 1 when a listed target is not in its package's Linux shape
  swift_linux_targets.py --write-list    list every Linux package's Linux-shape targets, then raise the
                                         floor to the new count (the floor never goes down)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from dataclasses import asdict, dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIST = ROOT / "scripts/ci/swift-linux-packages.txt"
WORKFLOW = ROOT / ".github/workflows/swift-linux-packages.yml"
FLOOR = ROOT / "scripts/ci/swift-linux-targets-floor.txt"
TARGETS = ROOT / "scripts/ci/swift-linux-targets.txt"

# Folders whose manifests are not part of the cmux-next build: the retired classic iPhone app,
# throwaway prototypes and build outputs.
SKIP_DIRS = {".build", ".git", "node_modules", "DerivedData", ".swiftpm", "Prototypes", "ios"}

UI = {"AppKit": "appkit", "UIKit": "uikit", "SwiftUI": "swiftui", "WebKit": "webkit"}
# Modules the swift.org Linux toolchain does not ship (Foundation, FoundationNetworking, Dispatch,
# Observation, Synchronization, XCTest, Testing, RegexBuilder, Glibc and CoreFoundation do ship).
APPLE = {
    "AVFoundation", "AVKit", "Accelerate", "Accessibility", "ActivityKit", "AppIntents", "AppTrackingTransparency",
    "AudioToolbox", "AuthenticationServices", "BackgroundTasks", "Carbon", "CloudKit", "Cocoa", "Combine",
    "Contacts", "CoreAudio", "CoreBluetooth", "CoreData", "CoreFoundation_Private", "CoreGraphics", "CoreHaptics",
    "CoreImage", "CoreLocation", "CoreMedia", "CoreML", "CoreMotion", "CoreServices", "CoreSpotlight",
    "CoreTelephony", "CoreText", "CoreTransferable", "CoreVideo", "CryptoKit", "DeviceCheck", "EventKit",
    "ExtensionFoundation", "ExtensionKit", "FileProvider", "GameController", "IOKit", "IOSurface", "ImageIO",
    "Intents", "JavaScriptCore", "LinkPresentation", "LocalAuthentication", "MapKit", "MediaPlayer", "Metal",
    "MetalKit", "MetalPerformanceShaders", "MultipeerConnectivity", "NaturalLanguage", "Network",
    "NetworkExtension", "NotificationCenter", "OSLog", "ObjectiveC", "PDFKit", "PassKit", "PencilKit", "Photos",
    "PhotosUI", "QuartzCore", "QuickLook", "QuickLookThumbnailing", "ReplayKit", "SafariServices",
    "ScreenCaptureKit", "Security", "ServiceManagement", "Speech", "StoreKit", "SwiftData", "Symbols",
    "SystemConfiguration", "TipKit", "Translation", "UniformTypeIdentifiers", "UserNotifications",
    "UserNotificationsUI", "VideoToolbox", "Vision", "WatchConnectivity", "WidgetKit", "XCUIAutomation",
    "os", "os_log", "simd", "ApplicationServices", "CoreWLAN", "ExceptionHandling", "Quartz", "SceneKit",
    "SpriteKit", "GLKit", "OpenGL", "MessageUI", "Messages", "SensitiveContentAnalysis", "Virtualization",
    "Hypervisor", "EndpointSecurity", "SystemExtensions", "DiskArbitration", "IOBluetooth", "CoreMIDI",
    "AppleArchive", "Compression", "GameKit", "HealthKit", "HomeKit", "ARKit", "RealityKit", "VisionKit",
    "LockedCameraCapture", "Foundation_Private",
}
DARWIN = {"Darwin", "MachO"}
# The order a target's blocker is reported in: the UI frameworks first, the cheap Darwin shim last.
KIND_ORDER = ["appkit", "uikit", "swiftui", "webkit", "apple", "darwin"]

IMPORT_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)"
)
IF_RE = re.compile(r"^\s*#if\b(.*)")
ELSEIF_RE = re.compile(r"^\s*#(elseif|else)\b(.*)")
ENDIF_RE = re.compile(r"^\s*#endif\b")
TARGET_RE = re.compile(r"\.(target|testTarget|executableTarget|binaryTarget|macro|plugin|systemLibrary)\s*\(")


@dataclass
class Target:
    package: str
    name: str
    type: str
    path: str
    deps: list[str] = field(default_factory=list)
    dep_blocker: str = ""  # a blocked dependency, even when the target's own import is named first
    imports: dict[str, str] = field(default_factory=dict)  # module -> first file importing it on Linux
    state: str = ""
    kind: str = ""
    blocker: str = ""
    blocker_file: str = ""


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def balanced(text: str, start: int) -> str:
    """The text from the `(` at `start` to its matching `)`, string literals respected."""
    depth, i, in_str = 0, start, False
    while i < len(text):
        c = text[i]
        if in_str:
            if c == "\\":
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
        i += 1
    return text[start:]


def manifests() -> list[Path]:
    out = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        if "Package.swift" in filenames:
            out.append(Path(dirpath) / "Package.swift")
    return sorted(out)


def parse_manifest(path: Path) -> tuple[list[Target], dict[str, list[str]], dict[str, str]]:
    """The targets, the products (name -> targets) and the local path dependencies (name -> dir)."""
    pkg = path.parent.relative_to(ROOT).as_posix()
    text = strip_comments(path.read_text())
    # The Linux shape's appended targets (the system SQLite module) are not Swift code of ours.
    targets: list[Target] = []
    seen: set[str] = set()
    inside = -1  # the end of the last target declaration: a `.target(name:)` before it is a dependency
    for m in TARGET_RE.finditer(text):
        if m.start() < inside:
            continue
        body = balanced(text, m.end() - 1)
        inside = m.end() - 1 + len(body)
        name = re.search(r'name:\s*"([^"]+)"', body)
        if not name or name.group(1) in seen:
            continue
        kind = m.group(1)
        if kind == "systemLibrary":
            continue
        seen.add(name.group(1))
        p = re.search(r'\bpath:\s*"([^"]+)"', body)
        if p:
            tpath = p.group(1)
        elif kind == "testTarget":
            tpath = f"Tests/{name.group(1)}"
        elif kind == "plugin":
            tpath = f"Plugins/{name.group(1)}"
        else:
            tpath = f"Sources/{name.group(1)}"
        deps = []
        dm = re.search(r"\bdependencies:\s*\[", body)
        if dm:
            dbody = balanced(body.replace("[", "(").replace("]", ")"), dm.end() - 1)
            for prod in re.finditer(r'\.product\(\s*name:\s*"([^"]+)"\s*,\s*package:\s*"([^"]+)"', dbody):
                deps.append(f"product:{prod.group(2)}:{prod.group(1)}")
            dbody_no_prod = re.sub(r"\.product\([^)]*\)", "", dbody)
            for t in re.finditer(r'\.(?:target|byName)\(\s*name:\s*"([^"]+)"', dbody_no_prod):
                deps.append(t.group(1))
            dbody_plain = re.sub(r"\.\w+\([^)]*\)", "", dbody_no_prod)
            deps.extend(re.findall(r'"([^"]+)"', dbody_plain))
        targets.append(Target(package=pkg, name=name.group(1), type=kind, path=f"{pkg}/{tpath}", deps=deps))
    products: dict[str, list[str]] = {}
    for m in re.finditer(r"\.(?:library|executable)\s*\(", text):
        body = balanced(text, m.end() - 1)
        n = re.search(r'name:\s*"([^"]+)"', body)
        t = re.search(r"targets:\s*\[([^\]]*)\]", body)
        if n and t:
            products[n.group(1)] = re.findall(r'"([^"]+)"', t.group(1))
    local: dict[str, str] = {}
    for m in re.finditer(r'\.package\(\s*(?:name:\s*"([^"]+)"\s*,\s*)?path:\s*"([^"]+)"', text):
        d = (path.parent / m.group(2)).resolve()
        try:
            rel = d.relative_to(ROOT).as_posix()
        except ValueError:
            continue
        local[m.group(1) or d.name] = rel
    return targets, products, local


# Compilation conditions as a Linux debug build sees them (swift build defaults to debug).
LINUX_FLAGS = {"DEBUG", "SWIFT_PACKAGE"}


def linux_condition(cond: str) -> bool:
    """Whether an `#if` condition holds in a Linux debug build: os(Linux), a canImport of a module
    Linux has, x86_64 or arm64, any compiler or swift version, and DEBUG are true; other platforms,
    simulators and unset custom flags are false."""
    expr = cond.split("//", 1)[0].strip()

    def call(m: re.Match) -> str:
        fn, arg = m.group(1), m.group(2).strip().split(",")[0].strip()
        if fn == "os":
            return " True " if arg == "Linux" else " False "
        if fn == "canImport":
            return " False " if import_kind(arg.split(".")[0]) else " True "
        if fn == "arch":
            return " True " if arg in ("x86_64", "arm64", "aarch64") else " False "
        if fn in ("compiler", "swift", "hasFeature", "hasAttribute"):
            return " True "
        return " False "  # targetEnvironment(simulator), _endian and the rest

    expr = re.sub(r"\b(\w+)\s*\(([^()]*)\)", call, expr)
    expr = re.sub(r"\b(?!True\b|False\b)([A-Za-z_]\w*)\b",
                  lambda m: " True " if m.group(1) in LINUX_FLAGS else " False ", expr)
    expr = expr.replace("&&", " and ").replace("||", " or ").replace("!", " not ")
    try:
        return bool(eval(expr, {"__builtins__": {}}, {}))  # only True/False/and/or/not/parens remain
    except Exception:
        return True  # an unparsed condition: assume the code compiles, so the import counts


def scan_imports(target: Target) -> None:
    """The modules a target imports in code a Linux debug build compiles."""
    root = ROOT / target.path
    if not root.is_dir():
        return
    for f in sorted(root.rglob("*.swift")):
        # One frame per open `#if`: (this branch compiles on Linux, an earlier branch did).
        stack: list[tuple[bool, bool]] = []
        rel = f.relative_to(ROOT).as_posix()
        try:
            lines = f.read_text(errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            m = IF_RE.match(line)
            if m:
                on = linux_condition(m.group(1))
                stack.append((on, on))
                continue
            m = ELSEIF_RE.match(line)
            if m and stack:
                _, taken = stack[-1]
                on = not taken and (m.group(1) == "else" or linux_condition(m.group(2)))
                stack[-1] = (on, taken or on)
                continue
            if ENDIF_RE.match(line):
                if stack:
                    stack.pop()
                continue
            m = IMPORT_RE.match(line)
            if m and all(on for on, _ in stack):
                target.imports.setdefault(m.group(1), rel)


def import_kind(module: str) -> str:
    if module in UI:
        return UI[module]
    if module in APPLE:
        return "apple"
    if module in DARWIN:
        return "darwin"
    return ""


def linux_packages() -> dict[str, dict[str, str]]:
    """Every package a Linux job builds -> the environment its Linux shape is read with."""
    out: dict[str, dict[str, str]] = {}
    for line in LIST.read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            dir_, _, envs = line.split()[:3]
            out[dir_] = {} if envs == "-" else dict(e.split("=", 1) for e in envs.split(","))
    # The portable groups build whole packages, always with CMUX_SWIFTPM_TARGET_LINUX=1.
    for m in re.finditer(r"^\s*packages:\s*(>-\s*\n((?:\s{14,}\S+\n)+)|(\S+))", WORKFLOW.read_text(), re.M):
        for dir_ in (m.group(2) or m.group(3) or "").split():
            out.setdefault(dir_, {"CMUX_SWIFTPM_TARGET_LINUX": "1"})
    return out


def read_list() -> set[tuple[str, str]]:
    out = set()
    for line in TARGETS.read_text().splitlines() if TARGETS.exists() else []:
        if line.strip() and not line.startswith("#"):
            pkg, name = line.split()[:2]
            out.add((pkg, name))
    return out


def dump_targets(pkg: str, env: dict[str, str], swift: str) -> set[str]:
    """The targets of PKG's manifest as Linux reads it (`swift package dump-package`)."""
    res = subprocess.run(
        [swift, "package", "--package-path", str(ROOT / pkg), "dump-package"],
        env=os.environ | env,
        capture_output=True,
        text=True,
        timeout=300,
    )
    if res.returncode != 0:
        raise SystemExit(f"{pkg}: swift package dump-package failed:\n{res.stderr[-2000:]}")
    return {
        t["name"]
        for t in json.loads(res.stdout)["targets"]
        if t.get("type") not in ("system", "binary", "plugin")
    }


# Remote packages whose products are Apple-only (an XCFramework or Cocoa API), as a binary blocker.
APPLE_REMOTE = {
    name: Target(package=f"remote:{name}", name=name, type="binaryTarget", path=f"remote:{name}")
    for name in ("Sparkle", "sentry-cocoa", "swift-nio-transport-services")
}


def classify() -> list[Target]:
    targets: list[Target] = []
    products: dict[str, dict[str, list[str]]] = {}
    locals_: dict[str, dict[str, str]] = {}
    for path in manifests():
        ts, prods, local = parse_manifest(path)
        pkg = path.parent.relative_to(ROOT).as_posix()
        products[pkg], locals_[pkg] = prods, local
        targets.extend(ts)
    by_key = {(t.package, t.name): t for t in targets}
    for t in targets:
        scan_imports(t)

    def resolve(t: Target, dep: str) -> list[Target]:
        if dep.startswith("product:"):
            _, pkgname, prod = dep.split(":", 2)
            other = locals_[t.package].get(pkgname)
            if other is None:
                # A remote package: swift-crypto, swift-nio and the rest build on Linux; these do not.
                return [APPLE_REMOTE[pkgname]] if pkgname in APPLE_REMOTE else []
            return [by_key[(other, n)] for n in products.get(other, {}).get(prod, [prod]) if (other, n) in by_key]
        return [by_key[(t.package, dep)]] if (t.package, dep) in by_key else []

    memo: dict[tuple[str, str], tuple[str, str, str, str]] = {}

    def own(t: Target) -> tuple[str, str, str]:
        if t.type == "binaryTarget":
            return "binary", t.name, t.path
        found = [(KIND_ORDER.index(k), mod, f) for mod, f in t.imports.items() if (k := import_kind(mod))]
        if not found:
            return "", "", ""
        _, mod, f = min(found)
        return import_kind(mod), mod, f

    def blocked(t: Target, trail: frozenset) -> tuple[str, str, str, str]:
        key = (t.package, t.name)
        if key in memo:
            return memo[key]
        kind, mod, f = own(t)
        via: tuple[str, str, str, str] = ("", "", "", "")
        for dep in t.deps:
            for d in resolve(t, dep):
                if (d.package, d.name) in trail:
                    continue
                dk = blocked(d, trail | {key})
                if dk[0]:
                    via = ("dep", f"{d.name} ({dk[1]})", dk[2], d.name)
                    break
            if via[0]:
                break
        # A target's own import names its blocker; a blocked dependency still keeps it off Linux, so
        # `dep_blocker` says whether fixing its own imports alone would be enough.
        t.dep_blocker = via[1]
        res = (kind, mod, f, "") if kind else via
        memo[key] = res
        return res

    linux, listed = linux_packages(), read_list()
    for t in targets:
        kind, mod, f, _ = blocked(t, frozenset())
        if (t.package, t.name) in listed:
            t.state = "linux"
        elif kind:
            t.state, t.kind, t.blocker, t.blocker_file = "blocked", kind, mod, f
        elif t.package in linux:
            # No unguarded Apple import, but the package's Linux shape leaves it out (its imports sit
            # under `#if canImport`, or it needs an Apple API Foundation lacks on Linux).
            t.state = "dropped"
        else:
            t.state = "clean"
    return targets


def read_floor() -> int:
    for line in FLOOR.read_text().splitlines() if FLOOR.exists() else []:
        if line.strip() and not line.startswith("#"):
            return int(line.split()[0])
    return 0


def summary(targets: list[Target]) -> str:
    states = Counter(t.state for t in targets)
    kinds = Counter(t.kind for t in targets if t.state == "blocked")
    lines = [
        f"{len(targets)} Swift targets in {len({t.package for t in targets})} packages",
        f"  linux    {states['linux']:4}  built on Linux by swift-linux-packages.yml (floor {read_floor()})",
        f"  dropped  {states['dropped']:4}  in a Linux package, no Apple-only import, left out of its Linux shape",
        f"  clean    {states['clean']:4}  no Apple-only import: add the package to a Linux job",
        f"  blocked  {states['blocked']:4}",
    ]
    for k in KIND_ORDER + ["binary", "dep"]:
        lines.append(f"    {k:8} {kinds[k]:4}")
    by_pkg = Counter(t.package for t in targets if t.state == "clean")
    if by_pkg:
        lines.append("clean targets by package (cheapest unblocks):")
        for pkg, n in by_pkg.most_common():
            lines.append(f"  {n:3}  {pkg}")
    dar = Counter(t.package for t in targets if t.kind == "darwin" and not t.dep_blocker)
    if dar:
        lines.append("targets blocked only by `import Darwin` (a canImport(Glibc) shim):")
        for pkg, n in dar.most_common():
            lines.append(f"  {n:3}  {pkg}")
    return "\n".join(lines)


def markdown(targets: list[Target]) -> str:
    out = [
        "# Swift targets on Linux",
        "",
        "Generated by `python3 scripts/ci/swift_linux_targets.py --markdown`; do not edit by hand.",
        "The floor (`scripts/ci/swift-linux-targets-floor.txt`) only goes up: ci-guards fails a change that",
        "drops the `linux` count below it.",
        "",
        "```",
        summary(targets),
        "```",
        "",
        "| Package | Target | Type | State | Blocker | First file |",
        "|---|---|---|---|---|---|",
    ]
    for t in sorted(targets, key=lambda t: (t.package, t.name)):
        out.append(
            f"| {t.package} | {t.name} | {t.type} | {t.state} | {t.kind + ': ' + t.blocker if t.kind else ''} "
            f"| {t.blocker_file} |"
        )
    return "\n".join(out) + "\n"


def write_floor(n: int) -> None:
    floor = read_floor()
    if n > floor:
        FLOOR.write_text(
            "# The number of Swift targets that build on Linux: the rows of scripts/ci/swift-linux-targets.txt.\n"
            "# It only goes up (scripts/ci/swift_linux_targets.py --write-list raises it); ci-guards fails below it.\n"
            f"{n}\n"
        )
        print(f"floor {floor} -> {n}")
    else:
        print(f"floor stays {floor} (today {n})")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--write-list", action="store_true")
    ap.add_argument("--package", help="only targets whose package path starts with this")
    args = ap.parse_args()
    swift = os.environ.get("SWIFT", "swift")
    if args.verify or args.write_list:
        linux, listed = linux_packages(), read_list()
        dumped = {pkg: dump_targets(pkg, env, swift) for pkg, env in sorted(linux.items())}
        if args.write_list:
            rows = sorted((pkg, n) for pkg, names in dumped.items() for n in names)
            TARGETS.write_text(
                "# Swift targets that build on Linux: PACKAGE_DIR TARGET, one per line. Generated by\n"
                "# `scripts/ci/swift_linux_targets.py --write-list` from the Linux shape (`swift package dump-package`)\n"
                "# of every package .github/workflows/swift-linux-packages.yml builds. Its `linux-targets` job fails\n"
                "# when a listed target leaves that shape; ci-guards fails when the rows drop below\n"
                "# scripts/ci/swift-linux-targets-floor.txt.\n" + "".join(f"{p}  {n}\n" for p, n in rows)
            )
            print(f"{len(rows)} Linux targets written to {TARGETS.relative_to(ROOT)}")
            write_floor(len(rows))
            return 0
        missing = sorted(f"{p}  {n}" for p, n in listed if n not in dumped.get(p, set()))
        unlisted = sorted(f"{p}  {n}" for p, names in dumped.items() for n in names if (p, n) not in listed)
        for row in unlisted:
            print(f"swift-linux-targets: new on Linux, not listed yet (run --write-list): {row}")
        if missing:
            print(
                "swift-linux-targets: listed targets no longer in their package's Linux shape:\n  "
                + "\n  ".join(missing)
                + "\nKeep the target building on Linux (guard the Apple-only import with `#if canImport`), or, when"
                "\nit truly moved off Linux, remove its row and say why in the pull request.",
                file=sys.stderr,
            )
            return 1
        print(f"swift-linux-targets: all {len(listed)} listed targets are in their Linux shape")
        return 0
    if args.check:
        n, floor = len(read_list()), read_floor()
        if n < floor:
            print(
                f"swift-linux-targets: {n} targets listed in {TARGETS.relative_to(ROOT)}, below the floor {floor}.\n"
                "The count only goes up: keep the targets building on Linux rather than dropping rows.",
                file=sys.stderr,
            )
            return 1
        print(f"swift-linux-targets: {n} on Linux (floor {floor})")
        return 0
    targets = classify()
    if args.package:
        targets = [t for t in targets if t.package.startswith(args.package)]
    if args.json:
        print(json.dumps([asdict(t) | {"imports": sorted(t.imports)} for t in targets], indent=1))
    elif args.markdown:
        print(markdown(targets), end="")
    else:
        print(summary(targets))
    return 0


if __name__ == "__main__":
    sys.exit(main())
