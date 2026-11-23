#!/usr/bin/env python3
"""fixit_compile.py: which errors count as machine-fixable, and that `run` applies only when every one is.

Run: python3 -I scripts/ci/oops/test_fixit_compile.py (the cargo end-to-end case needs cargo on PATH)."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fixit_compile as fc  # noqa: E402


def span(file="src/lib.rs", start=10, end=14, repl="", app="MachineApplicable"):
    return {"file_name": file, "byte_start": start, "byte_end": end, "suggested_replacement": repl,
            "suggestion_applicability": app}


def error(message, children=(), spans=(), level="error"):
    return {"reason": "compiler-message", "message": {
        "level": level, "message": message, "rendered": f"error: {message}\n", "spans": list(spans),
        "children": [{"level": "help", "message": "fix", "spans": list(c), "children": []} for c in children]}}


class CargoPlan(unittest.TestCase):
    def setUp(self):
        self.repo = Path(tempfile.mkdtemp()).resolve()
        (self.repo / "src").mkdir()
        (self.repo / "src" / "lib.rs").write_text("fn main() { let mut x = 5; }\n")

    def tearDown(self):
        shutil.rmtree(self.repo)

    def plan(self, *messages):
        return fc.cargo_plan(list(messages), [self.repo], self.repo)

    def test_one_machine_applicable_fix_per_error_is_fixable(self):
        got = self.plan(error("variable does not need to be mutable", children=[[span(start=16, end=20)]]),
                        error("aborting due to 1 previous error"))
        self.assertEqual((got["errors"], got["fixable"], got["unfixable"]), (1, 1, []))
        self.assertEqual(got["edits"], {str(self.repo / "src/lib.rs"): [(16, 20, "")]})

    def test_maybe_incorrect_is_not_a_fix(self):
        got = self.plan(error("cannot find value `y`", children=[[span(repl="x", app="MaybeIncorrect")]]))
        self.assertEqual(got["fixable"], 0)
        self.assertIn("no machine-applicable fix", got["unfixable"][0])

    def test_a_suggestion_with_one_unsure_span_is_not_a_fix(self):
        got = self.plan(error("e", children=[[span(), span(start=20, end=21, app="HasPlaceholders")]]))
        self.assertEqual(got["fixable"], 0)

    def test_two_fixes_for_one_error_is_a_choice(self):
        got = self.plan(error("e", children=[[span(repl="a")], [span(repl="b")]]))
        self.assertIn("more than one fix", got["unfixable"][0])

    def test_error_without_any_suggestion_is_unfixable(self):
        got = self.plan(error("mismatched types", spans=[{"file_name": "src/lib.rs", "byte_start": 1, "byte_end": 2,
                                                          "suggested_replacement": None}]))
        self.assertEqual((got["errors"], got["fixable"]), (1, 0))

    def test_fix_outside_the_repository_is_unfixable(self):
        got = self.plan(error("e", children=[[span(file="/usr/lib/rustlib/src/core.rs")]]))
        self.assertIn("outside this repository", got["unfixable"][0])

    def test_fix_under_target_is_unfixable(self):
        (self.repo / "target" / "debug").mkdir(parents=True)
        (self.repo / "target" / "debug" / "gen.rs").write_text("x")
        got = self.plan(error("e", children=[[span(file="target/debug/gen.rs", start=0, end=1)]]))
        self.assertEqual(got["fixable"], 0)

    def test_the_same_error_twice_counts_once(self):
        msg = error("unused", spans=[span()], children=[[span()]])
        got = self.plan(msg, json.loads(json.dumps(msg)))
        self.assertEqual(got["errors"], 1)

    def test_warnings_are_not_errors(self):
        got = self.plan(error("unused", children=[[span()]], level="warning"))
        self.assertEqual(got["errors"], 0)


class Edits(unittest.TestCase):
    def test_overlap_and_same_place_insertions_are_refused(self):
        self.assertIsNone(fc.overlaps([(0, 2, "a"), (2, 4, "b")]))
        self.assertIsNotNone(fc.overlaps([(0, 3, "a"), (2, 4, "b")]))
        self.assertIsNotNone(fc.overlaps([(5, 5, "a"), (5, 5, "b")]))

    def test_apply_back_to_front_in_bytes_and_restore(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "f.rs"
            path.write_bytes("é let mut x;".encode())
            originals = fc.apply_edits({str(path): [(3, 4, "L"), (7, 11, "")]})
            self.assertEqual(path.read_bytes(), "é Let x;".encode())
            fc.restore(originals)
            self.assertEqual(path.read_bytes(), "é let mut x;".encode())

    def test_utf16_offsets_become_bytes(self):
        conv = fc._utf16_to_bytes("a😀b")
        self.assertEqual((conv(0), conv(1), conv(3), conv(4)), (0, 1, 5, 6))


class Argv(unittest.TestCase):
    def test_json_added_after_the_subcommand_and_before_dashdash(self):
        self.assertEqual(fc.cargo_json_argv(["cargo", "clippy", "--locked", "--", "-D", "warnings"]),
                         ["cargo", "clippy", "--message-format=json", "--locked", "--", "-D", "warnings"])
        self.assertEqual(fc.cargo_json_argv(["cargo", "+nightly", "test", "--no-run"]),
                         ["cargo", "+nightly", "test", "--message-format=json", "--no-run"])

    def test_not_a_cargo_compile(self):
        self.assertIsNone(fc.cargo_json_argv(["make"]))
        self.assertIsNone(fc.cargo_json_argv(["cargo", "fmt", "--check"]))
        self.assertIsNone(fc.cargo_json_argv(["cargo", "build", "--message-format", "short"]))
        self.assertEqual(fc.cargo_json_argv(["cargo", "build", "--message-format=json-render-diagnostics"]),
                         ["cargo", "build", "--message-format=json-render-diagnostics"])


class TscErrors(unittest.TestCase):
    def test_both_spellings_and_prefixes(self):
        log = ("src/b.ts(1,16): error TS1484: 'Shape' is a type.\n"
               "\x1b[96msrc/c.tsx\x1b[0m:12:3 - \x1b[91merror\x1b[0m TS2304: Cannot find name 'x'.\n"
               "[webviews] src/b.ts(1,16): error TS1484: 'Shape' is a type.\n"
               "Found 2 errors.\n")
        got = fc.tsc_errors(log)
        self.assertEqual([(e["file"], e["line"], e["col"], e["code"]) for e in got],
                         [("src/b.ts", 1, 16, 1484), ("src/c.tsx", 12, 3, 2304)])

    def test_vp_check_graphical_report(self):
        log = ("\n  x typescript(TS2339): Property 'nope' does not exist on type 'Pane'.\n"
               "    ,-[src/pane/Pane.tsx:40:11]\n 39 |   const a = 1;\n 40 |   pane.nope();\n"
               "    :        ^^^^\n    `----\n\n"
               "  × typescript(TS4114): This member must have an 'override' modifier.\n"
               "   ╭─[src/x.ts:2:3]\n   ╰────\nFound 2 errors and 0 warnings in 2 files (1.0s)\n")
        got = fc.tsc_errors(log)
        self.assertEqual([(e["file"], e["line"], e["col"], e["code"]) for e in got],
                         [("src/pane/Pane.tsx", 40, 11, 2339), ("src/x.ts", 2, 3, 4114)])


@unittest.skipUnless(shutil.which("cargo"), "needs cargo")
class CargoEndToEnd(unittest.TestCase):
    def crate(self, body):
        root = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, root)
        (root / "src").mkdir()
        (root / "Cargo.toml").write_text('[package]\nname = "fx"\nversion = "0.1.0"\nedition = "2021"\n')
        (root / "src" / "main.rs").write_text(body)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
        subprocess.run(["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "i"],
                       check=True)
        return root

    def run_wrapper(self, root):
        out = root / "out"
        env = {**os.environ, "CARGO_TARGET_DIR": str(root / "target"), "GITHUB_STEP_SUMMARY": ""}
        got = subprocess.run([sys.executable, "-I", str(HERE / "fixit_compile.py"), "run", "--kind", "cargo", "--out",
                              str(out), "--", "cargo", "check"], cwd=root, capture_output=True, text=True, env=env)
        return got, out

    def test_every_error_fixable_writes_the_patch_and_keeps_the_red(self):
        root = self.crate("#![deny(warnings)]\nfn main() {\n    let mut x = 5;\n    println!(\"{}\", x);\n}\n")
        got, out = self.run_wrapper(root)
        self.assertNotEqual(got.returncode, 0, got.stdout)
        patch = next(out.glob("*.patch")).read_text()
        self.assertIn("-    let mut x = 5;\n+    let x = 5;", patch)
        self.assertIn("CI_OOPS=", got.stdout)
        self.assertIn("let mut x", (root / "src" / "main.rs").read_text(), "the tree is put back")

    def test_one_unfixable_error_applies_nothing(self):
        root = self.crate("#![deny(warnings)]\nfn main() {\n    let mut x = 5;\n    println!(\"{}\", x + y);\n}\n")
        got, out = self.run_wrapper(root)
        self.assertNotEqual(got.returncode, 0)
        self.assertFalse(out.exists() and any(out.iterdir()))
        self.assertIn("not every one", got.stdout)


class TscHelperFailures(unittest.TestCase):
    """A type check's verdict is its own: a tsc-fixits helper that prints no plan, or a crash in planning, keeps the
    check's exit status and adds no traceback (a webviews fast-gate check compares that output with the base's)."""

    def run_tsc(self, runner_body):
        root = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, root)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        runner = root / "runner.sh"
        runner.write_text("#!/bin/sh\n" + runner_body)
        runner.chmod(0o755)
        check = root / "check.sh"
        check.write_text("#!/bin/sh\necho \"src/a.ts(3,5): error TS2307: Cannot find module './x.json'.\"\nexit 2\n")
        check.chmod(0o755)
        env = {**os.environ, "FIXIT_COMPILE_TS_RUNNER": str(runner), "GITHUB_STEP_SUMMARY": ""}
        return subprocess.run([sys.executable, "-I", str(HERE / "fixit_compile.py"), "run", "--kind", "tsc", "--out",
                               str(root / "out"), "--", str(check)], cwd=root, capture_output=True, text=True, env=env)

    def test_a_helper_that_prints_no_plan_leaves_the_red_as_it_is(self):
        got = self.run_tsc("cat >/dev/null\nexit 0\n")
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertNotIn("Traceback", got.stdout + got.stderr)
        self.assertIn("printed no JSON plan", got.stdout)

    def test_a_crash_while_planning_keeps_the_checks_status(self):
        original = fc.tsc_plan
        self.addCleanup(setattr, fc, "tsc_plan", original)
        fc.tsc_plan = lambda *a: (_ for _ in ()).throw(RuntimeError("boom"))
        root = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, root)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        cwd = os.getcwd()
        self.addCleanup(os.chdir, cwd)
        os.chdir(root)
        status = fc.main(["run", "--kind", "tsc", "--out", str(root / "out"), "--", "sh", "-c",
                          "echo \"src/a.ts(3,5): error TS2307: no.\"; exit 3"])
        self.assertEqual(status, 3)


if __name__ == "__main__":
    unittest.main()
