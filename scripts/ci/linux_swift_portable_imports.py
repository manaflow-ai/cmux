#!/usr/bin/env python3
"""Rewrite the mechanical Linux blockers in Swift sources, in place.

    linux_swift_portable_imports.py FILE_OR_DIR ...

Each rewrite leaves Apple builds byte-for-byte equivalent:

  * `import Darwin` becomes `#if canImport(Darwin) import Darwin #elseif
    canImport(Glibc) import Glibc #endif` (the access level and attributes
    are kept). A file that calls `Darwin.close(fd)`-style qualified libc
    functions also imports `CmuxLinuxDarwin` in the Glibc branch, under
    `#if canImport(CmuxLinuxDarwin)`: that Linux-only module declares
    `enum Darwin` forwarding to Glibc (Packages/Shared/CmuxLinuxCompat; the
    package manifest adds it under `#if os(Linux)`).
  * a file that names a URL-loading type (URLSession, URLRequest,
    HTTPURLResponse, URLProtocol, ...) gets `#if canImport(FoundationNetworking)
    import FoundationNetworking #endif` after its Foundation import, because
    swift-corelibs-foundation keeps those types in that module.
  * `import CoreGraphics` becomes `#if canImport(CoreGraphics) import
    CoreGraphics #else import Foundation #endif`: swift-corelibs-foundation
    defines CGFloat, CGPoint, CGSize and CGRect.
  * `import os` / `import OSLog` / `import os.log` gets wrapped in
    `#if canImport(os)`; the file still needs a Linux path for what it used
    (OSAllocatedUnfairLock has a module-internal stand-in, see
    Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/OSAllocatedUnfairLock+Linux.swift).

Imports already inside an `#if` block are left alone.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

IMPORT_LINE = re.compile(
    r"^(?P<prefix>(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?)import\s+(?P<module>[A-Za-z_][A-Za-z0-9_.]*)\s*$"
)
NEEDS_COMPAT = re.compile(r"\bDarwin\.[a-z_]|\bString\(localized:|\bSHA256\.hash\(")
URL_TYPES = re.compile(r"\b(URLSession\w*|URLRequest|HTTPURLResponse|URLResponse|URLProtocol|URLCache|HTTPCookie\w*|URLCredential\w*|URLAuthenticationChallenge)\b")
OS_MODULES = {"os", "OSLog", "os.log", "os.signpost"}


def rewrite(text: str) -> str:
    lines = text.split("\n")
    out: list[str] = []
    depth = 0
    foundation_at = None
    has_networking = "FoundationNetworking" in text
    for line in lines:
        stripped = line.strip()
        if re.match(r"#\s*if\b", stripped):
            depth += 1
        elif re.match(r"#\s*endif\b", stripped):
            depth = max(0, depth - 1)
        match = IMPORT_LINE.match(line) if depth == 0 else None
        if match:
            module = match.group("module")
            if module == "Darwin":
                out += ["#if canImport(Darwin)", line,
                        "#elseif canImport(Glibc)", f"{match.group('prefix')}import Glibc", "#endif"]
                continue
            if module in OS_MODULES or module == "CryptoKit":
                guard = "os" if module in OS_MODULES else module
                out += [f"#if canImport({guard})", line, "#endif"]
                continue
            if module == "CoreGraphics":
                out += ["#if canImport(CoreGraphics)", line, "#else",
                        f"{match.group('prefix')}import Foundation", "#endif"]
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
    if NEEDS_COMPAT.search(text) and "CmuxLinuxCompat" not in text:
        at = foundation_at + 1 if foundation_at is not None else first_import_after_ifs(out)
        out[at:at] = ["#if canImport(CmuxLinuxCompat)", "import CmuxLinuxCompat", "#endif"]
    return "\n".join(out)


def first_import_after_ifs(lines: list[str]) -> int:
    """Index after the last top-of-file import or import #if block."""
    end = 0
    depth = 0
    for index, line in enumerate(lines):
        stripped = line.strip()
        if re.match(r"#\s*if\b", stripped):
            depth += 1
        elif re.match(r"#\s*endif\b", stripped):
            depth -= 1
            if depth == 0:
                end = index + 1
        elif IMPORT_LINE.match(line) or stripped.startswith("#else"):
            if depth == 0:
                end = index + 1
        elif stripped and not stripped.startswith("//") and depth == 0:
            break
    return end


def main(argv: list[str]) -> int:
    changed = 0
    for arg in argv:
        root = Path(arg)
        files = [root] if root.is_file() else sorted(p for p in root.rglob("*.swift") if ".build" not in p.parts)
        for path in files:
            before = path.read_text(encoding="utf-8")
            after = rewrite(before)
            if after != before:
                path.write_text(after, encoding="utf-8")
                changed += 1
                print(path)
    print(f"{changed} file(s) rewritten", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
