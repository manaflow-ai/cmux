Fix shortcut handling in `keychord.py`, which parses the shortcuts users write in cmux.json and shows them in
menus and help.

Bug report: "My cmux.json binds `ctrl+shift+p` to the command palette. The keymap reports Ctrl+Shift+P as
unbound: `keymap.lookup('Ctrl+Shift+P')` is None, though `keymap.lookup('ctrl+shift+p')` finds it."

Contract: two spellings that the module docstring's rules read as the same chords are the same shortcut,
everywhere: they parse to equal values, format to the same text, find the same binding, replace or remove each
other's binding, and show the same menu label. Every text the module writes (`format`, `format_sequence`,
`canonical`, `Keymap.bindings` keys, and the order of modifiers in `menu_label`) is canonical as the module
docstring defines it. Input the module rejects today with `ValueError` because of a spelling the docstring says is
accepted must be accepted; anything else it rejects stays rejected.
