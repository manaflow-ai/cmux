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


def test_non_canonical_input_falls_back():
    base = catalog({"a": unit("A")})
    ours = json.dumps(catalog({"a": unit("A"), "b": unit("B")}), indent=4)  # wrong indent
    theirs = catalog({"a": unit("A"), "c": unit("C")})
    code, _, stderr = run(base, ours, theirs)
    assert code == 1, "must not rewrite a catalog it cannot reproduce byte-for-byte"
    assert "canonically serialized" in stderr, stderr


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
