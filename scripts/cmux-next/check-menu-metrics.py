#!/usr/bin/env python3
"""Fail a menu that sets its own row paddings (Leo 2026-10-21, on Lawrence's screenshots of two
menus whose highlights, separators and columns sat at different x).

Every menu's highlight inset, separator inset, icon and text columns and shortcut column come from
the one grid, schemas/menu-metrics/menu-metrics.json (`MenuMetrics` in Swift). A menu surface here
is a Swift type whose name says it builds or draws a menu: a menu, popup or picker (`BrowserDownloadsMenu`),
its row, item, header, separator or strip, the style or layout type that holds a menu's metrics, or an
editor's row. In those files this check fails, also on an expression split over several lines:

- a horizontal metric declared with its own number (`static let inset: CGFloat = 5`, `let padding: CGFloat = 4`):
  names ending in X, or containing inset, padding, leading, trailing, indent or margin, and a row's or
  highlight's radius;
- a highlight drawn at its own inset (`bounds.insetBy(dx: 5`);
- a row laid out at its own x (`NSRect(x: 3`, `NSPoint(x: 10`) or with its own leading or trailing
  constraint constant (`leadingAnchor, constant: Metrics.space3`).

Files still on their own grid are listed in DEBT; the list only shrinks. Every run first checks the rules
against the examples in SELF_TEST, the menus they must fail and the ones they must pass. Run from anywhere:

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
# Files whose type names read as a menu but whose flagged metrics are not a menu row's: each with why.
NOT_MENUS = {
    # The Mac screen's toggle switch: its knob inset sits in a file that also adds NSMenuItem helpers.
    "CmuxNextMacScreen/MacScreenButtons.swift",
    # The DEBUG `debug.object_menu` capture command: its NSPoint is where it pops the pane's own menu up
    # (80 pt into a pane whose tab bar is hidden), a click location, not a row of a menu it draws.
    "CmuxNextApp/Control/DebugObjectMenu.swift",
}
# The system menu bar's status item (`MenuBarIcon`) is an icon, not a menu.
NOT_SURFACE = re.compile(r"MenuBar")
SURFACE = re.compile(r"\b(?:class|struct|enum|extension)\s+(\w*(?:Menu|Popup|Picker)s?(?:Row|Item|Header|Separator|Strip|Style|Layout|Metrics)?\w*?\b|\w*EditorRow\w*)(?=[\s:{<])")
NUMBER = r"-?\d+(?:\.\d+)?"
HORIZONTAL = r"\w*(?:[a-z]X|[Ii]nset|[Pp]adding|[Ll]eading|[Tt]railing|[Ii]ndent|[Mm]argin|(?:[Hh]ighlight|[Rr]ow)\w*Radius)\w*"
RULES = [
    (re.compile(r"\b(?:let|var)\s+(" + HORIZONTAL + r")\s*(?::\s*CGFloat)?\s*=\s*" + NUMBER + r"\b"),
     "declares its own horizontal metric"),
    (re.compile(r"\bbounds\.insetBy\(\s*dx:\s*" + NUMBER + r"\b"), "draws its highlight at its own inset"),
    (re.compile(r"\bNS(?:Rect|Point)\(\s*x:\s*(?!0\b)" + NUMBER + r"\b"), "places a row part at its own x"),
    # One constraint call: up to its closing parenthesis, over any line breaks.
    (re.compile(r"(?:leading|trailing)Anchor\b[^)]*?\bconstant:\s*(?![^)]*MenuMetrics)[^\s)]"),
     "lays out a row with its own leading or trailing constant"),
]
# Menus the rules must fail, and ones they must pass.
SELF_TEST = [
    (True, "enum BrowserDownloadsMenu {\n    static let leadingInset: CGFloat = 5\n}"),
    (True, "final class RowView: NSView {}\nstruct ProfileMenuItem {\n    let r = NSRect(\n        x: 3, y: 0, width: 1, height: 1)\n}"),
    (True, "final class EditorRowView {\n    func f() { a.leadingAnchor.constraint(\n        equalTo: b.leadingAnchor,\n        constant: 8) }\n}"),
    (True, "struct PopupStyle2 {\n    func f() { bounds.insetBy(\n        dx: 4, dy: 0) }\n}"),
    (False, "enum BrowserDownloadsMenu {\n    static let leadingInset = MenuMetrics.iconX\n    let r = NSRect(x: 0, y: 0, width: 1, height: 1)\n}"),
    (False, "final class EditorRowView {\n    func f() { a.leadingAnchor.constraint(\n        equalTo: b.leadingAnchor,\n        constant: MenuMetrics.iconX) }\n}"),
    (False, "struct ToolbarButton {\n    static let leadingInset: CGFloat = 5\n}"),
    (False, "enum BrowserDownloadsMenu {\n    // static let leadingInset: CGFloat = 5\n}"),
    (False, "public struct MenuBarIcon {\n    static let glyphRect = NSRect(x: 1.2, y: 1.5, width: 11.6, height: 15.0)\n}"),
]


def strip_comment(line):
    at = line.find("//")
    return line if at < 0 else line[:at]


def violations(text):
    """(line, why) for each rule a menu surface's text breaks; nothing for a file that is not one."""
    if not any(not NOT_SURFACE.search(match.group(1)) for match in SURFACE.finditer(text)):
        return None
    lines = text.splitlines()
    # Comments blanked, line breaks kept, so a match's start gives its line.
    code = "\n".join(strip_comment(line) for line in lines)
    found = []
    for pattern, why in RULES:
        for match in pattern.finditer(code):
            found.append((code.count("\n", 0, match.start()) + 1, why))
    return sorted(found)


def self_test():
    for must_fail, text in SELF_TEST:
        if bool(violations(text)) != must_fail:
            print("check-menu-metrics.py's rules %s this example:\n%s" % ("pass" if must_fail else "fail", text))
            sys.exit(2)


def main():
    self_test()
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
            found = violations(text)
            if found is None:
                continue
            seen.add(relative)
            if relative in DEBT or relative in NOT_MENUS or relative == GRID:
                continue
            lines = text.splitlines()
            for number, why in found:
                failures.append("%s/%s:%d: %s; take it from MenuMetrics (schemas/menu-metrics/menu-metrics.json): %s"
                                % (SOURCES, relative, number, why, lines[number - 1].strip()))
    stale = sorted((DEBT | NOT_MENUS) - seen)
    for relative in stale:
        failures.append("%s: listed in DEBT or NOT_MENUS but no longer a menu surface; remove it from scripts/cmux-next/check-menu-metrics.py" % relative)
    if failures:
        print("\n".join(failures))
        print("%d menu metric violation(s)" % len(failures))
        sys.exit(1)
    print("menu metrics: %d menu surface file(s) on the grid, %d still in DEBT" % (len(seen - DEBT - NOT_MENUS), len(DEBT & seen)))
    if "--list" in sys.argv[1:]:
        print("\n".join(sorted(seen)))


if __name__ == "__main__":
    main()
