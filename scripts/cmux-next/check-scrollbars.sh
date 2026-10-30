#!/usr/bin/env bash
# Fails when cmux-next code styles a scrollbar outside the one shared style (spec
# SCROLLBARS-THIN): every scroller is thin and stays hidden until the user
# scrolls, also for the macOS "Show scroll bars" setting "Always". The style
# lives in SystemScrollers.swift (native) and webviews/src/scrollers.ts (web).
#
# Swift (Packages/macOS/CmuxNext/Sources, Packages/Shared/CmuxMessagesLab/Sources):
#   - no `scrollerStyle = .legacy` / `.overlay` (call SystemScrollers.follow or
#     SystemScrollers.observe; only SystemScrollers.swift sets a style);
#   - no `showsIndicators: false`, `.scrollIndicators(.never)`, `(.hidden)` or
#     `(.visible)` (visible keeps an overlay scroller on screen at rest);
#   - no `autohidesScrollers = false` (an empty track when everything fits);
#   - a SwiftUI ScrollView takes `.thinScrollers()` on its content, a List on its rows (CmuxNext only).
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
# SCROLLBARS_WARN_MAX=N (CI sets it) is the warning tier: up to N hits are
# ratchet debt `::warning title=ratchet debt::` annotations and pass; more fail.
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
    # The one place that sets a native scroller style (SystemScrollers.nativeStyle).
    "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/SystemScrollers.swift": "applies the shared native style",
    # The Home transcript (vendored MessagesLab): rows are drawn under the scroller across the
    # full width, so a legacy scroller would cover them. Overlay, as SCROLLBARS-THIN asks.
    "Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/NativeScroll.swift": "Home transcript, vendored",
    # The shared rules for library scrollers (strings, not page CSS).
    "webviews/src/scrollers.ts": "library scroller rules",
}

# path suffix -> {rule id -> reason}: one rule off in one file.
ALLOWED_RULES = {
    # `overflow: "scroll"` here is the @pierre/diffs option for unwrapped code rows, not CSS; the
    # rows' scroller follows the host through PIERRE_DIFFS_SCROLLER_CSS.
    # EditDiffHunks and HighlightedCode load after the first frame (#19974); EditDiff and CodeBlock
    # no longer set the option.
    "webviews/src/agent-session/acpmux/conversation/EditDiffHunks.tsx": {"overflow-style": "@pierre/diffs option"},
    "webviews/src/agent-session/acpmux/conversation/HighlightedCode.tsx": {"overflow-style": "@pierre/diffs option"},
    # The vendored MessagesLab compose box, overlay as SCROLLBARS-THIN asks (as NativeScroll.swift).
    "Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/Compose.swift": {"style": "Home compose, vendored"},
    # Gallery only (PathPicker parity, #19533): a fixed gutter keeps the field's width the same
    # across folder sizes so frames compare. The shipped picker keeps the shared style.
    "webviews/src/viewer-empty/PathPicker.gallery.css": {"overflow": "gallery parity frames", "gutter": "gallery parity frames"},
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

# A SwiftUI ScrollView takes the shared thin scroller on its content, and a List on its rows
# (`.thinScrollers()`); a file needs at least one per ScrollView or List. Only a file that imports SwiftUI
# can name SwiftUI's (no CmuxNext module re-exports it), so `List(expectedMachineID:)` in a Foundation-only
# file (AgentCLIIntentLedger's own List request) is not one.
SWIFTUI_SCROLL = re.compile(r"(?<![A-Za-z])(?:ScrollView|List)\s*[({]")
SWIFTUI_IMPORT = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:struct|class|enum|protocol|typealias|func|var|let)\s+)?SwiftUI\b",
                            re.M)
STRING = re.compile(r'"(?:[^"\\\n]|\\.)*"')

def swiftui_scrolls(rel, path):
    if rel in ALLOWED:
        return []
    text = open(path, encoding="utf-8", errors="replace").read()
    if not SWIFTUI_IMPORT.search(text):
        return []
    lines = [STRING.sub('""', line).split("//", 1)[0] for line in text.splitlines()]
    scrolls = [number for number, code in enumerate(lines, 1) if SWIFTUI_SCROLL.search(code)]
    if len(scrolls) <= sum(code.count(".thinScrollers()") for code in lines):
        return []
    return [f"{rel}:{number}: a SwiftUI ScrollView or List without .thinScrollers(): {lines[number - 1].strip()}"
            for number in scrolls]

problems = []
for base in SWIFT_ROOTS:
    for rel, path in files(base, (".swift",)):
        problems += scan(rel, path, SWIFT_RULES, strip=False)
        if base == "Packages/macOS/CmuxNext/Sources":
            problems += swiftui_scrolls(rel, path)
for base in WEB_ROOTS:
    for rel, path in files(base, WEB_EXT):
        problems += scan(rel, path, WEB_RULES, strip=True)

warn_max = int(os.environ.get("SCROLLBARS_WARN_MAX") or 0)
if problems and len(problems) <= warn_max:
    for p in problems:
        print(f"::warning title=ratchet debt::{p}")
    print(f"check-scrollbars: {len(problems)} hits are ratchet debt (ceiling {warn_max})")
    sys.exit(0)
if problems:
    if warn_max:
        print(f"check-scrollbars: {len(problems)} hits are over the hard ceiling of {warn_max}")
    print("check-scrollbars: scrollbars use the one shared style (SCROLLBARS-THIN)")
    for p in problems:
        print("  " + p)
    sys.exit(1)
print("check-scrollbars: ok")
PY
