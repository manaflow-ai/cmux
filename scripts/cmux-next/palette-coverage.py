#!/usr/bin/env python3
"""Palette coverage: everything a person can do from the `cmux` CLI or a menu in NEXT has a command palette entry.

Leo, 2026-11-08 (cmuxterm-hq goals/palette-all-actions.md): every CLI and menu action has a palette entry, and the
palette takes the same keys as lists. This compares the lists and prints what the palette is missing; NOW's
`palette_coverage` reads the same two files with the same rules, so the goal's number is this script's count.

The lists, from plans/cmux-next/action-surfaces.json (the app's own export, kept fresh by
scripts/cmux-next/check-action-surfaces.sh):

  action  a registry action offered on the CLI (`cli: "offered"`), placed in the menu bar (`main_menu`) or offered
          in a right-click menu (`context_menu: "offered"`) whose `palette` is not "offered". Covered without an
          entry: an exemption that names the palette row standing in for it (FAMILY: a family's one row, the
          default engine's row), and a live-input action that only a right-click menu offers (Copy Link on the
          link under the pointer: the palette has no pointer).
  menu    a hand-built menu (`context_menus_not_exported`): its rows are not registry actions, so the palette
          cannot know them. It counts until its rows become actions or its keep reason says why none is needed.
  cli     cmux-tui's own grammar verbs, not app actions: not compared yet. `inventoried` in the keep list names
          the lists compared; NOW's count reads unknown until "cli" is one of them.

plans/cmux-next/palette-coverage.json holds the reviewed exceptions, {surface, name, reason} with a one-line reason
starting "keep: " that says why the palette needs no row. A keep entry that names no gap is an error (remove it).

Keys: the palette resolves the list navigation keys (`list_navigation`: Ctrl-N/J down, Ctrl-P/K up) and Up/Down,
the keys every list in NEXT takes.

  python3 scripts/cmux-next/palette-coverage.py            the missing entries; exit 1 when any (or a bad keep list)
  python3 scripts/cmux-next/palette-coverage.py --json     the same as JSON
  python3 scripts/cmux-next/palette-coverage.py --self-test
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KEEP = ROOT / "plans/cmux-next/palette-coverage.json"
SURFACES = ROOT / "plans/cmux-next/action-surfaces.json"
CATALOG = ROOT / "plans/cmux-next/action-catalog.json"
KEY_MAP = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextPalette/PaletteKeyMap.swift"
KINDS = ("action", "menu", "cli")
KEEP_REASON = re.compile(r"keep: \S[^\n]*$")
# Palette exemptions whose own row stands in for the action (ActionSurface.swift SurfaceExemption).
FAMILY = {"familyMember", "duplicateOfDefault", "secondaryEngine"}


def gaps(surfaces: dict) -> dict[tuple[str, str], str]:
    """{(surface, name): what it is} for every CLI or menu action the palette does not offer."""
    out: dict[tuple[str, str], str] = {}
    for a in surfaces.get("actions", []):
        palette = a.get("palette")
        cli, main_menu, context = a.get("cli") == "offered", a.get("main_menu"), a.get("context_menu") == "offered"
        if palette == "offered" or palette in FAMILY or not (cli or main_menu or context):
            continue
        if palette == "liveInput" and not cli and not main_menu:
            continue
        where = [f"cli `{a.get('cli_name')}`"] if cli else []
        where += [f"{main_menu} menu"] if main_menu else []
        where += [f"right-click {','.join(a.get('context_menus') or [])}"] if context else []
        out[("action", a["id"])] = f"{a.get('title')} (palette: {palette}; {'; '.join(where)})"
    for m in surfaces.get("context_menus_not_exported", []):
        out[("menu", m["name"])] = f"hand-built menu in {m.get('source')}"
    return out


def keep_problems(found: dict[tuple[str, str], str], keep: dict) -> list[str]:
    out = []
    seen = set()
    for e in keep.get("keep", []):
        key = (e.get("surface"), e.get("name"))
        if key in seen:
            out.append(f"{key}: listed twice")
        seen.add(key)
        if key[0] not in KINDS:
            out.append(f"{key}: unknown surface (one of {', '.join(KINDS)})")
        elif key not in found:
            out.append(f"{key[0]} {key[1]}: kept, but the palette covers it now (or it is gone): remove the entry")
        if not KEEP_REASON.match(str(e.get("reason", ""))):
            out.append(f"{key[0]} {key[1]}: the reason must be one line starting \"keep: \"")
    out += [f"inventoried: {k} is not one of {', '.join(KINDS)}" for k in keep.get("inventoried", []) if k not in KINDS]
    return out


def missing(found: dict[tuple[str, str], str], keep: dict) -> dict[tuple[str, str], str]:
    kept = {(e.get("surface"), e.get("name")) for e in keep.get("keep", [])}
    return {k: v for k, v in found.items() if k not in kept}


def key_problems(catalog: dict, key_map: str) -> list[str]:
    """The palette resolves the list keys and Up/Down: every list_navigation command moves its selection."""
    defaults = catalog.get("key_binding_defaults", {})
    moves = dict(re.findall(r'"([\w.]+)": \.(moveDown|moveUp)', key_map))
    out = []
    lists = defaults.get("list_navigation", [])
    if not {("n", ("ctrl",)), ("p", ("ctrl",))} <= {(k["key"], tuple(k["modifiers"])) for b in lists for k in b["keys"]}:
        out.append("list_navigation no longer binds Ctrl-N and Ctrl-P")
    for b in lists:
        want = "moveDown" if b["command"].endswith("next") else "moveUp"
        if moves.get(b["command"]) != want:
            out.append(f"{b['command']} ({b['keys']}): lists take it, the palette does not {want} on it")
    arrows = {(b["command"], k["key"]) for b in defaults.get("palette_keys", []) for k in b["keys"] if not k["modifiers"]}
    for command, key in (("commandPalettePrevious", ""), ("commandPaletteNext", "")):
        if (command, key) not in arrows:
            out.append(f"the palette's {command} lost its plain arrow key")
    return out


def report() -> dict:
    keep = json.loads(KEEP.read_text())
    found = gaps(json.loads(SURFACES.read_text()))
    gone = missing(found, keep)
    return {"inventoried": keep.get("inventoried", []), "missing": len(gone), "kept": len(found) - len(gone),
            "entries": [{"surface": s, "name": n, "what": w} for (s, n), w in sorted(gone.items())],
            "problems": keep_problems(found, keep) + key_problems(json.loads(CATALOG.read_text()), KEY_MAP.read_text())}


class Rules(unittest.TestCase):
    @staticmethod
    def action(**kw) -> dict:
        return {"id": "x", "title": "X", "palette": "noObject", "cli": "guiOnly", "cli_name": None,
                "main_menu": None, "context_menu": "noObject", **kw}

    def test_a_cli_or_menu_action_off_the_palette_is_a_gap(self):
        for kw in ({"cli": "offered"}, {"main_menu": "file"}, {"context_menu": "offered"}):
            with self.subTest(**kw):
                self.assertIn(("action", "x"), gaps({"actions": [self.action(**kw)]}))

    def test_covered_family_and_pointer_only_actions_are_not_gaps(self):
        covered = [self.action(palette="offered", cli="offered"), self.action(palette="familyMember", cli="offered"),
                   self.action(palette="liveInput", context_menu="offered"), self.action(palette="guiOnly")]
        self.assertEqual(gaps({"actions": covered}), {})
        self.assertIn(("action", "x"), gaps({"actions": [self.action(palette="liveInput", cli="offered")]}))

    def test_hand_built_menus_are_gaps(self):
        self.assertIn(("menu", "m"), gaps({"context_menus_not_exported": [{"name": "m", "source": "M.swift"}]}))

    def test_keep_entries_name_live_gaps_with_a_reason(self):
        found = {("action", "x"): "X", ("menu", "m"): "M"}
        keep = {"inventoried": ["action", "menu"], "keep": [{"surface": "menu", "name": "m", "reason": "keep: data"}]}
        self.assertEqual(keep_problems(found, keep), [])
        self.assertEqual(missing(found, keep), {("action", "x"): "X"})
        self.assertEqual(len(keep_problems({}, keep)), 1)  # covered now: remove it
        bad = {"keep": [{"surface": "menu", "name": "m", "reason": "debt: later"}]}
        self.assertEqual(len(keep_problems(found, bad)), 1)

    def test_key_rules(self):
        catalog = {"key_binding_defaults": {
            "list_navigation": [{"command": "list.next", "keys": [{"key": "n", "modifiers": ["ctrl"]}]},
                                {"command": "list.previous", "keys": [{"key": "p", "modifiers": ["ctrl"]}]}],
            "palette_keys": [{"command": "commandPalettePrevious", "keys": [{"key": "", "modifiers": []}]},
                             {"command": "commandPaletteNext", "keys": [{"key": "", "modifiers": []}]}]}}
        self.assertEqual(key_problems(catalog, '"list.next": .moveDown, "list.previous": .moveUp,'), [])
        self.assertEqual(len(key_problems(catalog, '"list.next": .moveDown,')), 1)

    def test_this_tree(self):
        got = report()
        self.assertEqual(got["problems"], [])
        self.assertIn("action", got["inventoried"])


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        return 0 if unittest.main(argv=[sys.argv[0]], exit=False).result.wasSuccessful() else 1
    got = report()
    if argv == ["--json"]:
        print(json.dumps(got, indent=2))
    else:
        for e in got["entries"]:
            print(f"{e['surface']}\t{e['name']}\t{e['what']}")
        for p in got["problems"]:
            print(f"problem: {p}")
        todo = [k for k in KINDS if k not in got["inventoried"]]
        print(f"{got['missing']} missing, {got['kept']} kept" + (f"; not compared yet: {', '.join(todo)}" if todo else ""))
    return 1 if got["missing"] or got["problems"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
