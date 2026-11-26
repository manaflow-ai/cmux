#!/usr/bin/env python3
"""Census of the Swift targets in this repo that can (and cannot) build on Linux.

    linux_swift_target_census.py census --root CHECKOUT [--swift swift] [--json OUT]
    linux_swift_target_census.py check  --root CHECKOUT --baseline scripts/ci/linux_swift_targets.json

`census` reads every first-party Package.swift through `swift package dump-package`,
finds each target's sources, and names what keeps it off Linux, in this order:

  * apple-import   a source file imports an Apple-only module (AppKit, UIKit,
                   SwiftUI, Combine, ...) outside an `#if canImport(...)` or
                   `#if os(...)` block.
  * binary         the target is (or depends on) a binary target (an xcframework).
  * dependency     the target depends on a target that is blocked for one of
                   the reasons above, in this package or another one.

A target with no blocker is a Linux candidate. With `--build`, census also runs
`swift build --target T` for each candidate and records which ones really
compile, so the count it reports is measured, not inferred.

`check` compares a fresh census with the checked-in baseline: the number of
targets that build on Linux may only go up, and no target in the baseline's
`builds` list may drop off it. A target that newly builds is reported so the
baseline can be raised (`census --write-baseline`).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# Modules that ship only with Apple SDKs. Foundation, Dispatch, XCTest,
# Testing, Observation, RegexBuilder, Synchronization and FoundationEssentials
# exist on Linux and are not listed.
APPLE_ONLY = {
    "AppKit", "UIKit", "SwiftUI", "Cocoa", "Combine", "CoreGraphics", "QuartzCore",
    "CoreText", "CoreImage", "Metal", "MetalKit", "MetalPerformanceShaders", "WebKit",
    "Carbon", "IOKit", "IOSurface", "Security", "CryptoKit", "Network", "OSLog", "os",
    "UserNotifications", "ServiceManagement", "AVFoundation", "AVKit", "CoreMedia",
    "CoreVideo", "CoreAudio", "AudioToolbox", "ApplicationServices", "CoreServices",
    "Darwin", "ObjectiveC", "SystemConfiguration", "LocalAuthentication",
    "AuthenticationServices", "StoreKit", "CloudKit", "CoreData", "SwiftData",
    "CoreLocation", "Photos", "PhotosUI", "Vision", "VisionKit", "ScreenCaptureKit",
    "UniformTypeIdentifiers", "CoreTransferable", "WidgetKit", "ActivityKit",
    "AppIntents", "Intents", "GameController", "CoreHaptics", "MessageUI",
    "SafariServices", "QuickLook", "QuickLookThumbnailing", "PDFKit",
    "LinkPresentation", "Accessibility", "NetworkExtension", "CoreBluetooth",
    "MultipeerConnectivity", "BackgroundTasks", "Speech", "NaturalLanguage",
    "CoreML", "ImageIO", "CoreSpotlight", "EventKit", "Contacts", "MapKit",
    "SceneKit", "SpriteKit", "RealityKit", "ARKit", "ExtensionFoundation",
    "ExtensionKit", "Virtualization", "Hypervisor", "CoreWLAN", "DeviceCheck",
    "PushKit", "CallKit", "UserNotificationsUI", "Charts", "TipKit", "GroupActivities",
    "SwiftUICore", "DeveloperToolsSupport", "XCUIAutomation", "FinderSync",
    "OpenDirectory", "LaunchServices", "Quartz", "CoreAnimation", "MediaPlayer",
    "Sparkle", "Sentry", "WireGuardKit", "QuartzCore",
}

IMPORT = re.compile(
    r"^\s*(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][A-Za-z0-9_]*)"
)
IF_DIRECTIVE = re.compile(r"^\s*#\s*(if|elseif|else|endif)\b(.*)")
GUARD = re.compile(r"canImport\s*\(|\bos\s*\(|targetEnvironment\s*\(|\bDEBUG\b|\bSWIFT_PACKAGE\b|arch\s*\(")
SKIP_DIRS = {".build", ".swiftpm", "node_modules", "DerivedData", ".git"}
SOURCE_SUFFIXES = (".swift",)


def first_party_packages(root: Path) -> list[Path]:
    found = []
    for path in root.rglob("Package.swift"):
        rel = path.relative_to(root)
        parts = set(rel.parts)
        if parts & SKIP_DIRS or rel.parts[0] in {"ghostty", "vendor", "web", "webviews"}:
            continue
        if "checkouts" in rel.parts or "experiments" in rel.parts[:1]:
            continue
        found.append(path.parent)
    return sorted(found)


def dump_package(swift: str, package: Path) -> dict | None:
    try:
        out = subprocess.run(
            [swift, "package", "dump-package", "--package-path", str(package)],
            capture_output=True, text=True, timeout=600,
        )
    except subprocess.TimeoutExpired:
        return None
    if out.returncode != 0:
        sys.stderr.write(f"census: dump-package failed for {package}: {out.stderr.strip()[-400:]}\n")
        return None
    return json.loads(out.stdout)


def target_dir(package: Path, target: dict) -> Path:
    if target.get("path"):
        return package / target["path"]
    base = "Tests" if target["type"] == "test" else "Sources"
    if target["type"] == "plugin":
        base = "Plugins"
    return package / base / target["name"]


def unguarded_apple_imports(path: Path) -> set[str]:
    """Apple-only modules a file imports outside any #if that tests the platform."""
    found: set[str] = set()
    stack: list[bool] = []  # True when the block is platform-guarded
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return found
    in_block_comment = False
    for line in text.splitlines():
        stripped = line.strip()
        if in_block_comment:
            if "*/" in stripped:
                in_block_comment = False
            continue
        if stripped.startswith("/*") and "*/" not in stripped:
            in_block_comment = True
            continue
        directive = IF_DIRECTIVE.match(line)
        if directive:
            kind, cond = directive.groups()
            if kind == "if":
                stack.append(bool(GUARD.search(cond)))
            elif kind == "elseif" and stack:
                stack[-1] = stack[-1] or bool(GUARD.search(cond))
            elif kind == "endif" and stack:
                stack.pop()
            continue
        if any(stack):
            continue
        match = IMPORT.match(line)
        if match and match.group(1) in APPLE_ONLY:
            found.add(match.group(1))
    return found


def census(root: Path, swift: str, jobs: int) -> dict:
    packages = first_party_packages(root)
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        dumps = dict(zip(packages, pool.map(lambda p: dump_package(swift, p), packages)))

    targets: dict[str, dict] = {}  # key "pkgrel:Target"
    products: dict[tuple[str, str], list[str]] = {}  # (package identity lower, product) -> target keys
    identity_of: dict[str, str] = {}
    for package, dump in dumps.items():
        rel = str(package.relative_to(root))
        identity_of[package.name.lower()] = rel
        if dump is None:
            targets[f"{rel}:*"] = dict(package=rel, name="*", type="manifest", blockers=["manifest"], deps=[])
            continue
        for product in dump.get("products", []):
            products[(package.name.lower(), product["name"])] = [f"{rel}:{t}" for t in product["targets"]]
        local_paths = {}
        for dep in dump.get("dependencies", []):
            for kind in ("fileSystem", "sourceControl", "registry"):
                if kind in dep:
                    spec = dep[kind][0]
                    ident = spec.get("identity", "")
                    if kind == "fileSystem":
                        dep_path = (package / spec["path"]).resolve()
                        try:
                            local_paths[ident] = str(dep_path.relative_to(root.resolve()))
                        except ValueError:
                            local_paths[ident] = None
                    else:
                        local_paths[ident] = None
        for target in dump.get("targets", []):
            key = f"{rel}:{target['name']}"
            entry = dict(package=rel, name=target["name"], type=target["type"], blockers=[], imports=[], deps=[])
            if target["type"] == "binary":
                entry["blockers"].append("binary")
            if target["type"] in ("regular", "executable", "test", "macro"):
                imports: set[str] = set()
                source_dir = target_dir(package, target)
                for file in source_dir.rglob("*.swift") if source_dir.is_dir() else []:
                    if set(file.relative_to(source_dir).parts) & SKIP_DIRS:
                        continue
                    imports |= unguarded_apple_imports(file)
                if imports:
                    entry["blockers"].append("apple-import")
                    entry["imports"] = sorted(imports)
            for dep in target.get("dependencies", []):
                if "byName" in dep:
                    name = dep["byName"][0]
                    entry["deps"].append(("local", rel, name))
                elif "target" in dep:
                    entry["deps"].append(("local", rel, dep["target"][0]))
                elif "product" in dep:
                    name, ident = dep["product"][0], (dep["product"][1] or "").lower()
                    entry["deps"].append(("product", local_paths.get(ident), name, ident))
                if dep.get("byName") and dep["byName"][1] or dep.get("product") and dep["product"][3]:
                    pass  # conditional deps (platforms:) still count; Linux resolves them unless excluded
            targets[key] = entry

    # Resolve deps to keys.
    def resolve(dep) -> list[str]:
        if dep[0] == "local":
            _, rel, name = dep
            key = f"{rel}:{name}"
            if key in targets:
                return [key]
            # byName may name a product of a dependency package.
            hits = [k for (ident, prod), ks in products.items() if prod == name for k in ks]
            return hits[:len(hits)]
        _, rel, name, ident = dep
        if rel is None:
            return []  # remote package: trusted to build on Linux unless it fails in --build
        return products.get((Path(rel).name.lower(), name), [])

    for entry in targets.values():
        entry["dep_keys"] = sorted({k for d in entry["deps"] for k in resolve(d)})
        del entry["deps"]

    blocked_by: dict[str, str | None] = {}

    def first_blocker(key: str, seen: set[str]) -> str | None:
        if key in blocked_by:
            return blocked_by[key]
        if key in seen:
            return None
        seen.add(key)
        entry = targets.get(key)
        if entry is None:
            return None
        result = None
        if entry["blockers"]:
            result = key
        else:
            for dep in entry["dep_keys"]:
                if first_blocker(dep, seen):
                    result = dep
                    break
        blocked_by[key] = result
        return result

    for key, entry in targets.items():
        culprit = first_blocker(key, set())
        if culprit and culprit != key:
            entry["blockers"].append("dependency")
            entry["blocked_by"] = culprit
    return dict(packages=len(packages), targets=targets)


BUILDABLE = ("regular", "executable", "test", "macro")
CURL_CRASH = "libcurl.Easy Code=43"  # swiftlang/swift-corelibs-foundation#5445; retried


def prefetch_artifacts(root: Path, swift: str, packages: list[str], store: Path) -> None:
    script = Path(__file__).with_name("swiftpm_prefetch_binary_artifacts.py")
    if not script.is_file():
        return
    args = [sys.executable, str(script), "--store", str(store), "--swift", swift]
    for rel in packages:
        args += ["--package-path", str(root / rel)]
    subprocess.run(args, check=False, stdout=subprocess.DEVNULL)


def build_targets(root: Path, swift: str, data: dict, jobs: int, scratch: Path,
                  only: set[str] | None = None) -> None:
    """Compile buildable targets (all of them, or the keys in `only`), one package
    per worker, and record the result.

    The static blocker stays the target's reason; the build decides whether it
    counts. A target that compiles despite a static blocker (a heuristic miss)
    counts as building; one with no static blocker that fails gets `compile`.
    """
    by_package: dict[str, list[str]] = {}
    for key, entry in data["targets"].items():
        if entry["type"] in BUILDABLE and (only is None or key in only):
            by_package.setdefault(entry["package"], []).append(key)
    prefetch_artifacts(root, swift, sorted(by_package), scratch / "artifact-store")

    def build(rel: str, name: str, build_path: Path) -> tuple[bool, str]:
        args = [swift, "build", "--package-path", str(root / rel), "--scratch-path", str(build_path),
                "--target", name]
        for _attempt in range(3):
            try:
                out = subprocess.run(args, capture_output=True, text=True, timeout=1800)
            except subprocess.TimeoutExpired:
                return False, "timeout"
            log = out.stdout + out.stderr
            if out.returncode == 0:
                return True, ""
            if CURL_CRASH not in log:
                return False, first_error(log)
        return False, first_error(log)

    def run(rel: str) -> list[tuple[str, bool, str]]:
        build_path = scratch / rel.replace("/", "_")
        # Libraries first: a test target's build compiles them anyway, and a
        # failing library names the real error once.
        keys = sorted(by_package[rel], key=lambda k: data["targets"][k]["type"] == "test")
        return [(key, *build(rel, data["targets"][key]["name"], build_path)) for key in keys]

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        for results in pool.map(run, sorted(by_package)):
            for key, ok, error in results:
                entry = data["targets"][key]
                entry["built"] = ok
                if not ok:
                    if not entry["blockers"]:
                        entry["blockers"].append("compile")
                    entry["error"] = error


def first_error(log: str) -> str:
    for line in log.splitlines():
        if "error:" in line:
            return line.strip()[:300]
    return log.strip().splitlines()[-1][:300] if log.strip() else ""


def summarize(data: dict) -> dict:
    targets = data["targets"]
    real = {k: v for k, v in targets.items() if v["type"] not in ("binary", "plugin", "manifest")}
    if any("built" in v for v in real.values()):
        builds = sorted(k for k, v in real.items() if v.get("built"))
    else:
        builds = sorted(k for k, v in real.items() if not v["blockers"])
    reasons: dict[str, int] = {}
    imports: dict[str, int] = {}
    for v in real.values():
        if v["blockers"] and not v.get("built"):
            reasons[v["blockers"][0]] = reasons.get(v["blockers"][0], 0) + 1
        for module in v.get("imports", []):
            imports[module] = imports.get(module, 0) + 1
    return dict(
        packages=data["packages"], targets=len(real), builds_on_linux=len(builds),
        measured=any("built" in v for v in real.values()),
        first_blocker_counts=dict(sorted(reasons.items(), key=lambda kv: -kv[1])),
        apple_import_counts=dict(sorted(imports.items(), key=lambda kv: -kv[1])),
        builds=builds,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("census", "check"):
        p = sub.add_parser(name)
        p.add_argument("--root", type=Path, default=Path.cwd())
        p.add_argument("--swift", default=os.environ.get("SWIFT", "swift"))
        p.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
        p.add_argument("--build", action="store_true",
                       help="compile targets to measure them: every target for census; for check, "
                            "the baseline's targets plus every target with no static blocker")
        p.add_argument("--scratch", type=Path, default=Path("/tmp/linux-swift-census"))
        p.add_argument("--json", type=Path, help="write the full per-target report here")
        p.add_argument("--baseline", type=Path, default=Path("scripts/ci/linux_swift_targets.json"))
        if name == "census":
            p.add_argument("--write-baseline", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    data = census(root, args.swift, args.jobs)
    baseline_path = args.baseline if args.baseline.is_absolute() else root / args.baseline
    baseline = json.loads(baseline_path.read_text()) if args.cmd == "check" else None
    if args.build:
        only = None
        if baseline is not None:
            # A target with an unguarded Apple import or a blocked dependency
            # cannot compile on Linux; skipping it keeps the check to minutes.
            only = set(baseline["builds"]) | {k for k, v in data["targets"].items() if not v["blockers"]}
        build_targets(root, args.swift, data, max(1, args.jobs // 4), args.scratch, only)
    summary = summarize(data)
    if args.json:
        args.json.write_text(json.dumps(dict(summary=summary, targets=data["targets"]), indent=1, sort_keys=True) + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "builds"}, indent=1))
    if args.cmd == "census":
        if args.write_baseline:
            baseline_path.write_text(json.dumps(
                dict(builds_on_linux=summary["builds_on_linux"], targets=summary["targets"],
                     builds=summary["builds"]), indent=1) + "\n")
        return 0
    # A removed or renamed target is not a regression; one that still exists
    # and stopped compiling is.
    lost = sorted(k for k in set(baseline["builds"]) - set(summary["builds"]) if k in data["targets"])
    gained = sorted(set(summary["builds"]) - set(baseline["builds"]))
    for key in lost:
        entry = data["targets"][key]
        why = f"{entry['blockers']} {entry.get('error') or entry.get('blocked_by') or entry.get('imports', '')}"
        print(f"::error title=Linux Swift ratchet::{key} built on Linux in the baseline and no longer does: {why}")
    if gained:
        print(f"::notice title=Linux Swift ratchet::{len(gained)} more target(s) build on Linux: {', '.join(gained)}. "
              "Raise the baseline: python3 scripts/ci/linux_swift_target_census.py census --build --write-baseline")
    if lost:
        return 1
    print(f"Linux Swift ratchet: {summary['builds_on_linux']} of {summary['targets']} targets build on Linux "
          f"(baseline {baseline['builds_on_linux']}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
