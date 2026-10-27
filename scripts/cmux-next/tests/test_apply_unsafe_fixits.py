#!/usr/bin/env python3
"""apply-unsafe-fixits.py (p10-stability-211): the strict-memory-safety fix-its of a real swiftc .dia become
`unsafe` insertions with one SAFETY-TODO(p10) mark per line, and everything that is not such an insertion on the
fix-its' own text is refused, never applied."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures" / "swift-diagnostics"


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, HERE.parent / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


auf = load("apply_unsafe_fixits", "apply-unsafe-fixits.py")
sd = load("swift_diagnostics", "swift_diagnostics.py")

REAL_SOURCE = (FIXTURES / "A.swift.txt").read_bytes()
REAL_PACKAGE = "/work/tmp/swiftdiag-p10-036/pkg"
FLEET_ROOT = "/Users/runner/work/cmux"
DEMO = "Packages/Shared/Demo"
DEMO_SOURCE = f"{DEMO}/Sources/Demo/A.swift"
APP_MANIFEST = ('// swift-tools-version: 6.2\nimport PackageDescription\n\nlet package = Package(\n'
                '    name: "CmuxNext",\n    dependencies: [\n        .package(path: "../../Shared/Demo"),\n'
                '        .package(path: "../../Shared/Vendored"),\n    ],\n'
                '    targets: [\n        .target(name: "App"),\n    ]\n)\n')
SHARED_MANIFEST = ('// swift-tools-version: 6.2\nimport PackageDescription\n\nlet package = Package(\n'
                   '    name: "{name}",\n    targets: [\n        .target(name: "{name}"),\n    ]\n)\n')
MARKED = (b"  let p = UnsafeMutablePointer<Int>.allocate(capacity: 1)\n"
          b"  // SAFETY-TODO(p10)\n  unsafe p.pointee = 3\n  // SAFETY-TODO(p10)\n  unsafe p.deallocate()\n")


def real_fixits(dia: str = "swift-6.3.3-A.dia") -> list[dict]:
    """swift-diagnostics.sh --fixits-out lines of a real swiftc .dia, at the fleet checkout's path."""
    rows = sd.dia_rows_from_bytes((FIXTURES / dia).read_bytes(), "clean", Path(REAL_PACKAGE), "Demo")
    lines = sd.fixit_lines(rows)
    for line in lines:
        line["file"] = line["file"].replace(REAL_PACKAGE, f"{FLEET_ROOT}/{DEMO}")
    return lines


def fixit(path: str, line: int, column: int, offset: int, text: str = "unsafe ", group: str = auf.GROUP,
          end_offset: int | None = None) -> dict:
    end = offset if end_offset is None else end_offset
    return {"file": f"{FLEET_ROOT}/{path}", "line": line, "column": column, "offset": offset, "end_line": line,
            "end_column": column + end - offset, "end_offset": end, "text": text, "group": group, "message": "m",
            "target": "Demo"}


def at(source: bytes, line: int, column: int) -> int:
    return sum(len(text) + 1 for text in source.split(b"\n")[:line - 1]) + column - 1


class Repo:
    def __init__(self, directory: Path):
        self.root = directory / "repo"
        self.root.mkdir()
        self.env = {**{k: v for k, v in os.environ.items() if not k.startswith("GIT_")},
                    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": str(directory / "gitconfig"),
                    "HOME": str(directory)}
        (directory / "gitconfig").write_text("[user]\n\tname = t\n\temail = t@example.com\n")
        self.git("init", "-q", "--initial-branch=main")
        self.write("Packages/macOS/CmuxNext/Package.swift", APP_MANIFEST.encode())
        self.write(f"{DEMO}/Package.swift", SHARED_MANIFEST.format(name="Demo").encode())
        self.write(DEMO_SOURCE, REAL_SOURCE)
        self.write("Packages/Shared/Vendored/Package.swift", SHARED_MANIFEST.format(name="Vendored").encode())
        self.write("Packages/Shared/Vendored/SOURCE", b"https://example.com/upstream@abc\n")
        self.write("Packages/Shared/Vendored/Sources/Vendored/V.swift", b"let v = p.pointee\n")
        self.write("Packages/Shared/Outside/Sources/Outside/O.swift", b"let o = p.pointee\n")
        self.ref = self.commit("base")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.root), *args], env=self.env, capture_output=True, text=True,
                              check=True).stdout.strip()

    def write(self, path: str, data: bytes) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    def read(self, path: str) -> bytes:
        return (self.root / path).read_bytes()

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "--no-verify", "-m", message)
        return self.git("rev-parse", "HEAD")


class Case(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.repo = Repo(self.directory)
        self.saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
        os.environ.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(self.directory / "gitconfig"))

    def tearDown(self):
        for key in ("GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL"):
            os.environ.pop(key, None)
        os.environ.update(self.saved)
        self.temporary.cleanup()

    def run_main(self, lines: list[dict], *extra: str, ref: str | None = None) -> tuple[int, str, str]:
        path = self.directory / "fixits.jsonl"
        path.write_text("".join(json.dumps(line) + "\n" for line in lines))
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            status = auf.main(["--fixits", str(path), "--ref", ref or self.repo.ref, "--repo", str(self.repo.root),
                               *extra])
        return status, out.getvalue(), err.getvalue()


class RealDiaTests(Case):
    def test_real_fixits_become_marked_unsafe_insertions(self):
        for dia in ("swift-6.2.4-A.dia", "swift-6.3.3-A.dia"):
            with self.subTest(dia=dia):
                self.repo.write(DEMO_SOURCE, REAL_SOURCE)
                status, out, err = self.run_main(real_fixits(dia))
                self.assertEqual(status, 1, err)  # the no-usage `_` fix-it is refused, not applied
                self.assertIn(MARKED, self.repo.read(DEMO_SOURCE))
                self.assertIn("var unused = 1", self.repo.read(DEMO_SOURCE).decode())
                self.assertIn("group no-usage, not StrictMemorySafety", err)
                self.assertIn(f"applied 2 insertion(s), 2 mark(s) in 1 file(s) of {DEMO}", out)

    def test_diff_is_only_unsafe_and_marks(self):
        self.run_main(real_fixits())
        diff = self.repo.git("diff", "-U0")
        added = [line for line in diff.splitlines() if line.startswith("+") and not line.startswith("+++")]
        self.assertEqual(len(added), 4)
        self.assertEqual([line for line in added if not re.search(r"unsafe|SAFETY-TODO", line)], [])
        removed = [line for line in diff.splitlines() if line.startswith("-") and not line.startswith("---")]
        self.assertEqual([auf.INSERTION.sub("", line[1:]) for line in added if "SAFETY" not in line],
                         [line[1:] for line in removed])

    def test_dry_run_writes_nothing(self):
        status, out, _ = self.run_main([f for f in real_fixits() if f["group"] == auf.GROUP], "--dry-run")
        self.assertEqual(status, 0)
        self.assertIn("would apply 2 insertion(s)", out)
        self.assertEqual(self.repo.read(DEMO_SOURCE), REAL_SOURCE)

    def test_commit_lands_one_commit_per_package_with_the_queue_count(self):
        status, out, err = self.run_main([f for f in real_fixits() if f["group"] == auf.GROUP], "--commit")
        self.assertEqual(status, 0, err)
        self.assertIn("committed", out)
        subject = self.repo.git("log", "-1", "--format=%s")
        self.assertEqual(subject, f"{auf.UNSAFE_SUBJECT} {DEMO} (p10-stability-211)")
        body = self.repo.git("log", "-1", "--format=%b")
        self.assertIn("Q04 count after it: 2.", body)
        self.assertEqual(self.repo.git("show", "--name-only", "--format=", "HEAD"), DEMO_SOURCE)
        self.assertEqual(self.repo.git("status", "--porcelain"), "")

    def test_commit_skips_a_file_changed_since_the_ref(self):
        self.repo.write(DEMO_SOURCE, REAL_SOURCE + b"// edit\n")
        self.repo.commit("edit")
        ref = self.repo.ref  # the fix-its are base's: DEMO_SOURCE is now stale, nothing to commit
        status, _, err = self.run_main(real_fixits(), "--commit", ref=ref)
        self.assertEqual(status, 1)
        self.assertIn("stale", err)
        self.assertEqual(self.repo.git("log", "-1", "--format=%s"), "edit")

    def test_rerun_on_the_marked_text_is_refused_as_stale(self):
        lines = [f for f in real_fixits() if f["group"] == auf.GROUP]
        self.assertEqual(self.run_main(lines)[0], 0)
        once = self.repo.read(DEMO_SOURCE)
        status, _, err = self.run_main(lines)
        self.assertEqual(status, 1)
        self.assertIn("stale", err)
        self.assertEqual(self.repo.read(DEMO_SOURCE), once)

    def test_rerun_on_a_new_tip_applies_fixits_of_that_tip(self):
        lines = [f for f in real_fixits() if f["group"] == auf.GROUP]
        self.repo.write(DEMO_SOURCE, b"// a new first line\n" + REAL_SOURCE)
        tip = self.repo.commit("tip")
        moved = [{**f, "line": f["line"] + 1, "end_line": f["line"] + 1, "offset": f["offset"] + 20,
                  "end_offset": f["offset"] + 20} for f in lines]
        status, _, err = self.run_main(moved, ref=tip)
        self.assertEqual(status, 0, err)
        self.assertIn(MARKED, self.repo.read(DEMO_SOURCE))

    def test_duplicate_lines_apply_once(self):
        lines = [f for f in real_fixits() if f["group"] == auf.GROUP]
        status, out, _ = self.run_main(lines + lines)
        self.assertEqual(status, 0)
        self.assertIn("2 duplicate fix-it line(s) dropped", out)
        self.assertEqual(self.repo.read(DEMO_SOURCE).count(b"unsafe p."), 2)


class RefusalTests(Case):
    def test_refusals(self):
        offset = at(REAL_SOURCE, 7, 3)
        cases = [
            ("replacement", fixit(DEMO_SOURCE, 7, 3, offset, "unsafe ", end_offset=offset + 1),
             "not an `unsafe` insertion"),
            ("other text", fixit(DEMO_SOURCE, 7, 3, offset, "try "), "not an `unsafe` insertion"),
            ("other group", fixit(DEMO_SOURCE, 7, 3, offset, group="DeprecatedDeclaration"), "group"),
            ("not a source", fixit(f"{DEMO}/Package.swift", 1, 1, 0), "not a .swift file"),
            ("outside the closure", fixit("Packages/Shared/Outside/Sources/Outside/O.swift", 1, 9, 8),
             "not in a package of the app's closure"),
            ("vendored", fixit("Packages/Shared/Vendored/Sources/Vendored/V.swift", 1, 9, 8), "vendored verbatim"),
            ("offset not the line and column", fixit(DEMO_SOURCE, 7, 4, offset), "is not line 7 column 4"),
            ("inside a word", fixit(DEMO_SOURCE, 7, 4, offset + 1), "not the start of an expression"),
            ("at a space", fixit(DEMO_SOURCE, 7, 2, offset - 1), "not the start of an expression"),
        ]
        for name, line, why in cases:
            with self.subTest(name):
                status, _, err = self.run_main([line])
                self.assertEqual(status, 1)
                self.assertIn(why, err)
                self.assertEqual(self.repo.read(DEMO_SOURCE), REAL_SOURCE)

    def test_bad_input_is_a_usage_error(self):
        path = self.directory / "fixits.jsonl"
        path.write_text("{not json\n")
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(auf.main(["--fixits", str(path), "--ref", self.repo.ref, "--repo",
                                       str(self.repo.root)]), 2)
            self.assertEqual(auf.main(["--fixits", str(path), "--ref", "0" * 40, "--repo", str(self.repo.root)]), 2)

    def test_leftovers_list_refusals_and_diagnostics_with_no_fixit_per_module_task(self):
        offset = at(REAL_SOURCE, 7, 3)
        diagnostics = self.directory / "diagnostics.jsonl"
        rows = [{"file": f"{FLEET_ROOT}/Packages/Shared/CmuxVNC/Sources/CmuxVNC/Frame.swift", "line": 4, "column": 9,
                 "group": auf.GROUP, "message": "expression uses unsafe constructs", "fixits": []},
                {"file": f"{FLEET_ROOT}/Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/Grid.swift", "line": 2,
                 "column": 1, "group": auf.GROUP, "message": "unsafe conformance", "fixits": []},
                {"file": f"{FLEET_ROOT}/{DEMO_SOURCE}", "line": 7, "column": 3, "group": auf.GROUP, "message": "m",
                 "fixits": [{"text": "unsafe "}]},
                {"file": f"{FLEET_ROOT}/{DEMO_SOURCE}", "line": 1, "column": 1, "group": "no-usage", "message": "m",
                 "fixits": []}]
        diagnostics.write_text("".join(json.dumps(row) + "\n" for row in rows))
        out_path = self.directory / "left.jsonl"
        status, out, err = self.run_main([fixit(DEMO_SOURCE, 7, 3, offset, "try ")], "--diagnostics",
                                         str(diagnostics), "--leftovers-out", str(out_path))
        self.assertEqual(status, 1)
        self.assertIn("3 site(s) left for the module tasks (2 with no fix-it): "
                      f"{auf.UNOWNED} 1, p10-stability-065 1, p10-stability-069 1", out)
        self.assertIn("no fix-it /Users/runner/work/cmux/Packages/Shared/CmuxVNC/Sources/CmuxVNC/Frame.swift:4:9", err)
        left = [json.loads(line) for line in out_path.read_text().splitlines()]
        self.assertEqual([(item["kind"], item["owner"]) for item in left],
                         [("refused", auf.UNOWNED), ("no fix-it", "p10-stability-065"),
                          ("no fix-it", "p10-stability-069")])
        self.assertEqual(left[0]["path"], DEMO_SOURCE)

    def test_module_owners_read_the_plan_globs(self):
        owners = auf.module_owners(auf.ROOT / auf.PLAN)
        self.assertEqual(auf.owner_of("Packages/Shared/CmuxAgentCursor/Sources/CmuxCuaHelperCore/A.swift", owners),
                         "p10-stability-078")
        self.assertEqual(auf.owner_of("Packages/macOS/CmuxNext/Sources/CmuxNextFocus/F.swift", owners),
                         "p10-stability-074")
        self.assertEqual(auf.owner_of("Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/C.swift", owners),
                         "p10-stability-067")
        self.assertEqual(auf.owner_of("Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/Tab.swift", owners),
                         "p10-stability-068")
        self.assertEqual(auf.owner_of(None, owners), auf.UNOWNED)

    def test_source_root_maps_fleet_paths(self):
        self.assertEqual(auf.relative_path("/x/y/Packages/A/Sources/B/C.swift", None), "Packages/A/Sources/B/C.swift")
        self.assertEqual(auf.relative_path("/fleet/co/Packages/A/S.swift", "/fleet/co"), "Packages/A/S.swift")
        self.assertIsNone(auf.relative_path("/elsewhere/Packages/A/S.swift", "/fleet/co"))
        self.assertIsNone(auf.relative_path("/tmp/x.swift", None))


MESSAGES_LAB = "Packages/Shared/CmuxMessagesLab"
LAB_VENDORED = f"{MESSAGES_LAB}/Sources/MessagesLabHome/Vendor/catalyst/LongText.swift"
LAB_OWN = f"{MESSAGES_LAB}/Sources/MessagesLabHome/Home.swift"
LAB_SOURCE = b"func f(_ p: UnsafeMutablePointer<Int>) {\n  p.pointee = 3\n}\n"


class VendorTableTests(Case):
    """A file a package's vendor.tsv lists is sync-messageslab.sh's (pin + Patches/): the pass never edits it."""

    def setUp(self):
        super().setUp()
        manifest = APP_MANIFEST.replace('        .package(path: "../../Shared/Vendored"),\n',
                                        '        .package(path: "../../Shared/Vendored"),\n'
                                        '        .package(path: "../../Shared/CmuxMessagesLab"),\n')
        self.repo.write("Packages/macOS/CmuxNext/Package.swift", manifest.encode())
        self.repo.write(f"{MESSAGES_LAB}/Package.swift", SHARED_MANIFEST.format(name="MessagesLabHome").encode())
        self.repo.write(f"{MESSAGES_LAB}/vendor.tsv",
                        b"# MessagesLab commit 849eb3f. upstream path<TAB>vendored path\n\n"
                        b"catalyst/Sources/LongText.swift\tSources/MessagesLabHome/Vendor/catalyst/LongText.swift\t"
                        b"bd65bbf\n")
        self.repo.write(LAB_VENDORED, LAB_SOURCE)
        self.repo.write(LAB_OWN, LAB_SOURCE)
        self.repo.ref = self.repo.commit("messages lab")

    def lab_fixit(self, path: str) -> dict:
        return fixit(path, 2, 3, at(LAB_SOURCE, 2, 3))

    def test_vendored_file_is_refused_and_left_to_its_module_task(self):
        out_path = self.directory / "left.jsonl"
        status, out, err = self.run_main([self.lab_fixit(LAB_VENDORED), self.lab_fixit(LAB_OWN)],
                                         "--leftovers-out", str(out_path))
        self.assertEqual(status, 1)
        self.assertIn(f"vendored by {MESSAGES_LAB}/vendor.tsv", err)
        self.assertEqual(self.repo.read(LAB_VENDORED), LAB_SOURCE)
        self.assertEqual(self.repo.read(LAB_OWN), b"func f(_ p: UnsafeMutablePointer<Int>) {\n  // SAFETY-TODO(p10)\n"
                                                  b"  unsafe p.pointee = 3\n}\n")
        self.assertIn(f"applied 1 insertion(s), 1 mark(s) in 1 file(s) of {MESSAGES_LAB}", out)
        left = [json.loads(line) for line in out_path.read_text().splitlines()]
        self.assertEqual([(item["path"], item["owner"]) for item in left], [(LAB_VENDORED, "p10-stability-073")])

    def test_source_root_refusals_keep_their_path_and_owner(self):
        self.repo.write(LAB_OWN, LAB_SOURCE + b"// edited since the ref\n")
        out_path = self.directory / "left.jsonl"
        status, out, err = self.run_main([self.lab_fixit(LAB_OWN), self.lab_fixit(LAB_VENDORED)], "--source-root",
                                         FLEET_ROOT, "--leftovers-out", str(out_path))
        self.assertEqual(status, 1)
        self.assertIn("stale", err)
        self.assertIn("2 site(s) left for the module tasks (0 with no fix-it): p10-stability-073 2", out)
        left = [json.loads(line) for line in out_path.read_text().splitlines()]
        self.assertEqual(sorted((item["path"], item["owner"]) for item in left),
                         [(LAB_OWN, "p10-stability-073"), (LAB_VENDORED, "p10-stability-073")])

    def test_this_repository_vendor_table_lists_the_vendored_lab_files(self):
        files = auf.vendored_files(auf.ROOT, MESSAGES_LAB)
        self.assertIn(LAB_VENDORED, files)
        self.assertTrue(all(path.startswith((f"{MESSAGES_LAB}/Sources/", f"{MESSAGES_LAB}/Tests/")) for path in files))
        self.assertTrue(all((auf.ROOT / path).is_file() for path in files))
        self.assertEqual(auf.vendored_files(auf.ROOT, DEMO), set())

    def test_malformed_vendor_table_is_a_usage_error(self):
        self.repo.write(f"{MESSAGES_LAB}/vendor.tsv", b"catalyst/Sources/LongText.swift\n")
        with self.assertRaises(auf.UsageError):
            auf.vendored_files(self.repo.root, MESSAGES_LAB)


class PlacementTests(unittest.TestCase):
    def test_literal_line_starts(self):
        text = ('let a = """\n  x \\(f(\n "y"))\n z\n  """\nlet b = 1 /* a\n b /* c */ d\n e */\n'
                'let c = #"q\\"#\nlet d = "\\("\\n")"\nlet e = 2 // "\nlet f = ##"""\n """#\n """##\nlet g = 3')
        flags = auf.literal_line_starts(text)
        self.assertEqual(flags, [False, True, True, True, True, False, True, True, False, False, False, False,
                                 True, True, False])

    def test_mark_goes_above_the_line_that_opens_a_multiline_string(self):
        source = b'func f(_ p: UnsafePointer<Int>) -> String {\n    return """\n    \\(p.pointee)\n    """\n}\n'
        line = fixit("Packages/X/Sources/X/X.swift", 3, 7, at(source, 3, 7))
        text, inserted, marked, refused = auf.apply_file(
            source, [auf.Fixit("Packages/X/Sources/X/X.swift", 3, 7, line["offset"], "unsafe ")])
        self.assertEqual((inserted, marked, refused), (1, 1, []))
        self.assertEqual(text, b'func f(_ p: UnsafePointer<Int>) -> String {\n    // SAFETY-TODO(p10)\n'
                               b'    return """\n    \\(unsafe p.pointee)\n    """\n}\n')

    def test_two_insertions_on_one_line_get_one_mark(self):
        source = b"  let s = p.pointee + q.pointee\n"
        fixits = [auf.Fixit("P/Sources/A.swift", 1, 11, at(source, 1, 11), "unsafe "),
                  auf.Fixit("P/Sources/A.swift", 1, 23, at(source, 1, 23), "unsafe ")]
        text, inserted, marked, _ = auf.apply_file(source, fixits)
        self.assertEqual((inserted, marked), (2, 1))
        self.assertEqual(text, b"  // SAFETY-TODO(p10)\n  let s = unsafe p.pointee + unsafe q.pointee\n")

    def test_conformance_insertion(self):
        source = b"extension Box: Sendable {}\n"
        text, _, _, refused = auf.apply_file(
            source, [auf.Fixit("P/Sources/A.swift", 1, 16, at(source, 1, 16), "@unsafe ")])
        self.assertEqual(refused, [])
        self.assertEqual(text, b"// SAFETY-TODO(p10)\nextension Box: @unsafe Sendable {}\n")


if __name__ == "__main__":
    unittest.main()
