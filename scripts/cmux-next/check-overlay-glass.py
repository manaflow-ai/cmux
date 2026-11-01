#!/usr/bin/env python3
"""Fails when cmux NEXT's Swift paints a floating surface solid instead of the shared glass.

Leo 2026-10-21: "STOP DOING SOLID. WE HAVE GLASS, SO JUST USE GLASS." Popovers, tooltips, hover
cards, menus and the sidebar's cards are the shared glass: `Glass.makeOverlayPanel` (themed Liquid
Glass, or `.neutralGlass(FloatingGlassStyle)`), the tooltip's frost (`TooltipSurface`) or the
sidebar cards' veil (`CardSurfaceView`). ccde782cb51 laid a mostly opaque card fill on every overlay
and turned them solid again without anyone noticing; this check names every solid fill so a new one
cannot land unseen. The no-opaque-glass ast-grep rule catches an opaque tint on a glass view itself;
this one catches the solid colors and switches that sit beside or replace the glass.

Rules (Packages/macOS/CmuxNext/Sources, Swift; comment lines are ignored):
  popup-surface    Palette.popupSurface, fillWithPopupSurface(...) or opaqueOverlayFill(...): the
                   always-solid popup surface (Reduce Transparency's).
  elevated-fill    Palette.elevatedBackground used as a fill (backgroundColor, fillColor,
                   .background(...)): an opaque card color.
  system-solid     NSColor.windowBackgroundColor / controlBackgroundColor / textBackgroundColor /
                   underPageBackgroundColor, unless at an alpha under 0.6.
  always-opaque    ReduceTransparency.alwaysOpaque: a surface that ignores the glass.
  card-fill        makeOverlayPanel(cardFill: true): the mostly opaque CardMaterial fill on glass.
  swiftui-solid    a SwiftUI .background(...) of white, black or a solid palette surface, or
                   .opacity(1).
  tooltip-material NSVisualEffectView's `.toolTip` material: AppKit's own near-opaque tooltip
                   bubble, not the shared glass.
  hover-window     a tooltip, hover card or hover preview window (a class named *Tooltip*,
                   *HoverCard*, *HoverPreview*, *Preview* or *Peek* that subclasses NSPanel or
                   NSWindow) whose file never makes the shared glass (`Glass.makeOverlayPanel`, or
                   `Glass.makeSurface(role)`, a SurfaceRole's).
                   Leo 2026-10-21: "WHERE IS THE GLASS EVERYWHERE, all these hover tooltips and
                   hover previews."
  popup-host       a native host of a menu, picker, popover or web popup that is not on the shared
                   glass: a panel or window class named for a menu, picker, popover, popup or the
                   palette, a NativePopupHost(panel:), an adoptPopupStyle(card:) or an NSPopover(),
                   whose own body builds no Glass.makeOverlayPanel(...) (or Glass.makeMenuPanel(...),
                   Glass.makeSurface(...)).
                   A host's own body is the panel class's braces (and its extensions in the file);
                   for a call, the braces of the type it sits in (and the panel class it hands
                   NativePopupHost(panel:), when the file declares it); glass elsewhere in the file,
                   or in a type nested in the host, does not count. A host whose glass another file
                   builds is listed in GLASS_FROM by its file and type, with the file and the type there
                   whose own body builds it; a host that is not a menu says why in NOT_POPUP_HOST
                   (also by file and type). An entry no host matches is stale and fails. (Leo 2026-10-21, "why is this not glassed and themed right", the
                   folder picker and the chat menu.)

  card-material    CardMaterial(...): the mostly opaque card fill (at least 90%) outside its
                   definition and the one place that hands it to pages.
  surface-window   a toast, sheet, dialog, card, banner, bubble or notice window (a class named so
                   that subclasses NSPanel or NSWindow) whose file builds no shared glass
                   (Glass.makeOverlayPanel, Glass.makePanel, OverlaySurfaceView, CardSurfaceView or
                   GlassPanelView). One whose glass another file builds is in SURFACE_GLASS_FROM.
  dense-fill       in a file that builds a floating surface's glass, a backgroundColor, fillColor or
                   .background(...) at 90% or more (withAlphaComponent, withAlpha, opacity): a
                   near-opaque veil laid over the glass reads as a solid card (cmux#22670 did this to
                   the sidebar's Updated card).

Hover cards (a file that hands a body to the app's one hover card window, `HoverCardBody(...)`, or
reports a card's lines, `HoverCardTextReporting`: the tab, link chip, sidebar workspace, group, pull
request and What's New cards). They show in `HoverCardPanel`, the bare themed glass, so a body draws
on that glass and nothing else:
  hover-own-window a body that builds its own window or material (NSPanel, NSPopover, NSWindow,
                   NSVisualEffectView, OverlaySurfaceView, makeOverlayPanel) instead of the one
                   glass hover card window.
  hover-body-fill  a body's backgroundColor / fillColor / .background(...) that is not glass-safe:
                   only Palette.hoverFill, clear, nil, or a color at an alpha under 0.6 (a pill's
                   tint), so no body lays a solid card over the panel's glass.

A hit passes when the file and rule are in ALLOWED below (with the reason the surface stays solid),
or the line, or the comment block right above it, says `// glass-opaque-allow: <reason>`. Reduce
Transparency's solid paths are the usual reason.

Usage: scripts/cmux-next/check-overlay-glass.py [repo-root]
"""

from __future__ import annotations

import bisect
import os
import re
import sys

SOURCES = "Packages/macOS/CmuxNext/Sources"
SKIP_DIRS = {"Resources"}

RULES: dict[str, re.Pattern[str]] = {
    "popup-surface": re.compile(r"\bPalette\.popupSurface\b|\bfillWithPopupSurface\(|\bopaqueOverlayFill\("),
    "elevated-fill": re.compile(
        r"(backgroundColor|fillColor|\.background\()[^\n]*\belevatedBackground\b(?!\.withAlphaComponent\(0\.[0-5])"
    ),
    "system-solid": re.compile(
        r"\b(NSColor)?\.(windowBackgroundColor|controlBackgroundColor|textBackgroundColor|underPageBackgroundColor)\b"
        r"(?!\.withAlphaComponent\(0\.[0-5])(?!\s*=)"
    ),
    "always-opaque": re.compile(r"\.alwaysOpaque\b"),
    "card-fill": re.compile(r"\bcardFill:\s*true\b"),
    "swiftui-solid": re.compile(
        r"\.background\(\s*(Color\.(white|black)|\.(white|black)|Color\(nsColor:\s*Palette\.(popupSurface|elevatedBackground|windowBackground)\))"
        r"|\.opacity\(1(\.0)?\)"
    ),
    "tooltip-material": re.compile(r"\.material\s*=\s*\.toolTip\b|\bMaterial\.toolTip\b"),
    "card-material": re.compile(r"\bCardMaterial\("),
}

# A floating surface's window that carries text: it must build the shared glass in its file.
SURFACE_WINDOW = re.compile(
    r"\bclass\s+\w*(Toast|Sheet|Dialog|Card|Banner|Bubble|Notice)\w*\s*:\s*(NSPanel|NSWindow)\b"
)
ANY_GLASS = re.compile(
    r"\bGlass\.make((Overlay|Menu)?Panel|Surface)\(|\b(OverlaySurfaceView|CardSurfaceView|GlassPanelView)\("
)
# A fill at 90% or more, in a file that builds a floating surface's glass.
DENSE_FILL = re.compile(
    r"(backgroundColor|fillColor|\.background\()[^\n]*"
    r"\b(withAlphaComponent|withAlpha|opacity)\(\s*(alpha:\s*)?(0?\.9\d*|1(\.0+)?)\s*\)"
)
# path -> (the file that builds its window's glass, why it lives there).
SURFACE_GLASS_FROM: dict[str, tuple[str, str]] = {
    SOURCES + "/CmuxNextServer/Views/AddServerCardPanel.swift": (
        SOURCES + "/CmuxNextServer/ServerHostView.swift",
        "the card's content view, ServerHostView, is the server surfaces' OverlaySurfaceView",
    ),
}
# A teammate's surfaces this check never flags (their call, not this check's): path -> whose and why.
# Lawrence R48 (CmuxNextDesignTokens/Windows/ThemeTokens+Surface.swift): the window's one surface
# background and the cards on it (Settings groups) are a tint over the window, never an opaque
# overlay fill; they are kept as they are.
TEAMMATE_SURFACES: dict[str, str] = {
    SOURCES + "/CmuxNextDesignTokens/Windows/ThemeTokens+Surface.swift": (
        "Lawrence R48: surfaceBackground, cardFill, legibilityScrim and capsuleScrim, the window's surface and its cards"
    ),
    SOURCES + "/CmuxNextSettingsWindow/Views/SettingsStyle.swift": (
        "Lawrence R48: the Settings group card, ThemeTokens.cardFill (a tint, never an opaque fill)"
    ),
}

# A file-level rule: a tooltip or hover window must make the shared glass somewhere in its file.
HOVER_WINDOW = re.compile(
    r"\bclass\s+\w*(Tooltip|ToolTip|HoverCard|HoverPreview|Preview|Peek)\w*\s*:\s*(NSPanel|NSWindow)\b"
)
SHARED_GLASS = re.compile(r"\bGlass\.make(OverlayPanel|Surface)\(")

# Hover card bodies (see the docstring), and the files that host them rather than draw one.
HOVER_BODY = re.compile(r"\bHoverCardBody\(|\bHoverCardTextReporting\b")
HOVER_HOSTS = {
    SOURCES + "/CmuxNextDesign/HoverCards/HoverCardPanel.swift",  # the one glass window itself
    SOURCES + "/CmuxNextDesign/HoverCards/HoverCardSource.swift",  # defines HoverCardBody
    SOURCES + "/CmuxNextDesign/HoverCards/HoverCardRow.swift",  # the shared rows and the gallery's glass
}
HOVER_RULES: dict[str, re.Pattern[str]] = {
    "hover-own-window": re.compile(
        r"\b(NSPanel|NSPopover|NSWindow|NSVisualEffectView|OverlaySurfaceView)\(|\bmakeOverlayPanel\("
    ),
}
HOVER_FILL = re.compile(r"\b(?:backgroundColor|fillColor)\s*=\s*(?P<rhs>[^\n]+)|\.background\((?P<call>[^\n]*)")
# One alternative of a fill (a ternary's branches are checked one by one), `.cgColor` dropped.
HOVER_SAFE = re.compile(
    r"^(Palette\.hoverFill|(NSColor)?\.clear|Color\.clear|nil|[\w.]+\.withAlphaComponent\(0?\.[0-5]\d*\))$"
)


def hover_fill_unsafe(line: str) -> bool:
    """A hover card body's fill that is not glass-safe (`hover-body-fill`)."""
    match = HOVER_FILL.search(line)
    if not match:
        return False
    rhs = (match.group("rhs") or match.group("call") or "").strip()
    rhs = re.sub(r"\)\s*$", "", rhs) if match.group("call") is not None else rhs
    rhs = rhs.replace(".cgColor", "").strip()
    if "?" in rhs:
        rhs = rhs.split("?", 1)[1]
    branches = [part.strip() for part in re.split(r"\s:\s|\?\?", rhs)]
    return any(not HOVER_SAFE.match(branch) for branch in branches if branch)


ESCAPE = re.compile(r"//\s*glass-opaque-allow:\s*\S")
COMMENT = re.compile(r"^\s*(//|\*|/\*)")

P = SOURCES + "/"
# path (repo-relative) -> {rule -> why it stays solid}
ALLOWED: dict[str, dict[str, str]] = {
    # The definitions themselves.
    P + "CmuxNextDesign/Palette.swift": {"popup-surface": "defines the popup surface"},
    P + "CmuxNextDesign/PaletteDynamic.swift": {"popup-surface": "defines the popup surface"},
    P + "CmuxNextDesign/OverlayMaterial.swift": {
        "popup-surface": "defines opaqueOverlayFill",
    },
    P + "CmuxNextDesign/CardMaterial.swift": {"popup-surface": "defines the opt-in card fill"},
    # The card fill's own path (only `cardFill: true` reaches it, flagged at each caller) and the one
    # place that hands it to pages (check-glass-never-opaque.ts counts --cmux-card-tint near-opaque).
    P + "CmuxNextDesign/Windows/WebTheme.swift": {
        "popup-surface": "hands pages --cmux-popup-surface for their Reduce Transparency path",
        "card-material": "hands pages --cmux-card-tint; the web check counts it near-opaque on an overlay",
    },
    P + "CmuxNextDesign/Tooltip/TooltipSurface.swift": {
        "popup-surface": "the tooltip frost: the popup surface at the least alpha that keeps 4.5:1, over a blur",
    },
    # Reduce Transparency: the one place every surface is solid.
    P + "CmuxNextDesign/OverlaySurface.swift": {
        "popup-surface": "the .opaque material (Reduce Transparency), and fillWithPopupSurface's definition",
        "card-material": "the opt-in card fill's path; only makeOverlayPanel(cardFill: true) reaches it",
    },
    P + "CmuxNextDesign/ShortcutHintChipView.swift": {"popup-surface": "the chip's .opaque material path (Reduce Transparency)"},
    P + "CmuxNextDesign/CardSurfaceView.swift": {"elevated-fill": "Reduce Transparency's sidebar card"},
    # Not a floating surface: content and in-pane chrome that sits on its own page.
    P + "CmuxNextAgentQuestion/AgentQuestionCardView.swift": {
        "elevated-fill": "a pending question card inline in the conversation, set apart from answered ones",
    },
    P + "CmuxNextTerminal/TerminalCopyModeBadge.swift": {"elevated-fill": "an in-pane badge over terminal text that must stay readable"},
    P + "CmuxNextTerminal/TerminalSizedForChip.swift": {"elevated-fill": "an in-pane chip over terminal text that must stay readable"},
    P + "CmuxNextTerminal/TerminalStatusBanner.swift": {"elevated-fill": "an in-pane banner over terminal text that must stay readable"},
    P + "CmuxNextLayout/Views/DropOverlay/DropOverlayOutlineRenderer.swift": {
        "elevated-fill": "the drop target's label chip over the moving pane outline",
    },
    P + "CmuxNextSidebar/Views/DragLiftView.swift": {"elevated-fill": "the dragged row's lifted copy (85%), not a resting surface"},
    P + "CmuxNextTerminal/TextBox/TextBoxView.swift": {"system-solid": "an editable text box's field fill (85%)"},
    P + "CmuxNextLayout/Views/DockBackdropView.swift": {
        "dense-fill": "a dock column's backdrop: the person's docks background over the window color (R55), a pane, not an overlay",
    },
}


# A native host of a menu, picker, popover, popup or the palette.
POPUP_HOST = re.compile(
    r"\bclass\s+\w*(Menu|Picker|Popover|Popup|Palette)\w*\s*:\s*\w*(Panel|Window)\b"
    r"|\bNativePopupHost\(\s*panel:|\badoptPopupStyle\(\s*card:|\bNSPopover\(\s*\)"
)
GLASS_SURFACE = re.compile(r"\bGlass\.make(OverlayPanel|MenuPanel|Surface)\(")

# (path, host type) -> (the file and the type in it whose own body builds its glass, why it lives
# there). That type must build it: glass elsewhere in the file does not count. The host type is the
# popup class a line declares, else the type the call sits in ("" outside every type); another host
# in the same file is checked on its own.
GLASS_FROM: dict[tuple[str, str], tuple[str, str, str]] = {
    (P + "CmuxNextPalette/PalettePanel.swift", "PalettePanel"): (
        P + "CmuxNextPalette/PaletteContentView.swift",
        "PaletteContentView",
        "the palette's pages (the folder picker included) draw on PaletteContentView's glass",
    ),
    (P + "CmuxNextBrowser/UI/ExtensionsMenu/ExtensionsMenuPanel.swift", "ExtensionsMenuPanel"): (
        P + "CmuxNextBrowser/UI/ExtensionsMenu/ExtensionsMenuCardView.swift",
        "ExtensionsMenuCardView",
        "the Extensions bubble's card is ExtensionsMenuCardView's glass",
    ),
    (P + "CmuxNextBrowser/UI/ExtensionsMenu/ExtensionsMenuController.swift", "ExtensionsMenuController"): (
        P + "CmuxNextBrowser/UI/ExtensionsMenu/ExtensionsMenuCardView.swift",
        "ExtensionsMenuCardView",
        "adopts ExtensionsMenuCardView's glass as its popup card",
    ),
    (P + "CmuxNextBrowser/PageInfo/UI/PageInfoController.swift", "PageInfoController"): (
        P + "CmuxNextBrowser/PageInfo/UI/PageInfoPanel.swift",
        "PageInfoCardView",
        "adopts PageInfoPanel.swift's glass card, PageInfoCardView",
    ),
}

# (path, host type) -> why it hosts no menu of its own.
NOT_POPUP_HOST: dict[tuple[str, str], str] = {
    (P + "CmuxNextDesign/PopupStyle.swift", "NSPanel"): "defines adoptPopupStyle(card:); each caller brings its glass",
    (P + "CmuxNextDesign/Overlay/NativePopupHost.swift", "NativePopupPanel"): (
        "the shared host's panel; each caller brings its glass"
    ),
    (P + "CmuxNextPopups/BrowserPopupWindow.swift", "BrowserPopupWindow"): (
        "a site's window.open popup: a browser window, not a menu"
    ),
    (P + "CmuxNextApp/Server/ServerMenuBarController.swift", "ServerMenuBarController"): (
        "the menu bar status item's system NSPopover (the system's own glass), outside any themed window"
    ),
}


# A type's declaration: its name, up to where its body's `{` may follow (`class func` is not one).
TYPE_DECL = re.compile(
    r"\b(?:class|struct|enum|actor|extension|protocol)\s+(?P<name>[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)"
    r"\s*(?:<[^{]*?>)?\s*(?=[:{]|where\b|$)"
)
BLOCK_TOKEN = re.compile(TYPE_DECL.pattern + r"|(?P<open>\{)|(?P<close>\})")
POPUP_CLASS = re.compile(r"\bclass\s+(?P<name>\w*(?:Menu|Picker|Popover|Popup|Palette)\w*)\s*:\s*\w*(?:Panel|Window)\b")
RAW_OPEN = re.compile(r'(#+)"')
HOSTED_PANEL = re.compile(r"\bNativePopupHost\(\s*panel:\s*(?P<name>[A-Za-z_][\w.]*)\(")


def skip_interpolation(text: str, index: int, out: list[str]) -> int:
    """The index just past a string interpolation's closing `)`, from just after its `\\(`. Its code is
    string text here: only its newlines are kept, and a string inside it is skipped whole."""
    depth = 1
    while index < len(text) and depth:
        char = text[index]
        if char == "\n":
            out.append(char)
        elif char == '"':
            index += 1
            while index < len(text) and text[index] not in '"\n':
                index += 2 if text[index] == "\\" else 1
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        index += 1
    return index


def code_lines(path: str) -> list[str]:
    """The file's lines, one per source line, without comments (`//`, and `/* */` anywhere, nested
    as Swift nests them) or the text of string literals, raw (`#"…"#`) ones too (each becomes `""`)."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    out: list[str] = []
    depth = 0  # how many /* */ comments are open
    quote = ""  # the open string literal's closing delimiter: `"` or `"""`, then a raw one's `#`s
    escape = "\\"  # what starts an escape in it: a backslash, then a raw one's `#`s
    index, end = 0, len(text)
    while index < end:
        char = text[index]
        if char == "\n":
            out.append(char)
            if not quote.startswith('"""'):
                quote = ""
            index += 1
        elif depth:
            if text.startswith("/*", index):
                depth += 1
                index += 2
            elif text.startswith("*/", index):
                depth -= 1
                index += 2
            else:
                index += 1
        elif quote:
            if text.startswith(escape + "(", index):
                index = skip_interpolation(text, index + len(escape) + 1, out)
            elif text.startswith(escape, index) and index + len(escape) < end and text[index + len(escape)] != "\n":
                index += len(escape) + 1
            elif text.startswith(quote, index):
                out.append('""')
                index += len(quote)
                quote = ""
            else:
                index += 1
        elif text.startswith("//", index):
            newline = text.find("\n", index)
            index = end if newline < 0 else newline
        elif text.startswith("/*", index):
            depth = 1
            index += 2
        elif (raw := RAW_OPEN.match(text, index)) or char == '"':
            hashes = raw.group(1) if raw else ""
            index += len(hashes)
            quote = ('"""' if text.startswith('"""', index) else '"') + hashes
            escape = "\\" + hashes
            index += len(quote) - len(hashes)
        else:
            out.append(char)
            index += 1
    return "".join(out).split("\n")


class Blocks:
    """The file's brace blocks, each the body of a type (by name) or not, and which are open where."""

    def __init__(self, lines: list[str]) -> None:
        self.names: list[str | None] = []  # block id -> the type (by its path) it is the body of, or None
        self.line_starts: list[tuple[int, ...]] = []  # the blocks open at each line's start
        self.line_events: list[list[tuple[int, tuple[int, ...]]]] = []  # (column, blocks open after it)
        stack: list[int] = []
        pending: str | None = None
        for line in lines:
            self.line_starts.append(tuple(stack))
            events: list[tuple[int, tuple[int, ...]]] = []
            for token in BLOCK_TOKEN.finditer(line):
                if token.group("name"):
                    pending = token.group("name")
                    continue
                if token.group("open"):
                    # A nested type is named by its path (Outer.Inner); an extension names its own.
                    outer = next((self.names[block] for block in reversed(stack) if self.names[block]), None)
                    if pending and outer and "." not in pending:
                        pending = f"{outer}.{pending}"
                    self.names.append(pending)
                    stack.append(len(self.names) - 1)
                    pending = None
                elif stack:
                    stack.pop()
                events.append((token.start(), tuple(stack)))
            self.line_events.append(events)

    def open_at(self, index: int, column: int) -> tuple[int, ...]:
        """The blocks around a position, outermost first."""
        open_blocks = self.line_starts[index]
        for at, after in self.line_events[index]:
            if at >= column:
                break
            open_blocks = after
        return open_blocks

    def bodies(self, name: str) -> set[int]:
        """The blocks that are a type's body: its declaration's and its extensions' in the file."""
        return {block for block, owner in enumerate(self.names) if owner == name}

    def resolve(self, index: int, column: int, name: str) -> set[int]:
        """The bodies of the type `name` names at a position: a type nested in an enclosing type
        first, innermost out, then a top-level one."""
        scopes = [self.names[block] for block in reversed(self.open_at(index, column)) if self.names[block]]
        for scope in scopes:
            if found := self.bodies(f"{scope}.{name}"):
                return found
        return self.bodies(name)

    def owner(self, index: int, column: int) -> int | None:
        """The innermost type body around a position (None: outside every type)."""
        named = [block for block in self.open_at(index, column) if self.names[block] is not None]
        return named[-1] if named else None


def glass_in(lines: list[str], blocks: Blocks, owners: set[int] | None) -> bool:
    """A Glass.make(Overlay|Menu)Panel call whose innermost type is one of `owners` (None: a call
    outside every type). A call in a type nested inside an owner is that nested type's, not the
    owner's."""
    for index, line in enumerate(lines):
        for glass in GLASS_SURFACE.finditer(line):
            owner = blocks.owner(index, glass.start())
            if (owner is None) if owners is None else (owner in owners):
                return True
    return False


def type_builds_glass(path: str, name: str) -> bool:
    """The type `name` in the file at `path` builds the glass in its own body."""
    if not os.path.exists(path):
        return False
    lines = code_lines(path)
    blocks = Blocks(lines)
    owners = blocks.bodies(name)
    return bool(owners) and glass_in(lines, blocks, owners)


def declaration(lines: list[str], index: int) -> str:
    """Line `index` and the next two, so a class declaration that wraps after its `:` reads whole."""
    return "\n".join(lines[index : index + 3])


def host_type(lines: list[str], blocks: Blocks, index: int, column: int) -> str:
    """The popup host's type: the popup class declared at `column`, else the type the call sits in
    ("" outside every type)."""
    owner = blocks.owner(index, column)
    declared = POPUP_CLASS.match(declaration(lines, index), column)
    if declared:
        return declared.group("name") if owner is None else f"{blocks.names[owner]}.{declared.group('name')}"
    return "" if owner is None else str(blocks.names[owner])


def host_has_glass(lines: list[str], blocks: Blocks, index: int, column: int) -> bool:
    """The popup host on line `index` builds a Glass.make(Overlay|Menu)Panel in its own body.

    A host's own body is its panel class's braces (and its extensions'). For a call, it is the
    type the call sits in, plus the panel class it hands NativePopupHost(panel:) when the file
    declares it; a call outside every type owns the code outside every type. A type nested in the
    host is not the host: its glass does not count.
    """
    line = lines[index]
    declared = POPUP_CLASS.match(declaration(lines, index), column)
    if declared:
        return glass_in(lines, blocks, blocks.resolve(index, column, declared.group("name")))
    # The call's argument may wrap onto the next lines.
    hosted = HOSTED_PANEL.match("\n".join([line[column:], *lines[index + 1 : index + 4]]))
    panel = blocks.resolve(index, column, hosted.group("name")) if hosted else set()
    if panel and glass_in(lines, blocks, panel):
        return True
    owner = blocks.owner(index, column)
    if owner is None:
        return glass_in(lines, blocks, None)
    return glass_in(lines, blocks, blocks.bodies(str(blocks.names[owner])))


def scan_popup_hosts(root: str) -> list[str]:
    """Every native popup host whose own body is not on the shared glass, and every stale entry."""
    findings: list[str] = []
    seen: set[tuple[str, str]] = set()
    base = os.path.join(root, SOURCES)
    for directory, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            lines = code_lines(path)
            # A host call may wrap after its `(`: match the whole file, then find each hit's line.
            text = "\n".join(lines)
            starts = [0]
            for line in lines[:-1]:
                starts.append(starts[-1] + len(line) + 1)
            hits = []
            for hit in POPUP_HOST.finditer(text):
                index = bisect.bisect_right(starts, hit.start()) - 1
                hits.append((index, hit.start() - starts[index]))
            if not hits:
                continue
            blocks = Blocks(lines)
            for index, column in hits:
                key = (rel, host_type(lines, blocks, index, column))
                seen.add(key)
                if key in NOT_POPUP_HOST:
                    continue
                source = GLASS_FROM.get(key)
                if source and type_builds_glass(os.path.join(root, source[0]), source[1]):
                    continue
                if host_has_glass(lines, blocks, index, column):
                    continue
                where = (
                    f" (GLASS_FROM names {source[1]} in {source[0]}, whose own body builds no Glass.makeOverlayPanel)"
                    if source
                    else ""
                )
                findings.append(f"{rel}:{index + 1}: [popup-host] {lines[index].strip()}{where}")
    # A renamed or deleted file's entry is stale too. A test fixture's root (one without this
    # script) holds only the files it tests, so there only an entry whose file is present counts.
    whole_repo = os.path.exists(os.path.join(root, "scripts/cmux-next/check-overlay-glass.py"))
    for rel, host in sorted({*GLASS_FROM, *NOT_POPUP_HOST} - seen):
        if not whole_repo and not os.path.exists(os.path.join(root, rel)):
            continue
        findings.append(
            f"{rel}:1: [popup-host] stale allowance: no popup host {host or '(top level)'} here; remove it"
        )
    return findings


def scan(root: str) -> list[str]:
    findings: list[str] = []
    used: set[tuple[str, str]] = set()
    base = os.path.join(root, SOURCES)
    for directory, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            with open(path, encoding="utf-8", errors="replace") as handle:
                lines = handle.read().split("\n")
            if rel in TEAMMATE_SURFACES:
                continue
            allowed = ALLOWED.get(rel, {})
            code_only = [line.split("//", 1)[0] for line in lines if not COMMENT.match(line)]
            makes_glass = any(SHARED_GLASS.search(code) for code in code_only)
            builds_glass = any(ANY_GLASS.search(code) for code in code_only)
            glass_from = SURFACE_GLASS_FROM.get(rel)
            glass_elsewhere = bool(glass_from) and file_builds_glass(os.path.join(root, glass_from[0]))
            hover = rel not in HOVER_HOSTS and any(HOVER_BODY.search(text) for text in lines)
            for index, line in enumerate(lines):
                if (
                    not COMMENT.match(line)
                    and SURFACE_WINDOW.search(line.split("//", 1)[0])
                    and not builds_glass
                    and not glass_elsewhere
                ):
                    if "surface-window" in allowed:
                        used.add((rel, "surface-window"))
                    elif not escaped(lines, index):
                        where = f" (SURFACE_GLASS_FROM names {glass_from[0]}, which builds no glass)" if glass_from else ""
                        findings.append(f"{rel}:{index + 1}: [surface-window] {line.strip()}{where}")
                if not COMMENT.match(line) and HOVER_WINDOW.search(line.split("//", 1)[0]) and not makes_glass:
                    if "hover-window" in allowed:
                        used.add((rel, "hover-window"))
                    elif not escaped(lines, index):
                        findings.append(f"{rel}:{index + 1}: [hover-window] {line.strip()}")
                if COMMENT.match(line):
                    continue
                code = line.split("//", 1)[0]
                if hover:
                    hits = [rule for rule, pattern in HOVER_RULES.items() if pattern.search(code)]
                    if hover_fill_unsafe(code):
                        hits.append("hover-body-fill")
                    for rule in hits:
                        if rule in allowed:
                            used.add((rel, rule))
                        elif not escaped(lines, index):
                            findings.append(f"{rel}:{index + 1}: [{rule}] {line.strip()}")
                hits = [rule for rule, pattern in RULES.items() if pattern.search(code)]
                if builds_glass and DENSE_FILL.search(code):
                    hits.append("dense-fill")
                for rule in hits:
                    if rule in allowed:
                        used.add((rel, rule))
                        continue
                    if escaped(lines, index):
                        continue
                    findings.append(f"{rel}:{index + 1}: [{rule}] {line.strip()}")
    # An allowance with nothing left to allow is stale: drop it, so it cannot cover a new fill.
    for rel, rules in sorted(ALLOWED.items()):
        for rule in sorted(rules):
            if (rel, rule) not in used and os.path.exists(os.path.join(root, rel)):
                findings.append(f"{rel}:1: [{rule}] stale allowance: the file no longer matches; remove it from ALLOWED")
    # A mapped window whose file no longer declares one, or a teammate's surface whose file is gone
    # (in the whole repo), is stale too.
    whole_repo = os.path.exists(os.path.join(root, "scripts/cmux-next/check-overlay-glass.py"))
    for rel in sorted(SURFACE_GLASS_FROM):
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            if whole_repo:
                findings.append(f"{rel}:1: [surface-window] stale allowance: no such file; remove it from SURFACE_GLASS_FROM")
            continue
        if not any(SURFACE_WINDOW.search(line) for line in code_lines(path)):
            findings.append(f"{rel}:1: [surface-window] stale allowance: no surface window here; remove it from SURFACE_GLASS_FROM")
    for rel in sorted(TEAMMATE_SURFACES):
        if whole_repo and not os.path.exists(os.path.join(root, rel)):
            findings.append(f"{rel}:1: [teammate] stale allowance: no such file; remove it from TEAMMATE_SURFACES")
    return findings + scan_popup_hosts(root)


def file_builds_glass(path: str) -> bool:
    """The file at `path` builds a shared glass surface (any of ANY_GLASS) outside comments and strings."""
    return os.path.exists(path) and any(ANY_GLASS.search(line) for line in code_lines(path))


def escaped(lines: list[str], index: int) -> bool:
    """The line, or the comment block right above it, says `glass-opaque-allow: <reason>`."""
    if ESCAPE.search(lines[index]):
        return True
    above = index - 1
    while above >= 0 and COMMENT.match(lines[above]):
        if ESCAPE.search(lines[above]):
            return True
        above -= 1
    return False


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    findings = scan(root)
    if findings:
        print("check-overlay-glass: a floating surface is solid instead of the shared glass.")
        print('  The rule: "Glass, never opaque" (Leo; 2026-10-21: "STOP DOING SOLID. WE HAVE GLASS, SO JUST')
        print('  USE GLASS."). Popovers, cards, menus, toasts and sheets are glass: legibility comes from the')
        print("  blur, tint and contrast inside the glass, never an opaque or near-opaque fill. Reduce")
        print("  Transparency is the only opaque fallback, and OverlayMaterial.opaque draws it for you.")
        print("  Use Glass.makeSurface(role) or Glass.makeOverlayPanel, the tooltip glass or CardSurfaceView.")
        print("  A surface that must stay")
        print("  solid is allowlisted with a written reason: `// glass-opaque-allow: <reason>`, or an ALLOWED")
        print("  entry in this script (design/overlay-surfaces.md in leo-workspace has the policy).")
        print("  [popup-host]: a menu, picker, popover or web popup host builds its surface with")
        print("  Glass.makeOverlayPanel in its own body, or names the file that does in GLASS_FROM.")
        for finding in findings:
            print(finding)
        return 1
    print("check-overlay-glass: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
