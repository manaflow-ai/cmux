#!/usr/bin/env python3
"""Contracts for the .xcstrings git merge driver.

The driver must merge disjoint key additions (the common case) and must refuse
to resolve a key that both sides changed differently, so a real disagreement
reaches the author as a visible diff3 conflict.
"""

import json
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "scripts" / "merge-xcstrings.py"


def load_driver():
    spec = importlib.util.spec_from_file_location("merge_xcstrings", DRIVER)
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    return driver


def unit(value):
    return {"localizations": {"en": {"stringUnit": {"state": "translated", "value": value}}}}


def localized_unit(values):
    return {
        "localizations": {
            language: {"stringUnit": {"state": "translated", "value": value}}
            for language, value in values.items()
        }
    }


def catalog(strings):
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


def render(document):
    return json.dumps(document, ensure_ascii=False, indent=2) + "\n"


def run(base, ours, theirs, marker_size=None):
    with tempfile.TemporaryDirectory() as directory:
        paths = {}
        for name, document in (("O", base), ("A", ours), ("B", theirs)):
            path = Path(directory) / f"{name}.json"
            path.write_text(document if isinstance(document, str) else render(document), encoding="utf-8")
            paths[name] = path
        command = [
            sys.executable,
            str(DRIVER),
            str(paths["O"]),
            str(paths["A"]),
            str(paths["B"]),
            "Localizable.xcstrings",
        ]
        if marker_size is not None:
            command.append(str(marker_size))
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
        )
        merged = paths["A"].read_text(encoding="utf-8")
        return result.returncode, merged, result.stderr


def assert_conflict_preserves(merged, *values, marker_size=7):
    assert f"{'<' * marker_size} ours" in merged
    assert f"{'|' * marker_size} base" in merged
    assert f"{'=' * marker_size}\n" in merged
    assert f"{'>' * marker_size} theirs" in merged
    for value in values:
        assert value in merged, value


def conflict_regions(text):
    lines = text.splitlines()
    starts = [index for index, line in enumerate(lines) if line.startswith("<<<<<<<")]
    ends = [index for index, line in enumerate(lines) if line.startswith(">>>>>>>")]
    assert len(starts) == len(ends), (starts, ends)
    return ["\n".join(lines[start : end + 1]) for start, end in zip(starts, ends)]


def run_with_patched_merge(result):
    driver = load_driver()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        base_path = root / "O"
        ours_path = root / "A"
        theirs_path = root / "B"
        base_path.write_text(render(catalog({})), encoding="utf-8")
        ours_path.write_text(render(catalog({"a": unit("ours")})), encoding="utf-8")
        theirs_path.write_text(render(catalog({"a": unit("theirs")})), encoding="utf-8")
        original = driver.merge_catalog_text
        driver.merge_catalog_text = lambda *_: result
        try:
            code = driver.main(
                [
                    str(DRIVER),
                    str(base_path),
                    str(ours_path),
                    str(theirs_path),
                    "Localizable.xcstrings",
                ]
            )
        finally:
            driver.merge_catalog_text = original
        return code, ours_path.read_text(encoding="utf-8")


def test_disjoint_additions_merge():
    base = catalog({"a": unit("A")})
    ours = catalog({"a": unit("A"), "b": unit("B")})
    theirs = catalog({"a": unit("A"), "c": unit("C")})
    code, merged, _ = run(base, ours, theirs)
    assert code == 0, "disjoint additions must merge"
    document = json.loads(merged)
    assert list(document["strings"]) == ["a", "b", "c"]


def test_theirs_only_top_level_keys_are_appended():
    base = catalog({"a": unit("A")})
    ours = catalog({"a": unit("A")})
    theirs = catalog({"a": unit("A")})
    theirs["metadata"] = {"owner": "theirs"}
    code, merged, stderr = run(base, ours, theirs)
    assert code == 0, stderr
    document = json.loads(merged)
    assert list(document) == ["sourceLanguage", "strings", "version", "metadata"]
    assert document["metadata"] == {"owner": "theirs"}


def test_top_level_divergence_is_reported():
    base = catalog({"a": unit("A")})
    ours = catalog({"a": unit("A")})
    ours["version"] = "2.0"
    theirs = catalog({"a": unit("A")})
    theirs["version"] = "3.0"
    code, merged, stderr = run(base, ours, theirs)
    assert code == 1
    assert "catalog.version" in stderr, stderr
    assert_conflict_preserves(merged, '"version": "2.0"', '"version": "3.0"')


def test_same_key_same_value_is_not_a_conflict():
    base = catalog({"a": unit("old")})
    ours = catalog({"a": unit("new")})
    theirs = catalog({"a": unit("new")})
    code, merged, _ = run(base, ours, theirs)
    assert code == 0
    assert json.loads(merged)["strings"]["a"] == unit("new")


def test_same_key_diverging_materializes_a_conflict():
    base = catalog({"a": unit("old")})
    ours = catalog({"a": unit("ours")})
    theirs = catalog({"a": unit("theirs")})
    code, merged, stderr = run(base, ours, theirs)
    assert code == 1, "a real disagreement must not be resolved silently"
    assert "strings.a" in stderr, stderr
    assert_conflict_preserves(merged, '"value": "ours"', '"value": "theirs"')


def test_multiple_conflict_hunks_keep_untouched_keys_outside_conflicts():
    base = catalog({"k1": unit("base-1"), "k2": unit("untouched"), "k3": unit("base-3")})
    ours = catalog({"k1": unit("ours-1"), "k2": unit("untouched"), "k3": unit("ours-3")})
    theirs = catalog({"k1": unit("theirs-1"), "k2": unit("untouched"), "k3": unit("theirs-3")})
    code, merged, stderr = run(base, ours, theirs)
    assert code == 1, stderr
    lines = merged.splitlines()
    starts = [index for index, line in enumerate(lines) if line.startswith("<<<<<<<")]
    ends = [index for index, line in enumerate(lines) if line.startswith(">>>>>>>")]
    assert len(starts) == len(ends) == 2
    for start, end in zip(starts, ends):
        assert '"value": "untouched"' not in "\n".join(lines[start : end + 1])
    assert merged.count('"value": "untouched"') == 1


def test_each_reported_key_is_inside_a_conflict_region():
    base = catalog(
        {
            "shared": localized_unit(
                {
                    "en": "base-en",
                    "ru": "base-ru",
                    "fr": "base-fr",
                    "de": "base-de",
                    "es": "base-es",
                    "it": "base-it",
                    "ja": "base-ja",
                    "ko": "base-ko",
                    "pt": "base-pt",
                    "zh": "base-zh",
                }
            )
        }
    )
    ours = catalog(
        {
            "shared": localized_unit(
                {
                    "en": "ours-en",
                    "ru": "base-ru",
                    "fr": "base-fr",
                    "de": "base-de",
                    "es": "base-es",
                    "it": "base-it",
                    "ja": "base-ja",
                    "ko": "base-ko",
                    "pt": "base-pt",
                    "zh": "base-zh",
                }
            ),
            "ours-only": unit("ours"),
        }
    )
    theirs = catalog(
        {
            "shared": localized_unit(
                {
                    "en": "base-en",
                    "ru": "theirs-ru",
                    "fr": "base-fr",
                    "de": "base-de",
                    "es": "base-es",
                    "it": "base-it",
                    "ja": "base-ja",
                    "ko": "base-ko",
                    "pt": "base-pt",
                    "zh": "base-zh",
                }
            ),
            "theirs-only": unit("theirs"),
        }
    )
    code, merged, stderr = run(base, ours, theirs)
    assert code == 1, stderr
    report = stderr.split("materializing a conflict: ", 1)[1].strip()
    regions = conflict_regions(merged)
    for name in report.split(", "):
        key = name.split(".", 1)[1]
        assert any(f'"{key}"' in region for region in regions), (name, merged)


def test_git_marker_size_is_used_for_materialized_conflicts():
    base = catalog({"a": unit("old")})
    ours = catalog({"a": unit("ours")})
    theirs = catalog({"a": unit("theirs")})
    code, merged, _ = run(base, ours, theirs, marker_size=11)
    assert code == 1
    assert_conflict_preserves(merged, '"value": "ours"', '"value": "theirs"', marker_size=11)


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
    code, merged, stderr = run(base, ours, theirs)
    assert code == 1, stderr
    assert_conflict_preserves(merged, '"value": "changed"', '"strings": {}')


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
    code, merged, stderr = run(catalog({}), "{not json", catalog({"a": unit("theirs")}))
    assert code == 1
    assert "cannot parse" in stderr, stderr
    assert_conflict_preserves(merged, "{not json", '"value": "theirs"')


def test_existing_markers_use_a_longer_outer_conflict_marker():
    base = catalog({})
    ours = "<<<<<<< embedded\n{not json\n"
    theirs = catalog({"a": unit("theirs")})
    code, merged, stderr = run(base, ours, theirs)
    assert code == 1
    assert "cannot parse" in stderr, stderr
    assert merged.startswith("<<<<<<<< ours\n")
    assert "<<<<<<< embedded\n" in merged
    marker_runs = [
        len(line) - len(line.lstrip("<"))
        for line in merged.splitlines()
        if line.startswith("<")
    ]
    assert max(marker_runs) > 7


def test_non_utf8_input_materializes_a_byte_conflict():
    driver = load_driver()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        base_path = root / "O"
        ours_path = root / "A"
        theirs_path = root / "B"
        base_path.write_bytes(render(catalog({})).encode())
        ours_path.write_bytes(b"{\xff\n")
        theirs_path.write_bytes(render(catalog({"a": unit("theirs")})).encode())
        code = driver.main(
            [
                str(DRIVER),
                str(base_path),
                str(ours_path),
                str(theirs_path),
                "Localizable.xcstrings",
            ]
        )
        merged = ours_path.read_bytes()
    assert code == 1
    assert merged.startswith(b"<<<<<<< ours\n")
    assert b"\xff" in merged
    assert b'"value": "ours"' in merged
    assert b'"value": "old"' in merged
    assert b'"value": "theirs"' in merged


def test_explicit_text_conflict_contains_all_sections():
    driver = load_driver()
    merged = driver.explicit_conflict("BASE section", "OURS section", "THEIRS section", 9)
    assert merged.startswith("<<<<<<<<<< ours\n")
    assert "OURS section" in merged
    assert "BASE section" in merged
    assert "THEIRS section" in merged


def test_invalid_catalog_shape_materializes_a_conflict():
    base = catalog({})
    ours = catalog({"a": unit("ours")})
    theirs = render({"sourceLanguage": "en", "strings": [], "version": "1.0"})
    code, merged, stderr = run(base, ours, theirs)
    assert code == 1
    assert "cannot merge" in stderr, stderr
    assert_conflict_preserves(merged, '"value": "ours"', '"strings": []')


def test_invalid_assembled_json_materializes_a_conflict():
    code, merged = run_with_patched_merge(("{not json", [], ["a"]))
    assert code == 1
    assert_conflict_preserves(merged, '"value": "ours"', '"value": "theirs"')


def test_unexpected_merged_key_set_materializes_a_conflict():
    merged = render(catalog({"a": unit("merged")}))
    code, output = run_with_patched_merge((merged, [], ["not-a"]))
    assert code == 1
    assert_conflict_preserves(output, '"value": "ours"', '"value": "theirs"')


def test_every_refusal_preserves_theirs_in_the_output():
    cases = [
        (
            catalog({"a": unit("old")}),
            catalog({"a": unit("ours")}),
            catalog({"a": unit("theirs")}),
            '"value": "theirs"',
        ),
        (catalog({}), "{not json", catalog({"a": unit("theirs")}), '"value": "theirs"'),
        (
            catalog({}),
            catalog({"a": unit("ours")}),
            render({"sourceLanguage": "en", "strings": [], "version": "1.0"}),
            '"strings": []',
        ),
    ]
    for base, ours, theirs, expected in cases:
        code, merged, _ = run(base, ours, theirs)
        assert code == 1
        assert expected in merged
        assert "<<<<<<<" in merged

    for result in (("{not json", [], ["a"]), (render(catalog({})), [], ["not-a"])):
        code, merged = run_with_patched_merge(result)
        assert code == 1
        assert '"value": "theirs"' in merged
        assert "<<<<<<<" in merged


def test_utf8_bom_falls_back_to_a_byte_conflict():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        base_path, ours_path, theirs_path = (root / "O", root / "A", root / "B")
        base_path.write_bytes(render(catalog({})).encode())
        ours_path.write_bytes(b"\xef\xbb\xbf" + render(catalog({"a": unit("ours")})).encode())
        theirs_path.write_bytes(render(catalog({"a": unit("theirs")})).encode())
        result = subprocess.run(
            [
                sys.executable,
                str(DRIVER),
                str(base_path),
                str(ours_path),
                str(theirs_path),
                "Localizable.xcstrings",
            ],
            capture_output=True,
        )
        merged = ours_path.read_bytes()
    assert result.returncode == 1
    assert b"\xef\xbb\xbf" in merged
    assert b'"value": "ours"' in merged
    assert b'"value": "theirs"' in merged


def test_a_refusal_that_cannot_render_blanks_the_result():
    """The one fail-open left: exit 1 with %A byte-identical to ours.

    git marks the path unmerged either way, but a file with no markers reads as
    "no disagreement here" and gets staged, which is the bug this driver exists
    to kill. If the conflict cannot be rendered at all, %A must still stop
    being ours.
    """
    driver = load_driver()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        base_path, ours_path, theirs_path = (root / "O", root / "A", root / "B")
        base_path.write_text(render(catalog({"a": unit("old")})), encoding="utf-8")
        ours_path.write_text(render(catalog({"a": unit("ours")})), encoding="utf-8")
        theirs_path.write_text(render(catalog({"a": unit("theirs")})), encoding="utf-8")
        before = ours_path.read_text(encoding="utf-8")

        def explode(*_args, **_kwargs):
            raise RuntimeError("no git here")

        original = driver.conflict_text
        driver.conflict_text = explode
        try:
            code = driver.main(
                [str(DRIVER), str(base_path), str(ours_path), str(theirs_path), "Localizable.xcstrings"]
            )
        finally:
            driver.conflict_text = original
        after = ours_path.read_text(encoding="utf-8")

    assert code == 1
    assert after != before, "a refusal left ours in place with no markers"
    assert after == ""


def test_an_unwritable_result_says_it_is_still_ours():
    """When even a blank write fails there is nothing left but to be loud.

    A driver cannot make git abort, so the only honest outcome is a message
    naming the file and saying it is not a merge of theirs.
    """
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        base_path, ours_path, theirs_path = (root / "O", root / "A", root / "B")
        base_path.write_text(render(catalog({"a": unit("old")})), encoding="utf-8")
        ours_path.write_text(render(catalog({"a": unit("ours")})), encoding="utf-8")
        theirs_path.write_text(render(catalog({"a": unit("theirs")})), encoding="utf-8")
        ours_path.chmod(0o444)
        try:
            ours_path.write_text("probe", encoding="utf-8")
        except OSError:
            pass
        else:
            ours_path.chmod(0o644)
            ours_path.write_text(render(catalog({"a": unit("ours")})), encoding="utf-8")
            print("ok (skipped: this user can write a read-only file)")
            return
        result = subprocess.run(
            [sys.executable, str(DRIVER), str(base_path), str(ours_path), str(theirs_path), "Localizable.xcstrings"],
            capture_output=True,
            text=True,
        )
        ours_path.chmod(0o644)

    assert result.returncode == 1
    assert "must not be committed" in result.stderr, result.stderr


def main():
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"ok {test.__name__}")
    print(f"\n{len(tests)} tests passed")


if __name__ == "__main__":
    main()
