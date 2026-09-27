#!/usr/bin/env python3
"""Contracts for the .xcstrings git merge driver.

The driver must merge disjoint key additions (the common case) and must refuse
to resolve a key that both sides changed differently, so a real disagreement
still reaches the author as a normal git conflict.
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "scripts" / "merge-xcstrings.py"


def unit(value):
    return {"localizations": {"en": {"stringUnit": {"state": "translated", "value": value}}}}


def catalog(strings):
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


def render(document):
    return json.dumps(document, ensure_ascii=False, indent=2) + "\n"


def run(base, ours, theirs):
    with tempfile.TemporaryDirectory() as directory:
        paths = {}
        for name, document in (("O", base), ("A", ours), ("B", theirs)):
            path = Path(directory) / f"{name}.json"
            path.write_text(document if isinstance(document, str) else render(document), encoding="utf-8")
            paths[name] = path
        result = subprocess.run(
            [sys.executable, str(DRIVER), str(paths["O"]), str(paths["A"]), str(paths["B"]), "Localizable.xcstrings"],
            capture_output=True,
            text=True,
        )
        merged = paths["A"].read_text(encoding="utf-8")
        return result.returncode, merged, result.stderr


def test_disjoint_additions_merge():
    base = catalog({"a": unit("A")})
    ours = catalog({"a": unit("A"), "b": unit("B")})
    theirs = catalog({"a": unit("A"), "c": unit("C")})
    code, merged, _ = run(base, ours, theirs)
    assert code == 0, "disjoint additions must merge"
    strings = json.loads(merged)["strings"]
    assert set(strings) == {"a", "b", "c"}, strings.keys()


def test_same_key_same_value_is_not_a_conflict():
    base = catalog({"a": unit("old")})
    ours = catalog({"a": unit("new")})
    theirs = catalog({"a": unit("new")})
    code, merged, _ = run(base, ours, theirs)
    assert code == 0
    assert json.loads(merged)["strings"]["a"] == unit("new")


def test_same_key_diverging_falls_back_to_git():
    base = catalog({"a": unit("old")})
    ours = catalog({"a": unit("ours")})
    theirs = catalog({"a": unit("theirs")})
    code, merged, stderr = run(base, ours, theirs)
    assert code == 1, "a real disagreement must not be resolved silently"
    assert "strings.a" in stderr, stderr
    assert json.loads(merged)["strings"]["a"] == unit("ours"), "ours must be left untouched for git"


def test_one_sided_delete_applies():
    base = catalog({"a": unit("A"), "b": unit("B")})
    ours = catalog({"a": unit("A"), "b": unit("B")})
    theirs = catalog({"a": unit("A")})
    code, merged, _ = run(base, ours, theirs)
    assert code == 0
    assert set(json.loads(merged)["strings"]) == {"a"}


def test_delete_versus_modify_conflicts():
    base = catalog({"a": unit("A")})
    ours = catalog({"a": unit("changed")})
    theirs = catalog({})
    code, _, stderr = run(base, ours, theirs)
    assert code == 1, stderr


def test_non_canonical_input_merges_without_reformatting():
    """Branches routinely carry a different catalog style from main. The driver
    must merge them anyway, and must not rewrite either side's formatting."""
    base = catalog({"a": unit("A")})
    ours = json.dumps(catalog({"a": unit("A"), "b": unit("B")}), indent=4)
    theirs = catalog({"a": unit("A"), "c": unit("C")})
    code, merged, stderr = run(base, ours, theirs)
    assert code == 0, stderr
    assert set(json.loads(merged)["strings"]) == {"a", "b", "c"}
    assert '\n        "a"' in merged, "our four-space layout must survive"
    assert "canonically serialized" not in stderr


def test_xcode_spaced_style_is_preserved():
    """Xcode writes `"key" : value`. Merging must not collapse that spacing."""
    base = catalog({"a": unit("A")})
    ours = render(catalog({"a": unit("A"), "b": unit("B")})).replace('": ', '" : ')
    theirs = catalog({"a": unit("A"), "c": unit("C")})
    code, merged, stderr = run(base, ours, theirs)
    assert code == 0, stderr
    assert set(json.loads(merged)["strings"]) == {"a", "b", "c"}
    assert '"sourceLanguage" : "en"' in merged, "our spacing must survive"


def test_key_text_comes_verbatim_from_the_side_that_supplied_it():
    """A key theirs changed arrives with theirs' bytes; ours' keys keep ours'."""
    base = catalog({"a": unit("A"), "b": unit("B")})
    ours = render(catalog({"a": unit("A"), "b": unit("ours-b")}))
    theirs = json.dumps(catalog({"a": unit("theirs-a"), "b": unit("B")}), indent=4)
    code, merged, stderr = run(base, ours, theirs)
    assert code == 0, stderr
    strings = json.loads(merged)["strings"]
    assert strings["a"] == unit("theirs-a"), "theirs' change to a must win"
    assert strings["b"] == unit("ours-b"), "our change to b must win"


def test_bool_and_int_are_different_edits():
    # Python treats True == 1, so a type change must still count as an edit.
    base = catalog({"a": {"shouldTranslate": 1}})
    ours = catalog({"a": {"shouldTranslate": True}})
    theirs = catalog({"a": {"shouldTranslate": 0}})
    code, _, stderr = run(base, ours, theirs)
    assert code == 1, "both sides changed a; the driver must defer"
    assert "strings.a" in stderr, stderr
    code, merged, _ = run(base, ours, base)
    assert code == 0
    assert json.loads(merged)["strings"]["a"] == {"shouldTranslate": True}


def test_unparseable_input_falls_back():
    code, _, stderr = run(catalog({}), "{not json", catalog({}))
    assert code == 1
    assert "cannot parse" in stderr, stderr


def main():
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"ok {test.__name__}")
    print(f"\n{len(tests)} tests passed")


if __name__ == "__main__":
    main()
