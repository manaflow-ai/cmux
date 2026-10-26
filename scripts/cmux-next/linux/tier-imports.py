#!/usr/bin/env python3
"""List what keeps each CmuxNext target from building on Linux (p15-oracle task 005, queue MQ-linux-imports).

For every target in Packages/macOS/CmuxNext/ci-target-graph.json it reports:

  imports   imports of a module Linux does not have: the MQ-linux-imports list (AppKit ... CmuxNextDesign,
            CmuxNextIcons) and the other Darwin-only modules this package imports. Every import form
            counts: attributes (`@preconcurrency`, `@_exported`), access levels (`public import`), kind
            imports (`import struct CmuxNextDesign.LaunchReveal`) and submodules (`import os.log`,
            `import Carbon.HIToolbox`). C and C++ files count Darwin-only headers (`<mach/mach.h>`,
            `<crt_externs.h>`); Objective-C files (.m, .mm) count as a whole, as Linux SwiftPM does not
            compile them.
  symbols   Darwin-only API used without an import: URLSession and its family (unless the file imports
            FoundationNetworking), FSEvent*, sysctl, os_unfair_lock, OSAllocatedUnfairLock,
            DistributedNotificationCenter.
  edges     the target's dependencies (targets in this package and local packages) that are blocked,
            and the directly blocked targets or packages at the end of those edges (roots).

Code that Linux does not compile is skipped: comments, string literals and `#if` branches that are false on
Linux (`os(macOS)`, `canImport(AppKit)`, `targetEnvironment(macCatalyst)`, C `__APPLE__`, and their
`!`/`&&`/`||` forms). A
condition the scanner cannot decide (`DEBUG`, `arch(...)`) counts as compiled, so the report never calls a
target clean that is not.

A local package is Linux-ready when a Linux CI workflow names it (the MQ-shared-packages rule); otherwise it is
blocked by an xcframework binary target (SwiftPM on Linux reads artifact bundles only), by its own Sources, or
by a package it depends on by path. External products (Sparkle, sentry-cocoa) are caught by their module
names. CCmuxAppFFI counts as available: the Linux mode maps it to CCmuxAppFFILinux (task 002).

When Packages/macOS/CmuxNext/linux-tier.json exists, each target shows its wave, and `--check` exits 1 when a
tier target is blocked (task 226: every wave-3 target is in-tier or names its blocking edge).

The output is sorted everywhere, so it does not depend on graph, directory or file order.

Usage: scripts/cmux-next/linux/tier-imports.py [--rev REV] [--json | --files | --summary]
           [--target NAME ...] [--blocked] [--check] [--root DIR]
  --rev REV       read the tree of a git revision instead of the working tree (run at base and tip)
  --json          the whole report as JSON
  --files         one line per finding: path:line, target, module or symbol (the queue input)
  --summary       counts only
  --target NAME   only these targets (repeatable; `Compat` means `CmuxNextCompat`)
  --blocked       only blocked targets
  --check         exit 1 when a linux-tier.json target is blocked
  --root DIR      repository root (default: this checkout)

Exit status: 0, 1 for --check failures, 2 for usage or input errors.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Mapping

ROOT = Path(__file__).resolve().parents[3]
PACKAGE_DIR = "Packages/macOS/CmuxNext"
GRAPH_PATH = f"{PACKAGE_DIR}/ci-target-graph.json"
TIER_PATH = f"{PACKAGE_DIR}/linux-tier.json"
LINUX_WORKFLOWS = (
    ".github/workflows/swift-packages-linux.yml",
    ".github/workflows/cmux-next-terminal.yml",
)

# The MQ-linux-imports module list (plans/cmux-next/chrome-parity/p15-oracle.md, machine queues).
QUEUE_MODULES = (
    "AppKit", "SwiftUI", "WebKit", "QuartzCore", "Carbon", "os", "OSLog", "Darwin", "CoreGraphics",
    "CoreFoundation", "CryptoKit", "Security", "MachO", "XPC", "MetricKit", "SystemConfiguration",
    "Compression", "CommonCrypto", "Network", "IOKit", "UniformTypeIdentifiers", "CoreServices",
    "LocalAuthentication", "CFNetwork", "SQLite3", "ImageIO", "CmuxNextDesign", "CmuxNextIcons",
)
# Darwin-only modules CmuxNext also imports, which the queue list leaves out. GhosttyNextKit is an Apple
# xcframework; Sparkle and Sentry are the external sparkle and sentry-cocoa products.
DARWIN_MODULES = (
    "AVFoundation", "Accelerate", "ApplicationServices", "AuthenticationServices", "Combine", "CoreImage",
    "CoreMedia", "CoreText", "CoreVideo", "DeviceCheck", "GhosttyNextKit", "IOSurface", "JavaScriptCore",
    "MediaPlayer", "Metal", "ObjectiveC", "Quartz", "QuickLookThumbnailing", "ScreenCaptureKit", "Sentry",
    "ServiceManagement", "Sparkle", "Speech", "UIKit", "UserNotifications", "VideoToolbox",
)
BLOCKED_MODULES = frozenset(QUEUE_MODULES + DARWIN_MODULES)
# Modules the swift.org Linux toolchain ships, so `canImport` of one is true there.
LINUX_MODULES = frozenset({
    "Foundation", "FoundationEssentials", "FoundationInternationalization", "FoundationNetworking",
    "FoundationXML", "Glibc", "Musl", "Dispatch", "Observation", "Synchronization", "Testing", "XCTest",
    "RegexBuilder", "Distributed",
})
LINUX_OS = "Linux"
OTHER_OS = frozenset({
    "macOS", "iOS", "tvOS", "watchOS", "visionOS", "Windows", "Android", "FreeBSD", "OpenBSD", "WASI",
    "Cygwin", "PS4", "Haiku",
})
NOT_LINUX_ENVIRONMENTS = frozenset({"macCatalyst", "simulator"})
# Binary targets the Linux mode replaces with a source module (task 002).
LINUX_MAPPED_BINARIES = {"CCmuxAppFFI": "CCmuxAppFFILinux"}

URLSESSION = re.compile(
    r"\bURLSession(?:Configuration|(?:Data|Download|Upload|Stream|WebSocket)?Task(?:Metrics|TransactionMetrics)?"
    r"|(?:Data|Download|Stream|Task|WebSocket)?Delegate)?\b"
)
SYMBOLS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("URLSession", URLSESSION),
    ("FSEvent", re.compile(r"\bk?FSEvent(?:Stream\w*)?\b")),
    ("sysctl", re.compile(r"\bsysctl(?:byname|nametomib)?\b")),
    ("os_unfair_lock", re.compile(r"\bos_unfair_lock\w*")),
    ("OSAllocatedUnfairLock", re.compile(r"\bOSAllocatedUnfairLock\b")),
    ("DistributedNotificationCenter", re.compile(r"\bDistributedNotificationCenter\b")),
)
SYMBOL_NAMES = tuple(name for name, _ in SYMBOLS)
# The symbol a module import makes available on Linux.
SYMBOL_PROVIDERS = {"URLSession": "FoundationNetworking"}

IMPORT = re.compile(
    r"^\s*(?:@[A-Za-z_]\w*(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|package|internal|private|fileprivate|open)\s+)?"
    r"import\s+(?:(?:struct|class|enum|func|typealias|protocol|var|let)\s+)?"
    r"([A-Za-z_]\w*)((?:\.\w+)*)\s*;?\s*$"
)
DIRECTIVE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")
C_DIRECTIVE = re.compile(r"^\s*#\s*(if|ifdef|ifndef|elif|else|endif)\b(.*)$")
C_INCLUDE = re.compile(r"^\s*#\s*(?:include|import)\s*<([^>]+)>")
C_DEFINED = re.compile(r"\bdefined\s*\(?\s*(\w+)\s*\)?")
SWIFT_EXTENSIONS = (".swift",)
C_EXTENSIONS = (".c", ".h", ".cc", ".cpp", ".hpp")
OBJC_EXTENSIONS = (".m", ".mm")
# C headers whose first path component (or whole name) exists only in the Apple SDKs.
DARWIN_HEADERS = frozenset({
    "mach", "mach-o", "malloc", "os", "libkern", "xpc", "objc", "CoreFoundation", "Foundation", "AppKit",
    "QuartzCore", "CoreGraphics", "Security", "IOKit", "Cocoa", "Metal", "IOSurface", "CoreServices",
    "TargetConditionals.h", "Availability.h", "AvailabilityMacros.h", "libproc.h", "sys/sysctl.h",
    "sys/proc_info.h", "crt_externs.h", "notify.h", "bsm",
})
# C predefined macros: false or true when the Linux toolchain compiles.
C_MACROS = {"__APPLE__": False, "__MACH__": False, "__OBJC__": False, "__linux__": True, "__linux": True, "__gnu_linux__": True}
STRING_OPEN = re.compile(r'(#*)("""|")')
PATH_DEPENDENCY = re.compile(r'\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?path:\s*"([^"]+)"')
XCFRAMEWORK_BINARY = re.compile(r"\.binaryTarget\((?:[^()]|\([^()]*\))*?xcframework", re.S)


class InputError(Exception):
    """A missing or unreadable input file."""


# ---------------------------------------------------------------------------------------------- sources


class Source:
    """The files of one tree: the working tree or a git revision."""

    label: str

    def files(self, directory: str) -> list[str]:
        raise NotImplementedError

    def read_many(self, paths: Iterable[str]) -> dict[str, str]:
        raise NotImplementedError

    def read(self, path: str) -> str | None:
        return self.read_many([path]).get(path)


class WorkingTree(Source):
    def __init__(self, root: Path) -> None:
        self.root = root
        self.label = "working tree"

    def files(self, directory: str) -> list[str]:
        base = self.root / directory
        found: list[str] = []
        for current, dirs, names in os.walk(base):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for name in names:
                found.append((Path(current) / name).relative_to(self.root).as_posix())
        return sorted(found)

    def read_many(self, paths: Iterable[str]) -> dict[str, str]:
        texts: dict[str, str] = {}
        for path in paths:
            try:
                texts[path] = (self.root / path).read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
        return texts


class GitTree(Source):
    def __init__(self, root: Path, rev: str) -> None:
        self.root = root
        self.sha = self._git("rev-parse", "--verify", "--end-of-options", f"{rev}^{{commit}}").decode().strip()
        self.label = f"{rev} ({self.sha[:12]})"
        listing = self._git("ls-tree", "-r", "-z", "--full-tree", self.sha)
        self.blobs: dict[str, str] = {}
        for entry in listing.split(b"\0"):
            if not entry:
                continue
            meta, _, path = entry.partition(b"\t")
            parts = meta.split()
            if len(parts) == 3 and parts[1] == b"blob":
                self.blobs[path.decode("utf-8", "surrogateescape")] = parts[2].decode()

    def _git(self, *args: str, stdin: bytes | None = None) -> bytes:
        result = subprocess.run(["git", "-C", str(self.root), *args], input=stdin, capture_output=True)
        if result.returncode != 0:
            raise InputError(f"git {args[0]} failed: {result.stderr.decode(errors='replace').strip()}")
        return result.stdout

    def files(self, directory: str) -> list[str]:
        prefix = directory.rstrip("/") + "/"
        return sorted(path for path in self.blobs if path.startswith(prefix))

    def read_many(self, paths: Iterable[str]) -> dict[str, str]:
        wanted = [(path, self.blobs[path]) for path in paths if path in self.blobs]
        if not wanted:
            return {}
        out = self._git("cat-file", "--batch", stdin="".join(f"{sha}\n" for _, sha in wanted).encode())
        texts: dict[str, str] = {}
        offset = 0
        for path, _ in wanted:
            header_end = out.index(b"\n", offset)
            size = int(out[offset:header_end].split()[2])
            start = header_end + 1
            texts[path] = out[start:start + size].decode("utf-8", errors="replace")
            offset = start + size + 1
        return texts


# ----------------------------------------------------------------------------------------- swift lexing


def code_lines(text: str) -> Iterable[tuple[int, str]]:
    """Yield (line number, code) with comments removed and string literals reduced to `""`."""
    depth = 0
    open_string: str | None = None
    for number, line in enumerate(text.splitlines(), 1):
        if not depth and not open_string and '"' not in line and "/" not in line:
            yield number, line
            continue
        out: list[str] = []
        i, n = 0, len(line)
        while i < n:
            if depth:
                if line.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                elif line.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                else:
                    i += 1
                continue
            if open_string:
                end = line.find(open_string, i)
                if end < 0:
                    break
                i, open_string = end + len(open_string), None
                out.append('""')
                continue
            if line.startswith("//", i):
                break
            if line.startswith("/*", i):
                depth, i = 1, i + 2
                continue
            opened = STRING_OPEN.match(line, i)
            if opened:
                hashes, quote = opened.groups()
                close = quote + hashes
                if quote == '"""':
                    end = line.find(close, opened.end())
                    if end < 0:
                        open_string = close
                        break
                    i = end + len(close)
                else:
                    j = opened.end()
                    while j < n and not line.startswith(close, j):
                        j += 2 if (not hashes and line[j] == "\\") else 1
                    i = j + len(close)
                out.append('""')
                continue
            out.append(line[i])
            i += 1
        yield number, "".join(out)


# A three-valued answer to "does Linux compile this branch": True, False or None (cannot tell).
Truth = bool | None


class Condition:
    """Evaluates a `#if` condition for the Linux toolchain."""

    TOKEN = re.compile(r"\s*(&&|\|\||!|\(|\)|[A-Za-z_]\w*)")

    def __init__(self, text: str) -> None:
        self.text = text
        self.pos = 0

    @classmethod
    def evaluate(cls, text: str) -> Truth:
        parser = cls(text.strip())
        try:
            value = parser._or()
        except ValueError:
            return None
        return value if parser.pos >= len(parser.text) else None

    def _peek(self) -> str | None:
        match = self.TOKEN.match(self.text, self.pos)
        return match.group(1) if match else None

    def _take(self) -> str:
        match = self.TOKEN.match(self.text, self.pos)
        if not match:
            raise ValueError(self.text[self.pos:])
        self.pos = match.end()
        while self.pos < len(self.text) and self.text[self.pos].isspace():
            self.pos += 1
        return match.group(1)

    def _or(self) -> Truth:
        value = self._and()
        while self._peek() == "||":
            self._take()
            right = self._and()
            value = True if True in (value, right) else (None if None in (value, right) else False)
        return value

    def _and(self) -> Truth:
        value = self._unary()
        while self._peek() == "&&":
            self._take()
            right = self._unary()
            value = False if False in (value, right) else (None if None in (value, right) else True)
        return value

    def _unary(self) -> Truth:
        if self._peek() == "!":
            self._take()
            value = self._unary()
            return None if value is None else not value
        return self._primary()

    def _primary(self) -> Truth:
        token = self._take()
        if token == "(":
            value = self._or()
            if self._take() != ")":
                raise ValueError("unbalanced")
            return value
        if not re.match(r"[A-Za-z_]", token):
            raise ValueError(token)
        if self.pos < len(self.text) and self.text[self.pos] == "(":
            return self._call(token, self._argument())
        return {"true": True, "false": False, **C_MACROS}.get(token)

    def _argument(self) -> str:
        depth, start = 0, self.pos
        for index in range(self.pos, len(self.text)):
            char = self.text[index]
            depth += {"(": 1, ")": -1}.get(char, 0)
            if depth == 0:
                self.pos = index + 1
                while self.pos < len(self.text) and self.text[self.pos].isspace():
                    self.pos += 1
                return self.text[start + 1:index].strip()
        raise ValueError("unbalanced")

    @staticmethod
    def _call(name: str, argument: str) -> Truth:
        first = argument.split(",")[0].strip()
        if name == "os":
            return True if first == LINUX_OS else (False if first in OTHER_OS else None)
        if name == "canImport":
            module = first.split(".")[0]
            return False if module in BLOCKED_MODULES else (True if module in LINUX_MODULES else None)
        if name == "targetEnvironment":
            return False if first in NOT_LINUX_ENVIRONMENTS else None
        return None


@dataclass(frozen=True, order=True)
class Finding:
    line: int
    name: str


@dataclass
class FileScan:
    imports: list[Finding] = field(default_factory=list)
    symbols: list[Finding] = field(default_factory=list)


class Branches:
    """The `#if` stack of one file: whether Linux may compile the current line."""

    def __init__(self) -> None:
        # Each frame: (parent compiled, an earlier branch is surely compiled, this branch may be compiled).
        self.frames: list[tuple[bool, bool, bool]] = []

    @property
    def compiled(self) -> bool:
        return self.frames[-1][2] if self.frames else True

    def open(self, value: Truth) -> None:
        compiled = self.compiled
        self.frames.append((compiled, value is True, compiled and value is not False))

    def otherwise(self, value: Truth = True) -> None:
        if self.frames:
            parent, taken, _ = self.frames[-1]
            self.frames[-1] = (parent, taken or value is True, parent and not taken and value is not False)

    def close(self) -> None:
        if self.frames:
            self.frames.pop()


def symbol_findings(number: int, code: str) -> list[Finding]:
    return [Finding(number, name) for name, pattern in SYMBOLS if pattern.search(code)]


def scan_swift(text: str) -> FileScan:
    """The blocked imports and unprovided symbols in the Linux-compiled code of one Swift file."""
    branches = Branches()
    imported: set[str] = set()
    blocked: list[Finding] = []
    symbols: list[Finding] = []
    for number, code in code_lines(text):
        directive = DIRECTIVE.match(code)
        if directive:
            kind, rest = directive.groups()
            if kind == "if":
                branches.open(Condition.evaluate(rest))
            elif kind == "elseif":
                branches.otherwise(Condition.evaluate(rest))
            elif kind == "else":
                branches.otherwise()
            else:
                branches.close()
            continue
        if not branches.compiled:
            continue
        match = IMPORT.match(code)
        if match:
            module = match.group(1)
            imported.add(module)
            if module in BLOCKED_MODULES:
                blocked.append(Finding(number, module + match.group(2)))
            continue
        symbols += symbol_findings(number, code)
    unprovided = [s for s in symbols if SYMBOL_PROVIDERS.get(s.name) not in imported]
    return FileScan(imports=sorted(blocked), symbols=sorted(unprovided))


def c_condition(kind: str, rest: str) -> Truth:
    if kind in ("ifdef", "ifndef"):
        value = C_MACROS.get(rest.strip())
        return value if kind == "ifdef" or value is None else not value
    return Condition.evaluate(C_DEFINED.sub(lambda m: m.group(1), rest))


def scan_c(text: str) -> FileScan:
    """The Darwin-only headers and symbols in the Linux-compiled code of one C or C++ file."""
    branches = Branches()
    blocked: list[Finding] = []
    symbols: list[Finding] = []
    for number, code in code_lines(text):
        directive = C_DIRECTIVE.match(code)
        if directive:
            kind, rest = directive.groups()
            if kind in ("if", "ifdef", "ifndef"):
                branches.open(c_condition(kind, rest))
            elif kind == "elif":
                branches.otherwise(c_condition("if", rest))
            elif kind == "else":
                branches.otherwise()
            else:
                branches.close()
            continue
        if not branches.compiled:
            continue
        include = C_INCLUDE.match(code)
        if include:
            header = include.group(1).strip()
            if header in DARWIN_HEADERS or header.split("/")[0] in DARWIN_HEADERS:
                blocked.append(Finding(number, f"<{header}>"))
            continue
        symbols += symbol_findings(number, code)
    return FileScan(imports=sorted(blocked), symbols=sorted(symbols))


def scan_file(path: str, text: str) -> FileScan:
    if path.endswith(OBJC_EXTENSIONS):
        return FileScan(imports=[Finding(1, "Objective-C source")])
    if path.endswith(C_EXTENSIONS):
        return scan_c(text)
    return scan_swift(text)


# ------------------------------------------------------------------------------------------------ report


@dataclass
class Node:
    """A target of CmuxNext or a local package, with what blocks it."""

    name: str
    kind: str
    path: str | None
    deps: list[str]
    imports: list[dict] = field(default_factory=list)
    symbols: list[dict] = field(default_factory=list)
    reason: str | None = None
    wave: str | None = None
    linux_ci: bool = False

    @property
    def direct(self) -> bool:
        return bool(self.imports or self.symbols or self.reason)


def package_node_name(name: str) -> str:
    return f"package:{name}"


def findings(scans: Mapping[str, FileScan], attribute: str, key: str) -> list[dict]:
    return [
        {"file": path, "line": item.line, key: item.name}
        for path in sorted(scans)
        for item in getattr(scans[path], attribute)
    ]


def scan_directory(source: Source, directory: str) -> dict[str, FileScan]:
    extensions = SWIFT_EXTENSIONS + C_EXTENSIONS + OBJC_EXTENSIONS
    paths = [p for p in source.files(directory) if p.endswith(extensions)]
    texts = source.read_many(paths)
    scans = {path: scan_file(path, texts[path]) for path in sorted(texts)}
    return {path: scan for path, scan in scans.items() if scan.imports or scan.symbols}


def linux_ci_names(source: Source) -> str:
    return "\n".join(text for text in source.read_many(LINUX_WORKFLOWS).values())


def normalize(path: str) -> str:
    return os.path.normpath(path).replace(os.sep, "/")


def package_nodes(source: Source, roots: Mapping[str, str]) -> dict[str, Node]:
    """Every local package reachable from `roots` (name -> repo path), with its blocker."""
    workflows = linux_ci_names(source)
    nodes: dict[str, Node] = {}
    pending = deque(sorted(roots.items()))
    while pending:
        name, path = pending.popleft()
        key = package_node_name(name)
        if key in nodes:
            continue
        manifest = source.read(f"{path}/Package.swift") or ""
        deps: list[str] = []
        for relative in sorted(set(PATH_DEPENDENCY.findall(manifest))):
            dep_path = normalize(f"{path}/{relative}")
            dep_name = dep_path.rsplit("/", 1)[-1]
            deps.append(package_node_name(dep_name))
            pending.append((dep_name, dep_path))
        node = Node(name=key, kind="package", path=path, deps=sorted(set(deps)))
        if re.search(rf"(?<![\w-]){re.escape(name)}(?![\w-])", workflows):
            node.deps, node.linux_ci = [], True
        elif XCFRAMEWORK_BINARY.search(manifest):
            node.reason = "xcframework binary target"
        else:
            scans = scan_directory(source, f"{path}/Sources")
            node.imports = findings(scans, "imports", "module")
            node.symbols = findings(scans, "symbols", "symbol")
        nodes[key] = node
    return nodes


def read_tier(source: Source, names: Iterable[str]) -> dict[str, str]:
    """Target name -> wave label from linux-tier.json (`.waves[][]`), or {} when there is no tier file."""
    text = source.read(TIER_PATH)
    if text is None:
        return {}
    try:
        waves = json.loads(text)["waves"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise InputError(f"{TIER_PATH}: no readable `waves`: {error}") from error
    items = waves.items() if isinstance(waves, dict) else enumerate(waves)
    known = set(names)
    tier: dict[str, str] = {}
    for label, members in items:
        for member in members:
            name = member if member in known or f"CmuxNext{member}" not in known else f"CmuxNext{member}"
            tier[name] = str(label)
    return tier


def build_report(source: Source) -> dict:
    graph_text = source.read(GRAPH_PATH)
    if graph_text is None:
        raise InputError(f"{GRAPH_PATH} is missing in {source.label}")
    graph = json.loads(graph_text)
    targets: Mapping[str, Mapping] = graph["targets"]
    packages = package_nodes(source, graph.get("packages", {}))

    nodes: dict[str, Node] = dict(packages)
    for name in sorted(targets):
        info = targets[name]
        deps = sorted(info.get("targets", [])) + sorted(package_node_name(p) for p in info.get("packages", []))
        node = Node(name=name, kind=info["kind"], path=info.get("path"), deps=deps)
        if node.kind == "binary":
            if name not in LINUX_MAPPED_BINARIES:
                node.reason = "binary target"
        elif node.path:
            scans = scan_directory(source, node.path)
            node.imports = findings(scans, "imports", "module")
            node.symbols = findings(scans, "symbols", "symbol")
        nodes[name] = node

    tier = read_tier(source, targets)
    for name, wave in tier.items():
        if name in nodes:
            nodes[name].wave = wave

    blocked = blocked_set(nodes)
    report_targets = {}
    for name in sorted(targets):
        node = nodes[name]
        report_targets[name] = target_entry(node, nodes, blocked)
    report_packages = {
        node.name.removeprefix("package:"): {
            "path": node.path,
            "status": status(node, blocked),
            "reason": "linux ci" if node.linux_ci else node.reason,
            "imports": node.imports,
            "symbols": node.symbols,
            "blocked_deps": [d.removeprefix("package:") for d in node.deps if d in blocked],
        }
        for node in sorted(packages.values(), key=lambda n: n.name)
    }
    missing = sorted(name for name in tier if name not in nodes)
    return {
        "source": source.label,
        "graph": GRAPH_PATH,
        "tier": TIER_PATH if tier else None,
        "blocked_modules": sorted(BLOCKED_MODULES),
        "symbols": list(SYMBOL_NAMES),
        "packages": report_packages,
        "targets": report_targets,
        "tier_missing_from_graph": missing,
        "summary": summarize(report_targets, missing),
    }


def blocked_set(nodes: Mapping[str, Node]) -> set[str]:
    """Names of nodes that are blocked directly or through any dependency (memoized, cycle-safe)."""
    state: dict[str, bool] = {}

    def visit(name: str, trail: frozenset[str]) -> bool:
        if name in state:
            return state[name]
        node = nodes.get(name)
        if node is None or name in trail:
            return False
        result = node.direct
        for dep in node.deps:
            result = visit(dep, trail | {name}) or result
        state[name] = result
        return result

    for name in sorted(nodes):
        visit(name, frozenset())
    return {name for name, is_blocked in state.items() if is_blocked}


def status(node: Node, blocked: set[str]) -> str:
    if node.direct:
        return "direct"
    return "transitive" if node.name in blocked else "ok"


def roots_and_chain(start: Node, nodes: Mapping[str, Node], blocked: set[str]) -> tuple[list[str], list[str]]:
    """The nearest directly blocked nodes behind `start`'s blocked edges, and the shortest chain to one of them.

    The walk stops at a directly blocked node: what is behind it is that node's own report.
    """
    previous: dict[str, str | None] = {start.name: None}
    queue = deque([start.name])
    roots: list[str] = []
    first: str | None = None
    while queue:
        name = queue.popleft()
        for dep in nodes[name].deps:
            if dep in previous or dep not in blocked:
                continue
            previous[dep] = name
            if nodes[dep].direct:
                roots.append(dep)
                first = first or dep
            else:
                queue.append(dep)
    chain: list[str] = []
    cursor = first
    while cursor is not None:
        chain.append(cursor)
        cursor = previous[cursor]
    return sorted(roots), list(reversed(chain))


def target_entry(node: Node, nodes: Mapping[str, Node], blocked: set[str]) -> dict:
    roots, chain = roots_and_chain(node, nodes, blocked)
    return {
        "kind": node.kind,
        "path": node.path,
        "wave": node.wave,
        "status": status(node, blocked),
        "reason": node.reason,
        "imports": node.imports,
        "symbols": node.symbols,
        "blocked_deps": [d for d in node.deps if d in blocked],
        "roots": roots,
        "chain": chain,
    }


def summarize(targets: Mapping[str, dict], missing: list[str]) -> dict:
    counts = {"ok": 0, "direct": 0, "transitive": 0}
    tier = {"ok": 0, "direct": 0, "transitive": 0}
    for entry in targets.values():
        counts[entry["status"]] += 1
        if entry["wave"] is not None:
            tier[entry["status"]] += 1
    files = {f["file"] for e in targets.values() for f in e["imports"] + e["symbols"]}
    return {
        "targets": len(targets),
        **counts,
        "files_with_findings": len(files),
        "tier": {**tier, "missing_from_graph": len(missing)},
    }


# ------------------------------------------------------------------------------------------------ output


def tally(items: list[dict], key: str) -> str:
    counts: dict[str, int] = {}
    for item in items:
        counts[item[key]] = counts.get(item[key], 0) + 1
    return " ".join(f"{name}({count})" for name, count in sorted(counts.items())) or "-"


def short(name: str) -> str:
    return name.replace("package:", "pkg:")


def render_table(report: dict, names: list[str]) -> str:
    lines = ["# target\tkind\twave\tstatus\timports\tsymbols\tblocked deps\troots"]
    for name in names:
        entry = report["targets"][name]
        lines.append("\t".join([
            name,
            entry["kind"],
            entry["wave"] if entry["wave"] is not None else "-",
            entry["status"] + (f" ({entry['reason']})" if entry["reason"] else ""),
            tally(entry["imports"], "module"),
            tally(entry["symbols"], "symbol"),
            ",".join(short(d) for d in entry["blocked_deps"]) or "-",
            ",".join(short(r) for r in entry["roots"]) or "-",
        ]))
    blocked_packages = sorted(
        (name, entry) for name, entry in report["packages"].items() if entry["status"] != "ok"
    )
    for name, entry in blocked_packages:
        why = entry["reason"] or (tally(entry["imports"], "module") if entry["imports"] else "")
        via = ",".join(entry["blocked_deps"])
        lines.append(f"# package {name}: {entry['status']} {why}{' via ' + via if via else ''}".rstrip())
    lines.append(render_summary(report))
    return "\n".join(lines)


def render_files(report: dict, names: list[str]) -> str:
    rows = []
    for name in names:
        entry = report["targets"][name]
        rows += [(f["file"], f["line"], name, f["module"]) for f in entry["imports"]]
        rows += [(f["file"], f["line"], name, f["symbol"]) for f in entry["symbols"]]
    return "\n".join(f"{path}:{line}\t{target}\t{what}" for path, line, target, what in sorted(rows))


def render_summary(report: dict) -> str:
    s = report["summary"]
    text = (
        f"# {report['source']}: {s['targets']} targets, {s['ok']} ok, {s['direct']} direct, "
        f"{s['transitive']} transitive; {s['files_with_findings']} files with findings"
    )
    if report["tier"]:
        t = s["tier"]
        text += (
            f"; tier {t['ok']} ok, {t['direct']} direct, {t['transitive']} transitive, "
            f"{t['missing_from_graph']} not in the graph"
        )
    return text


def resolve_names(report: dict, wanted: list[str]) -> list[str]:
    known = report["targets"]
    names = []
    for name in wanted:
        if name in known:
            names.append(name)
        elif f"CmuxNext{name}" in known:
            names.append(f"CmuxNext{name}")
        else:
            raise InputError(f"unknown target {name}")
    return sorted(set(names))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--rev")
    parser.add_argument("--root", type=Path, default=ROOT)
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true")
    output.add_argument("--files", action="store_true")
    output.add_argument("--summary", action="store_true")
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--blocked", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)

    try:
        source: Source = GitTree(args.root, args.rev) if args.rev else WorkingTree(args.root)
        report = build_report(source)
        names = resolve_names(report, args.target) if args.target else sorted(report["targets"])
    except (InputError, json.JSONDecodeError, KeyError) as error:
        print(f"tier-imports: {error}", file=sys.stderr)
        return 2
    if args.check and not report["tier"]:
        print(f"tier-imports: --check needs {TIER_PATH}", file=sys.stderr)
        return 2
    if args.blocked:
        names = [n for n in names if report["targets"][n]["status"] != "ok"]

    if args.json:
        selected = dict(report, targets={n: report["targets"][n] for n in names})
        print(json.dumps(selected, indent=2, sort_keys=True))
    elif args.files:
        print(render_files(report, names))
    elif args.summary:
        print(render_summary(report))
    else:
        print(render_table(report, names))

    if args.check:
        failing = sorted(
            n for n, e in report["targets"].items() if e["wave"] is not None and e["status"] != "ok"
        )
        for name in failing:
            entry = report["targets"][name]
            edge = "its own files" if entry["status"] == "direct" else " -> ".join(short(n) for n in entry["chain"])
            print(f"tier-imports: {name} (wave {entry['wave']}) is blocked by {edge}", file=sys.stderr)
        if failing or report["tier_missing_from_graph"]:
            for name in report["tier_missing_from_graph"]:
                print(f"tier-imports: tier target {name} is not in {GRAPH_PATH}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
