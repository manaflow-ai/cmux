#!/usr/bin/env python3
"""scripts/cmux-next/swift-logic-lines.py on throwaway git repositories.

An unlisted declaration counts its full span in swift_logic_lines and a view-shaped header counts 0; a listed one counts
its logic and mirror shares of its current span (rounded half up); lines outside declarations never count; a declaration
moved to another Swift module or renamed counts again, a file moved inside its module does not; the ordinal tells two
`extension Foo` of one module apart and shifts with a new one; the count reads git objects at the revision, not the
working tree; an unlisted declaration of a reviewed generator's output (GENERATORS: its path and its header) counts 0,
a spoofed header or a generated-looking name does not; an extension of `[T]` is a declaration; a line never counts
twice;
the table's invalid and missing rows are reported.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the script:
  python3 -I scripts/cmux-next/tests/test_swift_logic_lines.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
SRC = "Packages/macOS/CmuxNext/Sources"
TABLE = "plans/cmux-next/swift-logic-classes.tsv"
HEADER = "module\tkind\tname\tordinal\tclass\tlogic_share\tmirror_share\tpath\treason\n"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


logic = load("cmux_next_swift_logic_lines_under_test", SCRIPTS / "swift-logic-lines.py")


class Repo(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cmux-swift-logic-lines-")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.repo = root / "repo"
        self.repo.mkdir()
        config = root / "gitconfig"
        config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n[maintenance]\n\tauto = false\n"
                          "[gc]\n\tauto = 0\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config), HOME=str(root))
        saved = {k: os.environ.get(k) for k in ("GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "HOME")}
        os.environ.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config), HOME=str(root))
        self.addCleanup(lambda: [os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
                                 for k, v in saved.items()])
        self.git("init", "--quiet", "--initial-branch=feat-cmux-next")
        self.write("README", "fixture\n")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, text=True, capture_output=True,
                              check=True).stdout.strip()

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message="change"):
        self.git("add", "-A")
        self.git("commit", "--quiet", "--allow-empty", "--no-verify", "-m", message)
        return self.git("rev-parse", "HEAD")

    def table(self, *rows):
        self.write(TABLE, HEADER + "".join("\t".join(str(v) for v in row) + "\n" for row in rows))

    def count(self, rev="HEAD"):
        """The --json object of REV, through main() (the command the tip watcher runs)."""
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(logic.main(["--repo", str(self.repo), "--rev", rev, "--json"]), 0)
        return json.loads(out.getvalue())

    def packages(self, rev="HEAD"):
        return self.count(rev)["packages"]


class LogicLinesTests(Repo):
    def test_an_unlisted_declaration_counts_its_span_and_lines_outside_declarations_do_not(self):
        self.write(f"{SRC}/CmuxNextDomain/Rules.swift",
                   "// A header comment.\nimport Foundation\n\n@MainActor\nfinal class Rules {\n    func a() {}\n}\n\n"
                   "func helper(\n    x: Int\n) -> Int {\n    x\n}\nlet limit = [\n    1,\n]\n"
                   "private let names = base\n    .map { $0 }\ntypealias Limit = Int\n#if DEBUG\nvar debug = true\n"
                   "#endif\n/* struct InAComment {\n} */\nlet text = \"\"\"\n  struct InAString {}\n  \"\"\"\n")
        sha = self.commit()
        # Rules 4 (its attribute line too), helper 5, limit 3, names 2, Limit 1, debug 1, text 3.
        data = self.count()
        self.assertEqual(data["sha"], sha)
        self.assertEqual(data["rows"], {"swift_logic_lines": 19, "mirror_lines": 0})
        self.assertEqual(data["packages"], {"CmuxNextDomain": {"swift_logic_lines": 19}})
        self.assertEqual(data["unlisted"], {"lines": 19, "declarations": 7, "view_shaped": 0, "generated": 0,
                                            "generated_lines": 0,
                                            "in_table_modules": 0, "other_modules": 19,
                                            "packages": {"CmuxNextDomain": 19}})
        self.assertEqual((data["table_rows"], data["table_rows_missing"], data["table_rows_invalid"]), (0, 0, 0))

    def test_a_listed_declaration_counts_its_logic_and_mirror_shares_rounded_half_up(self):
        body = "    let a = 1\n    let b = 2\n    let c = 3\n}\n"
        self.write(f"{SRC}/CmuxNextDomain/Store.swift", "final class Store {\n    var n = 0\n    var m = 0\n}\n")  # 4
        self.write(f"{SRC}/CmuxNextDomain/Wire.swift", "struct Wire {\n" + body)  # 5
        self.write(f"{SRC}/CmuxNextDomain/Split.swift", "struct Split {\n" + body)  # 5
        self.write(f"{SRC}/CmuxNextDomain/Host.swift", "final class Host {\n" + body)  # 5
        self.table(("CmuxNextDomain", "class", "Store", 0, "LOGIC", 100, 0, f"{SRC}/CmuxNextDomain/Store.swift",
                    "rules"),
                   ("CmuxNextDomain", "struct", "Wire", 0, "MIRROR", 0, 100, f"{SRC}/CmuxNextDomain/Wire.swift",
                    "a daemon DTO"),
                   ("CmuxNextDomain", "struct", "Split", 0, "MIXED", 30, 10, f"{SRC}/CmuxNextDomain/Split.swift",
                    "1.5 and 0.5"),
                   ("CmuxNextDomain", "class", "Host", 0, "PLATFORM", 0, 0, f"{SRC}/CmuxNextDomain/Host.swift",
                    "a window host"))
        self.commit()
        data = self.count()
        # Store 4 logic, Wire 5 mirror, Split 5 * 30% = 1.5 -> 2 logic and 5 * 10% = 0.5 -> 1 mirror, Host 0.
        self.assertEqual(data["rows"], {"swift_logic_lines": 6, "mirror_lines": 6})
        self.assertEqual(data["unlisted"]["declarations"], 0)
        self.assertEqual(data["table_rows"], 4)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            logic.main(["--repo", str(self.repo), "--sites", "mirror_lines"])
        self.assertEqual(out.getvalue().splitlines(), [
            f"{SRC}/CmuxNextDomain/Split.swift:1: struct Split #0: 1 of 5 lines (MIXED 10%)",
            f"{SRC}/CmuxNextDomain/Wire.swift:1: struct Wire #0: 5 of 5 lines (MIRROR 100%)"])

    def test_a_view_shaped_header_counts_nothing_and_another_header_counts_in_full(self):
        self.write(f"{SRC}/CmuxNextUI/Badge.swift",
                   "struct Badge: View {\n    var body: some View { Text(\"\") }\n}\n"  # 0
                   "@MainActor\nfinal class Canvas: NSView {\n}\n"  # 0
                   "struct Tinted: SwiftUI.ShapeStyle, Sendable {\n}\n"  # 0
                   "struct Bridge: @MainActor NSViewRepresentable {\n}\n"  # 0
                   "extension View {\n    func badge() -> some View { self }\n}\n"  # 0
                   "extension Badge: Equatable {\n}\n"  # 2: the header does not say View
                   "struct Wrapper<Content: View> {\n    let content: Content\n}\n"  # 3: a constraint is no conformance
                   "extension Array where Element: View {\n}\n")  # 2: a where clause is no conformance
        self.commit()
        data = self.count()
        self.assertEqual(data["rows"]["swift_logic_lines"], 7)
        self.assertEqual(data["unlisted"]["view_shaped"], 5)

    def test_only_a_reviewed_generator_output_counts_nothing_and_a_spoofed_header_counts_in_full(self):
        rules = "enum Rules {\n    static let limit = 3\n}\n"  # 3 lines
        header = "// GENERATED by scripts/cmux-next/gen-settings-sources.py from schemas/settings.\n// Do not edit.\n\n"
        schema = f"{SRC}/CmuxNextSettings/Schema"
        # Listed in GENERATORS (path and generator) with its generator's header: 0.
        self.write(f"{schema}/SettingsSchema+Retry.generated.swift", header + rules)
        # A reviewed path without its header, a header elsewhere, a spoofed header, a generated name: all count.
        self.write(f"{schema}/SettingsSchema+Hand.generated.swift", rules.replace("Rules", "Hand"))  # 3
        self.write(f"{SRC}/CmuxNextSettings/Catalog.swift", header + rules.replace("Rules", "Catalog"))  # 3
        self.write(f"{SRC}/CmuxNextDomain/Rules.swift",
                   "// Generated by hand, honestly.\nfinal class Decide {\n    func decide() {}\n}\n")  # 3
        self.write(f"{SRC}/CmuxNextDomain/Rules+Generated.swift", rules.replace("Rules", "Named"))  # 3
        # A table row wins over the generator rule.
        self.write(f"{schema}/SettingsSchema+Listed.generated.swift", header + rules.replace("Rules", "Listed"))
        self.table(("CmuxNextSettings", "enum", "Listed", 0, "LOGIC", 100, 0,
                    f"{schema}/SettingsSchema+Listed.generated.swift", "the table wins"))
        self.commit()
        data = self.count()
        self.assertEqual(data["packages"], {"CmuxNextSettings": {"swift_logic_lines": 3 + 3 + 3},
                                            "CmuxNextDomain": {"swift_logic_lines": 3 + 3}})
        self.assertEqual((data["unlisted"]["generated"], data["unlisted"]["generated_lines"]), (1, 3))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            logic.main(["--repo", str(self.repo)])
        self.assertIn("1 in generated files (3 lines)", out.getvalue())

    def test_an_extension_of_a_shorthand_type_is_a_declaration(self):
        self.write(f"{SRC}/CmuxNextDomain/Bytes.swift",
                   "extension [UInt8] {\n    var hex: String { \"\" }\n}\n"  # 3
                   "extension [String: Int] {\n}\n"  # 2
                   "extension (Int, Int) {\n}\n")  # 2 (not valid Swift today; a declaration all the same)
        self.commit()
        self.assertEqual(self.count()["rows"]["swift_logic_lines"], 7)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            logic.main(["--repo", str(self.repo), "--sites", "swift_logic_lines"])
        self.assertIn("extension [UInt8] #0", out.getvalue())
        self.assertIn("extension [String:Int] #0", out.getvalue())

    def test_a_func_without_a_body_and_a_shared_line_never_count_a_line_twice(self):
        self.write(f"{SRC}/CmuxNextDomain/Silgen.swift",
                   "@_silgen_name(\"swift_task_startOnMainActor\")\n"
                   "func startOnMain(_ task: Builtin.NativeObject)\n\n"  # 2 (its attribute line too)
                   "struct Immediate {\n    let n = 1\n}\n"  # 3
                   "let a = 1; let b = 2\n"  # 1 line: a 1, b 0
                   "let total = a\n    - b\n"  # 2: a leading `-` goes on
                   "let less = a <\n    b\n")  # 2: a trailing `<` goes on
        self.commit()
        self.assertEqual(self.count()["rows"]["swift_logic_lines"], 2 + 3 + 1 + 2 + 2)

    def test_a_func_whose_effects_start_a_new_line_counts_its_body(self):
        self.write(f"{SRC}/CmuxNextDomain/Decide.swift",
                   "func decide(_ n: Int)\n    throws -> Int\n{\n    n + 1\n}\n"  # 5
                   "func later()\n    async\n    -> Int where Int: Sendable {\n    1\n}\n"  # 5
                   "@_silgen_name(\"x\")\nfunc bare()\n@MainActor\nstruct After {\n}\n"  # bare 2, After 3
                   "@_silgen_name(\"y\")\nfunc bare2()\n\nindirect enum Tree {\n    case leaf\n}\n"  # bare2 2, Tree 3
                   "@_silgen_name(\"z\")\nfunc bare3()\n#if DEBUG\nenum Debug {\n}\n#endif\n")  # bare3 2, Debug 2
        self.commit()
        self.assertEqual(self.count()["rows"]["swift_logic_lines"], 5 + 5 + 2 + 3 + 2 + 3 + 2 + 2)

    def test_a_generator_glob_matches_one_folder_only(self):
        header = "// GENERATED by scripts/cmux-next/gen-settings-sources.py from schemas/settings.\n"
        rules = "enum Rules {\n    static let limit = 3\n}\n"  # 3
        schema = f"{SRC}/CmuxNextSettings/Schema"
        self.write(f"{schema}/SettingsSchema+Retry.generated.swift", header + rules)  # 0
        self.write(f"{schema}/SettingsSchema+Hand/Copy.generated.swift", header + rules.replace("Rules", "Copy"))  # 3
        self.commit()
        data = self.count()
        self.assertEqual(data["rows"]["swift_logic_lines"], 3)
        self.assertEqual(data["unlisted"]["generated"], 1)

    def test_a_second_declaration_on_a_line_reports_that_line(self):
        self.write(f"{SRC}/CmuxNextDomain/Pair.swift", "struct A {\n}; struct B {\n}\n")  # A 2, B 1 (its line 3)
        self.commit()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            logic.main(["--repo", str(self.repo), "--sites", "swift_logic_lines"])
        self.assertEqual(out.getvalue().splitlines(), [
            f"{SRC}/CmuxNextDomain/Pair.swift:1: struct A #0: 2 of 2 lines (unlisted)",
            f"{SRC}/CmuxNextDomain/Pair.swift:2: struct B #0: 1 of 1 lines (unlisted)"])

    def test_top_level_statements_of_a_main_swift_count(self):
        self.write(f"{SRC}/CmuxNextHelper/main.swift",
                   "import Foundation\n@preconcurrency import Dispatch\npublic import Darwin\n"
                   "@_spi(Private) internal import CoreFoundation\n\n// The entry point.\n"
                   "guard let name = CommandLine.arguments.first,\n      let other = Optional(name) else {\n"
                   "    exit(1)\n}\n#if DEBUG\nprint(other)\n#endif\nlet service = Service()\n"  # 5, service 1
                   "struct Service {\n}\n"  # 2
                   "service.run()\nprint(\"\"\"\n    started\n\n    \"\"\")\n"
                   "RunLoop.main.run()\n")  # 5 more: a string's lines too, no blank line
        self.write(f"{SRC}/CmuxNextHelper/Other.swift", "struct Other {\n}\n")  # 2: no main.swift
        self.commit()
        self.assertEqual(self.count()["rows"]["swift_logic_lines"], (5 + 5) + 1 + 2 + 2)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            logic.main(["--repo", str(self.repo), "--sites", "swift_logic_lines"])
        self.assertIn(f"{SRC}/CmuxNextHelper/main.swift:7: main main.swift #0: 10 of 10 lines (unlisted)",
                      out.getvalue())

    def test_a_listed_declaration_moved_to_another_file_or_module_counts_again(self):
        self.write(f"{SRC}/CmuxNextDomain/Store.swift", "final class Store {\n    var n = 0\n}\n")
        self.table(("CmuxNextDomain", "class", "Store", 0, "PLATFORM", 0, 0, f"{SRC}/CmuxNextDomain/Store.swift",
                    "a host"))
        base = self.commit()
        (self.repo / SRC / "CmuxNextDomain" / "Hosts").mkdir()  # `git mv` into a missing directory fails
        self.git("mv", f"{SRC}/CmuxNextDomain/Store.swift", f"{SRC}/CmuxNextDomain/Hosts/Host.swift")
        self.commit("the file moves inside its module")
        self.assertEqual(self.count()["rows"]["swift_logic_lines"], 3, "a moved file counts until the table follows")
        (self.repo / SRC / "CmuxNextCore").mkdir(parents=True)
        self.git("mv", f"{SRC}/CmuxNextDomain/Hosts/Host.swift", f"{SRC}/CmuxNextCore/Host.swift")
        self.commit("the declaration moves to another Swift module")
        data = self.count()
        self.assertEqual(data["packages"], {"CmuxNextCore": {"swift_logic_lines": 3}})
        self.assertEqual(data["table_rows_missing"], 1)
        self.assertEqual(self.count(base)["rows"]["swift_logic_lines"], 0, "the count of a revision does not change")

    def test_a_renamed_listed_declaration_counts_again(self):
        self.write(f"{SRC}/CmuxNextDomain/Store.swift", "final class Store {\n    var n = 0\n}\n")
        self.table(("CmuxNextDomain", "class", "Store", 0, "PLATFORM", 0, 0, f"{SRC}/CmuxNextDomain/Store.swift",
                    "a host"))
        self.commit()
        self.write(f"{SRC}/CmuxNextDomain/Store.swift", "final class StoreHost {\n    var n = 0\n}\n")
        self.commit("renamed")
        data = self.count()
        self.assertEqual(data["rows"]["swift_logic_lines"], 3)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            logic.main(["--repo", str(self.repo), "--missing"])
        self.assertEqual(out.getvalue(),
                         f"CmuxNextDomain\tclass\tStore\t0\tPLATFORM\t{SRC}/CmuxNextDomain/Store.swift\n")

    def test_the_key_is_the_file_and_the_ordinal_within_it_so_a_new_file_shifts_nothing(self):
        # The WindowManager case (tip watcher, d6858a534b4): extensions of one type in many files of a module.
        d = f"{SRC}/CmuxNextApp"
        self.write(f"{d}/WindowManager+Membership.swift",
                   "extension WindowManager {\n    func b() {}\n    func c() {}\n}\n")  # 4
        self.write(f"{d}/WindowManager+Frames.swift", "extension WindowManager {\n}\nextension WindowManager {\n"
                                                     "    func a() {}\n}\n")  # 2, 3
        self.write(f"{SRC}/CmuxNextUI/WindowManager+Frames.swift", "extension WindowManager {\n}\n")  # another module
        self.table(("CmuxNextApp", "extension", "WindowManager", 0, "PLATFORM", 0, 0, f"{d}/WindowManager+Frames.swift",
                    "frames"),
                   ("CmuxNextApp", "extension", "WindowManager", 1, "LOGIC", 100, 0, f"{d}/WindowManager+Frames.swift",
                    "rules"),
                   ("CmuxNextApp", "extension", "WindowManager", 0, "PLATFORM", 0, 0,
                    f"{d}/WindowManager+Membership.swift", "membership"),
                   ("CmuxNextUI", "extension", "WindowManager", 0, "PLATFORM", 0, 0,
                    f"{SRC}/CmuxNextUI/WindowManager+Frames.swift", "ui"))
        self.commit()
        self.assertEqual(self.packages(), {"CmuxNextApp": {"swift_logic_lines": 3}})
        # A new file that sorts first adds only its own lines: no listed declaration changes its key.
        self.write(f"{d}/WindowManager+Activation.swift", "extension WindowManager {\n}\n")
        self.commit()
        data = self.count()
        self.assertEqual(data["packages"], {"CmuxNextApp": {"swift_logic_lines": 3 + 2}})
        self.assertEqual(data["table_rows_missing"], 0)

    def test_the_count_reads_the_revision_and_not_the_working_tree(self):
        self.write(f"{SRC}/CmuxNextDomain/Store.swift", "final class Store {\n    var n = 0\n}\n")
        self.commit()
        self.write(f"{SRC}/CmuxNextDomain/Store.swift", "final class Store {\n    var n = 0\n    var m = 0\n}\n")
        self.table(("CmuxNextDomain", "class", "Store", 0, "PLATFORM", 0, 0, f"{SRC}/CmuxNextDomain/Store.swift",
                    "uncommitted"))
        self.assertEqual(self.count()["rows"]["swift_logic_lines"], 3)
        self.assertEqual(self.count()["rows"]["swift_logic_lines"], 3, "the second count reads the cache")

    def test_a_closure_package_is_counted_under_its_module(self):
        self.write("Packages/macOS/CmuxNext/Package.swift",
                   '// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "CmuxNext", '
                   'dependencies: [.package(path: "../../Shared/Kit")], targets: [.target(name: "CmuxNextCore")])\n')
        self.write("Packages/Shared/Kit/Package.swift",
                   '// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "Kit", '
                   'targets: [.target(name: "Kit")])\n')
        self.write("Packages/Shared/Kit/Sources/Kit/Hub.swift", "struct Hub {\n}\n")
        self.write("Packages/Shared/Kit/Tests/KitTests/HubTests.swift", "struct HubTests {\n}\n")
        self.write("Packages/Shared/Other/Sources/Other/Other.swift", "struct Other {\n}\n")  # not linked
        self.table(("CmuxNextCore", "struct", "Core", 0, "LOGIC", 100, 0, f"{SRC}/CmuxNextCore/Core.swift",
                    "a module the table classifies"))
        self.write(f"{SRC}/CmuxNextCore/Core.swift", "struct Core {\n}\nstruct Unclassified {\n    let n = 1\n}\n")
        self.commit()
        data = self.count()
        self.assertEqual(data["packages"],
                         {"Kit": {"swift_logic_lines": 2}, "CmuxNextCore": {"swift_logic_lines": 2 + 3}})
        self.assertEqual((data["unlisted"]["in_table_modules"], data["unlisted"]["other_modules"]), (3, 2))

    def test_invalid_and_duplicate_table_rows_never_lower_the_count(self):
        self.write(f"{SRC}/CmuxNextDomain/Store.swift", "final class Store {\n    var n = 0\n}\n")  # 3
        self.write(f"{SRC}/CmuxNextDomain/Wire.swift", "struct Wire {\n}\n")  # 2
        d = f"{SRC}/CmuxNextDomain"
        self.table(("CmuxNextDomain", "class", "Store", 0, "LOGIC", 50, 0, f"{d}/Store.swift", "LOGIC must be 100/0"),
                   ("CmuxNextDomain", "struct", "Wire", 0, "PLATFORM", 0, 0, f"{d}/Wire.swift", "first"),
                   ("CmuxNextDomain", "struct", "Wire", 0, "MIXED", 50, 50, f"{d}/Wire.swift", "the higher sum counts"),
                   ("CmuxNextDomain", "struct", "Gone", "x", "LOGIC", 100, 0, f"{d}/Gone.swift", "not an ordinal"),
                   ("CmuxNextDomain", "struct", "Tie", 0, "MIXED", 60, 40, f"{d}/Tie.swift", "first, the same sum"),
                   ("CmuxNextDomain", "struct", "Tie", 0, "LOGIC", 100, 0, f"{d}/Tie.swift",
                    "the larger logic share counts"),
                   ("CmuxNextDomain", "struct", "Elsewhere", 0, "LOGIC", 100, 0, "Packages/Other/Tie.swift",
                    "a path outside a Sources/<module>/ folder"),
                   ("CmuxNextDomain", "class", "Store", 0, "PLATFORM", 0, 0, f"{SRC}/CmuxNextUI/Store.swift",
                    "a path in another module's folder: it never matches CmuxNextDomain/Store.swift"))
        self.write(f"{SRC}/CmuxNextDomain/Tie.swift", "struct Tie {\n    let a = 1\n    let b = 2\n    let c = 3\n}\n")
        self.commit()
        data = self.count()
        # Store 3 (unlisted), Wire 50/50 of 2 = 1/1, Tie the larger of each share: 100/40 of 5 = 5/2.
        self.assertEqual(data["rows"], {"swift_logic_lines": 3 + 1 + 5, "mirror_lines": 1 + 2})
        self.assertEqual(data["table_rows_invalid"], 6)
        self.write(TABLE, "module\tkind\tname\tordinal\tclass\tmove_share\tpath\treason\n"
                          "CmuxNextDomain\tclass\tStore\t0\tPLATFORM\t0\tp\tthe old header\n")
        self.commit()
        data = self.count()
        self.assertEqual(data["rows"]["swift_logic_lines"], 10, "a table of another header lists nothing")
        self.assertEqual(data["table_rows_invalid"], 1)


if __name__ == "__main__":
    unittest.main()
