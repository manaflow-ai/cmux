#!/usr/bin/env bash
# Fails when cmux-next code stops following the macOS "Show scroll bars" setting
# (spec SCROLLBARS-FOLLOW-MACOS): scrollers stay hidden until the user scrolls,
# unless the user chose "Always".
#
# Swift (Packages/macOS/CmuxNext/Sources, Packages/Shared/CmuxMessagesLab/Sources):
#   - no `scrollerStyle = .legacy` / `.overlay` (call SystemScrollers.follow or
#     SystemScrollers.observe; only SystemScrollers.swift sets a style);
#   - no `showsIndicators: false`, `.scrollIndicators(.never)` or `(.hidden)`.
# Web (webviews/src, tests excluded; CSS comments ignored):
#   - no `overflow: scroll` (use `auto`);
#   - no `scrollbar-width`, `scrollbar-color` or `::-webkit-scrollbar` (each
#     turns WebKit's overlay scroller into a custom one); libraries with their
#     own scrollers follow the host through webviews/src/scrollers.ts.
# Exceptions are listed below with their reason.
#
# Usage: scripts/cmux-next/check-scrollbars.sh [repo-root]
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)}"
exec python3 - "$root" <<'PY'
import os, re, sys

root = sys.argv[1]

SWIFT_ROOTS = ["Packages/macOS/CmuxNext/Sources", "Packages/Shared/CmuxMessagesLab/Sources"]
WEB_ROOTS = ["webviews/src"]

# path suffix -> reason
ALLOWED = {
    # The one place that applies the system's style.
    "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/SystemScrollers.swift": "applies NSScroller.preferredScrollerStyle",
    # The Home transcript (vendored MessagesLab): rows are drawn under the scroller across the
    # full width, so a legacy scroller would cover them. Overlay: correct. "Always": hidden at
    # rest (known gap, SCROLLBARS-FOLLOW-MACOS audit in .cmux-scratch/nx-scrollbars/STATUS.md).
    "Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/NativeScroll.swift": "Home transcript, vendored",
    # The shared rules for library scrollers (strings, not page CSS).
    "webviews/src/scrollers.ts": "library scroller rules",
}

SWIFT_RULES = [
    (re.compile(r"\bscrollerStyle\s*=\s*\.(legacy|overlay)\b"), "forced scroller style; use SystemScrollers.follow/observe"),
    (re.compile(r"showsIndicators\s*:\s*false"), "hidden scroll indicators; drop it (the system decides)"),
    (re.compile(r"\.scrollIndicators\(\s*\.(never|hidden)"), "hidden scroll indicators; use .automatic"),
]
WEB_RULES = [
    (re.compile(r"overflow(-[xy])?\s*:\s*scroll\b"), "overflow: scroll; use auto"),
    (re.compile(r"scrollbar-width\s*:"), "scrollbar-width makes a custom scrollbar"),
    (re.compile(r"scrollbar-color\s*:"), "scrollbar-color makes a custom scrollbar"),
    (re.compile(r"::-webkit-scrollbar"), "::-webkit-scrollbar makes a custom scrollbar"),
]
WEB_EXT = (".css", ".ts", ".tsx", ".html", ".mjs", ".js")
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)

def files(base, exts):
    top = os.path.join(root, base)
    for dirpath, dirnames, filenames in os.walk(top):
        dirnames[:] = [d for d in dirnames if d not in ("node_modules", "generated", "dist", ".build")]
        for name in filenames:
            if name.endswith(exts) and ".test." not in name:
                path = os.path.join(dirpath, name)
                yield os.path.relpath(path, root), path

def scan(rel, path, rules, strip):
    if rel in ALLOWED:
        return []
    text = open(path, encoding="utf-8", errors="replace").read()
    if strip:
        # Keep line numbers: replace each comment by its newlines.
        text = BLOCK_COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    out = []
    for number, line in enumerate(text.splitlines(), 1):
        code = line.split("//", 1)[0] if rel.endswith(".swift") else line
        for pattern, why in rules:
            if pattern.search(code):
                out.append(f"{rel}:{number}: {why}: {line.strip()}")
    return out

problems = []
for base in SWIFT_ROOTS:
    for rel, path in files(base, (".swift",)):
        problems += scan(rel, path, SWIFT_RULES, strip=False)
for base in WEB_ROOTS:
    for rel, path in files(base, WEB_EXT):
        problems += scan(rel, path, WEB_RULES, strip=True)

if problems:
    print("check-scrollbars: scrollers must follow the macOS setting (SCROLLBARS-FOLLOW-MACOS)")
    for p in problems:
        print("  " + p)
    sys.exit(1)
print("check-scrollbars: ok")
PY
