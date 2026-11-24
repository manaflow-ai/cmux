from pytest_shim import raises
from keychord import Chord, Keymap, canonical, format, format_sequence, menu_label, parse, parse_sequence


def test_reported_lookup_any_spelling():
    km = Keymap()
    km.bind("ctrl+shift+p", "palette")
    assert km.lookup("Ctrl+Shift+P") == "palette"
    assert km.lookup("shift+CONTROL+p") == "palette"
    assert km.lookup("ctrl+shift+p") == "palette"
    assert km.lookup("Ctrl+P") is None


def test_rebind_and_unbind_across_spellings():
    km = Keymap()
    km.bind("cmd+k cmd+s", "save-all")
    km.bind("Command+K Super+S", "settings")
    assert km.bindings() == {"Cmd+K Cmd+S": "settings"}
    km.bind("opt+esc", "cancel")
    km.unbind("Alt+Escape")
    assert km.lookup("alt+ESC") is None
    assert km.bindings() == {"Cmd+K Cmd+S": "settings"}


def test_format_uses_canonical_modifier_order():
    assert format(parse("shift+ctrl+a")) == "Ctrl+Shift+A"
    assert format(parse("cmd+alt+shift+ctrl+x")) == "Ctrl+Alt+Shift+Cmd+X"
    assert format(Chord(frozenset({"Shift", "Cmd", "Alt"}), "Z")) == "Alt+Shift+Cmd+Z"
    assert canonical("cmd+k   shift+ctrl+s") == "Cmd+K Ctrl+Shift+S"
    km = Keymap()
    km.bind("Shift+Ctrl+T", "reopen")
    assert km.bindings() == {"Ctrl+Shift+T": "reopen"}


def test_named_keys_are_case_insensitive():
    assert parse("ctrl+ESC") == parse("Ctrl+Escape") == parse("control+escape")
    assert format(parse("alt+pageup")) == "Alt+PageUp"
    assert format(parse("Alt+PGDN")) == "Alt+PageDown"
    assert format(parse("f5")) == "F5"
    assert format(parse("Shift+TAB")) == "Shift+Tab"
    assert format(parse("ctrl+Plus")) == "Ctrl++"
    assert parse("Ctrl+ArrowUp") == parse("ctrl+up")


def test_menu_labels():
    assert menu_label("shift+cmd+p", mac=True) == "⇧⌘P"
    assert menu_label("cmd+ctrl+alt+shift+f12", mac=True) == "⌃⌥⇧⌘F12"
    assert menu_label("shift+ctrl+esc") == "Ctrl+Shift+Escape"
    assert menu_label("ctrl+k ctrl+ESC", mac=True) == "⌃K ⌃Escape"


def test_plus_key_and_symbols_regressions():
    assert parse("Alt++") == Chord(frozenset({"Alt"}), "+")
    assert parse("+") == Chord(frozenset(), "+")
    assert format(parse("ctrl+-")) == "Ctrl+-"
    assert format(parse("ctrl+/")) == "Ctrl+/"
    assert format(parse("Ctrl+1")) == "Ctrl+1"
    assert format_sequence(parse_sequence("ctrl+k ctrl++")) == "Ctrl+K Ctrl++"


def test_rejections_regressions():
    for bad in ("", "Ctrl+", "Hyper+K", "Ctrl+Ctrl+K", "ctrl+control+k", "Ctrl+Foo", "Ctrl+F13"):
        raises(ValueError, parse, bad)
    raises(ValueError, parse_sequence, "   ")
    raises(ValueError, Keymap().bind, "Ctrl+Nope", "x")


def test_round_trip():
    for text in ("ctrl+a", "Alt+Shift+Enter", "cmd+opt+Backspace", "win+del", "Meta+Return", "shift+space"):
        c = parse(text)
        assert parse(format(c)) == c
        assert format(parse(format(c))) == format(c)
