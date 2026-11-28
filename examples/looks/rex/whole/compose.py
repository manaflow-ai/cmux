"""Rebuild the two distribution formats from the standalone Rex packs."""
import argparse
import itertools
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
PACKS = ("appearance", "toolbar", "new-tab", "hosts", "activity", "session-picker", "panes",
         "terminal", "tabs", "palette", "preferences", "session-operations", "pane-operations")
VIEWS = {"new-tab", "hosts", "activity", "session-picker"}
APP_FILES = ("customize/cmux-app.json", "customize/main.js")


def encode(value):
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def merge(items, key, value, source):
    if key in items and items[key] != value:
        raise ValueError(f"{source}: conflicting values for {key}")
    items[key] = value


# ShortcutBinding.keyEquivalent and parseStroke: punctuation names and
# modifier spelling/order don't distinguish shortcuts in the native dispatcher.
ALIASES = {alias: group[0] for group in (
    ("cmd", "command", "⌘"), ("shift", "⇧"), ("opt", "alt", "option", "⌥"),
    ("ctrl", "control", "ctl", "⌃"), ("return", "enter", "↩"), ("tab", "⇥"),
    ("escape", "esc", "⎋"), ("delete", "backspace", "⌫"), ("space", "spacebar", "<space>"),
    ("left", "arrowleft", "leftarrow", "←"), ("right", "arrowright", "rightarrow", "→"),
    ("up", "arrowup", "uparrow", "↑"), ("down", "arrowdown", "downarrow", "↓"),
    ("=", "plus", "equals"), (",", "comma"), (".", "period", "dot"), ("/", "slash"),
    (chr(92), "backslash"), (";", "semicolon"), ("'", "quote", "apostrophe"),
    (chr(96), "backtick", "grave"), ("-", "minus", "hyphen"),
    ("[", "leftbracket", "openbracket"), ("]", "rightbracket", "closebracket"),
) for alias in group}
MODIFIERS = {"cmd", "shift", "opt", "ctrl"}


def strokes(key):
    result = []
    for stroke in key.lower().split():
        if stroke.endswith("++"):
            stroke = stroke[:-1] + "plus"
        *mods, token = [ALIASES.get(s, s) for s in stroke.split("+")]
        if not token or set(mods) - MODIFIERS:
            raise ValueError(f"invalid Rex keystroke {stroke!r}")
        result.append((frozenset(mods), token))
    if not result:
        raise ValueError("missing Rex keystroke")
    return tuple(result)


def contexts(when):
    """Enumerate the truth table for the focus flags these packs use."""
    terms = [s.strip() for s in when.split("&&")] if when.strip() else []
    flags = ("terminalFocused", "paletteOpen")
    if any(t.lstrip("!") not in flags or t.startswith("!!") for t in terms):
        raise ValueError(f"unknown Rex binding condition {when!r}")
    return frozenset(values for values in itertools.product((False, True), repeat=len(flags))
                     if all(values[flags.index(t.lstrip("!"))] == (t[0] != "!") for t in terms))


def add_binding(by_key, row, source):
    chord = strokes(row["key"])
    context = contexts(row.get("when", ""))
    action = {k: v for k, v in row.items() if k not in {"key", "when"}}
    for other_context, other_action, owner in by_key.setdefault(chord, []):
        if context & other_context and action != other_action:
            raise ValueError(f"{source} and {owner}: conflicting actions on {row['key']}")
        if (context, action) == (other_context, other_action):
            return False
    by_key[chord].append((context, action, source))
    return True


def compose(root):
    settings, files, bindings, by_key = {}, {}, [], {}
    for name in PACKS:
        pack = root / name
        setup = json.loads((pack / "cmux-setup.json").read_text())
        profile = json.loads((pack / "profile.json").read_text())
        if profile.get("settings", {}) != setup.get("settings", {}):
            raise ValueError(f"{name}: setup and preview settings differ")
        if setup.get("actions") or setup.get("extensions") or setup.get("files"):
            raise ValueError(f"{name}: setup gained a payload needing integration")
        for key, value in profile.get("settings", {}).items():
            merge(settings, key, value, name)
        for path, content in profile.get("files", {}).items():
            if (pack / path).read_text() != content:
                raise ValueError(f"{name}: preview differs from adjacent {path}")
            if path == "keybindings.json":
                for row in json.loads(content):
                    if add_binding(by_key, row, name):
                        bindings.append(row)
            elif path not in APP_FILES or name not in VIEWS:
                merge(files, path, content, name)

    for path in APP_FILES:
        merge(files, path, (HERE / path).read_text(), "combined app")
    files["keybindings.json"] = encode(bindings)
    description = "Sessions, hosts, activity and terminal settings."
    setup = dict(cmuxSetup=1, cmuxProfile=1, id="manaflow-ai/rex-whole", name="Rex",
                 version="1.0.0", description=description, settings=settings)
    profile = dict(cmuxProfile=1, name="rex-whole", description=description,
                   settings=settings, files=files)
    return {**files, "cmux-setup.json": encode(setup), "profile.json": encode(profile)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, default=HERE.parent)
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args()
    output = compose(options.sources)
    for name, content in output.items():
        path = HERE / name
        if options.check:
            if not path.is_file() or path.read_text() != content:
                raise SystemExit(f"out of date: {name}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    print(f"{len(PACKS)} packs, {len(output)-2} payload files")
