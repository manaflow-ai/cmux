#!/usr/bin/env python3
"""Rewrite the mechanical Linux blockers in Swift sources, in place.

    linux_swift_portable_imports.py FILE_OR_DIR ...

Each rewrite leaves Apple builds byte-for-byte equivalent:

  * `import Darwin` becomes `#if canImport(Darwin) import Darwin #elseif
    canImport(Glibc) import Glibc #endif` (the access level and attributes
    are kept). A file that calls `Darwin.close(fd)`-style qualified libc
    functions also imports `CmuxLinuxCompat` in the Glibc branch, under
    `#if canImport(CmuxLinuxCompat)`: that Linux-only module declares
    `enum Darwin` forwarding to Glibc (Packages/Shared/CmuxLinuxCompat; the
    package manifest adds it under `#if os(Linux)`). The same import is added
    for `String(localized:)`, `SHA256.hash`, `Logger(` and
    `OSAllocatedUnfairLock`, which that module also provides off Apple.
  * a file that names XMLElement/XMLDocument/XMLNode imports FoundationXML
    under `#if canImport(FoundationXML)`.
  * a file that names a URL-loading type (URLSession, URLRequest,
    HTTPURLResponse, URLProtocol, ...) gets `#if canImport(FoundationNetworking)
    import FoundationNetworking #endif` after its Foundation import, because
    swift-corelibs-foundation keeps those types in that module.
  * `import CoreGraphics` becomes `#if canImport(CoreGraphics) import
    CoreGraphics #else import Foundation #endif`: swift-corelibs-foundation
    defines CGFloat, CGPoint, CGSize and CGRect.
  * `import os` / `import OSLog` / `import os.log` gets wrapped in
    `#if canImport(os)`; the file still needs a Linux path for what it used
    (CmuxLinuxCompat provides Logger and OSAllocatedUnfairLock).

Imports already under a platform `#if` (canImport, os(), targetEnvironment) are
left alone; imports under other conditions such as `#if DEBUG` are rewritten.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

IMPORT_LINE = re.compile(
    r"^(?P<prefix>(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?)import\s+(?P<module>[A-Za-z_][A-Za-z0-9_.]*)\s*$"
)
NEEDS_COMPAT = re.compile(r"\bDarwin\.[a-z_]|\bString\(\s*localized:|\bSHA256\.hash\(|\bLogger\(|\bOSAllocatedUnfairLock\b|\bOSLogType\b")
XML_TYPES = re.compile(r"\bXML(Element|Document|Node|DTD\w*)\b")
URL_TYPES = re.compile(r"\b(URLSession\w*|URLRequest|HTTPURLResponse|URLResponse|URLProtocol|URLCache|HTTPCookie\w*|URLCredential\w*|URLAuthenticationChallenge)\b")
PLATFORM_GUARD = re.compile(r"canImport\(|\bos\(|targetEnvironment\(")
OS_MODULES = {"os", "OSLog", "os.log", "os.signpost"}


def rewrite(text: str, has_compat: bool = True) -> str:
    lines = text.split("\n")
    out: list[str] = []
    # One entry per open #if: whether it (or its #elseif/#else) is a platform
    # guard. Imports under `#if DEBUG` still need rewriting; imports under a
    # canImport/os() guard were already placed by hand.
    guards: list[bool] = []
    foundation_at = None
    last_import_end = 0
    guarded_import = False
    has_networking = "FoundationNetworking" in text
    for line in lines:
        stripped = line.strip()
        if re.match(r"#\s*if\b", stripped):
            guards.append(bool(PLATFORM_GUARD.search(stripped)))
        elif re.match(r"#\s*(elseif|else)\b", stripped) and guards:
            guards[-1] = guards[-1] or bool(PLATFORM_GUARD.search(stripped)) or stripped.startswith("#else")
        elif re.match(r"#\s*endif\b", stripped) and guards:
            guards.pop()
            if guarded_import and not any(guards):
                # Insert after the platform block that held an import.
                last_import_end = len(out) + 1
                guarded_import = False
        match = IMPORT_LINE.match(line) if not any(guards) else None
        if IMPORT_LINE.match(line):
            if any(guards):
                guarded_import = True
            else:
                last_import_end = len(out) + 1
        if match:
            module = match.group("module")
            if module == "Darwin":
                out += ["#if canImport(Darwin)", line,
                        "#elseif canImport(Glibc)", f"{match.group('prefix')}import Glibc", "#endif"]
                last_import_end = len(out)
                continue
            if module in OS_MODULES or module == "CryptoKit":
                guard = "os" if module in OS_MODULES else module
                out += [f"#if canImport({guard})", line, "#endif"]
                last_import_end = len(out)
                continue
            if module == "CoreGraphics":
                out += ["#if canImport(CoreGraphics)", line, "#else",
                        f"{match.group('prefix')}import Foundation", "#endif"]
                last_import_end = len(out)
                continue
            if module == "Foundation" and foundation_at is None:
                foundation_at = len(out)
        out.append(line)
    if foundation_at is not None and not has_networking and URL_TYPES.search(text):
        prefix = IMPORT_LINE.match(out[foundation_at]).group("prefix")
        # A public Foundation import re-exports URL types in the module's
        # interface; keep the networking import at the same access level.
        out[foundation_at + 1:foundation_at + 1] = [
            "#if canImport(FoundationNetworking)", f"{prefix}import FoundationNetworking", "#endif"]
    if foundation_at is not None and "FoundationXML" not in text and XML_TYPES.search(text):
        prefix = IMPORT_LINE.match(out[foundation_at]).group("prefix")
        out[foundation_at + 1:foundation_at + 1] = [
            "#if canImport(FoundationXML)", f"{prefix}import FoundationXML", "#endif"]
    if has_compat and NEEDS_COMPAT.search(text) and "CmuxLinuxCompat" not in text:
        at = foundation_at + 1 if foundation_at is not None else last_import_end
        out[at:at] = ["#if canImport(CmuxLinuxCompat)", "import CmuxLinuxCompat", "#endif"]
    return "\n".join(out)


def manifest_has_compat(path: Path) -> bool:
    """Whether the nearest enclosing Package.swift depends on CmuxLinuxCompat."""
    for parent in path.resolve().parents:
        manifest = parent / "Package.swift"
        if manifest.is_file():
            return "CmuxLinuxCompat" in manifest.read_text(encoding="utf-8")
    return False


def main(argv: list[str]) -> int:
    changed = 0
    for arg in argv:
        root = Path(arg)
        files = [root] if root.is_file() else sorted(p for p in root.rglob("*.swift") if ".build" not in p.parts)
        for path in files:
            before = path.read_text(encoding="utf-8")
            has_compat = manifest_has_compat(path)
            if not has_compat and NEEDS_COMPAT.search(before) and "CmuxLinuxCompat" not in before:
                print(f"warning: {path} needs CmuxLinuxCompat; add it to its Package.swift under #if os(Linux) and rerun", file=sys.stderr)
            after = rewrite(before, has_compat)
            if after != before:
                path.write_text(after, encoding="utf-8")
                changed += 1
                print(path)
    print(f"{changed} file(s) rewritten", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
