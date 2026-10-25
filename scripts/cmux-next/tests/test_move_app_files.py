#!/usr/bin/env python3
"""move-app-files.py and follow-renames.py (p11-codebase task 000b): one App group moves as a pure move.

A fixture repository holds a small CmuxNextApp with a FixtureSearch folder, its tests, two string tables and
every kind of path-keyed file (sorted JSON, sorted lines, the godfile's Module/Type rows, OWNERS.md, a
regex in autofix-areas.sh, globs in a workflow paths filter, a doc). The tests move FixtureSearch and check
the acceptance: only paths change, no old path is left, every moved key is in the destination with all
locales, and follow-renames --check fails on a stale path.

  python3 -m pytest scripts/cmux-next/tests/test_move_app_files.py
  python3 -m unittest discover -s scripts/cmux-next/tests -p test_move_app_files.py
"""
from __future__ import annotations

import importlib.util
import io
import json
import contextlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, HERE.parent / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


mover = load("move_app_files", "move-app-files.py")
follow = mover.follow

PKG = "Packages/macOS/CmuxNext/"
APP = PKG + "Sources/CmuxNextApp/"
LOCALES = ("en", "de", "fr", "ar", "es", "zh-Hant", "zh-Hans", "ko", "ja")


def entry(text: str) -> dict:
    return {"extractionState": "manual", "localizations": {
        loc: {"stringUnit": {"state": "translated", "value": text if loc == "en" else f"{loc}: {text}"}} for loc in LOCALES}}


def table(keys: dict[str, str]) -> str:
    data = {"sourceLanguage": "en", "strings": {k: entry(v) for k, v in keys.items()}, "version": "1.0"}
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


MANIFEST = '''// swift-tools-version: 6.2
let package = Package(
    targets: [
        .target(
            name: "CmuxNextApp",
            resources: [
                .process("Resources"),
            ]
        ),
        .target(
            name: "CmuxNextPalette",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "CmuxNextPaletteTests",
            dependencies: ["CmuxNextPalette"]
        ),
        .target(
            name: "CmuxNextBare",
            dependencies: []
        ),
    ]
)
'''

FILES = {
    PKG + "Package.swift": MANIFEST,
    APP + "FixtureSearch/FixtureSearchControl.swift": (
        "import Foundation\n\n"
        "/// Lives at Packages/macOS/CmuxNext/Sources/CmuxNextApp/FixtureSearch/FixtureSearchControl.swift.\n"
        "final class FixtureSearchControl {\n"
        "    var title: String { String(localized: \"fixtureSearch.title\", table: \"FixtureSearch\", bundle: .module) }\n"
        "    var shared: String { String(localized: \"Shared words\", bundle: .module) }\n"
        "    func window(_ n: Int) -> String { String(localized: \"Window \\(n)\", bundle: .module) }\n"
        "    func refusal(_ why: String) -> String {\n"
        "        String(localized: String.LocalizationValue(\"fixtureSearch.refusal.\\(why)\"), table: \"FixtureSearch\", bundle: .module)\n"
        "    }\n"
        "}\n"),
    APP + "FixtureSearch/FixtureSearchHandlers.swift": "enum FixtureSearchHandlers {\n    static func bind() {}\n}\n",
    APP + "FixtureSearchy.swift": "// a neighbor whose name starts like the folder's; it stays\nstruct FixtureSearchy {}\n",
    APP + "Other.swift": "struct Other {\n    var a = String(localized: \"Shared words\", bundle: .module)\n"
                         "    var b = String(localized: \"Other only\", bundle: .module)\n}\n",
    APP + "Resources/FixtureSearch.xcstrings": table({"fixtureSearch.title": "Search Tabs", "fixtureSearch.refusal.gone": "Gone",
                                                  "fixtureSearch.refusal.focus": "Needs focus"}),
    APP + "Resources/Localizable.xcstrings": table({"Dead key": "Nobody", "Other only": "Other", "Shared words": "Shared",
                                                    "Window %lld": "Window %lld"}),
    PKG + "Sources/CmuxNextPalette/Palette.swift": "struct Palette {}\n",
    PKG + "Sources/CmuxNextBare/A.swift": "struct A {}\n",
    PKG + "Sources/CmuxNextPalette/Resources/Localizable.xcstrings": table({"Palette": "Palette"}),
    PKG + "Tests/CmuxNextAppTests/FixtureSearchClosedOnceTests.swift":
        "import XCTest\n@testable import CmuxNextApp\n\nfinal class FixtureSearchClosedOnceTests: XCTestCase {}\n",
    PKG + "Tests/CmuxNextAppTests/OtherTests.swift": "import XCTest\n@testable import CmuxNextApp\n",
    PKG + "Tests/CmuxNextAppTests/FixtureSearchyTests.swift": "import XCTest\n@testable import CmuxNextApp\n",
    "scripts/cmux-next/main-actor-work-baseline.json": json.dumps({
        APP + "Other.swift": {"sleep": 1},
        APP + "FixtureSearch/FixtureSearchControl.swift": {"sync": 2},
        PKG + "Sources/CmuxNextPalette/Palette.swift": {"sync": 1},
    }, indent=1, sort_keys=True) + "\n",
    "scripts/cmux-next/no-swiftui-allowlist.txt": "\n".join(sorted([
        APP + "Other.swift", APP + "FixtureSearch/FixtureSearchHandlers.swift", PKG + "Sources/CmuxNextBare/A.swift"])) + "\n",
    "scripts/cmux-next/godfile-baseline.tsv": "# header\nswift-type\tCmuxNextApp/FixtureSearchControl\t1200\t0\n"
                                              "swift-type\tCmuxNextApp/Other\t1100\t0\n",
    "plans/cmux-next/OWNERS.md": "| Area | Paths | Owner |\n|---|---|---|\n"
                                 f"| Search Tabs | `{APP}FixtureSearch/` | PL-palette |\n| Other | `{APP}Other.swift` | PL-other |\n",
    "scripts/cmux-next/autofix-areas.sh":
        f"area tabs '{APP}FixtureSearch/FixtureSearchControl\\.swift|{APP}Other\\.swift'\n",
    "scripts/ci/cmux_next_route.py": 'PACKAGE = "Packages/macOS/CmuxNext/"\n'
                                     'PATHS = (PACKAGE + "Sources/CmuxNextApp/FixtureSearch/FixtureSearchHandlers.swift",)\n',
    ".github/workflows/cmux-next-motion-golden.yml":
        f"paths:\n  - {APP}FixtureSearch/*.swift\n  - {APP}**/FixtureSearch*.swift\n  - {APP}Other.swift\n",
    "plans/cmux-next/notes.md": "FixtureSearch lives in CmuxNextApp/FixtureSearch/ (see Sources/CmuxNextApp/FixtureSearch/FixtureSearchHandlers.swift).\n"
                                "Not CmuxNextApp/FixtureSearchy.swift.\n",
    # The real map's shape: one line per target, blank lines between the layer blocks.
    "plans/cmux-next/architecture-layers.json": '{\n  "_doc": "x",\n  "targets": {\n'
                                                '    "CmuxNextPalette": {"layer": "ui"},\n\n'
                                                '    "CmuxNextBare": {"layer": "ui"},\n\n'
                                                '    "CmuxNextApp": {"layer": "app"}\n  },\n  "exceptions": []\n}\n',
    "scripts/localization-debt-baseline.json": json.dumps({"catalogs": {}}, indent=2, sort_keys=True) + "\n",
    "scripts/ci/generated-files.json": json.dumps({"conventions": ["**/*.generated.*"], "generators": []}) + "\n",
    "CHANGELOG.md": f"- moved {APP}FixtureSearch/FixtureSearchControl.swift\n",
    "webviews/scripts/pages/gen-strings.mjs":
        "const sources = 'Packages/macOS/CmuxNext/Sources';\n"
        "const pages = [{ file: `${sources}/CmuxNextApp/Resources/FixtureSearch.xcstrings` }];\n",
    "scripts/cmux-next/crash-allowlist.json": json.dumps({"banned": ["swift.unowned"], "allow": [
        {"path": APP + "FixtureSearch/FixtureSearchControl.swift", "class": "swift.unowned", "count": 1, "reason": "r",
         "reviewer": "crash-lead"}]}, indent=1) + "\n",
}


class Fixture:
    def __init__(self, files: dict[str, str] = FILES):
        self.tmp = tempfile.TemporaryDirectory(prefix="move-app-files-")
        self.root = Path(self.tmp.name)
        for path, text in files.items():
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_text(text, encoding="utf-8")
        self.git("init", "-q", "-b", "main")
        self.git("add", "-A")
        self.commit("fixture")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.root), "-c", "user.email=t@t", "-c", "user.name=t", *args],
                              check=True, capture_output=True, text=True).stdout

    def commit(self, message: str) -> str:
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD").strip()

    def read(self, path: str) -> str:
        return (self.root / path).read_text(encoding="utf-8")

    def move(self, *extra: str) -> tuple[int, dict]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = mover.main(["--repo", str(self.root), "--group", "FixtureSearch", "--destination", "CmuxNextPalette",
                               "--json", *extra])
        return code, json.loads(out.getvalue())

    def close(self) -> None:
        self.tmp.cleanup()


class MoveFixtureSearch(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fx = Fixture()
        cls.before = {p: cls.fx.read(p) for p in FILES}
        cls.code, cls.out = cls.fx.move()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.fx.close()

    def test_exit_clean_and_no_problems(self) -> None:
        self.assertEqual(self.code, 0, self.out["problems"])
        self.assertEqual(self.out["problems"], [])

    def test_code_and_tests_move_as_renames(self) -> None:
        status = self.fx.git("diff", "--cached", "-M", "--name-status").splitlines()
        self.assertIn(f"R100\t{APP}FixtureSearch/FixtureSearchHandlers.swift\t{PKG}Sources/CmuxNextPalette/FixtureSearch/FixtureSearchHandlers.swift",
                      status)
        moved_test = PKG + "Tests/CmuxNextPaletteTests/FixtureSearchClosedOnceTests.swift"
        self.assertIn("@testable import CmuxNextPalette\n", self.fx.read(moved_test))
        self.assertTrue((self.fx.root / PKG / "Tests/CmuxNextAppTests/OtherTests.swift").is_file())
        self.assertTrue((self.fx.root / APP / "FixtureSearchy.swift").is_file(), "a name-prefix neighbor stays")
        self.assertTrue((self.fx.root / PKG / "Tests/CmuxNextAppTests/FixtureSearchyTests.swift").is_file(),
                        "a test goes with the longest App stem it starts with: FixtureSearchy, which stays")

    def test_only_paths_change(self) -> None:
        """Undoing the path spellings in every edited text file gives back the original bytes."""
        undo = [(PKG + "Sources/CmuxNextPalette/FixtureSearch/", APP + "FixtureSearch/"),
                ("Sources/CmuxNextPalette/FixtureSearch/", "Sources/CmuxNextApp/FixtureSearch/"),
                ("CmuxNextPalette/FixtureSearch/", "CmuxNextApp/FixtureSearch/")]
        for path in ("plans/cmux-next/OWNERS.md", "scripts/cmux-next/autofix-areas.sh", "scripts/ci/cmux_next_route.py",
                     "plans/cmux-next/notes.md", ".github/workflows/cmux-next-motion-golden.yml"):
            text = self.fx.read(path)
            self.assertNotEqual(text, self.before[path], path)
            for new, old in undo:
                text = text.replace(new, old)
            self.assertEqual(text, self.before[path], path)
        moved = PKG + "Sources/CmuxNextPalette/FixtureSearch/FixtureSearchControl.swift"
        text = self.fx.read(moved).replace(PKG + "Sources/CmuxNextPalette/FixtureSearch/", APP + "FixtureSearch/")
        self.assertEqual(text, self.before[APP + "FixtureSearch/FixtureSearchControl.swift"])

    def test_no_old_path_left(self) -> None:
        for old in (APP + "FixtureSearch/", "Sources/CmuxNextApp/FixtureSearch/", "CmuxNextApp/FixtureSearch/",
                    "Sources/CmuxNextApp/Resources/FixtureSearch.xcstrings", "CmuxNextAppTests/FixtureSearchClosedOnceTests"):
            hits = subprocess.run(["git", "-C", str(self.fx.root), "grep", "-n", "-F", old],
                                  capture_output=True, text=True).stdout.splitlines()
            # CHANGELOG.md is release tooling's: never hand-edited, named in the report instead.
            self.assertEqual([h for h in hits if not h.startswith("CHANGELOG.md:")], [], old)
        self.assertIn("CHANGELOG.md", self.out["follow"]["generated"])
        self.assertIn(f"{APP}FixtureSearch/FixtureSearchControl.swift", self.fx.read("CHANGELOG.md"))

    def test_sorted_baselines_stay_sorted(self) -> None:
        data = self.fx.read("scripts/cmux-next/main-actor-work-baseline.json")
        keys = list(json.loads(data))
        self.assertEqual(keys, sorted(keys))
        self.assertIn(PKG + "Sources/CmuxNextPalette/FixtureSearch/FixtureSearchControl.swift", keys)
        self.assertEqual(data, json.dumps(json.loads(data), indent=1, sort_keys=True) + "\n")
        lines = self.fx.read("scripts/cmux-next/no-swiftui-allowlist.txt").splitlines()
        self.assertEqual(lines, sorted(lines))
        self.assertIn(PKG + "Sources/CmuxNextPalette/FixtureSearch/FixtureSearchHandlers.swift", lines)

    def test_godfile_type_rows_follow_their_declaration(self) -> None:
        text = self.fx.read("scripts/cmux-next/godfile-baseline.tsv")
        self.assertIn("swift-type\tCmuxNextPalette/FixtureSearchControl\t1200\t0\n", text)
        self.assertIn("swift-type\tCmuxNextApp/Other\t1100\t0\n", text)

    def test_glob_that_would_split_is_reported_not_guessed(self) -> None:
        yml = self.fx.read(".github/workflows/cmux-next-motion-golden.yml")
        self.assertIn(f"{PKG}Sources/CmuxNextPalette/FixtureSearch/*.swift", yml)
        self.assertIn(f"{APP}**/FixtureSearch*.swift", yml)  # also matches FixtureSearchy.swift, which stays
        self.assertTrue(any("**/FixtureSearch*.swift" in g for g in self.out["follow"]["split_globs"]))

    def test_table_only_the_group_uses_moves_whole(self) -> None:
        dest = PKG + "Sources/CmuxNextPalette/Resources/FixtureSearch.xcstrings"
        self.assertEqual(self.fx.read(dest), self.before[APP + "Resources/FixtureSearch.xcstrings"])
        self.assertFalse((self.fx.root / APP / "Resources/FixtureSearch.xcstrings").exists())

    def test_shared_table_splits_by_key_with_every_locale(self) -> None:
        dest = json.loads(self.fx.read(PKG + "Sources/CmuxNextPalette/Resources/Localizable.xcstrings"))["strings"]
        app = json.loads(self.fx.read(APP + "Resources/Localizable.xcstrings"))["strings"]
        source = json.loads(self.before[APP + "Resources/Localizable.xcstrings"])["strings"]
        for key in ("Shared words", "Window %lld"):  # the interpolation meets its format specifier
            self.assertEqual(dest[key], source[key], key)
            self.assertEqual(set(dest[key]["localizations"]), set(LOCALES))
        self.assertIn("Palette", dest)
        self.assertNotIn("Window %lld", app, "a key only the group uses leaves the App table")
        self.assertIn("Shared words", app, "a key both use is copied")
        self.assertIn("Other only", app)
        self.assertNotIn("Other only", dest)
        self.assertNotIn("Dead key", app, "no App table keeps an unreferenced key (p11-codebase.md 000b)")
        self.assertNotIn("Dead key", dest)
        split = next(m for m in self.out["tables"] if m["mode"] == "split")
        self.assertEqual(split["deleted_unreferenced"], ["Dead key"])

    def test_split_app_table_diff_is_deletions_only(self) -> None:
        diff = self.fx.git("diff", "--cached", "-U0", "--", APP + "Resources/Localizable.xcstrings")
        added = [ln for ln in diff.splitlines() if ln.startswith("+") and not ln.startswith("+++")]
        self.assertEqual(added, [])
        json.loads(self.fx.read(APP + "Resources/Localizable.xcstrings"))

    def test_debt_baseline_recounted_for_touched_tables(self) -> None:
        catalogs = json.loads(self.fx.read("scripts/localization-debt-baseline.json"))["catalogs"]
        self.assertFalse(any("CmuxNextApp/Resources/FixtureSearch" in name for name in catalogs))


class Preconditions(unittest.TestCase):
    def test_dry_run_changes_nothing(self) -> None:
        fx = Fixture()
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = mover.main(["--repo", str(fx.root), "--group", "FixtureSearch", "--destination", "CmuxNextPalette",
                                   "--dry-run"])
            self.assertEqual(code, 0)
            plan = json.loads(out.getvalue())
            self.assertIn(APP + "FixtureSearch/FixtureSearchControl.swift", plan["renames"])
            self.assertEqual(fx.git("status", "--porcelain"), "")
        finally:
            fx.close()

    def test_swift_basename_clash_in_destination_refuses(self) -> None:
        files = dict(FILES)
        files[PKG + "Sources/CmuxNextPalette/Other/FixtureSearchHandlers.swift"] = "struct X {}\n"
        fx = Fixture(files)
        try:
            err = io.StringIO()
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                code = mover.main(["--repo", str(fx.root), "--group", "FixtureSearch", "--destination", "CmuxNextPalette"])
            self.assertEqual(code, 2)
            self.assertIn("FixtureSearchHandlers.swift", err.getvalue())
            self.assertEqual(fx.git("status", "--porcelain"), "")
        finally:
            fx.close()

    def test_new_destination_gets_its_layer_and_manifest_requests(self) -> None:
        fx = Fixture()
        try:
            code, out = fx.move("--destination", "CmuxNextFixtureSearch", "--layer", "domain")
            self.assertEqual(code, 0, out["problems"])
            text = fx.read("plans/cmux-next/architecture-layers.json")
            layers = json.loads(text)["targets"]
            self.assertEqual(layers["CmuxNextFixtureSearch"], {"layer": "domain"})
            before = FILES["plans/cmux-next/architecture-layers.json"].splitlines()
            after = text.splitlines()
            self.assertEqual([ln for ln in after if ln not in before], ['    "CmuxNextApp": {"layer": "app"},',
                                                                         '    "CmuxNextFixtureSearch": {"layer": "domain"}'])
            self.assertEqual(after.count(""), before.count(""), "the blank lines between layer blocks stay")
            self.assertTrue(any("declare .target CmuxNextFixtureSearch" in m for m in out["manifest_requests"]))
            self.assertTrue(any("CmuxNextFixtureSearchTests" in m for m in out["manifest_requests"]))
            self.assertEqual(fx.read(PKG + "Package.swift"), MANIFEST, "Package.swift is never edited")
        finally:
            fx.close()

    def test_new_layer_goes_after_its_layer_block(self) -> None:
        fx = Fixture()
        try:
            code, out = fx.move("--destination", "CmuxNextFixtureSearch", "--layer", "ui")
            self.assertEqual(code, 0, out["problems"])
            text = fx.read("plans/cmux-next/architecture-layers.json")
            self.assertIn('    "CmuxNextBare": {"layer": "ui"},\n    "CmuxNextFixtureSearch": {"layer": "ui"},\n\n', text)
        finally:
            fx.close()

    def test_a_map_it_cannot_edit_refuses_before_any_file_moves(self) -> None:
        files = dict(FILES)
        files["plans/cmux-next/architecture-layers.json"] = '{"targets": {"CmuxNextApp": {"layer": "app"}}}\n'
        fx = Fixture(files)
        try:
            err = io.StringIO()
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                code = mover.main(["--repo", str(fx.root), "--group", "FixtureSearch", "--destination",
                                   "CmuxNextFixtureSearch", "--layer", "domain"])
            self.assertEqual(code, 2)
            self.assertIn("architecture-layers.json", err.getvalue())
            self.assertEqual(fx.git("status", "--porcelain"), "", "planned before the first git mv")
        finally:
            fx.close()

    def test_destination_without_resources_asks_the_manifest_agent(self) -> None:
        fx = Fixture()
        try:
            code, out = fx.move("--destination", "CmuxNextBare")
            self.assertEqual(code, 0, out["problems"])
            self.assertTrue(any(m.startswith("CmuxNextBare: add resources:") for m in out["manifest_requests"]))
        finally:
            fx.close()

    def test_group_from_app_graph(self) -> None:
        files = dict(FILES)
        files["plans/cmux-next/app-graph.json"] = json.dumps({"order": [
            {"group": "FixtureSearch", "destination": "CmuxNextPalette", "layer": "ui", "scc_id": 3}]})
        fx = Fixture(files)
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = mover.main(["--repo", str(fx.root), "--group", "FixtureSearch", "--dry-run"])
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(out.getvalue())["destination"], "CmuxNextPalette")
        finally:
            fx.close()


class StaleCheck(unittest.TestCase):
    def run_check(self, fx: Fixture, *args: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = follow.main(["--repo", str(fx.root), "--check", *args])
        return code, out.getvalue()

    def test_check_exits_1_on_a_stale_path_and_names_it(self) -> None:
        fx = Fixture()
        try:
            self.assertEqual(self.run_check(fx, "--rev", "HEAD")[0], 0)
            fx.git("mv", APP + "Other.swift", APP + "Renamed.swift")
            head = fx.commit("rename without following")
            code, out = self.run_check(fx, "--rev", head)
            self.assertEqual(code, 1)
            self.assertIn(f"scripts/cmux-next/main-actor-work-baseline.json: {APP}Other.swift", out)
            self.assertIn("plans/cmux-next/OWNERS.md", out)
            self.assertIn("scripts/cmux-next/autofix-areas.sh", out)  # the regex spelling, read as a path
            self.assertIn("CmuxNextApp/Other", out)  # the godfile's Module/Type row
        finally:
            fx.close()

    def test_base_debt_passes_and_a_new_stale_path_does_not(self) -> None:
        fx = Fixture()
        try:
            fx.git("mv", APP + "Other.swift", APP + "Renamed.swift")
            base = fx.commit("old debt")
            self.assertEqual(self.run_check(fx, "--rev", base, "--base", base)[0], 0)
            fx.git("rm", "-q", PKG + "Sources/CmuxNextPalette/Palette.swift")
            head = fx.commit("new debt")
            code, out = self.run_check(fx, "--rev", head, "--base", base)
            self.assertEqual(code, 1)
            self.assertIn("Palette.swift", out)
            self.assertNotIn("Other.swift", out)
        finally:
            fx.close()

    def test_from_git_follows_a_plain_rename(self) -> None:
        fx = Fixture()
        try:
            base = fx.git("rev-parse", "HEAD").strip()
            fx.git("mv", APP + "Other.swift", APP + "Renamed.swift")
            fx.commit("rename")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(follow.main(["--repo", str(fx.root), "--from-git", f"{base}..HEAD"]), 0)
            self.assertEqual(self.run_check(fx)[0], 0)
            self.assertIn(f"{APP}Renamed\\.swift", fx.read("scripts/cmux-next/autofix-areas.sh"))
        finally:
            fx.close()

    def test_glob_that_matches_nothing_is_stale(self) -> None:
        files = dict(FILES)
        files[".github/workflows/cmux-next-motion-golden.yml"] = f"paths:\n  - {PKG}Sources/**/Gone*.swift\n"
        fx = Fixture(files)
        try:
            code, out = self.run_check(fx, "--rev", "HEAD")
            self.assertEqual(code, 1)
            self.assertIn("Gone*.swift", out)
        finally:
            fx.close()


class StringKeys(unittest.TestCase):
    def test_interpolation_meets_format_specifiers(self) -> None:
        index = mover.KeyIndex({"Window %lld", "%1$@ of %2$@", "Plain", "fixtureSearch.refusal.gone", "tab.other"})
        used = index.used(mover.literals('Text("Window \\(n)"); Text("\\(a) of \\(b)"); x("fixtureSearch.refusal.\\(why)")'))
        self.assertEqual(used, {"Window %lld", "%1$@ of %2$@", "fixtureSearch.refusal.gone"})

    def test_a_generic_interpolation_is_not_a_dynamic_prefix(self) -> None:
        index = mover.KeyIndex({"Plain", "Other words"})
        self.assertEqual(index.used(mover.literals('print("\\(a) \\(b)"); print("x\\(y)")')), set())

    def test_remove_keys_keeps_every_other_byte(self) -> None:
        text = table({"a": "A", "b": "B", "c": "C"})
        for gone, left in (({"b"}, ["a", "c"]), ({"c"}, ["a", "b"]), ({"a"}, ["b", "c"])):
            result = mover.remove_keys(text, gone)
            self.assertEqual(list(json.loads(result)["strings"]), left)
            self.assertEqual(result, table({k: k.upper() for k in left}))


class Manifest(unittest.TestCase):
    def test_imports_the_destination_lacks_become_manifest_requests(self) -> None:
        files = dict(FILES)
        files[APP + "FixtureSearch/FixtureSearchHandlers.swift"] = "import CmuxNextBare\nimport Foundation\nenum FixtureSearchHandlers {}\n"
        files[PKG + "Tests/CmuxNextAppTests/FixtureSearchClosedOnceTests.swift"] = (
            "@testable import CmuxNextApp\nimport CmuxNextBare\nimport XCTest\n")
        fx = Fixture(files)
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                mover.main(["--repo", str(fx.root), "--group", "FixtureSearch", "--destination", "CmuxNextPalette", "--dry-run"])
            requests = json.loads(out.getvalue())["manifest_requests"]
            self.assertIn('CmuxNextPalette: add dependency "CmuxNextBare"', requests)
            self.assertIn('CmuxNextPaletteTests: add dependency "CmuxNextBare"', requests)
            self.assertFalse(any('"CmuxNextPalette"' in r and r.startswith("CmuxNextPaletteTests") for r in requests),
                             "the test target already depends on its subject")
            self.assertFalse(any("Foundation" in r or "XCTest" in r for r in requests))
        finally:
            fx.close()


class MadeUpPaths(unittest.TestCase):
    def test_a_synthesized_path_under_a_moved_folder_keeps_its_spelling(self) -> None:
        files = dict(FILES)
        files["scripts/cmux-next/tests/test_other.py"] = (
            'SRC = "Packages/macOS/CmuxNext/Sources"\n'
            'FIXTURE = f"{SRC}/CmuxNextApp/FixtureSearch/Moved{i}.swift"\n'
            'REAL = f"{SRC}/CmuxNextApp/FixtureSearch/FixtureSearchHandlers.swift"\n'
            'FOLDER = "CmuxNextApp/FixtureSearch/"\n'
            'PLANNED = "Sources/CmuxNextApp/FixtureSearch/Future.swift"\n')
        fx = Fixture(files)
        try:
            code, out = fx.move()
            self.assertEqual(code, 0, out["problems"])
            text = fx.read("scripts/cmux-next/tests/test_other.py")
            self.assertIn('f"{SRC}/CmuxNextApp/FixtureSearch/Moved{i}.swift"', text)
            self.assertIn('f"{SRC}/CmuxNextPalette/FixtureSearch/FixtureSearchHandlers.swift"', text)
            self.assertIn('"CmuxNextPalette/FixtureSearch/"', text)
            self.assertIn('"Sources/CmuxNextPalette/FixtureSearch/Future.swift"', text, "a planned file follows its folder")
        finally:
            fx.close()


class InterpolatedPaths(unittest.TestCase):
    def test_template_path_follows_the_table_and_check_reads_it(self) -> None:
        fx = Fixture()
        try:
            code, out = fx.move()
            self.assertEqual(code, 0, out["problems"])
            self.assertIn("`${sources}/CmuxNextPalette/Resources/FixtureSearch.xcstrings`",
                          fx.read("webviews/scripts/pages/gen-strings.mjs"))
            fx.commit("move")
            fx.git("mv", PKG + "Sources/CmuxNextPalette/Resources/FixtureSearch.xcstrings",
                   PKG + "Sources/CmuxNextPalette/Resources/Search.xcstrings")
            head = fx.commit("rename the table only")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(follow.main(["--repo", str(fx.root), "--check", "--rev", head]), 1)
            self.assertIn("gen-strings.mjs: CmuxNextPalette/Resources/FixtureSearch.xcstrings", stdout.getvalue())
        finally:
            fx.close()


class PrepushWiring(unittest.TestCase):
    def test_a_moved_files_old_findings_are_not_new(self) -> None:
        gate = load("cmux_next_prepush_gate_for_records", "prepush-gate.py")
        old = APP + "Handlers/Prompt.swift"
        new = PKG + "Sources/CmuxNextPalette/Handlers/Prompt.swift"
        with tempfile.TemporaryDirectory() as tmp:
            base, head = Path(tmp) / "base", Path(tmp) / "head"
            for tree, path in ((base, old), (head, new)):
                (tree / path).parent.mkdir(parents=True)
                (tree / path).write_text("struct P {\n    var s: [String]? = nil\n    var t: Int? = nil\n}\n")
            rule = "warning: Implicit Optional Initialization Violation (implicit_optional_initialization)"
            base_out = f"{base}/{old}:2:9: {rule}\n"
            head_out = f"{head}/{new}:2:9: {rule}\n{head}/{new}:3:9: {rule}\n"
            renamed = {new: old}
            fresh = gate.new_records(base_out, head_out, base, head, renamed)
            self.assertEqual(len(fresh), 1, "only the line the move did not bring is new")
            self.assertTrue(fresh[0].startswith(f"{new}:3:9"), fresh)
            self.assertEqual(len(gate.new_records(base_out, head_out, base, head)), 2, "without the rename both are new")

    def test_crash_allowance_that_follows_its_file_needs_no_new_review(self) -> None:
        gate = load("cmux_next_prepush_gate_for_crash", "prepush-gate.py")
        fx = Fixture()
        try:
            base = fx.git("rev-parse", "HEAD").strip()
            code, out = fx.move()
            self.assertEqual(code, 0, out["problems"])
            allow = json.loads(fx.read("scripts/cmux-next/crash-allowlist.json"))["allow"]
            self.assertEqual(allow[0]["path"], PKG + "Sources/CmuxNextPalette/FixtureSearch/FixtureSearchControl.swift")
            moved = fx.commit("move FixtureSearch")
            self.assertEqual(gate.crash_allow_unreviewed(fx.root, base, moved), [])
            data = json.loads(fx.read("scripts/cmux-next/crash-allowlist.json"))
            data["allow"][0]["count"] = 2
            (fx.root / "scripts/cmux-next/crash-allowlist.json").write_text(json.dumps(data, indent=1) + "\n")
            fx.git("add", "-A")
            raised = fx.commit("raise")
            self.assertEqual(len(gate.crash_allow_unreviewed(fx.root, moved, raised)), 1, "a raise still needs review")
        finally:
            fx.close()

    def test_gate_refuses_a_push_that_leaves_a_stale_path(self) -> None:
        gate = load("cmux_next_prepush_gate_for_move", "prepush-gate.py")
        fx = Fixture()
        try:
            base = fx.git("rev-parse", "HEAD").strip()
            fx.git("mv", APP + "Other.swift", APP + "Renamed.swift")
            head = fx.commit("rename without following")

            class Own:
                pass
            own = Own()
            own.base, own.head, own.before = base, head, ()
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertTrue(gate.stale_baseline_paths(fx.root, [own], HERE.parent))
                own.base = head
                self.assertFalse(gate.stale_baseline_paths(fx.root, [own], HERE.parent))
                # A hand edit that adds a path naming nothing is caught too, without any rename.
                allow = fx.root / "scripts/cmux-next/no-swiftui-allowlist.txt"
                allow.write_text(allow.read_text() + PKG + "Sources/CmuxNextBare/Typo.swift\n")
                fx.git("add", "-A")
                own.base, own.head = head, fx.commit("typo")
                self.assertTrue(gate.stale_baseline_paths(fx.root, [own], HERE.parent))
                # An edit to a file no baseline lists skips the scan.
                (fx.root / APP / "Other.swift").write_text("struct Other {}\n")
                fx.git("add", "-A")
                own.base, own.head = own.head, fx.commit("edit")
                self.assertFalse(gate.can_leave_stale_paths(fx.root, own.base, own.head, HERE.parent / "follow-renames.py"))
        finally:
            fx.close()


class CrashRows(unittest.TestCase):
    """The module-keyed crash baseline follows a pure move (crash_ratchet.py --update-baseline --base HEAD), and the
    gate needs no Crash-allow-OK trailer for it."""

    def fixture(self) -> Fixture:
        files = dict(FILES)
        files[APP + "FixtureSearch/FixtureSearchHandlers.swift"] = (
            "final class FixtureSearchBox: @unchecked Sendable {}\nenum FixtureSearchHandlers {\n    static func bind() {}\n}\n")
        files[APP + "Other.swift"] = files[APP + "Other.swift"].replace("struct Other {", "final class OtherBox: @unchecked Sendable {}\nstruct Other {")
        files["scripts/cmux-next/crash_ratchet.py"] = (HERE.parent / "crash_ratchet.py").read_text(encoding="utf-8")
        fx = Fixture(files)
        subprocess.run([sys.executable, "-I", str(fx.root / "scripts/cmux-next/crash_ratchet.py"), "--repo", str(fx.root),
                        "--update-baseline"], check=True, capture_output=True)
        fx.git("add", "-A")
        fx.commit("crash baseline")
        return fx

    def rows(self, fx: Fixture) -> dict:
        return json.loads(fx.read("scripts/cmux-next/crash-safety-baseline.json"))["swift"]["unchecked"]

    def test_moved_hit_carries_its_row_and_the_gate_needs_no_trailer(self) -> None:
        gate = load("cmux_next_prepush_gate_for_crash_rows", "prepush-gate.py")
        fx = self.fixture()
        try:
            self.assertEqual(self.rows(fx), {"CmuxNextApp": 2})
            base = fx.git("rev-parse", "HEAD").strip()
            code, out = fx.move()
            self.assertEqual(code, 0, out["problems"])
            self.assertEqual(self.rows(fx), {"CmuxNextApp": 1, "CmuxNextPalette": 1})
            self.assertIn("scripts/cmux-next/crash-safety-baseline.json",
                          fx.git("diff", "--cached", "--name-only").splitlines(), "staged with the move")
            ratchet = subprocess.run([sys.executable, "-I", str(fx.root / "scripts/cmux-next/crash_ratchet.py"),
                                      "--repo", str(fx.root)], capture_output=True, text=True)
            self.assertEqual(ratchet.returncode, 0, ratchet.stdout)
            moved = fx.commit("move FixtureSearch")
            raises = gate.crash_raises(fx.root, base, moved)
            self.assertEqual([rows for _, _, _, _, rows, _ in raises if rows], [], "no raised row is left for a trailer")
            self.assertEqual(raises[0][5].rows, {("swift", "unchecked", "CmuxNextApp"): -1,
                                                 ("swift", "unchecked", "CmuxNextPalette"): 1})
            self.assertEqual(gate.crash_allow_unreviewed(fx.root, base, moved), [])
            with tempfile.TemporaryDirectory() as tmp:
                scripts = Path(tmp)
                (scripts / "crash-safety-baseline.json").write_text(self.before_baseline(fx, base))
                taken = gate.apply_reviewed_crash_data(fx.root, base, moved, scripts)
                carried = json.loads((scripts / "crash-safety-baseline.json").read_text())["swift"]["unchecked"]
                self.assertEqual(carried, {"CmuxNextApp": 1, "CmuxNextPalette": 1}, taken)
        finally:
            fx.close()

    def before_baseline(self, fx: Fixture, rev: str) -> str:
        return fx.git("show", f"{rev}:scripts/cmux-next/crash-safety-baseline.json")

    def test_a_row_that_rises_past_what_the_move_brought_still_needs_review(self) -> None:
        gate = load("cmux_next_prepush_gate_for_crash_rows2", "prepush-gate.py")
        renamed = {PKG + "Sources/CmuxNextPalette/A.swift": APP + "A.swift"}
        old = {("swift", "unchecked", "CmuxNextApp"): 2}
        new = {("swift", "unchecked", "CmuxNextApp"): 1, ("swift", "unchecked", "CmuxNextPalette"): 3}
        rows = {("swift", "unchecked", "CmuxNextPalette"): 3}
        left, carried = gate.followed_rows(rows, old, new, renamed)
        self.assertEqual(left, rows, "a total that rises is not a move")
        left, carried = gate.followed_rows({("swift", "unchecked", "CmuxNextPalette"): 1}, old,
                                           {("swift", "unchecked", "CmuxNextApp"): 1, ("swift", "unchecked", "CmuxNextPalette"): 1},
                                           renamed)
        self.assertEqual(left, {})
        self.assertEqual(carried, {("swift", "unchecked", "CmuxNextApp"): -1, ("swift", "unchecked", "CmuxNextPalette"): 1})
        self.assertEqual(gate.followed_rows(rows, old, new, {})[0], rows, "no rename across modules, nothing carried")


class CheckFailures(unittest.TestCase):
    def test_an_unknown_rev_exits_2_and_the_gate_does_not_refuse(self) -> None:
        gate = load("cmux_next_prepush_gate_for_check_failure", "prepush-gate.py")
        fx = Fixture()
        try:
            for args in (["--rev", "deadbeef"], ["--rev", "HEAD", "--base", "deadbeef"]):
                err = io.StringIO()
                with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(err):
                    code = follow.main(["--repo", str(fx.root), "--check", *args])
                self.assertEqual(code, 2, args)
                self.assertEqual(out.getvalue(), "", args)
                self.assertIn("deadbeef", err.getvalue())
            base = fx.git("rev-parse", "HEAD").strip()
            fx.git("rm", "-q", PKG + "Sources/CmuxNextPalette/Palette.swift")  # a deletion makes the gate run --check
            head = fx.commit("delete")

            class Own:
                pass
            own = Own()
            # A base the clone lacks (a pruned upstream head): --check exits 2, a warning, not a refusal.
            own.base, own.head, own.before = base, head, (("upstream", "deadbeef"),)
            log = io.StringIO()
            with contextlib.redirect_stderr(log):
                self.assertFalse(gate.stale_baseline_paths(fx.root, [own], HERE.parent))
            self.assertIn("WARNING", log.getvalue())
        finally:
            fx.close()


class BraceLists(unittest.TestCase):
    def test_a_brace_list_under_a_moved_folder_follows_and_a_split_one_is_reported(self) -> None:
        files = dict(FILES)
        files["plans/cmux-next/work.tsv"] = (
            f"a\t{APP}FixtureSearch/{{FixtureSearchControl,FixtureSearchHandlers}}.swift\n"
            "b\tCmuxNextApp/FixtureSearch/{FixtureSearchControl*,FixtureSearchHandlers}.swift\n"
            f"c\t{APP}{{FixtureSearch,Resources}}/\n"
            "d\tf\"{SRC}/CmuxNextApp/FixtureSearch/Moved{i}.swift\"\n"
            "e\t`S/CmuxNextApp/FixtureSearch/FixtureSearchHandlers.swift`, T/CmuxNextAppTests/FixtureSearchClosedOnceTests.swift\n"
            "f\tAPP/CmuxNextApp/Other.swift and xS/CmuxNextApp/FixtureSearch/ (not an alias: a letter before it)\n")
        fx = Fixture(files)
        try:
            code, out = fx.move()
            text = fx.read("plans/cmux-next/work.tsv")
            self.assertIn(f"a\t{PKG}Sources/CmuxNextPalette/FixtureSearch/{{FixtureSearchControl,FixtureSearchHandlers}}.swift\n", text)
            self.assertIn("b\tCmuxNextPalette/FixtureSearch/{FixtureSearchControl*,FixtureSearchHandlers}.swift\n", text)
            self.assertIn(f"c\t{APP}{{FixtureSearch,Resources}}/\n", text, "only one of the two folders moved")
            self.assertTrue(any("{FixtureSearch,Resources}" in g for g in out["follow"]["split_globs"]), out["follow"])
            self.assertIn('d\tf"{SRC}/CmuxNextApp/FixtureSearch/Moved{i}.swift"\n', text, "an interpolation is code-built")
            self.assertIn("e\t`S/CmuxNextPalette/FixtureSearch/FixtureSearchHandlers.swift`, "
                          "T/CmuxNextPaletteTests/FixtureSearchClosedOnceTests.swift\n", text, "doc aliases follow")
            self.assertIn("f\tAPP/CmuxNextApp/Other.swift and xS/CmuxNextApp/FixtureSearch/", text)
            self.assertEqual(code, 0, out["problems"])
        finally:
            fx.close()


class DestinationTables(unittest.TestCase):
    COMPACT = ('{\n  "sourceLanguage" : "en",\n  "strings" : {\n'
               '    "Alpha" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Alpha" } } } },\n'
               '    "Zulu" : { "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Zulu" } } } }\n'
               '  },\n  "version" : "1.0"\n}')

    def test_adding_keys_to_a_compact_table_changes_only_the_added_lines(self) -> None:
        source = table({"Mike": "M", "Other": "O"})
        out = mover.add_entries(self.COMPACT, source, {"Mike"})
        self.assertEqual(list(json.loads(out)["strings"]), ["Alpha", "Mike", "Zulu"])
        before, after = self.COMPACT.splitlines(), out.splitlines()
        self.assertEqual([ln for ln in after if ln not in before][0], '    "Mike" : {')
        self.assertEqual([ln for ln in before if ln not in after], [], "no existing line changes")
        self.assertFalse(out.endswith("\n"), "the missing final newline stays missing")
        self.assertEqual(json.loads(out)["strings"]["Mike"], json.loads(source)["strings"]["Mike"])

    def test_keys_go_at_the_end_of_an_unsorted_table_and_in_case_folded_order(self) -> None:
        unsorted = table({"b": "B", "a": "A"})
        out = mover.add_entries(unsorted, table({"c": "C"}), {"c"})
        self.assertEqual(list(json.loads(out)["strings"]), ["b", "a", "c"])
        self.assertTrue(out.startswith(unsorted[:unsorted.rindex('"a"')]))
        folded = table({"accounts.hint": "H", "accounts.Status": "S"})  # case-folded, not code point order
        out = mover.add_entries(folded, table({"accounts.mid": "M"}), {"accounts.mid"})
        self.assertEqual(list(json.loads(out)["strings"]), ["accounts.hint", "accounts.mid", "accounts.Status"])

    def test_merge_into_an_existing_table_rewrites_its_path_everywhere(self) -> None:
        files = dict(FILES)
        dest = PKG + "Sources/CmuxNextPalette/Resources/FixtureSearch.xcstrings"
        files[dest] = table({"palette.only": "P"})
        fx = Fixture(files)
        try:
            code, out = fx.move()
            self.assertEqual(code, 0, out["problems"])
            self.assertTrue(any(m["mode"] == "merge" for m in out["tables"]))
            self.assertIn("`${sources}/CmuxNextPalette/Resources/FixtureSearch.xcstrings`",
                          fx.read("webviews/scripts/pages/gen-strings.mjs"))
            hits = subprocess.run(["git", "-C", str(fx.root), "grep", "-n", "CmuxNextApp/Resources/FixtureSearch.xcstrings"],
                                  capture_output=True, text=True).stdout
            self.assertEqual(hits, "")
            self.assertEqual(sorted(json.loads(fx.read(dest))["strings"]),
                             ["fixtureSearch.refusal.focus", "fixtureSearch.refusal.gone", "fixtureSearch.title", "palette.only"])
        finally:
            fx.close()

    def test_keys_a_webview_page_reads_stay_in_the_app_table(self) -> None:
        files = dict(FILES)
        files[APP + "Resources/Localizable.xcstrings"] = table({
            "Other only": "Other", "Shared words": "Shared", "Window %lld": "Window %lld",
            "page.title": "Title", "page.unused": "Webview only"})
        files[APP + "FixtureSearch/FixtureSearchHandlers.swift"] = (
            "enum FixtureSearchHandlers {\n    static let t = String(localized: \"page.title\", bundle: .module)\n}\n")
        files["webviews/scripts/pages/gen-strings.mjs"] = (
            "const sources = 'Packages/macOS/CmuxNext/Sources';\n"
            "const pages = [{ file: `${sources}/CmuxNextApp/Resources/FixtureSearch.xcstrings` },\n"
            "  { file: `${sources}/CmuxNextApp/Resources/Localizable.xcstrings`,\n"
            "    keys: (all) => all.filter((key) => key.startsWith(\"page.\")) }];\n")
        fx = Fixture(files)
        try:
            code, out = fx.move()
            self.assertEqual(code, 0, out["problems"])
            app = json.loads(fx.read(APP + "Resources/Localizable.xcstrings"))["strings"]
            dest = json.loads(fx.read(PKG + "Sources/CmuxNextPalette/Resources/Localizable.xcstrings"))["strings"]
            self.assertIn("page.title", app, "the reader still finds it: copied, not moved")
            self.assertIn("page.title", dest)
            self.assertIn("page.unused", app, "only the reader references it: not dead")
            self.assertNotIn("Window %lld", app)
        finally:
            fx.close()

    def test_reader_filters(self) -> None:
        self.assertFalse(mover.key_filter("g", "(all) => all.filter((key) => key.startsWith(\"a.\"))").reads("b"))
        self.assertTrue(mover.key_filter("g", "(all) => all.filter((key) => key.startsWith(\"a.\") || key === \"z\")").reads("z"))
        self.assertTrue(mover.key_filter("g", "() => [\"x.y\"]").reads("x.y"))
        self.assertTrue(mover.key_filter("g", "(all) => all.filter((key) => /^a/.test(key))").reads("b"), "unknown test: every key")
        self.assertTrue(mover.key_filter("g", None).reads("b"))


class TestSelection(unittest.TestCase):
    def test_a_stem_needs_a_word_boundary_and_helpers_follow_their_only_users(self) -> None:
        files = dict(FILES)
        files[PKG + "Tests/CmuxNextAppTests/FixtureSearchesTests.swift"] = "import XCTest\n@testable import CmuxNextApp\n"
        files[PKG + "Tests/CmuxNextAppTests/Support/FakeFixtureSearch.swift"] = "struct FakeFixtureSearch {}\n"
        files[PKG + "Tests/CmuxNextAppTests/Support/SharedFake.swift"] = "struct SharedFake {}\n"
        files[PKG + "Tests/CmuxNextAppTests/FixtureSearchClosedOnceTests.swift"] = (
            "import XCTest\n@testable import CmuxNextApp\n\nfinal class FixtureSearchClosedOnceTests: XCTestCase {\n"
            "    let fake = FakeFixtureSearch()\n    let shared = SharedFake()\n}\n")
        files[PKG + "Tests/CmuxNextAppTests/OtherTests.swift"] = "import XCTest\n@testable import CmuxNextApp\nlet s = SharedFake()\n"
        fx = Fixture(files)
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                mover.main(["--repo", str(fx.root), "--group", "FixtureSearch", "--destination", "CmuxNextPalette", "--dry-run"])
            plan = json.loads(out.getvalue())
            tests = [Path(t).name for t in plan["tests"]]
            self.assertIn("FixtureSearchClosedOnceTests.swift", tests)
            self.assertIn("FakeFixtureSearch.swift", tests, "a helper only moving tests use moves with them")
            self.assertNotIn("SharedFake.swift", tests)
            self.assertNotIn("FixtureSearchesTests.swift", tests, "FixtureSearches is not FixtureSearch")
            self.assertTrue(any("SharedFake.swift stays" in n for n in plan["notes"]), plan["notes"])
        finally:
            fx.close()


class WidenedFolders(unittest.TestCase):
    def test_a_folder_merged_into_a_held_folder_follows_file_by_file(self) -> None:
        files = dict(FILES)
        files[PKG + "Sources/CmuxNextPalette/FixtureSearch/FixtureSearchPlan.swift"] = "struct FixtureSearchPlan {}\n"
        fx = Fixture(files)
        try:
            code, out = fx.move()
            owners = fx.read("plans/cmux-next/OWNERS.md")
            self.assertIn(f"`{APP}FixtureSearch/`", owners, "the folder entry would also cover FixtureSearchPlan.swift")
            self.assertTrue(any("OWNERS.md" in w for w in out["follow"]["widened"]), out["follow"])
            self.assertIn(f"{PKG}Sources/CmuxNextPalette/FixtureSearch/FixtureSearchHandlers.swift",
                          fx.read("scripts/cmux-next/no-swiftui-allowlist.txt"), "file entries follow")
            yml = fx.read(".github/workflows/cmux-next-motion-golden.yml")
            self.assertIn(f"{APP}FixtureSearch/*.swift", yml, "a glob that would widen stays and is reported")
            self.assertEqual(code, 1, "left for review")
            self.assertTrue(any("review it by hand" in p for p in out["problems"]))
        finally:
            fx.close()


if __name__ == "__main__":
    unittest.main()
