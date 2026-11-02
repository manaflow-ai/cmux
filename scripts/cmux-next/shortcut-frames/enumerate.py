#!/usr/bin/env python3
"""Every default keyboard shortcut of cmux-next, as cases for the SHORTCUT FRAMES video judge.

SHORTCUT FRAMES (Lawrence 2026-11-02): "cmd+t and cmd shift l, literally all the keyboard shortcuts, to open
the new tab instantly, the frame of". This script lists every default key, so no shortcut is picked by hand:

  1. schemas/defaults/cmux-next.json `key.*` (the golden snapshot of every default binding, made by
     scripts/ci/defaults_guard.py from plans/cmux-next/action-surfaces.json, the exported action catalog),
  2. the action catalog itself (plans/cmux-next/action-surfaces.json: title, menu, palette section), and the
     catalog Swift source for what the export does not carry (`shortcutFamily: .digits`: Cmd-1 is Cmd-1 to Cmd-9),
  3. the AppKit menu keys MainMenu.swift adds outside the catalog (Hide, Undo, Copy, Minimize, ...),
  4. the steps-aside lists (a binding that yields to a focused terminal or code editor) from the same snapshot.

The two key sources must agree: a `key.*` id that the catalog export lacks, or a catalog shortcut the snapshot
lacks, stops the script (exit 2), so a stale snapshot cannot drop a shortcut from the list.

Each output row is one key stroke (a digit family gives 9 rows) bound to one action in one context, with:
  effect     what the first frame after the key must show (new-tab, new-pane, new-workspace, new-window, close,
             switch, overlay, chrome, focus, content, navigate, none, global, exit)
  context    the focus the key needs to run this action (terminal, page, agent, home, palette, ...)
  priority   1 = named first by the order (Cmd-T, Shift-Cmd-L, Cmd-N, Cmd-D, ...), 2 = creates, closes, switches
             or opens something, 3 = the rest
  judge      what the frame judge (judge.py) looks for: the region that must change and the checks that apply

Usage: enumerate.py [--repo DIR] [--out FILE.json] [--markdown FILE.md]
Prints the counts. Portable (no app, no build).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# The order's own list (Lawrence via the lead, 2026-11-02), in its order: these are measured first.
FIRST = [
    "newTab.default",      # Cmd-T
    "openBrowser",         # Shift-Cmd-L
    "newTab",              # Cmd-N (New Workspace)
    "splitRight",          # Cmd-D
    "splitDown",           # Shift-Cmd-D
    "newSurface",          # Ctrl-`
    "newColumn",           # Ctrl-Cmd-D
    "newRow",              # Ctrl-Shift-Cmd-D
    "closeTab",            # Cmd-W
    "terminal.clear",      # Cmd-K in a terminal
    "agentPane.searchChats",  # Cmd-K elsewhere
    "commandPalette",      # Shift-Cmd-P
    "goToWorkspace",       # Cmd-P
    "selectWorkspaceByNumber",  # Cmd-1..9
    "prevSurface",         # Shift-Cmd-[
    "nextSurface",         # Shift-Cmd-]
]

# Effect class by exact id first, then by pattern. The first matching rule wins. `effect` names what the first
# visible frame after the key-down must show; `region` names where the judge looks for it.
EXACT = {
    # New tab in the focused pane: the tab strip gains the selected tab and the pane shows its surface.
    **dict.fromkeys(["newTab.default", "newSurface", "openBrowser", "reopenClosedBrowserPanel",
                     "omnibar.openInForegroundTab"], ("new-tab", "pane+tabstrip")),
    "omnibar.openInBackgroundTab": ("new-tab-background", "tabstrip"),
    # A new pane: the grid gets a column or row, focused.
    **dict.fromkeys(["splitRight", "splitDown", "newColumn", "newRow", "newPaneAutoLayout", "splitBrowserRight",
                     "splitBrowserDown", "browserLinkHintsNewSplit"], ("new-pane", "content")),
    **dict.fromkeys(["newTab", "newBrowserWorkspace", "newCloudWorkspace"], ("new-workspace", "sidebar+content")),
    **dict.fromkeys(["newWindow", "newIncognitoWindow"], ("new-window", "screen")),
    **dict.fromkeys(["closeTab", "closeOtherTabsInPane", "closeWorkspace", "agentPane.archiveChat"], ("close", "content")),
    "closeWindow": ("close-window", "screen"),
    **dict.fromkeys(["selectWorkspaceByNumber", "nextSidebarTab", "prevSidebarTab", "workspace.selectLastUsed",
                     "space.next", "space.previous", "space.selectByNumber", "nextWorkspaceGroup",
                     "prevWorkspaceGroup", "jumpToUnread", "markOldestUnreadAndJumpNext", "focusHistoryBack",
                     "focusHistoryForward"], ("switch", "sidebar+content")),
    **dict.fromkeys(["nextSurface", "prevSurface", "selectSurfaceByNumber", "home.nextConversation",
                     "home.previousConversation", "home.selectConversationByNumber"], ("switch", "pane+tabstrip")),
    **dict.fromkeys(["moveSurfaceLeft", "moveSurfaceRight"], ("reorder", "tabstrip")),
    **dict.fromkeys(["moveSurfaceToPreviousPane", "moveSurfaceToNextPane", "moveSurfaceToPaneLeft",
                     "moveSurfaceToPaneRight", "moveSurfaceToPaneUp", "moveSurfaceToPaneDown", "column.dock"],
                    ("move", "content")),
    **dict.fromkeys(["moveWorkspaceUp", "moveWorkspaceDown", "groupSelectedWorkspaces", "newWorkspaceGroup",
                     "toggleFocusedWorkspaceGroupCollapsed", "markWorkspaceDone", "cycleWorkspaceStatus",
                     "toggleUnread", "palette.toggleTabPin", "sidebar.priorityView.toggle"], ("sidebar", "sidebar")),
    **dict.fromkeys(["commandPalette", "goToWorkspace", "search.chats", "globalSearch", "agentPane.searchChats",
                     "palette.searchShortcuts", "palette.quickAgentChat", "agentPane.switchModel", "hints.show",
                     "browserLinkHints", "find", "findInDirectory", "renameTab", "renameWorkspace",
                     "editWorkspaceDescription", "fileEditorGotoLine", "browserShowHistory", "browser.pageInfo",
                     "openTeamPicker", "saveLayoutTemplate", "openFolder", "feed.show", "openSettings",
                     "diffViewerSearch", "markdownLink"], ("overlay", "window")),
    **dict.fromkeys(["hideFind"], ("overlay-close", "window")),
    **dict.fromkeys(["toggleSidebar", "toggleRightSidebar", "toggleFullScreen", "toggleSplitZoom",
                     "toggleCanvasLayout", "canvasOverview", "canvasTidy", "canvasRevealFocusedPane",
                     "bookmark.toggleBar", "toggleBrowserFocusMode", "toggleBrowserDeveloperTools",
                     "showBrowserJavaScriptConsole", "inspectBrowserElement", "equalizeSplits", "resizePaneLeft",
                     "resizePaneRight", "resizePaneUp", "resizePaneDown", "openDiffViewer",
                     "appearance.uiScale.increase", "appearance.uiScale.decrease", "appearance.uiScale.reset"],
                    ("chrome", "window")),
    **dict.fromkeys(["focusLeft", "focusRight", "focusUp", "focusDown", "focusPaneByNumber", "focusSidebar",
                     "focusRightSidebar", "focusLocation", "focusTextBoxInput", "triggerFlash"], ("focus", "content")),
    **dict.fromkeys(["palette.newAgentChat"], ("new-pane", "content")),
    **dict.fromkeys(["palette.forkAgentConversation"], ("new-tab", "pane+tabstrip")),
    **dict.fromkeys(["browserBack", "browserForward", "browserReload", "browserHardReload", "browserStop",
                     "markdownBack", "markdownForward", "markdownReload"], ("navigate", "pane")),
    **dict.fromkeys(["terminalCopy", "browser.copyURL", "agentPane.copyLastCodeBlock", "saveFilePreview",
                     "markdownSave", "reloadConfiguration", "useSelectionForFind"], ("none", "none")),
    **dict.fromkeys(["home.messageChiefFromAnyApp", "palette.startAgentFromAnyApp", "showHideAllWindows",
                     "palette.toggleDictation"], ("global", "screen")),
    "quit": ("exit", "screen"),
    "reopenPreviousSession": ("new-window", "screen"),
}
PATTERNS = [
    (r"(?i)zoom(In|Out|Reset)$|FontSize$|^terminal\.(increase|decrease|reset)FontSize$", ("content", "pane")),
    (r"^paletteKey\.|^commandPalette(Next|Previous)$|^list\.", ("overlay-key", "overlay")),
    (r"^diffViewer|^agentPane\.(previous|next)Turn$|^jumpToLastPrompt$|^terminal\.scrollToSelection$",
     ("scroll", "pane")),
    (r"^agentPane\.permission\.", ("content", "pane")),
    (r"^simulator", ("content", "pane")),
    (r"^(terminal\.clear|clearScreenKeepScrollback|terminalPaste|toggleTerminalCopyMode|cycleTextBoxSubmitAction|"
     r"attachTextBoxFile|toggleChecklistItemComplete|toggleFileEditorWordWrap|toggleBrowserDesignMode|findNext|"
     r"findPrevious|browser\.findPrevious|fileExplorerOpenSelection.*|home\.replyToSelection)$", ("content", "pane")),
]

# The focus a key needs (from the binding's `when`, else the action's id).
CONTEXT_BY_WHEN = [
    (r"paletteOpen", "palette"),
    (r"listFocus", "sidebar-list"),
    (r"topPage == home|surfaceKind == home", "home"),
    (r"sidebar\.multiSelection", "sidebar-multi"),
    (r"surfaceKind != terminal", "non-terminal"),
    (r"surfaceKind != page", "non-page"),
]
CONTEXT_BY_ID = [
    (r"^(browser|splitBrowser|toggleBrowser|showBrowser|inspectBrowser|bookmark\.)|^browserLinkHints", "page"),
    (r"^omnibar\.", "omnibar"),
    (r"^markdown", "markdown"),
    (r"^diffViewer", "diff"),
    (r"^fileEditor|^toggleFileEditor|^saveFilePreview", "file-editor"),
    (r"^fileExplorer", "file-explorer"),
    (r"^simulator", "simulator"),
    (r"^canvas", "canvas"),
    (r"^agentPane|^palette\.forkAgentConversation", "agent"),
    (r"^home\.", "home"),
    (r"^terminal|^clearScreen|^toggleTerminalCopyMode|^focusTextBox|^cycleTextBox|^attachTextBox|^jumpToLastPrompt",
     "terminal"),
    (r"^(find|findNext|findPrevious|hideFind|useSelectionForFind)$", "terminal"),
    (r"^paletteKey|^commandPalette(Next|Previous)$", "palette"),
    (r"^list\.", "sidebar-list"),
    (r"^(home\.messageChiefFromAnyApp|palette\.startAgentFromAnyApp|showHideAllWindows)$", "other-app"),
    (r"^(focusHistoryBack|focusHistoryForward)$", "two-panes"),
    (r"^(focusLeft|focusRight|focusUp|focusDown|focusPaneByNumber|resizePane.*|equalizeSplits|toggleSplitZoom|"
     r"moveSurfaceTo.*|closeOtherTabsInPane|nextSurface|prevSurface|selectSurfaceByNumber|moveSurfaceLeft|"
     r"moveSurfaceRight)$", "grid"),
]

# What the judge checks per effect: the region where the first change must appear, and which defects apply.
JUDGE = {
    "new-tab": "first frame: the new tab selected in the strip AND its surface (terminal background, New Tab page or "
               "page chrome) in the pane, focused; checks: blank, flash, half chrome, jump, re-layout; content fills in place",
    "new-tab-background": "first frame: a new unselected tab in the strip; the pane does not change",
    "new-pane": "first frame: the new pane at its final rect (or the motion's first step), focused, with its tab bar; "
                "checks: blank, flash, half chrome, gap/overlap, jump, re-layout (motion itself: RESIZE VIDEOS judge)",
    "new-workspace": "first frame: the new sidebar row selected AND the window showing the new workspace; checks: blank, "
                     "flash, half chrome, jump, re-layout",
    "new-window": "first frame: the new window on screen with its chrome; checks: blank window, flash, half chrome, jump",
    "close": "first frame: the object gone and its neighbor in its place (or the motion's first step); checks: flash, "
             "stale frame, gap, jump back",
    "close-window": "first frame: the window gone (or its close animation's first step)",
    "switch": "first frame: the selected item changed AND the content area shows it; checks: blank, flash, stale frame, "
              "half-drawn content",
    "reorder": "first frame: the tab at its new slot; checks: jump, re-layout",
    "move": "first frame: the tab in its new pane, the old pane updated; checks: blank, flash, gap, jump",
    "sidebar": "first frame: the sidebar row(s) changed; checks: jump, re-layout of other rows",
    "overlay": "first frame: the overlay (palette, field, bar, menu, panel) drawn whole with its focus; checks: half "
               "drawn, flash, jump of the content under it",
    "overlay-close": "first frame: the overlay gone; checks: flash, jump",
    "overlay-key": "first frame: the overlay's selection or level changed; checks: jump, flash",
    "chrome": "first frame: the change's first step (sidebar slide start, zoom, devtools); checks: blank, flash, jump "
              "(motion itself: RESIZE VIDEOS judge)",
    "focus": "first frame: the focus ring/indicator on the new target; checks: flash, jump",
    "content": "first frame: the content changed (font size, clear, scale); checks: blank, flash, half drawn",
    "scroll": "first frame: the content scrolled; checks: blank, tear",
    "navigate": "first frame: the navigation's first visible response (progress, back/forward state); the page fills "
                "in place later; checks: blank, flash",
    "none": "no frame change expected (clipboard, save): judged as 'no flash, no jump' only",
    "global": "first frame: the panel or window change while another app is front; checks: half drawn, flash",
    "exit": "not measured (ends the app)",
}

DIGIT_ROWS = 9


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def digit_families(repo: Path) -> set[str]:
    """Ids whose shortcut is a 1..9 family (`shortcutFamily: .digits`), read from the catalog Swift source."""
    found: set[str] = set()
    catalog = repo / "Packages/macOS/CmuxNext/Sources/CmuxNextActions"
    for file in sorted(catalog.rglob("*.swift")):
        text = file.read_text(encoding="utf-8")
        for match in re.finditer(r"(shortcutFamily|family): *\.digits", text):
            # The descriptor's id is the nearest `id: "..."` (or a helper's first string argument) before the family.
            head = text[: match.start()]
            ids = list(re.finditer(r'\bid: *"([^"]+)"|^\s*\w+\(\s*"([^"]+)"', head, re.M))
            if ids:
                found.add(ids[-1].group(1) or ids[-1].group(2))
    return found


def menu_keys(repo: Path) -> list[dict]:
    """The AppKit menu keys MainMenu.swift adds outside the catalog."""
    text = (repo / "Packages/macOS/CmuxNext/Sources/CmuxNextApp/MainMenu.swift").read_text(encoding="utf-8")
    rows = []
    mods = {".command": "cmd", ".shift": "shift", ".option": "opt", ".control": "ctrl"}
    order = ["ctrl", "opt", "shift", "cmd"]
    for m in re.finditer(r'item\(Strings\.(\w+), [^,]+, "([^"]+)", \[([^\]]*)\]\)', text):
        names = [mods[x.strip()] for x in m.group(3).split(",") if x.strip() in mods]
        rows.append({"id": f"menu.{m.group(1)}", "stroke": "+".join([n for n in order if n in names] + [m.group(2)])})
    for m in re.finditer(r'NSMenuItem\(title: Strings\.(\w+), action: [^,]+, keyEquivalent: "([^"]+)"\)', text):
        rows.append({"id": f"menu.{m.group(1)}", "stroke": f"cmd+{m.group(2)}"})
    return rows


def classify(ident: str) -> tuple[str, str]:
    if ident in EXACT:
        return EXACT[ident]
    for pattern, value in PATTERNS:
        if re.search(pattern, ident):
            return value
    return ("unclassified", "window")


def context_of(ident: str, when: str | None) -> str:
    for pattern, name in CONTEXT_BY_WHEN:
        if when and re.search(pattern, when):
            return name
    for pattern, name in CONTEXT_BY_ID:
        if re.search(pattern, ident):
            return name
    return "any"


def split_binding(text: str) -> tuple[str, str | None]:
    if " when " in text:
        keys, when = text.split(" when ", 1)
        return keys.strip(), when.strip()
    return text.strip(), None


def expand_digits(stroke: str) -> list[str]:
    if not re.search(r"(^|\+)1$", stroke):
        return [stroke]
    return [stroke[:-1] + str(n) for n in range(1, DIGIT_ROWS + 1)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo", default=str(HERE.parents[2]))
    parser.add_argument("--out", default="")
    parser.add_argument("--markdown", default="")
    args = parser.parse_args()
    repo = Path(args.repo)

    snapshot = read_json(repo / "schemas/defaults/cmux-next.json")["defaults"]
    surfaces = read_json(repo / "plans/cmux-next/action-surfaces.json")["actions"]
    by_id = {a["id"]: a for a in surfaces}
    snap_keys = {k[4:]: v for k, v in snapshot.items() if k.startswith("key.")}
    catalog_keyed = {a["id"] for a in surfaces
                     if a.get("default_shortcut") or a.get("default_chord") or a.get("default_aliases")}
    missing_in_catalog = sorted(set(snap_keys) - set(by_id))
    missing_in_snapshot = sorted(catalog_keyed - set(snap_keys))
    if missing_in_catalog or missing_in_snapshot:
        print(f"key sources disagree: snapshot-only {missing_in_catalog}, catalog-only {missing_in_snapshot}",
              file=sys.stderr)
        return 2
    steps_aside = {name.removeprefix("steps-aside."): value for name, value in snapshot.items()
                   if name.startswith("steps-aside.")}
    families = digit_families(repo)
    first = {ident: n for n, ident in enumerate(FIRST)}

    rows = []
    for ident, bindings in sorted(snap_keys.items()):
        action = by_id[ident]
        effect, region = classify(ident)
        for binding in bindings:
            keys, when = split_binding(binding)
            chord = " " in keys
            strokes = expand_digits(keys) if ident in families and not chord else [keys]
            for stroke in strokes:
                context = context_of(ident, when)
                priority = 1 if ident in first else (2 if effect in {
                    "new-tab", "new-pane", "new-workspace", "new-window", "close", "close-window", "switch",
                    "overlay", "move"} else 3)
                rows.append({
                    "stroke": stroke, "chord": chord, "when": when, "action": ident, "title": action.get("title"),
                    "menu": action.get("main_menu"), "section": (action.get("palette_section") or {}).get("id"),
                    "source": "catalog", "family": "digits" if len(strokes) > 1 else None, "effect": effect,
                    "region": region, "context": context, "priority": priority,
                    "order": first.get(ident, len(FIRST)),
                    "yields_to": sorted(name for name, ids in steps_aside.items() if ident in ids),
                    "judge": JUDGE.get(effect, "unclassified: review"),
                })
    for item in menu_keys(repo):
        effect = {"menu.menuHide": "global", "menu.menuHideOthers": "global", "menu.menuMinimize": "close-window"}.get(
            item["id"], "content")
        rows.append({"stroke": item["stroke"], "chord": False, "when": None, "action": item["id"],
                     "title": item["id"].removeprefix("menu.menu"), "menu": "appkit", "section": None,
                     "source": "MainMenu.swift", "family": None, "effect": effect, "region": "window",
                     "context": "text-field" if effect == "content" else "any", "priority": 3, "order": len(FIRST),
                     "yields_to": [], "judge": JUDGE[effect]})
    # A family's `cmd+1` row and an explicit `cmd+2 when ...` alias of the same action are one case.
    unique: dict[tuple, dict] = {}
    for r in rows:
        unique.setdefault((r["stroke"], r["action"], r["when"]), r)
    rows = sorted(unique.values(), key=lambda r: (r["priority"], r["order"], r["action"], r["stroke"]))

    # Two actions on the same stroke and context would make one press ambiguous: list them so a case sets the
    # context that picks the intended one.
    shared: dict[str, list[str]] = {}
    for r in rows:
        shared.setdefault(r["stroke"], []).append(r["action"])
    for r in rows:
        r["same_stroke"] = sorted(set(shared[r["stroke"]]) - {r["action"]})

    unclassified = sorted({r["action"] for r in rows if r["effect"] == "unclassified"})
    summary = {
        "sources": ["schemas/defaults/cmux-next.json (key.*, steps-aside.*)", "plans/cmux-next/action-surfaces.json",
                    "Packages/macOS/CmuxNext/Sources/CmuxNextActions (shortcutFamily .digits)",
                    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/MainMenu.swift"],
        "actions_with_keys": len(snap_keys),
        "menu_keys": len(menu_keys(repo)),
        "rows": len(rows),
        "distinct_strokes": len({r["stroke"] for r in rows}),
        "chords": sum(r["chord"] for r in rows),
        "by_effect": {},
        "by_priority": {},
        "unclassified": unclassified,
    }
    for r in rows:
        summary["by_effect"][r["effect"]] = summary["by_effect"].get(r["effect"], 0) + 1
        summary["by_priority"][str(r["priority"])] = summary["by_priority"].get(str(r["priority"]), 0) + 1
    out = {"summary": summary, "rows": rows}
    if args.out:
        Path(args.out).write_text(json.dumps(out, indent=1) + "\n", encoding="utf-8")
    if args.markdown:
        lines = ["# SHORTCUT FRAMES: every default shortcut", "",
                 f"Made by `scripts/cmux-next/shortcut-frames/enumerate.py`. {summary['actions_with_keys']} catalog "
                 f"actions with a default key, {summary['menu_keys']} AppKit menu keys, {summary['rows']} rows "
                 f"(a digit family is 9 rows), {summary['distinct_strokes']} distinct strokes.", "",
                 "| P | Stroke | Action | Title | Effect | Context | When | Same stroke |", "|---|---|---|---|---|---|---|---|"]
        for r in rows:
            lines.append(f"| {r['priority']} | `{r['stroke']}` | {r['action']} | {r['title']} | {r['effect']} | "
                         f"{r['context']} | {r['when'] or ''} | {', '.join(r['same_stroke'])} |")
        Path(args.markdown).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=1))
    return 1 if unclassified else 0


if __name__ == "__main__":
    sys.exit(main())
