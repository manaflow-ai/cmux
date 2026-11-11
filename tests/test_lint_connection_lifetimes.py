#!/usr/bin/env python3
"""scripts/lint-connection-lifetimes.py: each rule flags its shape and leaves the bounded one alone, and the
baseline ratchets (a new hit warns, a fixed hit leaves a stale entry that is reported).

The source snippets live in tests/fixtures/lint_connection_lifetimes/cases.txt, each with the hits it must give.
"""

import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
LINTER = REPO_ROOT / "scripts" / "lint-connection-lifetimes.py"
CASES = REPO_ROOT / "tests" / "fixtures" / "lint_connection_lifetimes" / "cases.txt"
PATHS = {
    "rs": "cmux-tui/crates/acpmux/src/x.rs",
    "ts": "webviews/src/x.ts",
    "swift": "Packages/macOS/CmuxNext/Sources/CmuxNextCloud/X.swift",
}
RS = PATHS["rs"]


def load_linter():
    spec = importlib.util.spec_from_file_location("lint_connection_lifetimes", LINTER)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses look their module up while the class is made
    spec.loader.exec_module(module)
    return module


def load_cases():
    cases, name = {}, None
    for line in CASES.read_text(encoding="utf-8").splitlines(keepends=True):
        if line.startswith("=== "):
            name, lang, expect = line[4:].split()
            hits = [] if expect == "-" else [(rule, int(n)) for rule, n in (item.split(":") for item in expect.split(","))]
            cases[name] = {"lang": lang, "expect": hits, "text": ""}
        elif name:
            cases[name]["text"] += line
    for case in cases.values():
        case["text"] = case["text"].rstrip("\n") + "\n"
    return cases


lint = load_linter()
CASE = load_cases()


def scan(name):
    case = CASE[name]
    return lint.scan_text(PATHS[case["lang"]], case["text"])


class ScopeTests(unittest.TestCase):
    def test_next_code_is_scanned_and_tests_vendor_classic_are_not(self):
        for kind, path in PATHS.items():
            self.assertEqual(lint.language(path), {"rs": "rust", "ts": "ts", "swift": "swift"}[kind])
        self.assertEqual(lint.language("webviews/src/a/b.tsx"), "ts")
        for path in (
            "cmux-tui/crates/acpmux/tests/x.rs",
            "cmux-tui/crates/acpmux/src/x_tests.rs",
            "cmux-tui/crates/acpmux/src/tests.rs",
            "cmux-tui/crates/ghostty-vt/src/lib.rs",
            "cmux-tui/crates/cmux-classic-import/src/lib.rs",
            "cmux-tui/vendor/foo/src/lib.rs",
            "webviews/src/a.test.ts",
            "webviews/test/a.ts",
            "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/A.swift",
            "Sources/Classic.swift",
            "ghostty/src/main.zig",
        ):
            self.assertIsNone(lint.language(path), path)


class RuleFixtureTests(unittest.TestCase):
    def test_every_fixture_gives_exactly_its_hits(self):
        self.assertGreater(len(CASE), 40)
        for name, case in CASE.items():
            with self.subTest(name):
                self.assertEqual([(hit.rule, hit.line) for hit in scan(name)], case["expect"])

    def test_every_rule_has_a_positive_and_a_negative_fixture(self):
        for rule in ("R1", "R2", "R3", "R4", "R5", "R6"):
            prefix = rule.lower() + "_"
            named = [case for name, case in CASE.items() if name.startswith(prefix)]
            self.assertTrue(any(case["expect"] for case in named), rule)
            self.assertTrue(any(not case["expect"] for case in named), rule)


class BaselineTests(unittest.TestCase):
    def test_fingerprint_ignores_line_numbers_and_indentation(self):
        a, b = scan("baseline_one"), scan("baseline_one_moved")
        self.assertEqual([hit.key for hit in a], [hit.key for hit in b])
        self.assertNotEqual(a[0].line, b[0].line)

    def test_ratchet_reports_new_and_stale(self):
        old = scan("baseline_two_opens")
        baseline = lint.load_baseline(lint.render_baseline(old))
        self.assertEqual(sum(baseline.values()), 2)
        self.assertEqual(lint.compare(old, baseline), ([], []))
        # The TcpStream hit is fixed, a new reqwest client appears, the UnixStream line is unchanged.
        new, stale = lint.compare(scan("baseline_one_fixed_one_new"), baseline)
        self.assertEqual([(hit.rule, hit.line) for hit in new], [("R1", 3)])
        self.assertEqual([(key[0], key[1], gone) for key, gone in stale], [(RS, "R1", 1)])

    def test_a_repeated_line_counts_each_hit(self):
        baseline = lint.load_baseline(lint.render_baseline(scan("baseline_one")))
        new, stale = lint.compare(scan("baseline_twice"), baseline)
        self.assertEqual(([hit.line for hit in new], stale), ([5], []))

    def test_main_is_warn_only_unless_strict(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src = root / RS
            src.parent.mkdir(parents=True)
            src.write_text(CASE["baseline_one"]["text"], encoding="utf-8")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            baseline = root / "baseline.txt"
            baseline.write_text(lint.BASELINE_HEADER, encoding="utf-8")
            args = ["--root", str(root), "--baseline", str(baseline)]
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(lint.main(args), 0)
            self.assertIn("1 new", out.getvalue())
            self.assertIn("connections-and-lifetimes.md", out.getvalue())
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(lint.main(args + ["--strict"]), 1)
                self.assertEqual(lint.main(args + ["--update-baseline"]), 0)
                self.assertEqual(lint.main(args + ["--strict"]), 0)
            # Fixing the hit leaves a stale entry: reported, red under --strict.
            src.write_text(CASE["baseline_fixed"]["text"], encoding="utf-8")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(lint.main(args), 0)
                self.assertEqual(lint.main(args + ["--strict"]), 1)
            self.assertIn("1 fixed since the baseline", out.getvalue())

    def test_checked_in_baseline_parses(self):
        baseline = lint.load_baseline(lint.BASELINE.read_text(encoding="utf-8"))
        self.assertGreater(sum(baseline.values()), 0)


class GuardRunnerTests(unittest.TestCase):
    def test_a_passing_steps_warnings_are_forwarded(self):
        spec = importlib.util.spec_from_file_location("run_ci_guards", REPO_ROOT / "scripts" / "ci" / "run_ci_guards.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        output = "noise\n::warning file=a.rs,line=3,title=t::m\n::notice file=b.rs,title=t::n\n::error::x\n"
        self.assertEqual(
            module.passed_step_annotations(output),
            ["::warning file=a.rs,line=3,title=t::m", "::notice file=b.rs,title=t::n"],
        )


if __name__ == "__main__":
    unittest.main()
