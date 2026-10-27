#!/usr/bin/env python3
"""List what keeps each CmuxNext target from building on Linux (p15-oracle task 005, queue MQ-linux-imports).

For every target in Packages/macOS/CmuxNext/ci-target-graph.json and its Package.swift it reports:

  imports   imports of a module Linux does not have: the MQ-linux-imports list (AppKit ... CmuxNextDesign,
            CmuxNextIcons) and the other Darwin-only modules this package imports. Every import form
            counts: attributes (`@preconcurrency`, `@_exported`), access levels (`public import`), kind
            imports (`import struct CmuxNextDesign.LaunchReveal`) and submodules (`import os.log`,
            `import Carbon.HIToolbox`). C and C++ files count Darwin-only headers (`<mach/mach.h>`,
            `<crt_externs.h>`); Objective-C files (.m, .mm) count as a whole, as Linux SwiftPM does not
            compile them.
  symbols   Darwin-only API used without an import: URLSession and its family, and the other types Linux keeps
            in FoundationNetworking (URLRequest, URLResponse, HTTPURLResponse, HTTPCookie, URLCache,
            URLCredential, URLProtectionSpace, URLProtocol, URLAuthenticationChallenge), unless the file imports
            FoundationNetworking; FSEvent*, sysctl, os_unfair_lock, OSAllocatedUnfairLock,
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

The generated graph can be older than Package.swift, so the targets and edges come from both: each target
declaration of Package.swift (`.target`, `.testTarget`, ...) adds its target and its dependency edges
(`"Name"`, `.target(name:)`, `.byName(name:)`, `.product(name:package:)` of a local package). A target only
Package.swift names shows `in_graph: false`; one whose `dependencies:` is not an array literal has unknown
edges and the status `unknown`, which blocks its dependents like a blocked target does. A directory under
Sources/ or Tests/ that no target declares is still scanned and reported under `unmapped`, `direct` or
`unknown`, never `ok`.

When Packages/macOS/CmuxNext/linux-tier.json exists, each target shows its wave. A target its `pending` list names
shows `pending:` and its blocking edges instead: the targets of this package it depends on that no wave lists
(`pending_edges` in --json). `--check` exits 1 when a tier target is not `ok`, a tier or pending name is not a
target, a pending target is also in a wave or has no blocking edge left (it belongs in a wave), or a directory no
target declares exists (task 226: every wave-3 target is in-tier or names its blocking edge).

The output is sorted everywhere, so it does not depend on graph, directory or file order.

Usage: scripts/cmux-next/linux/tier-imports.py [--rev REV] [--json | --files | --summary]
           [--target NAME ...] [--blocked] [--check] [--root DIR]
  --rev REV       read the tree of a git revision instead of the working tree (run at base and tip)
  --json          the whole report as JSON
  --files         one line per finding: path:line, target, module or symbol (the queue input)
  --summary       counts only
  --target NAME   only these targets (repeatable; `Compat` means `CmuxNextCompat`)
  --blocked       only targets and directories that are not `ok`
  --check         exit 1 when a linux-tier.json target is not `ok` (see above)
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
# Where SwiftPM target directories live; a directory here that no graph target covers is reported as unmapped.
TARGET_ROOTS = (f"{PACKAGE_DIR}/Sources", f"{PACKAGE_DIR}/Tests")
UNMAPPED_PREFIX = "unmapped:"
UNKNOWN_EDGES = "dependencies Package.swift does not list as an array literal"
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
# Darwin-only modules CmuxNext and the local packages it reaches also import, which the queue list leaves out.
# GhosttyNextKit is an Apple xcframework; Sparkle and Sentry are the external sparkle and sentry-cocoa products;
# IrohLib (iroh-ffi) wraps an xcframework; NIOTransportServices is Network.framework's NIO transport and is empty
# off Darwin; dnssd and zlib are module maps of the Apple SDKs (the Linux mode uses CZlib).
DARWIN_MODULES = (
    "AVFoundation", "Accelerate", "ApplicationServices", "AuthenticationServices", "Combine", "CoreImage",
    "CoreMedia", "CoreText", "CoreVideo", "DeviceCheck", "GhosttyNextKit", "IOSurface", "IrohLib", "JavaScriptCore",
    "MediaPlayer", "Metal", "NIOTransportServices", "ObjectiveC", "Quartz", "QuickLookThumbnailing",
    "ScreenCaptureKit", "Sentry", "ServiceManagement", "Sparkle", "Speech", "UIKit", "UserNotifications",
    "VideoToolbox", "VisionKit", "dnssd", "zlib",
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
# The rest of FoundationNetworking: on Linux `import Foundation` does not declare these types either.
FOUNDATION_NETWORKING = re.compile(
    r"\b(?:URLRequest|URLResponse|HTTPURLResponse|CachedURLResponse|HTTPCookie(?:Storage|PropertyKey)?|URLCache"
    r"|URLCredential(?:Storage)?|URLProtectionSpace|URLProtocol(?:Client)?|URLAuthenticationChallenge(?:Sender)?)\b"
)
SYMBOLS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("URLSession", URLSESSION),
    ("FoundationNetworking", FOUNDATION_NETWORKING),
    ("FSEvent", re.compile(r"\bk?FSEvent(?:Stream\w*)?\b")),
    ("sysctl", re.compile(r"\bsysctl(?:byname|nametomib)?\b")),
    ("os_unfair_lock", re.compile(r"\bos_unfair_lock\w*")),
    ("OSAllocatedUnfairLock", re.compile(r"\bOSAllocatedUnfairLock\b")),
    ("DistributedNotificationCenter", re.compile(r"\bDistributedNotificationCenter\b")),
)
SYMBOL_NAMES = tuple(name for name, _ in SYMBOLS)
# The symbol a module import makes available on Linux.
SYMBOL_PROVIDERS = {"URLSession": "FoundationNetworking", "FoundationNetworking": "FoundationNetworking"}

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


def compiled_swift_lines(text: str) -> Iterable[tuple[int, str]]:
    """(line number, code) of each line of a Swift file Linux may compile: no `#if` lines, no false branches."""
    branches = Branches()
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
        elif branches.compiled:
            yield number, code


def scan_swift(text: str) -> FileScan:
    """The blocked imports and unprovided symbols in the Linux-compiled code of one Swift file."""
    imported: set[str] = set()
    blocked: list[Finding] = []
    symbols: list[Finding] = []
    for number, code in compiled_swift_lines(text):
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


# ---------------------------------------------------------------------------------------------- manifest


@dataclass(frozen=True)
class ManifestTarget:
    """A target as a Package.swift declares it: the graph's fields, read from the manifest text."""

    name: str
    kind: str
    path: str | None
    targets: tuple[str, ...]
    packages: tuple[str, ...]
    # False when `dependencies:` is not an array literal (a variable, a `+`), so the edges are not known.
    edges_known: bool = True


MANIFEST_DECLARATION = re.compile(r"\.(target|testTarget|executableTarget|binaryTarget|systemLibrary|macro|plugin)\(")
MANIFEST_KINDS = {
    "target": "regular", "testTarget": "test", "executableTarget": "executable", "binaryTarget": "binary",
    "systemLibrary": "system", "macro": "macro", "plugin": "plugin",
}
# SwiftPM's default directory root for a target without `path:`.
MANIFEST_DEFAULT_ROOTS = {"test": "Tests", "plugin": "Plugins"}
MANIFEST_LABEL = re.compile(r"(\w+)\s*:")
MANIFEST_STRING = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
MANIFEST_DEPENDENCY = re.compile(r'\.(target|byName|product)\(\s*name:\s*"([^"]+)"(?:\s*,\s*package:\s*"([^"]+)")?')
MANIFEST_PLATFORMS = re.compile(r"platforms:\s*\[([^\]]*)\]")


def manifest_code(text: str) -> str:
    """`text` with comments removed and string literals kept, so names and paths stay readable."""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            out.append(" ")
        elif text[i] == '"':
            match = MANIFEST_STRING.match(text, i)
            literal = match.group(0) if match else '"'
            out.append(literal)
            i += len(literal)
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def split_top_level(code: str, start: int, end: int) -> tuple[list[str], int]:
    """The comma-separated items of `code[start:end]` at bracket depth 0, and where depth first goes below 0.

    String literals are skipped, so a comma or bracket inside one does not count.
    """
    items: list[str] = []
    depth, item_start, i = 0, start, start
    while i < end:
        char = code[i]
        if char == '"':
            match = MANIFEST_STRING.match(code, i)
            i += len(match.group(0)) if match else 1
            continue
        if char in "([":
            depth += 1
        elif char in ")]":
            if depth == 0:
                end = i
                break
            depth -= 1
        elif char == "," and depth == 0:
            items.append(code[item_start:i].strip())
            item_start = i + 1
        i += 1
    items.append(code[item_start:end].strip())
    return [item for item in items if item], end


def call_arguments(items: Iterable[str]) -> dict[str, str]:
    """`label: value` items -> {label: value}; the first of a repeated label wins."""
    arguments: dict[str, str] = {}
    for item in items:
        labeled = MANIFEST_LABEL.match(item)
        if labeled:
            arguments.setdefault(labeled.group(1), item[labeled.end():].strip())
    return arguments


def array_literal(value: str) -> list[str] | None:
    """The items of an array literal `[a, .b(...), "c"]`, or None when `value` is not one (a variable, `x + y`)."""
    value = value.strip()
    if not value.startswith("["):
        return None
    items, end = split_top_level(value, 1, len(value))
    return items if end == len(value) - 1 else None


def manifest_targets(text: str, package_dir: str) -> dict[str, ManifestTarget]:
    """Name -> target for each target declaration of a Package.swift whose repo directory is `package_dir`.

    A dependency with `condition: .when(platforms: [...])` that leaves out `.linux` is not built on Linux and is
    dropped. A dependency named by a bare string is kept as written; the caller keeps the names that are targets.
    """
    code = manifest_code(text)
    found: dict[str, ManifestTarget] = {}
    position = 0
    while match := MANIFEST_DECLARATION.search(code, position):
        items, end = split_top_level(code, match.end(), len(code))
        position = end + 1
        arguments = call_arguments(items)
        name = MANIFEST_STRING.fullmatch(arguments.get("name", ""))
        if not name or name.group(1) in found:
            continue
        kind = MANIFEST_KINDS[match.group(1)]
        path_literal = MANIFEST_STRING.fullmatch(arguments.get("path", ""))
        if kind == "binary":
            path = None
        elif path_literal:
            path = normalize(f"{package_dir}/{path_literal.group(1)}")
        else:
            path = f"{package_dir}/{MANIFEST_DEFAULT_ROOTS.get(kind, 'Sources')}/{name.group(1)}"
        targets: set[str] = set()
        packages: set[str] = set()
        dependencies = array_literal(arguments.get("dependencies", "[]"))
        for item in dependencies or []:
            platforms = MANIFEST_PLATFORMS.search(item)
            if platforms and not re.search(r"\.linux\b", platforms.group(1)):
                continue
            literal = MANIFEST_STRING.fullmatch(item)
            call = MANIFEST_DEPENDENCY.match(item)
            if literal:
                targets.add(literal.group(1))
            elif call and call.group(1) == "product" and call.group(3):
                packages.add(call.group(3))
            elif call:
                targets.add(call.group(2))
        found[name.group(1)] = ManifestTarget(
            name=name.group(1), kind=kind, path=path, targets=tuple(sorted(targets)), packages=tuple(sorted(packages)),
            edges_known=dependencies is not None,
        )
    return found


def manifest_packages(text: str, package_dir: str) -> dict[str, str]:
    """Local package name (its directory name) -> repo path, for each `.package(path:)` of a manifest."""
    paths = {normalize(f"{package_dir}/{relative}") for relative in PATH_DEPENDENCY.findall(manifest_code(text))}
    return {path.rsplit("/", 1)[-1]: path for path in sorted(paths)}


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
    # For a linux-tier.json `pending` target: its dependencies outside the tier (tier_edges); None otherwise.
    pending_edges: list[str] | None = None
    linux_ci: bool = False
    in_graph: bool = True
    # Package.swift names this target's dependencies in a form the scanner does not read, so its edges are not known.
    edges_unknown: bool = False

    @property
    def direct(self) -> bool:
        return bool(self.imports or self.symbols or self.reason)

    @property
    def root(self) -> bool:
        """A node that is not Linux-ready on its own account: what a dependent's `roots` names."""
        return self.direct or self.edges_unknown


def package_node_name(name: str) -> str:
    return f"package:{name}"


def findings(scans: Mapping[str, FileScan], attribute: str, key: str) -> list[dict]:
    return [
        {"file": path, "line": item.line, key: item.name}
        for path in sorted(scans)
        for item in getattr(scans[path], attribute)
    ]


SOURCE_EXTENSIONS = SWIFT_EXTENSIONS + C_EXTENSIONS + OBJC_EXTENSIONS


def scan_directory(source: Source, directory: str) -> dict[str, FileScan]:
    return scan_paths(source, [p for p in source.files(directory) if p.endswith(SOURCE_EXTENSIONS)])


def scan_paths(source: Source, paths: Iterable[str]) -> dict[str, FileScan]:
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


def unmapped_directories(source: Source, covered: Iterable[str]) -> dict[str, list[str]]:
    """Target directories (`Sources/X`, `Tests/X`) -> their source files that no target path covers."""
    prefixes = tuple(normalize(path).rstrip("/") + "/" for path in covered)
    groups: dict[str, list[str]] = {}
    for root in TARGET_ROOTS:
        for path in source.files(root):
            if not path.endswith(SOURCE_EXTENSIONS) or path.startswith(prefixes):
                continue
            rest = path[len(root) + 1:]
            if "/" not in rest:
                continue  # a loose file is not a target directory
            groups.setdefault(f"{root}/{rest.split('/', 1)[0]}", []).append(path)
    return {directory: sorted(files) for directory, files in sorted(groups.items())}


def read_tier(source: Source, names: Iterable[str]) -> tuple[dict[str, str], list[str]]:
    """(target name -> wave label from linux-tier.json `.waves[][]`, the `.pending` names), or ({}, []) when there
    is no tier file. A pending target waits outside the tier until every target it depends on is in a wave."""
    text = source.read(TIER_PATH)
    if text is None:
        return {}, []
    try:
        document = json.loads(text)
        waves = document["waves"]
        pending = list(document.get("pending", []))
    except (json.JSONDecodeError, KeyError, TypeError, AttributeError) as error:
        raise InputError(f"{TIER_PATH}: no readable `waves`: {error}") from error
    items = waves.items() if isinstance(waves, dict) else enumerate(waves)
    known = set(names)

    def resolve(member: str) -> str:
        return member if member in known or f"CmuxNext{member}" not in known else f"CmuxNext{member}"

    tier: dict[str, str] = {}
    for label, members in items:
        for member in members:
            tier[resolve(member)] = str(label)
    return tier, sorted(resolve(member) for member in pending)


def tier_edges(node: Node, nodes: Mapping[str, Node], tier: Mapping[str, str]) -> list[str]:
    """The targets of this package that ``node`` depends on and that no wave lists: what keeps a pending target out
    of the tier. CCmuxAppFFI counts as in the tier (the Linux mode maps it), and a package product never blocks:
    the Linux mode keeps a Linux-ready package and drops an excluded one."""
    return sorted(dep for dep in node.deps
                  if dep in nodes and not dep.startswith("package:") and dep not in tier
                  and dep not in LINUX_MAPPED_BINARIES)


def local_package_names(packages: Mapping[str, str]) -> dict[str, str]:
    """SwiftPM package identity (the directory name, lowercased) -> package name, for `.product(package:)`."""
    return {path.rsplit("/", 1)[-1].lower(): name for name, path in sorted(packages.items())}


def build_report(source: Source) -> dict:
    graph_text = source.read(GRAPH_PATH)
    if graph_text is None:
        raise InputError(f"{GRAPH_PATH} is missing in {source.label}")
    graph = json.loads(graph_text)
    graph_targets: Mapping[str, Mapping] = graph["targets"]
    # The graph comes from `swift package dump-package` and can be older than Package.swift; the manifest adds the
    # targets and edges added since, so a stale graph neither hides a target nor drops one of its blocked edges.
    manifest_text = source.read(f"{PACKAGE_DIR}/Package.swift") or ""
    manifest = manifest_targets(manifest_text, PACKAGE_DIR)
    local = dict(manifest_packages(manifest_text, PACKAGE_DIR))
    local.update(graph.get("packages", {}))
    identities = local_package_names(local)
    packages = package_nodes(source, local)

    names = set(graph_targets) | set(manifest)
    nodes: dict[str, Node] = dict(packages)
    for name in sorted(names):
        info = graph_targets.get(name)
        declared = manifest.get(name)
        if info is not None:
            kind, path = info["kind"], info.get("path")
            target_deps = set(info.get("targets", []))
            package_deps = set(info.get("packages", []))
        else:
            kind, path = declared.kind, declared.path
            target_deps, package_deps = set(), set()
        if declared is not None:
            target_deps |= {dep for dep in declared.targets if dep in names}
            package_deps |= {identities[p.lower()] for p in declared.packages if p.lower() in identities}
        deps = sorted(target_deps) + sorted(package_node_name(p) for p in package_deps)
        node = Node(name=name, kind=kind, path=path, deps=deps, in_graph=info is not None)
        node.edges_unknown = info is None and not declared.edges_known
        if node.kind == "binary":
            if name not in LINUX_MAPPED_BINARIES:
                node.reason = "binary target"
        elif node.path:
            scans = scan_directory(source, node.path)
            node.imports = findings(scans, "imports", "module")
            node.symbols = findings(scans, "symbols", "symbol")
        nodes[name] = node

    unmapped = {}
    covered = [nodes[name].path for name in names if nodes[name].path]
    for directory, paths in unmapped_directories(source, covered).items():
        scans = scan_paths(source, paths)
        imports, symbols = findings(scans, "imports", "module"), findings(scans, "symbols", "symbol")
        unmapped[directory.removeprefix(PACKAGE_DIR + "/")] = {
            "path": directory,
            "files": len(paths),
            # No target declares these files, so nothing says what they depend on: never "ok".
            "status": "direct" if imports or symbols else "unknown",
            "imports": imports,
            "symbols": symbols,
        }

    tier, pending = read_tier(source, names)
    for name, wave in tier.items():
        if name in nodes:
            nodes[name].wave = wave
    for name in pending:
        if name in nodes:
            nodes[name].pending_edges = tier_edges(nodes[name], nodes, tier)

    blocked = blocked_set(nodes)
    report_targets = {name: target_entry(nodes[name], nodes, blocked) for name in sorted(names)}
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
    missing = sorted({name for name in [*tier, *pending] if name not in nodes})
    return {
        "source": source.label,
        "graph": GRAPH_PATH,
        "tier": TIER_PATH if tier else None,
        "blocked_modules": sorted(BLOCKED_MODULES),
        "symbols": list(SYMBOL_NAMES),
        "packages": report_packages,
        "targets": report_targets,
        "unmapped": unmapped,
        "tier_missing": missing,
        "pending_in_wave": sorted(name for name in pending if name in tier),
        "summary": summarize(report_targets, unmapped, missing),
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
        result = node.root
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
    if node.edges_unknown:
        return "unknown"
    return "transitive" if node.name in blocked else "ok"


def roots_and_chain(start: Node, nodes: Mapping[str, Node], blocked: set[str]) -> tuple[list[str], list[str]]:
    """The nearest root nodes behind `start`'s blocked edges, and the shortest chain to one of them.

    A root is directly blocked or has unknown edges. The walk stops at a root: what is behind it is that node's
    own report.
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
            if nodes[dep].root:
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
        "in_graph": node.in_graph,
        "wave": node.wave,
        "pending_edges": node.pending_edges,
        "status": status(node, blocked),
        "reason": node.reason,
        "imports": node.imports,
        "symbols": node.symbols,
        "blocked_deps": [d for d in node.deps if d in blocked],
        "roots": roots,
        "chain": chain,
    }


def summarize(targets: Mapping[str, dict], unmapped: Mapping[str, dict], missing: list[str]) -> dict:
    counts = {"ok": 0, "direct": 0, "transitive": 0, "unknown": 0}
    tier = {"ok": 0, "direct": 0, "transitive": 0, "unknown": 0}
    for entry in targets.values():
        counts[entry["status"]] += 1
        if entry["wave"] is not None:
            tier[entry["status"]] += 1
    entries = list(targets.values()) + list(unmapped.values())
    files = {f["file"] for e in entries for f in e["imports"] + e["symbols"]}
    return {
        "targets": len(targets),
        **counts,
        "not_in_graph": sum(1 for e in targets.values() if not e["in_graph"]),
        "unmapped": len(unmapped),
        "unmapped_direct": sum(1 for e in unmapped.values() if e["status"] == "direct"),
        "files_with_findings": len(files),
        "tier": {**tier, "missing": len(missing)},
    }


# ------------------------------------------------------------------------------------------------ output


def tally(items: list[dict], key: str) -> str:
    counts: dict[str, int] = {}
    for item in items:
        counts[item[key]] = counts.get(item[key], 0) + 1
    return " ".join(f"{name}({count})" for name, count in sorted(counts.items())) or "-"


def short(name: str) -> str:
    return name.replace("package:", "pkg:")


def wave_cell(entry: dict) -> str:
    if entry["wave"] is not None:
        return entry["wave"]
    if entry["pending_edges"] is not None:
        return "pending:" + (",".join(entry["pending_edges"]) or "-")
    return "-"


def render_table(report: dict, names: list[str], unmapped: Iterable[str]) -> str:
    lines = ["# target\tkind\twave\tstatus\timports\tsymbols\tblocked deps\troots"]
    for name in names:
        entry = report["targets"][name]
        lines.append("\t".join([
            name,
            entry["kind"],
            wave_cell(entry),
            entry["status"] + (f" ({entry['reason'] or UNKNOWN_EDGES})" if entry["reason"] or entry["status"] == "unknown" else ""),
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
    for name in unmapped:
        entry = report["unmapped"][name]
        found = " ".join(filter(None, [tally(entry["imports"], "module") if entry["imports"] else "",
                                       tally(entry["symbols"], "symbol") if entry["symbols"] else ""]))
        lines.append(f"# no target declares {name}: {entry['status']} {found}".rstrip())
    lines.append(render_summary(report))
    return "\n".join(lines)


def render_files(report: dict, names: list[str], unmapped: Iterable[str]) -> str:
    rows = []
    entries = [(name, report["targets"][name]) for name in names]
    entries += [(UNMAPPED_PREFIX + name, report["unmapped"][name]) for name in unmapped]
    for name, entry in entries:
        rows += [(f["file"], f["line"], name, f["module"]) for f in entry["imports"]]
        rows += [(f["file"], f["line"], name, f["symbol"]) for f in entry["symbols"]]
    return "\n".join(f"{path}:{line}\t{target}\t{what}" for path, line, target, what in sorted(rows))


def render_summary(report: dict) -> str:
    s = report["summary"]
    text = (
        f"# {report['source']}: {s['targets']} targets, {s['ok']} ok, {s['direct']} direct, "
        f"{s['transitive']} transitive, {s['unknown']} unknown; {s['files_with_findings']} files with findings"
    )
    if s["not_in_graph"]:
        text += f"; {s['not_in_graph']} targets not in the graph (edges from Package.swift)"
    if s["unmapped"]:
        text += f"; {s['unmapped']} directories no target declares ({s['unmapped_direct']} with findings)"
    if report["tier"]:
        t = s["tier"]
        text += (
            f"; tier {t['ok']} ok, {t['direct']} direct, {t['transitive']} transitive, {t['unknown']} unknown, "
            f"{t['missing']} not a target"
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
        # A target filter selects targets; a directory no target declares has no name to match.
        unmapped = [] if args.target else sorted(report["unmapped"])
    except (InputError, json.JSONDecodeError, KeyError) as error:
        print(f"tier-imports: {error}", file=sys.stderr)
        return 2
    if args.check and not report["tier"]:
        print(f"tier-imports: --check needs {TIER_PATH}", file=sys.stderr)
        return 2
    if args.blocked:
        names = [n for n in names if report["targets"][n]["status"] != "ok"]
        unmapped = [n for n in unmapped if report["unmapped"][n]["status"] != "ok"]

    if args.json:
        selected = dict(
            report,
            targets={n: report["targets"][n] for n in names},
            unmapped={n: report["unmapped"][n] for n in unmapped},
        )
        print(json.dumps(selected, indent=2, sort_keys=True))
    elif args.files:
        print(render_files(report, names, unmapped))
    elif args.summary:
        print(render_summary(report))
    else:
        print(render_table(report, names, unmapped))

    if args.check:
        failing = sorted(
            n for n, e in report["targets"].items() if e["wave"] is not None and e["status"] != "ok"
        )
        for name in sorted(n for n, e in report["targets"].items() if not e["in_graph"]):
            print(f"tier-imports: warning: {name} is not in {GRAPH_PATH}; regenerate it", file=sys.stderr)
        for name in failing:
            entry = report["targets"][name]
            if entry["status"] == "direct":
                edge = "its own files"
            elif entry["status"] == "unknown":
                edge = UNKNOWN_EDGES
            else:
                edge = " -> ".join(short(n) for n in entry["chain"])
            print(f"tier-imports: {name} (wave {entry['wave']}) is blocked by {edge}", file=sys.stderr)
        for name in report["tier_missing"]:
            print(f"tier-imports: tier target {name} is not a target in {GRAPH_PATH} or Package.swift", file=sys.stderr)
        for name in report["pending_in_wave"]:
            print(f"tier-imports: {name} is both pending and in a wave", file=sys.stderr)
        # A pending target names the edge that keeps it out; with none left it belongs in a wave.
        ready = sorted(n for n, e in report["targets"].items() if e["pending_edges"] == [])
        for name in ready:
            print(f"tier-imports: pending {name} depends only on tier targets: move it into a wave", file=sys.stderr)
        # A directory no target declares may belong to a tier target the scanner could not read.
        for name in report["unmapped"]:
            print(f"tier-imports: no target in {GRAPH_PATH} or Package.swift declares {name}", file=sys.stderr)
        if failing or report["tier_missing"] or report["pending_in_wave"] or ready or report["unmapped"]:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
