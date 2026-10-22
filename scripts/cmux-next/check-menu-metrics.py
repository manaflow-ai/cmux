#!/usr/bin/env python3
"""Fail a menu that sets its own row paddings (Leo 2026-10-21, on Lawrence's screenshots of two
menus whose highlights, separators and columns sat at different x).

Every menu's highlight inset, separator inset, icon and text columns and shortcut column come from
the one grid, schemas/menu-metrics/menu-metrics.json (`MenuMetrics` in Swift). A menu surface here
is a Swift type whose name says it draws a menu's rows: a menu, popup or picker row, item, header,
separator or strip, the style or layout type that holds a menu's metrics, or an editor's row. In those files this check fails:

- a horizontal metric declared with its own number (`static let inset: CGFloat = 5`, `let padding: CGFloat = 4`):
  names ending in X, or containing inset, padding, leading, trailing, indent or margin, and a row's or
  highlight's radius;
- a highlight drawn at its own inset (`bounds.insetBy(dx: 5`);
- a row laid out at its own x (`NSRect(x: 3`, `NSPoint(x: 10`) or with its own leading or trailing
  constraint constant (`leadingAnchor, constant: Metrics.space3`).

Files still on their own grid are listed in DEBT; the list only shrinks. Run from anywhere:

    python3 scripts/cmux-next/check-menu-metrics.py [ROOT]
"""
import os, re, sys

SOURCES = "Packages/macOS/CmuxNext/Sources"
# The grid itself (gen-menu-metrics.py --check holds it to the JSON).
GRID = "CmuxNextDesign/MenuMetrics.swift"
# Menus not yet on the grid: each moves to MenuMetrics in its own follow-up and leaves this list.
DEBT = {
    "CmuxNextSidebar/Views/GroupEditor/SidebarGroupEditorControls.swift",
    "CmuxNextTabs/Groups/Editor/TabGroupEditorControls.swift",
    "CmuxNextPalette/PaletteActionsMenuView.swift",
    "CmuxNextDesign/Overlay/PopupRowView.swift",
    "CmuxNextDesign/Overlay/WebPopupHost.swift",
    "CmuxNextDesign/PopupStyle.swift",
    "CmuxNextBrowser/UI/ExtensionsMenu/ExtensionsMenuStyle.swift",
}
SURFACE = re.compile(r"\b(?:class|struct|enum|extension)\s+(\w*(?:Menu|Popup|Picker)\w*(?:Row|Item|Header|Separator|Strip|Style|Layout|Metrics)\w*|\w*EditorRow)\b")
NUMBER = r"-?\d+(?:\.\d+)?"
HORIZONTAL = r"\w*(?:[a-z]X|[Ii]nset|[Pp]adding|[Ll]eading|[Tt]railing|[Ii]ndent|[Mm]argin|(?:[Hh]ighlight|[Rr]ow)\w*Radius)\w*"
RULES = [
    (re.compile(r"\b(?:let|var)\s+(" + HORIZONTAL + r")\s*(?::\s*CGFloat)?\s*=\s*" + NUMBER + r"\b"),
     "declares its own horizontal metric"),
    (re.compile(r"\bbounds\.insetBy\(dx:\s*" + NUMBER + r"\b"), "draws its highlight at its own inset"),
    (re.compile(r"\bNS(?:Rect|Point)\(x:\s*(?!0\b)" + NUMBER + r"\b"), "places a row part at its own x"),
    (re.compile(r"(?:leading|trailing)Anchor\b[^\n]*\bconstant:\s*(?![^\n]*MenuMetrics)[^\s)]"),
     "lays out a row with its own leading or trailing constant"),
]


def strip_comment(line):
    at = line.find("//")
    return line if at < 0 else line[:at]


def main():
    args = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    root = os.path.abspath(args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    base = os.path.join(root, SOURCES)
    failures, seen = [], set()
    for folder, _, files in os.walk(base):
        for name in sorted(files):
            if not name.endswith(".swift") or name.endswith(".generated.swift"):
                continue
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, base)
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            if not SURFACE.search(text):
                continue
            seen.add(relative)
            if relative in DEBT or relative == GRID:
                continue
            for number, line in enumerate(text.splitlines(), 1):
                code = strip_comment(line)
                for pattern, why in RULES:
                    if pattern.search(code):
                        failures.append("%s/%s:%d: %s; take it from MenuMetrics (schemas/menu-metrics/menu-metrics.json): %s"
                                        % (SOURCES, relative, number, why, line.strip()))
    stale = sorted(DEBT - seen)
    for relative in stale:
        failures.append("%s: listed in DEBT but no longer a menu surface; remove it from scripts/cmux-next/check-menu-metrics.py" % relative)
    if failures:
        print("\n".join(failures))
        print("%d menu metric violation(s)" % len(failures))
        sys.exit(1)
    print("menu metrics: %d menu surface file(s) on the grid, %d still in DEBT" % (len(seen - DEBT), len(DEBT & seen)))
    if "--list" in sys.argv[1:]:
        print("\n".join(sorted(seen)))


if __name__ == "__main__":
    main()
