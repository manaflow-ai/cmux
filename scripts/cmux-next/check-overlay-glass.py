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
  popup-host       a native host of a menu, picker, popover or web popup that is not on the shared
                   glass: a panel or window class named for a menu, picker, popover, popup or the
                   palette, a NativePopupHost(panel:), an adoptPopupStyle(card:) or an NSPopover(),
                   in a file with no Glass.makeOverlayPanel(...) (or Glass.makeMenuPanel(...)). A
                   host whose glass another file builds names that file in GLASS_FROM, which must
                   build it; a host that is not a menu says why in NOT_POPUP_HOST. (Leo 2026-10-21,
                   "why is this not glassed and themed right", the folder picker and the chat menu.)

A hit passes when the file and rule are in ALLOWED below (with the reason the surface stays solid),
or the line, or the comment block right above it, says `// glass-opaque-allow: <reason>`. Reduce
Transparency's solid paths are the usual reason.

Usage: scripts/cmux-next/check-overlay-glass.py [repo-root]
"""

from __future__ import annotations

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
}

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
    P + "CmuxNextDesign/Tooltip/TooltipSurface.swift": {
        "popup-surface": "the tooltip frost: the popup surface at the least alpha that keeps 4.5:1, over a blur",
    },
    P + "CmuxNextDesign/Windows/WebTheme.swift": {
        "popup-surface": "hands pages --cmux-popup-surface for their Reduce Transparency path",
    },
    # Reduce Transparency: the one place every surface is solid.
    P + "CmuxNextDesign/OverlaySurface.swift": {
        "popup-surface": "the .opaque material (Reduce Transparency), and fillWithPopupSurface's definition",
    },
    P + "CmuxNextDesign/Tooltip/TooltipPanel.swift": {"popup-surface": "Reduce Transparency's tooltip surface"},
    P + "CmuxNextDesign/ShortcutHintChipView.swift": {"popup-surface": "the chip's .opaque material path (Reduce Transparency)"},
    P + "CmuxNextDesign/CardSurfaceView.swift": {"elevated-fill": "Reduce Transparency's sidebar card"},
    # Not a floating surface: content and in-pane chrome that sits on its own page.
    P + "CmuxNextHome/Conversations/HomeSheetController.swift": {
        "popup-surface": "a sheet window: the theme's surface over AppKit's sheet background (HomeSheetThemeTests)",
    },
    P + "CmuxNextHome/Conversations/HomeGroupInfoColors.swift": {
        "popup-surface": "the group info sheet's surface, as the other Home sheets",
    },
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
    P + "CmuxNextApp/TextBox/TextBoxView.swift": {"system-solid": "an editable text box's field fill (85%)"},
}


# A native host of a menu, picker, popover, popup or the palette.
POPUP_HOST = re.compile(
    r"\bclass\s+\w*(Menu|Picker|Popover|Popup|Palette)\w*\s*:\s*\w*(Panel|Window)\b"
    r"|\bNativePopupHost\(panel:|\badoptPopupStyle\(card:|\bNSPopover\(\)"
)
GLASS_SURFACE = re.compile(r"\bGlass\.make(Overlay|Menu)Panel\(")

# path -> (the file that builds its glass, why it lives there). That file must build it.
GLASS_FROM: dict[str, tuple[str, str]] = {
    P + "CmuxNextPalette/PalettePanel.swift": (
        P + "CmuxNextPalette/PaletteContentView.swift",
        "the palette's pages (the folder picker included) draw on PaletteContentView's glass",
    ),
    P + "CmuxNextBrowser/UI/ExtensionsMenu/ExtensionsMenuPanel.swift": (
        P + "CmuxNextBrowser/UI/ExtensionsMenu/ExtensionsMenuCardView.swift",
        "the Extensions bubble's card is ExtensionsMenuCardView's glass",
    ),
    P + "CmuxNextBrowser/UI/ExtensionsMenu/ExtensionsMenuController.swift": (
        P + "CmuxNextBrowser/UI/ExtensionsMenu/ExtensionsMenuCardView.swift",
        "adopts ExtensionsMenuCardView's glass as its popup card",
    ),
    P + "CmuxNextBrowser/PageInfo/UI/PageInfoController.swift": (
        P + "CmuxNextBrowser/PageInfo/UI/PageInfoPanel.swift",
        "adopts PageInfoPanel's glass card",
    ),
}

# path -> why it hosts no menu of its own.
NOT_POPUP_HOST: dict[str, str] = {
    P + "CmuxNextDesign/PopupStyle.swift": "defines adoptPopupStyle(card:); each caller brings its glass",
    P + "CmuxNextDesign/Overlay/NativePopupHost.swift": "the shared host; each caller brings its glass",
    P + "CmuxNextPopups/BrowserPopupWindow.swift": "a site's window.open popup: a browser window, not a menu",
    P + "CmuxNextApp/Server/ServerMenuBarController.swift": (
        "the menu bar status item's system NSPopover (the system's own glass), outside any themed window"
    ),
}


def code_lines(path: str) -> list[str]:
    """The file's lines without comment lines or trailing comments."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        return [line.split("//", 1)[0] for line in handle.read().split("\n") if not COMMENT.match(line)]


def builds_glass(path: str) -> bool:
    return os.path.exists(path) and any(GLASS_SURFACE.search(line) for line in code_lines(path))


def scan_popup_hosts(root: str) -> list[str]:
    """Every native popup host whose surface is not the shared glass, and every stale entry."""
    findings: list[str] = []
    hosts: set[str] = set()
    base = os.path.join(root, SOURCES)
    for directory, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            lines = code_lines(path)
            hit = next((line for line in lines if POPUP_HOST.search(line)), None)
            if hit is None:
                continue
            hosts.add(rel)
            if rel in NOT_POPUP_HOST or any(GLASS_SURFACE.search(line) for line in lines):
                continue
            source = GLASS_FROM.get(rel)
            if source and builds_glass(os.path.join(root, source[0])):
                continue
            where = f" (GLASS_FROM names {source[0]}, which builds no Glass.makeOverlayPanel)" if source else ""
            findings.append(f"{rel}:1: [popup-host] {hit.strip()}{where}")
    for rel in sorted({*GLASS_FROM, *NOT_POPUP_HOST}):
        if rel not in hosts and os.path.exists(os.path.join(root, rel)):
            findings.append(f"{rel}:1: [popup-host] stale allowance: the file hosts no popup; remove it")
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
            allowed = ALLOWED.get(rel, {})
            for index, line in enumerate(lines):
                if COMMENT.match(line):
                    continue
                code = line.split("//", 1)[0]
                for rule, pattern in RULES.items():
                    if not pattern.search(code):
                        continue
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
    return findings + scan_popup_hosts(root)


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
        print("check-overlay-glass: a floating surface is solid instead of the shared glass (Leo 2026-10-21:")
        print('  "STOP DOING SOLID. WE HAVE GLASS, SO JUST USE GLASS."). Use Glass.makeOverlayPanel, the')
        print("  tooltip frost or CardSurfaceView, or say why it stays solid: `// glass-opaque-allow: <reason>`.")
        print("  [popup-host]: a menu, picker, popover or web popup host builds its surface with")
        print("  Glass.makeOverlayPanel, or names the file that does in GLASS_FROM.")
        for finding in findings:
            print(finding)
        return 1
    print("check-overlay-glass: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
