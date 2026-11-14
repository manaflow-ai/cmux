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
  cli     cmux-tui's own grammar verbs (`workspace create`, `tab pin`, `closed reopen`), not app actions, so the
          export does not list them. `cli_verbs` in the keep list holds one entry per verb: {verb, palette} names
          the palette-offered (or FAMILY) action that does the same for a person, {verb, reason} says with
          "keep: " why the palette needs no row (a read, a stream, scripting plumbing), and a bare {verb} is a
          gap. `--refresh-cli CMUX_BINARY` reads the verbs from the binary's help and merges them in: new verbs
          arrive bare, mappings stay, verbs the binary no longer has are removed and printed. `cli_source`
          records the build read.

`inventoried` in the keep list names the lists compared; NOW's count reads unknown until all three are.

plans/cmux-next/palette-coverage.json holds the reviewed exceptions, {surface, name, reason} with a one-line reason
starting "keep: " that says why the palette needs no row. A keep entry that names no gap is an error (remove it).

Keys: the palette resolves the list navigation keys (`list_navigation`: Ctrl-N/J down, Ctrl-P/K up) and Up/Down,
the keys every list in NEXT takes.

  python3 scripts/cmux-next/palette-coverage.py            the missing entries; exit 1 when any (or a bad keep list)
  python3 scripts/cmux-next/palette-coverage.py --json     the same as JSON
  python3 scripts/cmux-next/palette-coverage.py --refresh-cli CMUX_BINARY [--source TEXT]
                                                           re-read the cli verbs (tools/cmux-cli --info: the commit)
  python3 scripts/cmux-next/palette-coverage.py --self-test
"""

from __future__ import annotations

import json
import re
import subprocess
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


def cli_gaps(surfaces: dict, keep: dict) -> dict[tuple[str, str], str]:
    """{("cli", verb): what} for every cli verb no palette-offered action covers (kept ones included)."""
    actions = {a["id"]: a for a in surfaces.get("actions", [])}
    out = {}
    for e in keep.get("cli_verbs", []):
        target = actions.get(e.get("palette"))
        if target and (target.get("palette") == "offered" or target.get("palette") in FAMILY):
            continue
        out[("cli", e.get("verb"))] = "cmux-tui verb" + (f" (maps to {e['palette']}, which the palette does not offer)"
                                                         if e.get("palette") else "")
    return out


def cli_problems(surfaces: dict, keep: dict) -> list[str]:
    actions = {a["id"]: a for a in surfaces.get("actions", [])}
    out, seen = [], set()
    for e in keep.get("cli_verbs", []):
        verb = e.get("verb")
        if not isinstance(verb, str) or not verb.strip():
            out.append(f"cli_verbs: an entry with no verb: {e}")
            continue
        if verb in seen:
            out.append(f"cli {verb}: listed twice")
        seen.add(verb)
        if "palette" in e and "reason" in e:
            out.append(f"cli {verb}: a palette mapping and a keep reason; give one")
        if "palette" in e:
            a = actions.get(e["palette"])
            if a is None:
                out.append(f"cli {verb}: maps to {e['palette']}, which is no registry action")
            elif a.get("palette") != "offered" and a.get("palette") not in FAMILY:
                out.append(f"cli {verb}: maps to {e['palette']}, which the palette does not offer ({a.get('palette')})")
        if "reason" in e and not KEEP_REASON.match(str(e["reason"])):
            out.append(f"cli {verb}: the reason must be one line starting \"keep: \"")
    return out


def kept_keys(keep: dict) -> set[tuple[str, str]]:
    kept = {(e.get("surface"), e.get("name")) for e in keep.get("keep", [])}
    return kept | {("cli", e.get("verb")) for e in keep.get("cli_verbs", []) if KEEP_REASON.match(str(e.get("reason", "")))}


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
    kept = kept_keys(keep)
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


# --- cli verbs, read from the binary's help ---------------------------------------------------------------------

LITERAL = re.compile(r"[a-z][a-z0-9-]*$")
UPPER = re.compile(r"[A-Z][A-Z0-9_]*$")
# Example values in usage lines (`cmux vm status dev`) and the `current` selector are no verbs.
EXAMPLE_WORDS = {"dev", "current"}


def _strip_groups(text: str, open_: str, close: str) -> str:
    out, depth = [], 0
    for ch in text:
        if ch == open_:
            depth += 1
        elif ch == close and depth:
            depth -= 1
        elif not depth:
            out.append(ch)
    return "".join(out)  # an unclosed group runs to the end of the line


def _protect(text: str) -> str:
    """Spaces and parens inside <...> belong to the placeholder (`<cloud machine>`, `<http(s) URL>`)."""
    return re.sub(r"<[^<>]*>", lambda m: re.sub(r"[()]", "", m.group(0).replace(" ", "\x00")), text)


def segment_verbs(scope: str, tokens: list[str]) -> tuple[list[str], bool]:
    """(verb paths, from an index) of the tokens after `cmux SCOPE`: literal words, `a|b` expanded, <selectors>,
    UPPER placeholders and example values skipped, stopping at the first flag or argument after a verb word."""
    head = next((tokens[:i] for i, t in enumerate(tokens) if t.startswith("-")), tokens)
    if "..." in head or "…" in head:
        return [], False  # a nested scope: `pane <selector> tab ...`
    paths: list[list[str]] = [[]]
    words, placeholder, index = 0, False, False
    for i, tok in enumerate(tokens):
        if tok.startswith("-"):
            break
        if i == 0 and tok.startswith("<") and tok.endswith(">") and "|" in tok:
            alts = tok[1:-1].split("|")
            if all(LITERAL.match(a) for a in alts):  # `cmux link <init|show|...>`: the scope's verb index
                paths, words, index = [p + [a] for p in paths for a in alts], words + 1, True
                continue
        alts = tok.split("|")
        if all(LITERAL.match(a) for a in alts):
            alts = [a for a in alts if a not in EXAMPLE_WORDS]
            if alts:
                paths, words = [p + [a] for p in paths for a in alts], words + 1
            continue
        lits = [a for a in alts if LITERAL.match(a) and a not in EXAMPLE_WORDS]
        if i == 0 and lits:  # `browser page|<tab_…> <verb>`
            paths, words = [p + [a] for p in paths for a in lits], words + 1
            continue
        if tok.startswith("<") or UPPER.match(tok.rstrip(".…")) or any(a.startswith("<") for a in alts):
            if words and not tok.startswith("<"):
                break  # NAME, HOST: arguments follow
            if not words and re.search(r"verb|action|command", tok, re.I):
                return [], False  # `cmux app <verb...>`: app actions, the export lists them
            placeholder = True
            continue
        if words:
            break  # prose after the usage
        return [], False
    if not words and placeholder:
        return [], False
    return [" ".join([scope, *p]) for p in paths], index


def usage_verbs(scope: str, text: str) -> list[tuple[str, bool]]:
    """Verb paths of a scope help's `cmux SCOPE ...` usage lines (indented, or after `usage:`)."""
    out = []
    for raw in text.splitlines():
        m = re.match(r"(?:\s*usage:?\s*|\s{2,})cmux\s+(.*)$", raw, re.I)
        if not m:
            continue
        line = re.split(r"\s{2,}", _protect(m.group(1)).strip())[0]  # drop the description column
        no_bare = bool(re.search(r"[\[<](COMMAND|verb|action)", line, re.I))
        line = re.sub(r"'[^']*'|\"[^\"]*\"|`[^`]*`", " ", line)
        line = re.sub(r"<([^<>]*)>(\.\.\.|…)", lambda m: f"<{m.group(1).replace('|', '/')}>", line)  # repeated args
        line = re.sub(r"([\])])(\.\.\.|…)", r"\1", line)
        line = _strip_groups(_strip_groups(line, "[", "]"), "(", ")")
        segs = [s.split() for s in re.split(r"\s\|\s", line)]
        first = segs[0]
        while first and first[0] != scope and first[0].startswith(("-", "<")):
            first = first[1:]  # `cmux --machine <cloud machine> workspace list`
        if not first or first[0] != scope:
            continue
        segs[0] = first[1:]
        for n, seg in enumerate(segs):
            if seg[:2] == ["cmux", scope]:
                seg = seg[2:]
            elif n and seg and seg[0].startswith("-"):
                continue  # `get <checkpoint> | --key <key>`: the same verb
            got, index = segment_verbs(scope, seg)
            if got == [scope]:
                if no_bare:
                    got = []
                if n == 0:
                    out += [(v, False) for v in got]
                    break  # `cmux identify | ping`: sibling root commands
            out += [(v, index) for v in got]
    return out


def command_list_verbs(scope: str, text: str) -> list[str]:
    """A clap help's `Commands:` section (cmux acp, chats, harness)."""
    out, on = [], False
    for line in text.splitlines():
        if line.strip() == "Commands:":
            on = True
        elif on:
            m = re.match(r"  ([a-z][a-z0-9-]*)(\s{2,}|$)", line)
            if m and m.group(1) != "help":
                out.append(f"{scope} {m.group(1)}")
            elif not m and line.strip() and not line.startswith("   "):
                on = False
    return out


def indented_verbs(scope: str, text: str, strict: bool = False) -> list[str]:
    """A hand-written verb table, two spaces in (cmux link, cmux server)."""
    out = []
    # Beside usage lines (`strict`), a row is its verb's words, then two or more spaces and a description, or a
    # first word the scope's usage names (`cmux link <init|show|peer|...>`, then `  peer add --install ID`):
    # prose there has neither. A page with no usage line (`cmux server --help`) is all table.
    named = {w for group in re.findall(rf"cmux {re.escape(scope)} <([a-z0-9|-]+)>", text) for w in group.split("|")}
    for line in text.splitlines():
        row = not strict or re.match(r"  [a-z][^ ]*(?: [^ ]+)*?\s{2,}\S", line) or line[2:].split(" ", 1)[0] in named
        if row and re.match(r"  [a-z]", line) and not line.startswith("  cmux"):
            head = _strip_groups(_protect(re.split(r"\s{2,}", line.strip())[0]), "[", "]")
            out += segment_verbs(scope, head.split())[0]
    return out


def scope_verbs(scope: str, text: str) -> list[str]:
    usage = usage_verbs(scope, text)
    got = [v for v, _ in usage] + command_list_verbs(scope, text)
    # A verb table counts beside usage lines too: `cmux vm --help` has both, and its VM API table (run, show,
    # start, stop, snapshot, access, key, creation) is in no usage line (#38553 review F1).
    got += indented_verbs(scope, text, strict=bool(got) and not any(index for _, index in usage))
    # An index word with deeper verbs (`agents <chat|...>`, `agents chat send`) is no verb of its own.
    from_index = {v for v, index in usage if index} - {v for v, index in usage if not index}
    got = [v for v in dict.fromkeys(got) if not (v in from_index and any(w.startswith(v + " ") for w in got))
           and v != f"{scope} help"]
    return got


def root_scopes(text: str) -> list[str]:
    """The scope names of `cmux help`: the indented first words under its section headings."""
    out = []
    for line in text.splitlines():
        m = re.match(r"  ([a-z][a-z0-9-]*)\s", line + " ")
        if m and m.group(1) != "cmux":
            out.append(m.group(1))
    return list(dict.fromkeys(out))


SCOPE_ALIASES = {"vm": "cloud"}


def read_cli(binary: str) -> list[str]:
    def run(*args: str) -> tuple[int, str]:
        p = subprocess.run([binary, *args], capture_output=True, text=True, timeout=60)
        return p.returncode, p.stdout + p.stderr

    # A verb that is an app action's CLI name is the action list's, not a grammar verb (`vm rename-machine` is
    # the app action `cloud rename-machine`; `vm` is `cloud`'s name).
    # Only an action offered on the CLI: an exempt one (ownerVerb, liveInput) leaves the verb to the grammar.
    actions = {a["cli_name"] for a in json.loads(SURFACES.read_text()).get("actions", [])
               if a.get("cli_name") and a.get("cli") == "offered"}
    def is_action(verb: str) -> bool:
        words = verb.split(" ", 1)
        return verb in actions or (words[0] in SCOPE_ALIASES and f"{SCOPE_ALIASES[words[0]]} {words[-1]}" in actions)

    verbs: list[str] = []
    for scope in root_scopes(run("help")[1]):
        code, text = run("help", scope)
        if code or "unknown resource scope" in text:
            text = run(scope, "--help")[1]
        verbs += scope_verbs(scope, text)
    return sorted(v for v in set(verbs) if not is_action(v))


def merge_cli(keep: dict, verbs: list[str]) -> tuple[dict, list[str], list[str]]:
    """(keep with cli_verbs merged, added, removed): mappings stay, new verbs arrive bare, gone ones leave."""
    old = {e["verb"]: e for e in keep.get("cli_verbs", []) if isinstance(e.get("verb"), str)}
    added = [v for v in verbs if v not in old]
    removed = sorted(v for v in old if v not in set(verbs))
    return {**keep, "cli_verbs": [old.get(v, {"verb": v}) for v in verbs]}, added, removed


def refresh_cli(binary: str, source: str | None) -> int:
    keep = json.loads(KEEP.read_text())
    merged, added, removed = merge_cli(keep, read_cli(binary))
    if source is None:
        code, info = 0, ""
        try:
            p = subprocess.run([binary, "--info"], capture_output=True, text=True, timeout=60)
            code, info = p.returncode, p.stdout
            source = f"cmux-tui {json.loads(info)['commit']}"
        except (ValueError, KeyError, OSError, subprocess.SubprocessError):
            source = f"{Path(binary).name} (no --info)" if code or not info else info.strip()
    merged["cli_source"] = source
    KEEP.write_text(json.dumps(merged, indent=2, ensure_ascii=False) + "\n")
    for v in added:
        print(f"added\t{v}")
    for v in removed:
        print(f"removed\t{v}")
    print(f"{len(merged['cli_verbs'])} cli verbs from {source}: {len(added)} added, {len(removed)} removed")
    return 0


def report() -> dict:
    keep = json.loads(KEEP.read_text())
    surfaces = json.loads(SURFACES.read_text())
    found = gaps(surfaces)
    if "cli" in keep.get("inventoried", []):
        found |= cli_gaps(surfaces, keep)
    gone = missing(found, keep)
    return {"inventoried": keep.get("inventoried", []), "missing": len(gone), "kept": len(found) - len(gone),
            "entries": [{"surface": s, "name": n, "what": w} for (s, n), w in sorted(gone.items())],
            "problems": keep_problems(found, keep) + cli_problems(surfaces, keep)
            + key_problems(json.loads(CATALOG.read_text()), KEY_MAP.read_text())}


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

    def test_cli_verbs_are_gaps_unless_mapped_to_a_palette_action_or_kept(self):
        surfaces = {"actions": [self.action(id="ws.new", palette="offered"), self.action(id="fam", palette="familyMember"),
                                self.action(id="hidden", palette="guiOnly")]}
        keep = {"inventoried": ["action", "menu", "cli"], "cli_verbs": [
            {"verb": "workspace create", "palette": "ws.new"}, {"verb": "tab pin", "palette": "fam"},
            {"verb": "tab list", "reason": "keep: a listing"}, {"verb": "tab move"},
            {"verb": "tab hide", "palette": "hidden"}]}
        found = cli_gaps(surfaces, keep)
        self.assertEqual(set(found), {("cli", "tab list"), ("cli", "tab move"), ("cli", "tab hide")})
        self.assertEqual(set(missing(found, keep)), {("cli", "tab move"), ("cli", "tab hide")})
        self.assertEqual(cli_problems(surfaces, keep), ["cli tab hide: maps to hidden, which the palette does not offer (guiOnly)"])

    def test_cli_problems(self):
        surfaces = {"actions": [self.action(id="ws.new", palette="offered")]}
        bad = {"cli_verbs": [{"verb": "a", "palette": "nope"}, {"verb": "b", "reason": "later"},
                             {"verb": "c"}, {"verb": "c"}, {"verb": "d", "palette": "ws.new", "reason": "keep: x"}, {}]}
        got = cli_problems(surfaces, bad)
        self.assertEqual(len(got), 5, got)
        self.assertTrue(any("no registry action" in p for p in got))
        self.assertTrue(any("listed twice" in p for p in got))

    def test_cli_help_parsing(self):
        text = """USAGE
  cmux workspace create [--name <value>] [--focus]
  cmux workspace <selector> show|focus|close
  cmux workspace <selector> rename <name>|--name <name>
  cmux workspace group <group> update [--name <value>]
  cmux workspace <selector> screen ...
  cmux --machine <cloud machine> workspace list
  cmux workspace [<selector>] status set <key> <text>
  cmux workspace placement list
Prose: cmux workspace close --all closes them.
"""
        self.assertEqual(sorted(scope_verbs("workspace", text)),
                         ["workspace close", "workspace create", "workspace focus", "workspace group update",
                          "workspace list", "workspace placement list", "workspace rename", "workspace show",
                          "workspace status set"])
        self.assertEqual(scope_verbs("vm", "  cmux vm status dev\n  cmux vm ls | pause | rm [NAME|ID]\n"),
                         ["vm status", "vm ls", "vm pause", "vm rm"])
        self.assertEqual(scope_verbs("open", "usage: cmux open <path|url>... [--focus]\n  cmux open --link\n"), ["open"])
        self.assertEqual(scope_verbs("status", "  cmux status run [--label <text>] -- CMD …\n"), ["status run"])
        self.assertEqual(scope_verbs("identify", "usage: cmux identify | ping | capabilities\n"), ["identify"])
        self.assertEqual(scope_verbs("app", "  cmux app <verb...> [--x <v>]\n  cmux app ping\n"), ["app ping"])
        self.assertEqual(scope_verbs("device", "  cmux device add HOST --yes\n  cmux device remove ID|NAME\n"),
                         ["device add", "device remove"])
        index = "Usage: cmux agents <chat|doctor>\n  cmux agents chat send <chat>\n  cmux agents doctor\n"
        self.assertEqual(sorted(scope_verbs("agents", index)), ["agents chat send", "agents doctor"])
        link = "USAGE: cmux link <init|peer> [OPTIONS]\n  init --install ID   create\n  peer add --install ID\n"
        self.assertEqual(scope_verbs("link", link), ["link init", "link peer add"])
        clap = "Usage: cmux chats [OPTIONS] <COMMAND>\n\nCommands:\n  list    Chats\n  help    Print\n\nOptions:\n"
        self.assertEqual(scope_verbs("chats", clap), ["chats list"])
        # Usage lines and a verb table on one page (`cmux vm --help`): both count, prose does not (#38553 F1).
        mixed = ("USAGE\n  cmux vm <action> [--x <v>]\n  cmux vm ls [NAME]\n\n  run       Run a command on a fresh VM\n"
                 "  stop      Stop a VM; its disk stays\n  caller is the object this command runs\n")
        self.assertEqual(sorted(scope_verbs("vm", mixed)), ["vm ls", "vm run", "vm stop"])
        root = "USAGE\n  cmux attach\n\nAGENT\n  workspace     Create\n  tab           Tabs\nGLOBAL\n  --json  x\n"
        self.assertEqual(root_scopes(root), ["workspace", "tab"])

    def test_cli_merge_keeps_mappings(self):
        keep = {"cli_verbs": [{"verb": "a", "palette": "x"}, {"verb": "gone", "reason": "keep: y"}]}
        merged, added, removed = merge_cli(keep, ["a", "b"])
        self.assertEqual(merged["cli_verbs"], [{"verb": "a", "palette": "x"}, {"verb": "b"}])
        self.assertEqual((added, removed), (["b"], ["gone"]))

    def test_this_tree(self):
        got = report()
        self.assertEqual(got["problems"], [])
        self.assertIn("action", got["inventoried"])


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        return 0 if unittest.main(argv=[sys.argv[0]], exit=False).result.wasSuccessful() else 1
    if argv[:1] == ["--refresh-cli"] and len(argv) in (2, 4) and (len(argv) == 2 or argv[2] == "--source"):
        return refresh_cli(argv[1], argv[3] if len(argv) == 4 else None)
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
