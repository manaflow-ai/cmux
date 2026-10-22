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

The webviews' menus read the CSS copy (--cmux-menu-*, webviews/src/pages/shared/desktop.css). In
webviews/src/**/*.css, a rule whose selector names a menu (menu, menuitem, context-menu, dropdown,
popup-row) fails when a horizontal padding, margin, inline offset or gap is its own px number instead
of var(--cmux-menu-*) or a calc of them: padding-left/right, padding-inline(-start/-end), the
horizontal parts of the padding and margin shorthands, margin-inline(-start/-end), left,
inset-inline-start and gap or column-gap. Shared row tokens (var(--ui-row-padding-inline)) pass; they
are defined from the grid.

Files still on their own grid are listed in DEBT and WEB_DEBT; the lists only shrink. Run from anywhere:

    python3 scripts/cmux-next/check-menu-metrics.py [ROOT]
"""
import os, re, sys

SOURCES = "Packages/macOS/CmuxNext/Sources"
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
WEB_SOURCES = "webviews/src"
# The model picker belongs to another lane; it moves to the grid in its own follow-up.
WEB_DEBT = {
    "agent-session/acpmux/modelPicker.css",
}
WEB_MENU = re.compile(r"menu|dropdown|popup-row", re.IGNORECASE)
# A rule for a control that sits in or opens a menu, not a row of one: its own paddings are not the grid's.
WEB_NOT_ROW = re.compile(r"(?:button|trigger|badge|hint|symbol|controls|chevron|anchor)\b[^\s>+~]*$", re.IGNORECASE)
# A menu's own spacing variables (`--acpmux-project-menu-edge: 4px`) count as its paddings.
WEB_CUSTOM = re.compile(r"^--[\w-]*(?:edge|inset|padding|indent|gutter|gap|leading|trailing|-x)$", re.IGNORECASE)
WEB_HORIZONTAL = {
    "padding-left", "padding-right", "padding-inline", "padding-inline-start", "padding-inline-end",
    "margin-inline", "margin-inline-start", "margin-inline-end", "left", "inset-inline-start",
    "gap", "column-gap",
}
WEB_SHORTHAND = {"padding", "margin"}
PX = re.compile(r"(?<![\w-])-?(?:\d+\.?\d*|\.\d+)px\b")
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


def css_declarations(text):
    """(selector, declaration, line) for each declaration; a nested rule's selector is joined to its parents'."""
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    out, stack, start = [], [], 0

    def emit(lo, hi):
        selector = " ".join(prelude for prelude in stack if not prelude.startswith("@"))
        offset = lo
        for decl in text[lo:hi].split(";"):
            if ":" in decl and selector:
                line = text.count("\n", 0, offset + len(decl) - len(decl.lstrip())) + 1
                out.append((selector, " ".join(decl.split()), line))
            offset += len(decl) + 1

    for at, char in enumerate(text):
        if char == "{":
            cut = text.rfind(";", start, at)
            if cut >= 0 and stack:
                emit(start, cut)
            stack.append(" ".join(text[max(cut + 1, start):at].split()))
            start = at + 1
        elif char == "}":
            if stack:
                emit(start, at)
                stack.pop()
            start = at + 1
    return out


def without_fallbacks(value):
    """The value with every var() fallback dropped: `var(--a, 4px)` reads `var(--a)`."""
    out, at = [], 0
    while True:
        found = value.find("var(", at)
        if found < 0:
            return "".join(out) + value[at:]
        out.append(value[at:found])
        depth, end, comma = 0, found + 3, None
        for end in range(found + 3, len(value)):
            if value[end] == "(":
                depth += 1
            elif value[end] == ")":
                depth -= 1
                if depth == 0:
                    break
            elif value[end] == "," and depth == 1 and comma is None:
                comma = end
        out.append(value[found:comma] + ")" if comma is not None else value[found:end + 1])
        at = end + 1


def own_px(value):
    """The value's own px numbers: not 0, not a var() fallback."""
    return [m.group(0) for m in PX.finditer(without_fallbacks(value)) if float(m.group(0)[:-2]) != 0]


def horizontal_parts(prop, value):
    if prop in WEB_HORIZONTAL:
        return value
    if prop in WEB_SHORTHAND:
        parts = re.findall(r"(?:[\w-]+\((?:[^()]|\([^()]*\))*\)|[^\s]+)", value)
        if len(parts) == 1:
            return parts[0]
        if len(parts) in (2, 3):
            return parts[1]
        if len(parts) == 4:
            return parts[1] + " " + parts[3]
    return ""


def web_failures(root):
    base = os.path.join(root, WEB_SOURCES)
    failures, seen = [], set()
    for folder, _, files in os.walk(base):
        for name in sorted(files):
            if not name.endswith(".css") or name.endswith(".gallery.css"):
                continue
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, base)
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            for selector, decl, line in css_declarations(text):
                subjects = [part.strip() for part in selector.split(",")]
                if not any(WEB_MENU.search(subject) and not WEB_NOT_ROW.search(subject) for subject in subjects):
                    continue
                prop, value = (part.strip() for part in decl.split(":", 1))
                prop = prop.lower()
                # `left: calc(100% + 4px)` places a submenu beside its row; it is not a row inset.
                if prop in ("left", "inset-inline-start") and "%" in value:
                    continue
                parts = value if WEB_CUSTOM.match(prop) else horizontal_parts(prop, value)
                if not parts or not own_px(parts):
                    continue
                seen.add(relative)
                if relative in WEB_DEBT:
                    continue
                failures.append("%s/%s:%d: %s sets its own %s; take it from var(--cmux-menu-*) (schemas/menu-metrics/menu-metrics.json): %s"
                                % (WEB_SOURCES, relative, line, selector, prop, decl))
    for relative in sorted(WEB_DEBT - seen):
        failures.append("%s/%s: listed in WEB_DEBT but on the grid now; remove it from scripts/cmux-next/check-menu-metrics.py" % (WEB_SOURCES, relative))
    return failures


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
            if relative in DEBT:
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
    failures += web_failures(root)
    if failures:
        print("\n".join(failures))
        print("%d menu metric violation(s)" % len(failures))
        sys.exit(1)
    print("menu metrics: %d menu surface file(s) on the grid, %d still in DEBT; web menus on the grid, %d stylesheet(s) still in WEB_DEBT"
          % (len(seen - DEBT), len(DEBT & seen), len(WEB_DEBT)))
    if "--list" in sys.argv[1:]:
        print("\n".join(sorted(seen)))


if __name__ == "__main__":
    main()
