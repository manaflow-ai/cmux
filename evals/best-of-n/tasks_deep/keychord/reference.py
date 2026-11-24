"""Keyboard shortcuts for cmux keymaps: parse what users write in cmux.json, show them in menus and help.

A chord is modifiers plus one key, written with "+": `Ctrl+Shift+P`, `cmd+k`, `Alt++` (the key is "+").
A sequence is chords separated by spaces: `Ctrl+K Ctrl+S`.

Canonical text (what `format` writes): modifiers in the order Ctrl, Alt, Shift, Cmd, then the key; a letter key in
upper case, a digit or symbol as itself, a named key in its spelling from NAMED_KEYS. Modifier names, key names
and letters are case-insensitive on input, and the aliases below are accepted.
"""
from dataclasses import dataclass

MOD_ORDER = ("Ctrl", "Alt", "Shift", "Cmd")
MOD_ALIASES = {
    "ctrl": "Ctrl", "control": "Ctrl", "ctl": "Ctrl",
    "alt": "Alt", "option": "Alt", "opt": "Alt", "meta": "Alt",
    "shift": "Shift",
    "cmd": "Cmd", "command": "Cmd", "super": "Cmd", "win": "Cmd",
}
NAMED_KEYS = ("Enter", "Escape", "Tab", "Space", "Backspace", "Delete", "Insert", "Up", "Down", "Left", "Right",
              "Home", "End", "PageUp", "PageDown") + tuple(f"F{n}" for n in range(1, 13))
KEY_ALIASES = {
    "esc": "Escape", "return": "Enter", "del": "Delete", "ins": "Insert", "bs": "Backspace",
    "pgup": "PageUp", "pgdn": "PageDown", "pagedn": "PageDown",
    "arrowup": "Up", "arrowdown": "Down", "arrowleft": "Left", "arrowright": "Right",
    "plus": "+", "minus": "-",
}
_NAMED = {name.lower(): name for name in NAMED_KEYS}


@dataclass(frozen=True)
class Chord:
    mods: frozenset
    key: str


def normalize_key(key: str) -> str:
    """The canonical spelling of one key; ValueError for a key we do not know."""
    if len(key) == 1:
        if key.isalpha():
            return key.upper()
        if key.isprintable() and not key.isspace():
            return key
        raise ValueError(f"unknown key {key!r}")
    low = key.lower()
    if low in KEY_ALIASES:
        return KEY_ALIASES[low]
    if low in _NAMED:
        return _NAMED[low]
    raise ValueError(f"unknown key {key!r}")


def parse(text: str) -> Chord:
    """One chord. ValueError for an empty chord, an unknown modifier or key, or a repeated modifier."""
    text = text.strip()
    if not text:
        raise ValueError("empty chord")
    if text.endswith("++") or text == "+":
        head, key = text[:-2] if text != "+" else "", "+"
    else:
        head, _, key = text.rpartition("+")
    mods = set()
    for part in head.split("+") if head else []:
        mod = MOD_ALIASES.get(part.strip().lower())
        if mod is None:
            raise ValueError(f"unknown modifier {part!r} in {text!r}")
        if mod in mods:
            raise ValueError(f"repeated modifier {mod} in {text!r}")
        mods.add(mod)
    if not key.strip():
        raise ValueError(f"no key in {text!r}")
    return Chord(frozenset(mods), normalize_key(key.strip()))


def format(chord: Chord) -> str:
    """The chord's canonical text."""
    return "+".join([m for m in MOD_ORDER if m in chord.mods] + [chord.key])


def parse_sequence(text: str) -> tuple:
    """A space-separated sequence of chords."""
    parts = text.split()
    if not parts:
        raise ValueError("empty sequence")
    return tuple(parse(p) for p in parts)


def format_sequence(seq) -> str:
    return " ".join(format(c) for c in seq)


def canonical(text: str) -> str:
    """`text` (a chord or a sequence) in canonical form."""
    return format_sequence(parse_sequence(text))


def menu_label(text: str, mac: bool = False) -> str:
    """How a menu shows a shortcut: canonical text, or on macOS the symbols ⌃⌥⇧⌘ before the key, in that order."""
    if not mac:
        return canonical(text)
    symbols = {"Ctrl": "⌃", "Alt": "⌥", "Shift": "⇧", "Cmd": "⌘"}
    out = []
    for chord in parse_sequence(text):
        out.append("".join(symbols[m] for m in MOD_ORDER if m in chord.mods) + chord.key)
    return " ".join(out)


class Keymap:
    """Bindings from shortcut text (as written in cmux.json) to action names."""

    def __init__(self):
        self._bindings: dict = {}

    def bind(self, shortcut: str, action: str) -> None:
        """Bind `shortcut`; binding a shortcut again (in any spelling) replaces its action."""
        self._bindings[parse_sequence(shortcut)] = action

    def unbind(self, shortcut: str) -> None:
        self._bindings.pop(parse_sequence(shortcut), None)

    def lookup(self, shortcut: str):
        """The action bound to `shortcut` (in any spelling), or None."""
        return self._bindings.get(parse_sequence(shortcut))

    def bindings(self) -> dict:
        """{canonical shortcut text: action}."""
        return {format_sequence(seq): action for seq, action in self._bindings.items()}
