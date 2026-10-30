#!/usr/bin/env python3
"""ONE-OMNIBAR: cmux-next draws every browser address bar with one view.

Browser tabs, the New Tab page and popup windows (window.open, OAuth,
extension popups, sign-in windows) all show `AddressBarView`, run by the
omnibar state machine (`OmnibarReducer`). A second address bar drifts: the
popup location bar was its own label with its own URL styling, so it missed
the omnibar's look, selection, suggestions and keys (user, 2026-10-19:
"omnibar for popover web windows need to reuse the same omnibar code").

Findings, in tracked Swift sources under Packages/macOS/CmuxNext/Sources:
  1. A type named like an address bar (`...AddressBar...`, `...LocationBar...`,
     `...AddressField...`, `...URLBar...`, `...URLField...`, `...Omnibar...View`)
     other than the omnibar's own types (ALLOWED_TYPES).
  2. The omnibar's URL styling (`BrowserURLDisplay.hostRange`, the host at
     full strength) outside the omnibar's text field: only the omnibar draws
     a URL that way.

A new surface puts `AddressBarView` (or `OmnibarToolbarView`) in its view tree
instead; a layout-only difference is a property of that view.

Usage: check-single-omnibar.py [repo-root]
Exit 0 clean, 1 with findings (each names the file).
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

SOURCES = "Packages/macOS/CmuxNext/Sources"

# The omnibar's own types (CmuxNextBrowser/UI and CmuxNextDesign).
ALLOWED_TYPES = {
    "AddressBarView",
    # AddressBarView's frame layout (the pill, chip, field and badges rects); it draws nothing.
    "AddressBarLayout",
    "AddressField",
    "AddressFieldCell",
    "AddressBarSurface",
    "OmnibarToolbarView",
    "OmnibarPillView",
    "OmnibarCardTopView",
}

# Files allowed to style a URL the omnibar's way.
HOST_RANGE_ALLOWED = {
    f"{SOURCES}/CmuxNextBrowser/UI/AddressField.swift",
    f"{SOURCES}/CmuxNextBrowser/Omnibox/BrowserURLDisplay.swift",
}

TYPE_DECL = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|open|final|nonisolated)\s+)*"
                       r"(?:class|struct|enum|actor|protocol)\s+(\w+)", re.MULTILINE)
BAR_NAME = re.compile(r"(AddressBar|LocationBar|AddressField|URLBar|UrlBar|URLField|UrlField|Omnibar\w*View)")
HOST_RANGE = re.compile(r"BrowserURLDisplay\s*\.\s*hostRange\s*\(")


def tracked_swift(root: pathlib.Path) -> list[str]:
    try:
        out = subprocess.run(["git", "-C", str(root), "ls-files", "--", f"{SOURCES}/*.swift"],
                             check=True, capture_output=True, text=True).stdout
        files = [line for line in out.splitlines() if line]
        if files:
            return files
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    # Not a git checkout (the lint's own fixture test): every file on disk.
    base = root / SOURCES
    return [str(p.relative_to(root)) for p in base.rglob("*.swift")] if base.is_dir() else []


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    findings: list[str] = []
    for rel in tracked_swift(root):
        path = root / rel
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for match in TYPE_DECL.finditer(text):
            name = match.group(1)
            if BAR_NAME.search(name) and name not in ALLOWED_TYPES:
                line = text.count("\n", 0, match.start(1)) + 1
                findings.append(f"{rel}:{line}: `{name}` is a second address bar. Show `AddressBarView` "
                                "(or `OmnibarToolbarView`) instead; a layout difference is a property of it.")
        if rel not in HOST_RANGE_ALLOWED:
            for match in HOST_RANGE.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                findings.append(f"{rel}:{line}: draws a URL with the omnibar's host styling outside the omnibar. "
                                "Show `AddressBarView` instead.")
    for finding in findings:
        print(f"check-single-omnibar: {finding}", file=sys.stderr)
    if findings:
        return 1
    print("check-single-omnibar: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
