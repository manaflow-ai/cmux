#!/usr/bin/env python3
"""Write or check the `generated` part of Packages/macOS/CmuxNext/linux-tier.json.

linux-tier.json says which CmuxNext targets build on Linux (plans/cmux-next/chrome-parity/p15-oracle.md,
section H). People edit `waves`, `new`, `excludedPackages` and `ffi`; this script writes `generated`, which
the Linux scripts read, and copies `ffi` and the lists the manifest uses into the Linux mode of Package.swift
(CMUX_SWIFTPM_TARGET_LINUX=1 on Linux) as a literal between its `BEGIN linux-tier.py` and `END linux-tier.py`
lines. The manifest reads no file: SwiftPM keys its manifest cache on the manifest text, so every tier change
is a manifest change.

  targets             the tier's source targets that exist, in wave order, then CZlib and CCmuxNextLinux when a
                      target needs them
  testTargets         the test targets whose every in-package dependency is a tier target
  products            the library products whose every target is a tier target
  pathDependencies    the local packages (repository paths) the kept targets use, excluded packages left out
  remoteDependencies  the remote package identities the kept targets use, swift-crypto when one needs Crypto
  linuxDependencies   per kept target, the Linux stand-ins its imports need: Crypto for CryptoKit (swift-crypto),
                      CZlib for Compression, CCmuxNextLinux for the Linux system interfaces Glibc does not import
  blockedEdges        per kept target, the dependencies the Linux mode drops: an in-package target outside the
                      tier or a product of an excluded package (a compile error there is the Linux work queue)
  absent              tier names with no target yet (the `new` targets until their tasks land them)

The input is `swift package dump-package` of the Apple manifest (the Linux variable is unset for that run),
the same JSON scripts/cmux-next/ci-target-graph.py reads, and the targets' Swift imports. Stdlib only.

Usage: scripts/cmux-next/linux/linux-tier.py [--check] [--dump FILE]
  --check      exit 1 when the committed `generated` part or the Package.swift literal is stale
  --dump FILE  read dump-package JSON from FILE instead of running swift
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PACKAGE = ROOT / "Packages/macOS/CmuxNext"
TIER = PACKAGE / "linux-tier.json"
MANIFEST = PACKAGE / "Package.swift"
LINUX_VARIABLE = "CMUX_SWIFTPM_TARGET_LINUX"
HEADER = "Written by scripts/cmux-next/linux/linux-tier.py from swift package dump-package; do not edit."
BEGIN = "    // BEGIN linux-tier.py: generated from linux-tier.json by scripts/cmux-next/linux/linux-tier.py; do not edit.\n"
END = "    // END linux-tier.py\n"
# The generated lists the Linux mode of Package.swift uses, in its LinuxTier.Generated argument order.
MANIFEST_FIELDS = ("targets", "testTargets", "products", "pathDependencies", "remoteDependencies", "linuxDependencies")

# Imports that need a Linux stand-in: the module, then the dependency the Linux mode adds for it.
STAND_INS = (
    (re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|private|fileprivate)\s+)?"
                r"import\s+(?:CryptoKit|Crypto)\b", re.M), "Crypto"),
    (re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|private|fileprivate)\s+)?"
                r"import\s+(?:Compression|CZlib)\b", re.M), "CZlib"),
    (re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|private|fileprivate)\s+)?"
                r"import\s+CCmuxNextLinux\b", re.M), "CCmuxNextLinux"),
)
ZLIB_TARGET = "CZlib"
# The Linux system interfaces Glibc does not import (epoll, eventfd, timerfd, struct ucred; p15-oracle-126).
LINUX_SHIM_TARGET = "CCmuxNextLinux"
# The stand-ins that are system-library targets of this package (the rest are swift-crypto's Crypto).
SYSTEM_TARGETS = (ZLIB_TARGET, LINUX_SHIM_TARGET)
CRYPTO_PACKAGE = "swift-crypto"


def graph_module():
    """scripts/cmux-next/ci-target-graph.py: its dump-package readers are the one implementation."""
    spec = importlib.util.spec_from_file_location("ci_target_graph", ROOT / "scripts/cmux-next/ci-target-graph.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def dump_package(dump: Path | None) -> dict:
    if dump is not None:
        return json.loads(dump.read_text(encoding="utf-8"))
    env = {key: value for key, value in os.environ.items() if key != LINUX_VARIABLE}
    output = subprocess.run(["swift", "package", "dump-package"], cwd=PACKAGE, env=env, check=True,
                            capture_output=True, text=True).stdout
    return json.loads(output)


def identity(location: str) -> str:
    """SwiftPM's package identity: the last path component, without `.git`, lowercased."""
    name = location.rstrip("/").rsplit("/", 1)[-1]
    return (name[:-4] if name.endswith(".git") else name).lower()


def remote_identities(manifest: dict) -> set[str]:
    found = set()
    for dependency in manifest.get("dependencies", []):
        for spec in dependency.get("sourceControl", []):
            found.add(spec["identity"].lower())
    return found


def stand_ins(directory: Path) -> list[str]:
    needed = set()
    for source in sorted(directory.rglob("*.swift")):
        text = source.read_text(encoding="utf-8", errors="replace")
        needed.update(name for pattern, name in STAND_INS if pattern.search(text))
    return sorted(needed)


def build(tier: dict, manifest: dict, graph) -> dict:
    ffi = tier["ffi"]
    excluded = {name.lower() for name in tier["excludedPackages"]}
    local = {name.lower(): path for name, path in graph.local_packages(manifest).items()}
    remote = remote_identities(manifest)
    declared = {target["name"]: target for target in manifest["targets"]}
    platform = {ffi["target"]: f"Sources/{ffi['target']}"} | {name: f"Sources/{name}" for name in SYSTEM_TARGETS}

    wanted = [name for wave in tier["waves"] for name in wave] + tier["new"]
    duplicates = sorted({name for name in wanted if wanted.count(name) > 1})
    if duplicates:
        raise SystemExit(f"{TIER.relative_to(ROOT)}: listed more than once: {', '.join(duplicates)}")
    for name in wanted:
        if declared.get(name, {}).get("type") == "test":
            raise SystemExit(f"{TIER.relative_to(ROOT)}: {name} is a test target; test targets are generated")
    # The Linux mode declares the FFI target itself whenever the Apple manifest has the binary target it replaces.
    present = [name for name in wanted
               if (name in declared and name != ffi["replaces"]) or (name == ffi["target"] and ffi["replaces"] in declared)]
    absent = [name for name in wanted if name not in present]

    def directory(name: str) -> Path:
        if name in platform:
            return PACKAGE / platform[name]
        target = declared[name]
        return PACKAGE / (target.get("path") or ("Tests/" if target["type"] == "test" else "Sources/") + name)

    def split(name: str, sources: set[str]) -> tuple[list[str], list[str], set[str]]:
        """(kept target deps, dropped deps, kept package identities) of a declared target."""
        kept, dropped, packages = [], [], set()
        for dependency in declared[name].get("dependencies", []) if name in declared else []:
            how, dep = graph.dependency_name(dependency)
            if how in ("target", "byName"):
                if dep not in declared:
                    raise SystemExit(f"{name}: by-name dependency {dep} is not a target of this package")
                dep = ffi["target"] if dep == ffi["replaces"] else dep
                (kept if dep in sources else dropped).append(dep)
            else:
                package = dep.lower()
                if package in excluded:
                    dropped.append(f"{dependency['product'][0]} ({dep})")
                elif package in local or package in remote:
                    packages.add(package)
                else:
                    raise SystemExit(f"{name}: product {dependency['product'][0]} names unknown package {dep}")
        return kept, dropped, packages

    sources = set(present)
    tests = []
    for name, target in sorted(declared.items()):
        if target["type"] != "test":
            continue
        kept, dropped, _ = split(name, sources)
        if kept and not dropped:
            tests.append(name)

    kept_names = present + tests
    packages, blocked, linux = set(), {}, {}
    for name in kept_names:
        _, dropped, used = split(name, sources)
        packages |= used
        if dropped:
            blocked[name] = sorted(dropped)
        needed = stand_ins(directory(name))
        if needed:
            linux[name] = needed
    targets = [name for name in present if name not in SYSTEM_TARGETS]
    for system in SYSTEM_TARGETS:
        if any(system in needed for needed in linux.values()):
            if not (PACKAGE / platform[system]).is_dir():
                raise SystemExit(f"a tier target needs {system} but {platform[system]} is missing")
            targets.append(system)
    remote_used = sorted(packages & remote)
    if any("Crypto" in needed for needed in linux.values()):
        remote_used = sorted(set(remote_used) | {CRYPTO_PACKAGE})
    products = sorted(product["name"] for product in manifest.get("products", [])
                      if product["targets"] and all(t in sources for t in product["targets"]))
    return {
        "_comment": HEADER,
        "targets": targets,
        "testTargets": tests,
        "products": products,
        "pathDependencies": sorted(local[p] for p in packages if p in local),
        "remoteDependencies": remote_used,
        "linuxDependencies": dict(sorted(linux.items())),
        "blockedEdges": dict(sorted(blocked.items())),
        "absent": absent,
    }


def render(tier: dict) -> str:
    return json.dumps(tier, indent=2) + "\n"


def swift_literal(value, indent: str) -> str:
    """``value`` (a string, a list of strings or a dict of string lists) as a Swift literal, one entry per line."""
    inner = indent + "    "
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, dict):
        if not value:
            return "[:]"
        entries = (f"{inner}{json.dumps(key)}: {swift_literal(item, inner)}," for key, item in value.items())
        return "[\n" + "\n".join(entries) + f"\n{indent}]"
    if not value:
        return "[]"
    if all(isinstance(item, str) for item in value) and len(value) <= 3:
        return "[" + ", ".join(json.dumps(item) for item in value) + "]"
    return "[\n" + "\n".join(f"{inner}{json.dumps(item)}," for item in value) + f"\n{indent}]"


def render_manifest_tier(tier: dict) -> str:
    """The `let linuxTier = LinuxTier(...)` literal of the Linux mode of Package.swift."""
    ffi, generated = tier["ffi"], tier["generated"]
    ffi_fields = ("replaces", "target", "library", "libraryDirectory")
    lines = ["    let linuxTier = LinuxTier(", "        ffi: LinuxTier.FFI("]
    lines += [f"            {name}: {json.dumps(ffi[name])}," for name in ffi_fields]
    lines += ["        ),", "        generated: LinuxTier.Generated("]
    lines += [f"            {name}: {swift_literal(generated[name], '            ')}," for name in MANIFEST_FIELDS]
    lines += ["        ),", "    )"]
    return "\n".join(lines) + "\n"


def splice_manifest(manifest: str, tier: dict) -> str:
    """``manifest`` with the text between its BEGIN and END linux-tier.py lines replaced by the tier literal."""
    if manifest.count(BEGIN) != 1 or manifest.count(END) != 1 or manifest.index(BEGIN) > manifest.index(END):
        raise SystemExit(f"{MANIFEST.relative_to(ROOT)}: needs one {BEGIN.strip()!r} line, "
                         f"then one {END.strip()!r} line")
    head, rest = manifest.split(BEGIN)
    _, tail = rest.split(END)
    return head + BEGIN + render_manifest_tier(tier) + END + tail


def main(argv: list[str], graph=None) -> int:
    """``graph`` is the ci-target-graph module (tests pass one with a stubbed local_packages)."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true",
                        help="fail when the committed `generated` part or the Package.swift literal is stale")
    parser.add_argument("--dump", type=Path, help="dump-package JSON to read instead of running swift")
    args = parser.parse_args(argv)

    current = TIER.read_text(encoding="utf-8")
    current_manifest = MANIFEST.read_text(encoding="utf-8")
    tier = json.loads(current)
    tier["generated"] = build(tier, dump_package(args.dump), graph or graph_module())
    text = render(tier)
    manifest = splice_manifest(current_manifest, tier)
    relative = TIER.relative_to(ROOT)
    pairs = ((TIER, current, text), (MANIFEST, current_manifest, manifest))
    stale = [str(path.relative_to(ROOT)) for path, old, new in pairs if old != new]
    if args.check:
        if stale:
            print(f"{', '.join(stale)} stale. Run: scripts/cmux-next/linux/linux-tier.py", file=sys.stderr)
            return 1
        print(f"{relative} and its Package.swift literal are fresh")
        return 0
    TIER.write_text(text, encoding="utf-8")
    MANIFEST.write_text(manifest, encoding="utf-8")
    generated = tier["generated"]
    print(f"wrote {relative}: {len(generated['targets'])} targets, {len(generated['testTargets'])} test targets, "
          f"{len(generated['blockedEdges'])} with blocked edges, {len(generated['absent'])} absent")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
