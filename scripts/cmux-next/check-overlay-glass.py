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
                   NSWindow) whose file never makes the shared glass (`Glass.makeOverlayPanel`).
                   Leo 2026-10-21: "WHERE IS THE GLASS EVERYWHERE, all these hover tooltips and
                   hover previews."

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
}

# A file-level rule: a tooltip or hover window must make the shared glass somewhere in its file.
HOVER_WINDOW = re.compile(
    r"\bclass\s+\w*(Tooltip|ToolTip|HoverCard|HoverPreview|Preview|Peek)\w*\s*:\s*(NSPanel|NSWindow)\b"
)
SHARED_GLASS = re.compile(r"\bGlass\.makeOverlayPanel\(")

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
}


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
            makes_glass = any(SHARED_GLASS.search(line.split("//", 1)[0]) for line in lines if not COMMENT.match(line))
            hover = rel not in HOVER_HOSTS and any(HOVER_BODY.search(text) for text in lines)
            for index, line in enumerate(lines):
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
    return findings


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
        print("  tooltip glass or CardSurfaceView, or say why it stays solid: `// glass-opaque-allow: <reason>`.")
        for finding in findings:
            print(finding)
        return 1
    print("check-overlay-glass: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
