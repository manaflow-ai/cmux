#!/usr/bin/env python3
"""A pre-push gate layer that subtracts the base's findings never subtracts a run that gave no verdict.

Codex on #40840 found two cases in the single-host fallback layer (tests/test_ci_single_host_fallbacks.py pins
those): a scan that did not run at the base was subtracted as old debt, and output of the wrong shape compared equal
on both sides. The class is every layer that diffs the head's findings against the base's: when the check crashes or
times out the same way on both sides, the diff is empty and the push passes a check that never judged it. Each test
here is that case for one layer: the check crashes alike at the base and the head, and the push must be refused.

Not in CI (tests/test-execution.d/ci.toml: manual; no new CI tests, Lawrence 2026-10-23): run it yourself after
changing a subtracting layer of scripts/cmux-next/prepush-gate.py (a few seconds, no build).
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

# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
_git_fixture_spec = importlib.util.spec_from_file_location(
    "git_fixture_env", os.path.join(os.path.dirname(os.path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = importlib.util.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts" / "cmux-next"
CRASH = "raise RuntimeError('the check crashed before it judged anything')\n"


def load_gate():
    spec = importlib.util.spec_from_file_location("prepush_gate_no_verdict", SCRIPTS / "prepush-gate.py")
    gate = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = gate
    spec.loader.exec_module(gate)
    return gate


class NoVerdictNeverSubtracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.gate = load_gate()
        cls.gate.load_push_range(ROOT, SCRIPTS)  # gate_own reads it from sys.modules

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        self.installed = Path(self.tmp.name) / "installed"
        self.installed.mkdir()
        self.git("init", "-q")
        for key, value in git_fixture_env.OPT_OUT:  # in the repository's own config too
            self.git("config", key, value)

    def git(self, *args: str) -> str:
        # No GIT_* from the caller (a pre-push hook's GIT_DIR would aim this at the pushing repository), then
        # the helper's maintenance opt-out back on top.
        env = git_fixture_env.fixture_env({k: v for k, v in os.environ.items() if not k.startswith("GIT_")})
        return subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=fixture",
                               "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", *args],
                              check=True, capture_output=True, text=True, env=env).stdout.strip()

    def write(self, relative: str, text: str) -> None:
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "--no-gpg-sign", "-m", message)
        return self.git("rev-parse", "HEAD")

    def install(self, relative: str, source: str) -> None:
        """SOURCE as the hook's installed copy of RELATIVE, and a placeholder at the head (a commit not older than
        the check)."""
        (self.installed / Path(relative).name).write_text(source, encoding="utf-8")
        self.write(relative, "# the pushed copy; the hook runs the installed one\n")

    def quiet(self, call, *args, **kwargs):
        with contextlib.redirect_stderr(io.StringIO()):
            return call(*args, **kwargs)

    def assertRefusedWithNoVerdict(self, found: list[str], what: str) -> None:
        self.assertTrue(found, f"{what}: a check that crashed alike on both sides passed the push")
        self.assertTrue(any(isinstance(f, self.gate.NoVerdict) for f in found), found)

    def reserved_repo(self) -> tuple[str, str]:
        self.install(self.gate.RESERVED_SCRIPT, CRASH)
        self.write(self.gate.RESERVED_LIST, "[]\n")
        self.write(self.gate.RESERVED_SURFACES, "{}\n")
        base = self.commit("base")
        self.write(self.gate.RESERVED_SURFACES, '{"changed": true}\n')
        return base, self.commit("head")

    def test_the_ghostty_reserved_keys_layer(self) -> None:
        base, head = self.reserved_repo()
        found = self.quiet(self.gate.reserved_keys, self.repo, base, head, self.installed)
        self.assertRefusedWithNoVerdict(found, "reserved keys")

    def test_the_ui_font_layer(self) -> None:
        # Its --inputs answer still works, so the layer runs; the check itself crashes on both passes.
        self.install(self.gate.UI_FONT_SCRIPT, "import sys\nif '--inputs' in sys.argv:\n    print('webviews/')\n"
                                               "    raise SystemExit(0)\n" + CRASH)
        self.write("webviews/a.css", "a {}\n")
        base = self.commit("base")
        self.write("webviews/a.css", "b {}\n")
        head = self.commit("head")
        found = self.quiet(self.gate.ui_font, self.repo, base, head, self.installed)
        self.assertRefusedWithNoVerdict(found, "ui font")

    def test_the_scanner_layer(self) -> None:
        # A scanner run from the trees, as the real ones are; it crashes the same way in both.
        self.write("scripts/cmux-next/fake-check.py", CRASH)
        self.write("webviews/a.ts", "export const a = 1\n")
        base = self.commit("base")
        self.write("webviews/a.ts", "export const a = 2\n")
        head = self.commit("head")
        scanners = (("Fake check", ["python3", "-I", "{s}/fake-check.py", "{root}"], ("webviews/",)),)
        original = self.gate.SCANNERS
        self.gate.SCANNERS = scanners
        try:
            found = dict(self.quiet(self.gate.gate, self.repo, base, head, {"scanners"}, False))
        finally:
            self.gate.SCANNERS = original
        self.assertIn("Fake check", found, "a scanner that crashed alike on both sides passed the push")
        self.assertRefusedWithNoVerdict(found["Fake check"], "scanner")

    def test_a_scanner_base_that_crashed_subtracts_nothing(self) -> None:
        # The base crashes after printing a finding the head also has: what a crashed run printed is not its findings.
        self.write("scripts/cmux-next/fake-check.py",
                   "import pathlib, sys\nprint('webviews/a.ts:1: [fake] a finding')\n"
                   "if 'two' not in (pathlib.Path(sys.argv[1]) / 'webviews/a.ts').read_text():\n" + "    " + CRASH
                   + "raise SystemExit(1)\n")
        # Line 1, the finding's line, is the same on both sides, so only the base's crash can tell them apart.
        self.write("webviews/a.ts", "// a finding here\nexport const a = 1\n")
        base = self.commit("base")
        self.write("webviews/a.ts", "// a finding here\nexport const a = 'two'\n")
        head = self.commit("head")
        original = self.gate.SCANNERS
        self.gate.SCANNERS = (("Fake check", ["python3", "-I", "{s}/fake-check.py", "{root}"], ("webviews/",)),)
        try:
            found = dict(self.quiet(self.gate.gate, self.repo, base, head, {"scanners"}, False))
        finally:
            self.gate.SCANNERS = original
        self.assertIn("Fake check", found, "a finding was subtracted against a base run that crashed")
        self.assertTrue(any("[fake] a finding" in f for f in found["Fake check"]), found)

    def fake_scanner(self, source: str, prefixes=("webviews/",)):
        """SCANNERS as one fake scanner (scripts/cmux-next/fake-check.py with SOURCE), restored after the test."""
        self.write("scripts/cmux-next/fake-check.py", source)
        original = self.gate.SCANNERS
        self.gate.SCANNERS = (("Fake check", ["python3", "-I", "{s}/fake-check.py", "{root}"], prefixes),)
        self.addCleanup(setattr, self.gate, "SCANNERS", original)

    def scanner_push(self) -> tuple[str, str]:
        self.write("webviews/a.ts", "// a finding here\nexport const a = 1\n")
        base = self.commit("base")
        self.write("webviews/a.ts", "// a finding here\nexport const a = 2\n")
        return base, self.commit("head")

    def test_a_scanner_that_exits_outside_its_verdict_codes_refuses(self) -> None:
        # Codex on #40880 (F1): the process-scan checker with a bad baseline row exits 2 ("bad baseline row") on both
        # revisions, prints the same line on both, and gate() returned []: exit 2 counted as a verdict.
        script = SCRIPTS / "check-no-process-scan.py"
        self.write("scripts/cmux-next/check-no-process-scan.py", script.read_text(encoding="utf-8"))
        self.write("scripts/cmux-next/process-scan-baseline.tsv", "cmux-tui/x.rs\tnot-a-count\tkeep\treason\n")
        self.write("cmux-tui/x.rs", "fn a() {}\n")
        base = self.commit("base")
        self.write("cmux-tui/x.rs", "fn a() { let _ = 1; }\n")
        head = self.commit("head")
        name = next(n for n, _, _ in self.gate.SCANNERS if "process scanning" in n)
        original = self.gate.SCANNERS
        self.gate.SCANNERS = tuple(row for row in original if row[0] == name)
        self.addCleanup(setattr, self.gate, "SCANNERS", original)
        found = dict(self.quiet(self.gate.gate, self.repo, base, head, {"scanners"}, False))
        self.assertIn(name, found, "a scanner that refused to judge (exit 2) on both sides passed the push")
        self.assertRefusedWithNoVerdict(found[name], "process scan exit 2")

    def test_a_scanner_killed_by_a_signal_refuses(self) -> None:
        self.fake_scanner("import os, signal\nprint('webviews/a.ts:1: [fake] half a report')\n"
                          "os.kill(os.getpid(), signal.SIGKILL)\n")
        base, head = self.scanner_push()
        found = dict(self.quiet(self.gate.gate, self.repo, base, head, {"scanners"}, False))
        self.assertIn("Fake check", found, "a scanner killed by a signal on both sides passed the push")
        self.assertRefusedWithNoVerdict(found["Fake check"], "signal")

    def test_a_scanner_finding_on_both_sides_still_subtracts(self) -> None:
        # The verdict codes take nothing away from old debt: exit 1 with the same finding at the base passes.
        self.fake_scanner("print('webviews/a.ts:1: [fake] old debt')\nraise SystemExit(1)\n")
        base, head = self.scanner_push()
        self.assertEqual(dict(self.quiet(self.gate.gate, self.repo, base, head, {"scanners"}, False)), {})

    def test_gate_own_never_takes_a_no_verdict_off(self) -> None:
        # A merge: the upstream range's run crashes the same way as the push's own, and must not take its refusal off.
        base, upstream = self.reserved_repo()
        self.write("own.txt", "own\n")
        head = self.commit("own")
        own = sys.modules[self.gate.PUSH_RANGE_MODULE].OwnRange(head=head, base=upstream, before=((base, upstream),))
        found = dict(self.quiet(self.gate.gate_own, self.repo, own, {"reserved"}, False, self.installed))
        self.assertIn(self.gate.RESERVED_CHECK, found, "the upstream run's crash took the push's own crash off")
        self.assertRefusedWithNoVerdict(found[self.gate.RESERVED_CHECK], "gate_own")


    # #41818 review: a gate that passes what it could not read. Each layer below kept only its finding lines from a
    # tool run, or read "no output" as "no findings", so a tool that could not read the file (a parse error, a bad
    # config, a crash, a timeout) passed the push. Each must now give a refusal no base run can take off.

    def fake_tool(self, name: str, body: str) -> Path:
        tool = Path(self.tmp.name) / name
        tool.write_text("#!/usr/bin/env python3\nimport sys\n" + body, encoding="utf-8")
        tool.chmod(0o755)
        return tool

    def swift_tree(self) -> Path:
        tree = Path(self.tmp.name) / "tree"
        (tree / "Sources").mkdir(parents=True)
        (tree / "Sources" / "A.swift").write_text("let a = (\n", encoding="utf-8")
        return tree

    def assertNoVerdictText(self, out: str, what: str) -> None:
        self.assertTrue(self.gate.no_verdict(1 if out else 0, out), f"{what}: a run that could not read the file "
                                                                    f"passed as no findings: {out!r}")

    def test_ast_grep_that_errors_with_no_list_is_no_verdict(self) -> None:
        # A config error: exit 1, nothing on stdout. `stdout or "[]"` read it as no matches.
        tool = self.fake_tool("ast-grep", "print('Error: Cannot parse rule sgconfig.yml', file=sys.stderr)\n"
                                          "raise SystemExit(1)\n")
        tree = self.swift_tree()
        out = self.gate.ast_grep(tool, tree / "sgconfig.yml", tree, ["Sources/A.swift"])
        self.assertNoVerdictText(out, "ast-grep")

    def test_ast_grep_that_crashes_is_no_verdict(self) -> None:
        tool = self.fake_tool("ast-grep", "print('[]')\nraise SystemExit(101)\n")
        tree = self.swift_tree()
        self.assertNoVerdictText(self.gate.ast_grep(tool, tree / "sgconfig.yml", tree, ["Sources/A.swift"]), "ast-grep")

    def test_ast_grep_that_prints_json_of_the_wrong_shape_is_no_verdict(self) -> None:
        # #41827 review (F1): valid JSON that is not a list of matches (an error object, a match with no file) made
        # m["file"] raise TypeError and crash the gate instead of refusing.
        tree = self.swift_tree()
        for printed in ('{"error": "rule sgconfig.yml failed"}', '[{"ruleId": "x"}]',
                        '[{"file": "Sources/A.swift", "range": {"start": {}}, "ruleId": "x", "message": "m"}]'):
            with self.subTest(printed=printed):
                tool = self.fake_tool("ast-grep", f"print({printed!r})\n")
                out = self.gate.ast_grep(tool, tree / "sgconfig.yml", tree, ["Sources/A.swift"])
                self.assertNoVerdictText(out, "ast-grep wrong-shape JSON")

    def test_ast_grep_clean_and_matching_runs_still_judge(self) -> None:
        tree = self.swift_tree()
        clean = self.fake_tool("ast-grep", "print('[]')\n")
        self.assertEqual(self.gate.ast_grep(clean, tree / "sgconfig.yml", tree, ["Sources/A.swift"]), "")
        match = ('[{"file": "Sources/A.swift", "range": {"start": {"line": 0}}, "ruleId": "no-try-bang", '
                 '"message": "no try!"}]')
        found = self.fake_tool("ast-grep", f"print({match!r})\nraise SystemExit(1)\n")
        out = self.gate.ast_grep(found, tree / "sgconfig.yml", tree, ["Sources/A.swift"])
        self.assertEqual(out, "Sources/A.swift:1: [no-try-bang] no try!")
        self.assertFalse(self.gate.no_verdict(1, out), out)

    def test_swiftformat_that_cannot_parse_the_file_is_no_verdict(self) -> None:
        tool = self.fake_tool("swiftformat", "print('error: Unexpected end of file at 2:1 in Sources/A.swift.', "
                                             "file=sys.stderr)\nraise SystemExit(70)\n")
        tree = self.swift_tree()
        out = self.gate.swiftformat(tool, tree / "swiftformat.conf", tree, ["Sources/A.swift"])
        self.assertNoVerdictText(out, "SwiftFormat")

    def test_swiftlint_that_cannot_read_its_config_is_no_verdict(self) -> None:
        tool = self.fake_tool("swiftlint", "print('Could not read configuration: swiftlint.yml', file=sys.stderr)\n"
                                           "raise SystemExit(1)\n")
        tree = self.swift_tree()
        out = self.gate.swiftlint(tool, tree / "swiftlint.yml", tree, ["Sources/A.swift"])
        self.assertNoVerdictText(out, "SwiftLint")

    def test_swiftlint_serious_violations_still_judge(self) -> None:
        tool = self.fake_tool("swiftlint", "print('Sources/A.swift:1:9: error: Syntax Violation: x (rule)')\n"
                                           "raise SystemExit(2)\n")
        tree = self.swift_tree()
        out = self.gate.swiftlint(tool, tree / "swiftlint.yml", tree, ["Sources/A.swift"])
        self.assertIn("Sources/A.swift:1:9", out)
        self.assertFalse(self.gate.no_verdict(1, out), out)

    def test_rustfmt_that_times_out_is_no_verdict(self) -> None:
        from unittest import mock  # noqa: PLC0415
        tree = Path(self.tmp.name) / "tree"
        (tree / "cmux-tui/crates/x/src").mkdir(parents=True)
        (tree / "cmux-tui/crates/x/src/lib.rs").write_text("fn a() {}\n", encoding="utf-8")
        config = Path(self.tmp.name) / "rustfmt.toml"
        config.write_text("", encoding="utf-8")
        (self.repo / "cmux-tui").mkdir()
        hang = subprocess.TimeoutExpired(["rustfmt"], 60)
        with self.rustfmt_on_path(), mock.patch.object(self.gate.subprocess, "run", side_effect=hang):
            out = self.quiet(self.gate.rustfmt, self.repo, config, tree, ["cmux-tui/crates/x/src/lib.rs"])
        self.assertNoVerdictText(out, "rustfmt")

    @contextlib.contextmanager
    def rustfmt_on_path(self):
        """The gate's PATH lookup answers "there is a rustfmt" while PATH itself holds none, so a test that mocks the
        rustfmt run judges the same on a machine with or without a real one (#41945 review, F3: these passed only
        where rustfmt was installed, and on a machine without one the layer warned and returned before the mock)."""
        from unittest import mock  # noqa: PLC0415
        empty = Path(self.tmp.name) / "empty-path"
        empty.mkdir(exist_ok=True)
        with mock.patch.dict(os.environ, {"PATH": str(empty)}), \
                mock.patch.object(self.gate, "rustfmt_on_path", return_value=True):
            yield

    def test_a_whats_new_validator_that_crashes_refuses(self) -> None:
        # The validator at the head raises on the highlight (not a ValueError, so not a finding): it fell open.
        self.write("scripts/whats-new/digest.py", "def parse(name, text):\n    raise KeyError('category')\n\n\n"
                                                  "def entry_problems(entry):\n    return []\n")
        self.write("scripts/whats-new/validate.py", "")
        self.write(self.gate.HIGHLIGHTS_DIR + "a.md", "title: A\n\nOne.\n")
        base = self.commit("base")
        self.write(self.gate.HIGHLIGHTS_DIR + "a.md", "title: B\n\nTwo.\n")
        head = self.commit("head")
        found = self.quiet(self.gate.highlight_problems, self.repo, base, head)
        self.assertRefusedWithNoVerdict(found, "highlights")

    def test_a_whats_new_result_of_the_wrong_shape_refuses(self) -> None:
        # #41827 review: the result was checked to be a dict, not its values. A problem that is not a string raised
        # TypeError in the loop after the try and crashed the gate instead of refusing.
        self.write("scripts/whats-new/digest.py", "def parse(name, text):\n    return text\n\n\n"
                                                  "def entry_problems(entry):\n    return [{'not': 'a string'}]\n")
        self.write("scripts/whats-new/validate.py", "")
        self.write(self.gate.HIGHLIGHTS_DIR + "a.md", "title: A\n\nOne.\n")
        base = self.commit("base")
        self.write(self.gate.HIGHLIGHTS_DIR + "a.md", "title: B\n\nTwo.\n")
        head = self.commit("head")
        found = self.quiet(self.gate.highlight_problems, self.repo, base, head)
        self.assertRefusedWithNoVerdict(found, "highlights wrong shape")

    def test_a_cargo_locks_checker_that_crashes_refuses(self) -> None:
        from unittest import mock  # noqa: PLC0415
        self.install(self.gate.CARGO_LOCKS_SCRIPT, CRASH)
        self.write("cmux-tui/Cargo.toml", "[workspace]\n")
        base = self.commit("base")
        self.write("cmux-tui/Cargo.toml", "[workspace]\nmembers = []\n")
        head = self.commit("head")
        with mock.patch.object(self.gate.shutil, "which", return_value="/usr/bin/cargo"):
            found = self.quiet(self.gate.cargo_lock_drift, self.repo, base, head, self.installed)
        self.assertRefusedWithNoVerdict(found, "cargo locks")


    # #41827 review: a checker's "findings" exit with no finding the gate can read is no verdict, not a pass.

    def test_swiftformat_exit_1_with_no_finding_line_is_no_verdict(self) -> None:
        tool = self.fake_tool("swiftformat", "print('Source input did not pass lint check.', file=sys.stderr)\n"
                                             "raise SystemExit(1)\n")
        tree = self.swift_tree()
        out = self.gate.swiftformat(tool, tree / "swiftformat.conf", tree, ["Sources/A.swift"])
        self.assertNoVerdictText(out, "SwiftFormat exit 1, no finding")

    def test_swiftlint_violations_exit_with_no_located_line_is_no_verdict(self) -> None:
        tool = self.fake_tool("swiftlint", "print('Done linting! Found 1 violation, 1 serious in 1 file.')\n"
                                           "raise SystemExit(2)\n")
        tree = self.swift_tree()
        out = self.gate.swiftlint(tool, tree / "swiftlint.yml", tree, ["Sources/A.swift"])
        self.assertNoVerdictText(out, "SwiftLint exit 2, no located finding")

    def rustfmt_failing(self, stderr: bytes) -> str:
        from unittest import mock  # noqa: PLC0415
        tree = Path(self.tmp.name) / "tree"
        (tree / "cmux-tui/crates/x/src").mkdir(parents=True, exist_ok=True)
        (tree / "cmux-tui/crates/x/src/lib.rs").write_text("fn a() {}\n", encoding="utf-8")
        config = Path(self.tmp.name) / "rustfmt.toml"
        config.write_text("", encoding="utf-8")
        (self.repo / "cmux-tui").mkdir(exist_ok=True)
        done = subprocess.CompletedProcess(["rustfmt"], 101, stdout=b"", stderr=stderr)
        with self.rustfmt_on_path(), mock.patch.object(self.gate.subprocess, "run", return_value=done):
            return self.quiet(self.gate.rustfmt, self.repo, config, tree, ["cmux-tui/crates/x/src/lib.rs"])

    def test_rustfmt_that_panics_is_no_verdict(self) -> None:
        out = self.rustfmt_failing(b"thread 'main' panicked at src/formatting.rs:1:1\n")
        self.assertNoVerdictText(out, "rustfmt panic")

    def test_rustfmt_missing_from_the_toolchain_still_warns_and_passes(self) -> None:
        out = self.rustfmt_failing(b"error: 'rustfmt' is not installed for the toolchain '1.90.0'\n")
        self.assertEqual(out, "")

    def test_a_cargo_locks_exit_1_with_no_stale_line_refuses(self) -> None:
        from unittest import mock  # noqa: PLC0415
        self.install(self.gate.CARGO_LOCKS_SCRIPT, "print('checking 30 workspaces')\nraise SystemExit(1)\n")
        self.write("cmux-tui/Cargo.toml", "[workspace]\n")
        base = self.commit("base")
        self.write("cmux-tui/Cargo.toml", "[workspace]\nmembers = []\n")
        head = self.commit("head")
        with mock.patch.object(self.gate.shutil, "which", return_value="/usr/bin/cargo"):
            found = self.quiet(self.gate.cargo_lock_drift, self.repo, base, head, self.installed)
        self.assertRefusedWithNoVerdict(found, "cargo locks exit 1, no stale line")

    def test_a_reserved_keys_exit_1_with_no_finding_refuses(self) -> None:
        self.install(self.gate.RESERVED_SCRIPT, "raise SystemExit(1)\n")
        self.write(self.gate.RESERVED_LIST, "[]\n")
        self.write(self.gate.RESERVED_SURFACES, "{}\n")
        base = self.commit("base")
        self.write(self.gate.RESERVED_SURFACES, '{"changed": true}\n')
        head = self.commit("head")
        found = self.quiet(self.gate.reserved_keys, self.repo, base, head, self.installed)
        self.assertRefusedWithNoVerdict(found, "reserved keys exit 1, no finding")

    def test_a_ui_font_exit_1_with_only_its_summary_refuses(self) -> None:
        self.install(self.gate.UI_FONT_SCRIPT, "import sys\nif '--inputs' in sys.argv:\n    print('webviews/')\n"
                                               "    raise SystemExit(0)\nprint('ui font: 1 finding(s).')\n"
                                               "raise SystemExit(1)\n")
        self.write("webviews/a.css", "a {}\n")
        base = self.commit("base")
        self.write("webviews/a.css", "b {}\n")
        head = self.commit("head")
        found = self.quiet(self.gate.ui_font, self.repo, base, head, self.installed)
        self.assertRefusedWithNoVerdict(found, "ui font exit 1, only its summary")

    # #41888 review (F2): the reserved-key and UI-font layers took any nonempty output as findings, so a checker that
    # printed "could not read checker input" on both revisions subtracted to [] and the push passed.

    def test_a_reserved_keys_line_in_no_finding_shape_refuses(self) -> None:
        self.install(self.gate.RESERVED_SCRIPT, "print('could not read checker input')\nraise SystemExit(1)\n")
        self.write(self.gate.RESERVED_LIST, "[]\n")
        self.write(self.gate.RESERVED_SURFACES, "{}\n")
        base = self.commit("base")
        self.write(self.gate.RESERVED_SURFACES, '{"changed": true}\n')
        head = self.commit("head")
        found = self.quiet(self.gate.reserved_keys, self.repo, base, head, self.installed)
        self.assertRefusedWithNoVerdict(found, "reserved keys, unreadable output alike on both sides")

    def test_a_ui_font_line_in_no_finding_shape_refuses(self) -> None:
        self.install(self.gate.UI_FONT_SCRIPT, "import sys\nif '--inputs' in sys.argv:\n    print('webviews/')\n"
                                               "    raise SystemExit(0)\nprint('could not read checker input')\n"
                                               "print('ui font: 1 finding(s).')\nraise SystemExit(1)\n")
        self.write("webviews/a.css", "a {}\n")
        base = self.commit("base")
        self.write("webviews/a.css", "b {}\n")
        head = self.commit("head")
        found = self.quiet(self.gate.ui_font, self.repo, base, head, self.installed)
        self.assertRefusedWithNoVerdict(found, "ui font, unreadable output alike on both sides")

    # #41945 review (F1): any nonempty exit-0 answer to --inputs was taken as the paths the check reads, so a
    # diagnostic there became the changed-path set, matched no changed file, and the check was skipped (passed).
    # Only an answer whose every line is a repository path is the check's inputs; else the check runs.

    def test_a_ui_font_inputs_answer_that_is_not_repo_paths_runs_the_check(self) -> None:
        for answer in ("could not list INPUTS: config missing", "Traceback (most recent call last):", "error",
                       "/abs/inputs/", "../outside/", "webviews/../src/", "webviews/src/"):
            with self.subTest(answer=answer):
                self.install(self.gate.UI_FONT_SCRIPT,
                             "import sys\n"
                             f"if '--inputs' in sys.argv:\n    print({answer!r})\n    raise SystemExit(0)\n"
                             "if '--base' in sys.argv:\n    print('webviews/src/a.css: names Inter')\n"
                             "    print('ui font: 1 finding(s).')\n    raise SystemExit(1)\n"
                             "print('ui font: ok')\n")
                self.write("webviews/src/a.css", "a {}\n")
                base = self.commit(f"base {answer}")
                self.write("webviews/src/a.css", "b {}\n")
                head = self.commit(f"head {answer}")
                found = self.quiet(self.gate.ui_font, self.repo, base, head, self.installed)
                # webviews/src/ is a path the push changes, so the check runs there too (the control row).
                self.assertEqual(found, ["webviews/src/a.css: names Inter"],
                                 f"--inputs answer {answer!r}: the check was skipped instead of judging the push")

    def test_a_ui_font_inputs_answer_of_nested_repo_paths_still_skips_an_unrelated_push(self) -> None:
        # The real answer names a file inside a folder it also names (desktop.css under webviews/src/): it is a path
        # list, so a push that changes none of them still skips the check.
        ran = Path(self.tmp.name) / "ui-font-ran"
        self.install(self.gate.UI_FONT_SCRIPT,
                     "import sys\nif '--inputs' in sys.argv:\n"
                     "    print('webviews/src/\\nwebviews/src/pages/shared/desktop.css\\nschemas/pin.json')\n"
                     f"    raise SystemExit(0)\nopen({str(ran)!r}, 'a').write('ran\\n')\nprint('ui font: ok')\n")
        self.write("webviews/src/pages/shared/desktop.css", "a {}\n")
        self.write("schemas/pin.json", "{}\n")
        self.write("other.txt", "a\n")
        base = self.commit("base")
        self.write("other.txt", "b\n")
        head = self.commit("head")
        self.assertEqual(self.quiet(self.gate.ui_font, self.repo, base, head, self.installed), [])
        self.assertFalse(ran.exists(), "a push that changes none of the check's inputs ran it")

    # #41945 review (F2): every line starting `ui font:` was dropped before the shape check, so a diagnostic in that
    # prefix (`ui font: could not read ...`) with exit 0 read as a clean run. Only its two summary lines are dropped.

    def test_a_ui_font_diagnostic_in_its_summary_prefix_refuses(self) -> None:
        self.install(self.gate.UI_FONT_SCRIPT, "import sys\nif '--inputs' in sys.argv:\n    print('webviews/')\n"
                                               "    raise SystemExit(0)\n"
                                               "print('ui font: could not read schemas/type-scale/type-scale.json')\n")
        self.write("webviews/a.css", "a {}\n")
        base = self.commit("base")
        self.write("webviews/a.css", "b {}\n")
        head = self.commit("head")
        found = self.quiet(self.gate.ui_font, self.repo, base, head, self.installed)
        self.assertRefusedWithNoVerdict(found, "ui font, a `ui font:` diagnostic with exit 0")

    def test_a_ui_font_clean_run_still_passes(self) -> None:
        self.install(self.gate.UI_FONT_SCRIPT, "import sys\nif '--inputs' in sys.argv:\n    print('webviews/')\n"
                                               "    raise SystemExit(0)\nprint('ui font: ok')\n")
        self.write("webviews/a.css", "a {}\n")
        base = self.commit("base")
        self.write("webviews/a.css", "b {}\n")
        head = self.commit("head")
        self.assertEqual(self.quiet(self.gate.ui_font, self.repo, base, head, self.installed), [])

    # #41851 review (F1): escaped() read lines[index] before checking INDEX against the file (a negative index read
    # the last line; one past the end raised IndexError in the comment walk and crashed the gate) and read any path
    # ast-grep named, inside the tree or not. An escape it cannot place in the tree escapes nothing.

    def test_ast_grep_match_outside_the_file_or_tree_is_still_a_finding(self) -> None:
        tree = self.swift_tree()
        # No final newline: line -1 is the escaped line itself.
        (tree / "Sources" / "A.swift").write_text("let a = try! b() // crash-allow: reviewed", encoding="utf-8")
        (Path(self.tmp.name) / "Outside.swift").write_text("let a = try! b() // crash-allow: reviewed",
                                                           encoding="utf-8")
        for file, line in (("Sources/A.swift", 5), ("Sources/A.swift", -1), ("../Outside.swift", 0),
                           (str(Path(self.tmp.name) / "Outside.swift"), 0)):
            with self.subTest(file=file, line=line):
                match = json.dumps([{"file": file, "range": {"start": {"line": line}}, "ruleId": "no-try-bang",
                                     "message": "no try!"}])
                tool = self.fake_tool("ast-grep", f"print({match!r})\nraise SystemExit(1)\n")
                out = self.gate.ast_grep(tool, tree / "sgconfig.yml", tree, ["Sources/A.swift"])
                self.assertEqual(out, f"{file}:{line + 1}: [no-try-bang] no try!")

    def test_ast_grep_escape_on_the_line_still_escapes(self) -> None:
        tree = self.swift_tree()
        (tree / "Sources" / "A.swift").write_text("let a = try! b() // crash-allow: reviewed\n", encoding="utf-8")
        match = json.dumps([{"file": "Sources/A.swift", "range": {"start": {"line": 0}}, "ruleId": "no-try-bang",
                             "message": "no try!"}])
        tool = self.fake_tool("ast-grep", f"print({match!r})\nraise SystemExit(1)\n")
        self.assertEqual(self.gate.ast_grep(tool, tree / "sgconfig.yml", tree, ["Sources/A.swift"]), "")

    def test_real_finding_lines_still_subtract(self) -> None:
        # The shapes the two checkers print: old debt on both sides is not the push's.
        self.install(self.gate.RESERVED_SCRIPT, "print('action-surfaces.json: a.b takes Ghostty\\'s cmd+d (split, "
                                                "reserved for split)')\nraise SystemExit(1)\n")
        self.write(self.gate.RESERVED_LIST, "[]\n")
        self.write(self.gate.RESERVED_SURFACES, "{}\n")
        base = self.commit("base")
        self.write(self.gate.RESERVED_SURFACES, '{"changed": true}\n')
        head = self.commit("head")
        self.assertEqual(self.quiet(self.gate.reserved_keys, self.repo, base, head, self.installed), [])


if __name__ == "__main__":
    sys.exit(unittest.main())
