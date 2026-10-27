#!/usr/bin/env python3
"""Context menu rows run registered actions, never inline handlers.

Lawrence 2026-10-19: right-click "New Tab Group" was broken while the
Cmd-Shift-P path worked; "eliminate this entire error class". A menu row
whose click runs its own selector or closure is a second path beside the
action the palette, shortcuts, the CLI and MCP run, and the two drift. Rows
come from `ActionRegistry.makeContextMenu` (an `ActionMenuPayload` with a
registered action id and the right-clicked target), so the menu and the
palette run the same handler on the same target.

This check counts the inline menu rows in each cmux-next source file: an
`NSMenuItem(...)` or `addItem(withTitle:...)` with an `action: #selector`.
The files that had them on 2026-10-19 are listed in
scripts/cmux-next/check-menu-actions-baseline.txt with their counts. A new
file with an inline row, or more inline rows in a listed file, fails. Moving
a row to the registry lowers a count; run with --update to rewrite the
baseline then (it never raises a count).

Usage: check-menu-actions.py [--update] [ROOT]
"""
import os
import re
import sys

SOURCES = "Packages/macOS/CmuxNext/Sources"
BASELINE = "scripts/cmux-next/check-menu-actions-baseline.txt"
# The registry builds every action row (its AppKit side, CmuxNextActionsAppKit, makes the items); the demo app
# has no registry.
EXEMPT = ("Packages/macOS/CmuxNext/Sources/CmuxNextActions/", "Packages/macOS/CmuxNext/Sources/CmuxNextActionsAppKit/",
          "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/Demo/")
ROW = re.compile(r"(NSMenuItem\s*\(|addItem\s*\(\s*withTitle\s*:)[^;{}]*?action\s*:\s*#selector", re.S)


def counts(root):
    found = {}
    base = os.path.join(root, SOURCES)
    for directory, _, files in os.walk(base):
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            rel = os.path.relpath(path, root)
            if rel.startswith(EXEMPT):
                continue
            with open(path, encoding="utf-8") as handle:
                n = len(ROW.findall(handle.read()))
            if n:
                found[rel] = n
    return found


def read_baseline(root):
    path = os.path.join(root, BASELINE)
    allowed = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line and not line.startswith("#"):
                    count, rel = line.split(None, 1)
                    allowed[rel] = int(count)
    return allowed


def write_baseline(root, found, allowed):
    kept = {rel: min(n, allowed.get(rel, n)) for rel, n in found.items()}
    with open(os.path.join(root, BASELINE), "w", encoding="utf-8") as handle:
        handle.write("# Inline context menu rows allowed per file (scripts/cmux-next/check-menu-actions.py).\n")
        handle.write("# Lower a count when a row moves to ActionRegistry.makeContextMenu; never add a file.\n")
        for rel in sorted(kept):
            handle.write(f"{kept[rel]} {rel}\n")


def main(argv):
    update = "--update" in argv
    args = [a for a in argv if a != "--update"]
    root = os.path.abspath(args[0]) if args else os.getcwd()
    found, allowed = counts(root), read_baseline(root)
    if update:
        write_baseline(root, found, allowed if allowed else found)
        return 0
    failures = [f"{rel}: {n} inline menu row(s), {allowed.get(rel, 0)} allowed" for rel, n in sorted(found.items()) if n > allowed.get(rel, 0)]
    if failures:
        print("Context menu rows must run a registered action (ActionRegistry.makeContextMenu or makeMenuItem),")
        print("not an inline selector: a menu-only path drifts from the palette, shortcut and CLI path.")
        for failure in failures:
            print(f"  {failure}")
        return 1
    lowered = [rel for rel, n in allowed.items() if found.get(rel, 0) < n]
    if lowered:
        print("note: fewer inline rows than the baseline in " + ", ".join(sorted(lowered)) + "; run with --update to lock that in")
    print(f"ok: {sum(found.values())} inline menu rows in {len(found)} baselined files, none new")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
