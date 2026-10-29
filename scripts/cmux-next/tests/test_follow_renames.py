#!/usr/bin/env python3
"""follow-renames.py --check and the pre-push gate's "Baseline paths follow renames" rule (stale_baseline_paths).

A fixture repository holds a small CmuxNextApp and every kind of path-keyed file (sorted JSON, sorted lines, the
godfile's Module/Type rows, OWNERS.md, a regex in autofix-areas.sh, globs in a workflow paths filter, a doc). The
tests rename or delete a file without following it and check that --check names the stale entry, that base debt
passes, that --from-git repairs a plain rename, that the gate refuses only what the push's own commits leave, and
that the gate credits a pure rename (RenameCredit).

  python3 -m pytest scripts/cmux-next/tests/test_follow_renames.py
  python3 -m unittest discover -s scripts/cmux-next/tests -p test_follow_renames.py
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


follow = load("cmux_next_follow_renames", "follow-renames.py")

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
        self.tmp = tempfile.TemporaryDirectory(prefix="follow-renames-")
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

    def close(self) -> None:
        self.tmp.cleanup()


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


class PrepushGate(unittest.TestCase):
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


class RenameCredit(unittest.TestCase):
    """The gate credits a pure rename: the scanners read a renamed file at its old path, and the crash data that
    follow-renames.py --from-git moves with its file needs no new Crash-allow-OK trailer."""

    def test_crash_allowance_that_follows_its_file_needs_no_new_review(self) -> None:
        gate = load("cmux_next_prepush_gate_for_crash", "prepush-gate.py")
        fx = Fixture()
        try:
            base = fx.git("rev-parse", "HEAD").strip()
            fx.git("mv", APP + "FixtureSearch", APP + "Moved")
            fx.commit("move FixtureSearch")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(follow.main(["--repo", str(fx.root), "--from-git", f"{base}..HEAD"]), 0)
            allow = json.loads(fx.read("scripts/cmux-next/crash-allowlist.json"))["allow"]
            self.assertEqual(allow[0]["path"], APP + "Moved/FixtureSearchControl.swift")
            fx.git("add", "-A")
            fx.git("commit", "-q", "--amend", "--no-edit")
            moved = fx.git("rev-parse", "HEAD").strip()
            self.assertEqual(gate.crash_allow_unreviewed(fx.root, base, moved), [])
            data = json.loads(fx.read("scripts/cmux-next/crash-allowlist.json"))
            data["allow"][0]["count"] = 2
            (fx.root / "scripts/cmux-next/crash-allowlist.json").write_text(json.dumps(data, indent=1) + "\n")
            fx.git("add", "-A")
            raised = fx.commit("raise")
            self.assertEqual(len(gate.crash_allow_unreviewed(fx.root, moved, raised)), 1, "a raise still needs review")
        finally:
            fx.close()

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
            fresh = gate.new_records(base_out, head_out, base, head, {new: old})
            self.assertEqual(len(fresh), 1, "only the line the move did not bring is new")
            self.assertTrue(fresh[0].startswith(f"{new}:3:9"), fresh)
            self.assertEqual(len(gate.new_records(base_out, head_out, base, head)), 2, "without the rename both are new")

    def test_a_row_that_rises_past_what_the_move_brought_still_needs_review(self) -> None:
        gate = load("cmux_next_prepush_gate_for_crash_rows", "prepush-gate.py")
        renamed = {PKG + "Sources/CmuxNextPalette/A.swift": APP + "A.swift"}
        old = {("swift", "unchecked", "CmuxNextApp"): 2}
        new = {("swift", "unchecked", "CmuxNextApp"): 1, ("swift", "unchecked", "CmuxNextPalette"): 3}
        rows = {("swift", "unchecked", "CmuxNextPalette"): 3}
        self.assertEqual(gate.followed_rows(rows, old, new, renamed)[0], rows, "a total that rises is not a move")
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


if __name__ == "__main__":
    unittest.main()
