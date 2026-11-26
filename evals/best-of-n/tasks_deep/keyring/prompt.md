Fix unset values in the layered settings resolver, `keyring.py`.

Bug report: "My user settings have `"terminal": {"font": {"family": "Iosevka", "size": 14}}`. A workspace file with
`"terminal": {"font": {"size": null}}` should leave me at 14 (null means the workspace does not set it), but
`get("terminal.font.size")` returns None. A null at the top level, like `"theme": null`, already works."

Contract. In every layer, an object member whose value is null is unset: it is as if the layer did not contain that
key at all, at any depth, wherever the object sits. A key that no layer sets is absent from the resolved settings
(`get` returns its default, `as_dict` does not contain it). An environment variable set to the empty string is
unset in the same way. Items of a keyed list that match by id merge exactly as two objects merge. Everything else
the module docstring and the docstrings of `Settings` describe stays as it is.
