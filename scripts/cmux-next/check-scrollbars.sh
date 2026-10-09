#!/usr/bin/env bash
# Fails when cmux-next code stops following the macOS "Show scroll bars" setting
# (spec SCROLLBARS-FOLLOW-MACOS): scrollers stay hidden until the user scrolls,
# unless the user chose "Always".
#
# Swift (Packages/macOS/CmuxNext/Sources, Packages/Shared/CmuxMessagesLab/Sources):
#   - no `scrollerStyle = .legacy` / `.overlay` (call SystemScrollers.follow or
#     SystemScrollers.observe; only SystemScrollers.swift sets a style);
#   - no `showsIndicators: false`, `.scrollIndicators(.never)`, `(.hidden)` or
#     `(.visible)` (visible keeps an overlay scroller on screen at rest);
#   - no `autohidesScrollers = false` (an empty track when everything fits).
# Web (webviews/src, tests excluded; CSS comments ignored):
#   - no `overflow: scroll` (use `auto`), also as a Tailwind class
#     (`overflow-y-scroll`) or a React style (`overflowY: "scroll"`);
#   - no `scrollbar-width`, `scrollbar-color` or `::-webkit-scrollbar` (each
#     turns WebKit's overlay scroller into a custom one), also as React styles
#     (`scrollbarWidth`) and Tailwind arbitrary properties; libraries with
#     their own scrollers follow the host through webviews/src/scrollers.ts;
#   - no `scrollbar-gutter: stable` (an empty gutter for "Always" when
#     everything fits).
# Exceptions are listed below with their reason: a whole file (ALLOWED) or one
# rule in one file (ALLOWED_RULES).
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

# path suffix -> {rule id -> reason}: one rule off in one file.
ALLOWED_RULES = {
    # `overflow: "scroll"` here is the @pierre/diffs option for unwrapped code rows, not CSS; the
    # rows' scroller follows the host through PIERRE_DIFFS_SCROLLER_CSS.
    "webviews/src/agent-session/acpmux/conversation/EditDiff.tsx": {"overflow-style": "@pierre/diffs option"},
    "webviews/src/agent-session/acpmux/conversation/CodeBlock.tsx": {"overflow-style": "@pierre/diffs option"},
    "webviews/src/pierre-options.ts": {
        "overflow-style": "@pierre/diffs option",
        # The @pierre/trees list draws its own scroller in this gutter; the gutter width is 0 for
        # overlay and 6px only for "Always" (--trees-scrollbar-gutter-override in styles.css).
        "gutter": "@pierre/trees gutter, sized by the host style",
    },
}

SWIFT_RULES = [
    ("style", re.compile(r"\bscrollerStyle\s*=\s*\.(legacy|overlay)\b"), "forced scroller style; use SystemScrollers.follow/observe"),
    ("indicators", re.compile(r"showsIndicators\s*:\s*false"), "hidden scroll indicators; drop it (the system decides)"),
    ("indicators", re.compile(r"\.scrollIndicators\(\s*\.(never|hidden)"), "hidden scroll indicators; use .automatic"),
    ("indicators", re.compile(r"\.scrollIndicators\(\s*\.visible"), "always-visible scroll indicators; use .automatic"),
    ("autohide", re.compile(r"\bautohidesScrollers\s*=\s*false\b"), "an empty scroller track; use SystemScrollers.follow"),
]
WEB_RULES = [
    ("overflow", re.compile(r"overflow(-[xy])?\s*:\s*scroll\b"), "overflow: scroll; use auto"),
    ("overflow", re.compile(r"(?<![\w-])overflow-(x-|y-)?scroll(?![\w-])"), "Tailwind overflow-scroll; use overflow-auto"),
    ("overflow-style", re.compile(r"\boverflow[XY]?\s*:\s*[\"'`]scroll[\"'`]"), "a React overflow: \"scroll\" style; use \"auto\""),
    ("custom", re.compile(r"scrollbar-width\s*:"), "scrollbar-width makes a custom scrollbar"),
    ("custom", re.compile(r"scrollbar-color\s*:"), "scrollbar-color makes a custom scrollbar"),
    ("custom", re.compile(r"\bscrollbar(Width|Color)\s*:"), "a React scrollbarWidth/Color style makes a custom scrollbar"),
    ("custom", re.compile(r"::-webkit-scrollbar"), "::-webkit-scrollbar makes a custom scrollbar"),
    ("gutter", re.compile(r"scrollbar-gutter\s*:\s*stable"), "scrollbar-gutter: stable leaves an empty gutter for \"Always\""),
    ("gutter", re.compile(r"\bscrollbarGutter\s*:"), "a React scrollbarGutter style leaves an empty gutter"),
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
    off = ALLOWED_RULES.get(rel, {})
    out = []
    for number, line in enumerate(text.splitlines(), 1):
        code = line.split("//", 1)[0] if rel.endswith(".swift") else line
        for rule, pattern, why in rules:
            if rule in off:
                continue
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
