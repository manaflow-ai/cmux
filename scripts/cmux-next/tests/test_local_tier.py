#!/usr/bin/env python3
"""The local-only rule tier and the report-only baselines (p10-stability-199).

plans/cmux-next/chrome-parity/p10-stability.md, implementer rule 1: p10 adds no CI gate. Its new rules live in the
local-only tier (prepush-gate.py's LOCAL_TIER, every guardrails.py rule), which runs in the hook and a plain run and
never under GITHUB_ACTIONS or `--commits`; its new rows live in report-only baselines that only `--report` reads,
never the compare CI runs. These tests prove both: the gate's local rules do not run in CI's two modes (and do run
locally, the control), guardrails.py judges nothing under GitHub Actions, the crash ratchet's and the Rust panic
ratchet's compare modes never open a report-only baseline (a corrupt one leaves them green), and the CI-read
baselines hold no report-only class or out-of-workspace crate.

Not a CI job (Lawrence 2026-10-23: no new CI tests): run it yourself after changing the tier or the baselines:
  python3 -I -m pytest scripts/cmux-next/tests/test_local_tier.py
  python3 -I scripts/cmux-next/tests/test_local_tier.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True

SCRIPTS = Path(__file__).resolve().parents[1]
REPO = SCRIPTS.parents[1]
# The functions LOCAL_TIER's rules call (and start_guardrails, which starts the guardrails' arch ratchet early).
LOCAL_FUNCTIONS = ("start_guardrails", "guardrails", "perf_cron_tests", "stale_baseline_paths", "compile_trailer",
                   "stability_settings")


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # guardrails' dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t",
                           "-c", "commit.gpgsign=false", *args], check=True, capture_output=True,
                          text=True).stdout.strip()


class FakeRange:
    def __init__(self, base: str, head: str):
        self.base, self.head, self.before = base, head, []

    def describe(self) -> str:
        return f"{self.base[:11]}..{self.head[:11]}"


class FakePushRange:
    def given_range(self, _repo, base, head):
        return FakeRange(base, head)

    def own_range(self, _repo, head):
        return FakeRange(head, head)


class PrepushLocalTierTests(unittest.TestCase):
    """prepush-gate.py: the LOCAL_TIER rules run in a plain run and never in CI's runs."""

    def setUp(self):
        self.gate = load("cmux_next_prepush_gate_local_tier", "prepush-gate.py")
        self.repo = Path(tempfile.mkdtemp(prefix="local-tier-"))
        self.addCleanup(shutil.rmtree, self.repo, True)
        git(self.repo, "init", "--quiet")
        (self.repo / "a.txt").write_text("1\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "--quiet", "-m", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")
        (self.repo / "a.txt").write_text("2\n")
        git(self.repo, "commit", "--quiet", "-am", "head")
        self.head = git(self.repo, "rev-parse", "HEAD")

    def run_gate(self, argv: list[str], env: dict[str, str], refuse: str = "") -> tuple[int, list[str], str]:
        """main(ARGV) with ENV over an environment without GITHUB_ACTIONS; the CI checks find nothing, and each
        local rule records that it ran (the one named REFUSE refuses). (exit code, the local functions called,
        stderr)."""
        called: list[str] = []

        def recorder(name):
            def record(*_args, **_kwargs):
                called.append(name)
                return (None, None, None) if name == "start_guardrails" else name == refuse
            return record

        clean = {k: v for k, v in os.environ.items() if k != "GITHUB_ACTIONS"}
        stderr = io.StringIO()
        with contextlib.ExitStack() as stack:
            for name in LOCAL_FUNCTIONS:
                stack.enter_context(mock.patch.object(self.gate, name, recorder(name)))
            stack.enter_context(mock.patch.object(self.gate, "gate", lambda *a, **k: []))
            stack.enter_context(mock.patch.object(self.gate, "gate_own", lambda *a, **k: []))
            stack.enter_context(mock.patch.object(self.gate, "load_push_range", lambda *a, **k: FakePushRange()))
            stack.enter_context(mock.patch.dict(os.environ, {**clean, **env}, clear=True))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            stack.enter_context(contextlib.redirect_stderr(stderr))
            code = self.gate.main(["--repo", str(self.repo), *argv])
        return code, called, stderr.getvalue()

    def test_a_plain_run_runs_every_local_rule(self):
        code, called, _ = self.run_gate(["--base", self.base, "--head", self.head], {})
        self.assertEqual(code, 0)
        self.assertEqual(called, list(LOCAL_FUNCTIONS), "the control: a local run applies the whole tier")

    def test_github_actions_runs_no_local_rule(self):
        code, called, stderr = self.run_gate(["--base", self.base, "--head", self.head], {"GITHUB_ACTIONS": "true"})
        self.assertEqual(code, 0)
        self.assertEqual(called, [])
        self.assertIn("local-only tier does not run here (GITHUB_ACTIONS)", stderr)
        self.assertNotIn("guardrails", stderr)

    def test_the_commits_sweep_runs_no_local_rule(self):
        for env in ({}, {"GITHUB_ACTIONS": "true"}):
            with self.subTest(env=env):
                code, called, _ = self.run_gate(["--commits", f"{self.base}..{self.head}"], env)
                self.assertEqual(code, 0)
                self.assertEqual(called, [])

    def test_only_and_no_guardrails_turn_the_tier_off(self):
        for argv, reason in ((["--only", "scanners"], "--only"), (["--no-guardrails"], "--no-guardrails")):
            with self.subTest(argv=argv):
                code, called, stderr = self.run_gate(["--base", self.base, "--head", self.head, *argv], {})
                self.assertEqual(code, 0)
                self.assertEqual(called, [])
                self.assertIn(f"({reason})", stderr)

    def test_a_refusing_local_rule_refuses_a_local_run(self):
        code, called, _ = self.run_gate(["--base", self.base, "--head", self.head], {}, refuse="perf_cron_tests")
        self.assertEqual(code, 1)
        self.assertEqual(called, list(LOCAL_FUNCTIONS), "one refusal does not stop the later rules")

    def test_no_local_rule_is_a_ci_scanner(self):
        scanners = {name for name, _, _ in self.gate.SCANNERS}
        self.assertFalse(scanners & {rule.name for rule in self.gate.LOCAL_TIER})


class GuardrailsLocalTierTests(unittest.TestCase):
    """guardrails.py: every rule is local-only, so under GitHub Actions it judges nothing."""

    def setUp(self):
        self.guardrails = load("cmux_next_guardrails_local_tier", "guardrails.py")

    def test_run_push_judges_nothing_under_github_actions(self):
        def must_not_run(*_args, **_kwargs):
            raise AssertionError("a guardrail rule ran under GitHub Actions")

        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}), \
                mock.patch.object(self.guardrails, "check_own", must_not_run), \
                mock.patch.object(self.guardrails, "Ratchet", must_not_run), \
                mock.patch.object(self.guardrails, "load_push_range", must_not_run):
            self.assertFalse(self.guardrails.run_push(REPO, [("a" * 40, "b" * 40)]))

    def test_a_judging_run_under_github_actions_says_so_and_passes(self):
        def must_not_run(*_args, **_kwargs):
            raise AssertionError("a guardrail rule ran under GitHub Actions")

        out = io.StringIO()
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}), \
                mock.patch.object(self.guardrails, "run_push", must_not_run), contextlib.redirect_stdout(out):
            self.assertEqual(self.guardrails.main(["--repo", str(REPO), "--base", "HEAD", "--head", "HEAD"]), 0)
        self.assertIn("not run under GitHub Actions", out.getvalue())

    def test_list_still_runs_under_github_actions(self):
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(self.guardrails.main(["--list"]), 0)
        self.assertIn("raw-continuation", out.getvalue())


CRASH_FIXTURE = {
    "Packages/macOS/CmuxNext/Package.swift": "// swift-tools-version: 6.2\nimport PackageDescription\n"
                                             'let package = Package(name: "CmuxNext")\n',
    # A report-only class hit of each kind (trap_api, raw_continuation) next to nothing the CI classes count.
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/A.swift":
        "func f(pairs: [(Int, Int)]) async {\n    let d = Dictionary(uniqueKeysWithValues: pairs)\n"
        "    await withCheckedContinuation { $0.resume() }\n    _ = d\n}\n",
    "cmux-tui/crates/x/src/lib.rs": "pub fn f() {}\n",
}


class CrashRatchetReportBaselineTests(unittest.TestCase):
    """crash_ratchet.py: the compare CI runs never reads crash-safety-report-baseline.json; --report does."""

    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(prefix="local-tier-crash-"))
        self.addCleanup(shutil.rmtree, self.repo, True)
        here = self.repo / "scripts/cmux-next"
        here.mkdir(parents=True)
        shutil.copy(SCRIPTS / "crash_ratchet.py", here / "crash_ratchet.py")
        for relative, text in CRASH_FIXTURE.items():
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        (here / "crash-safety-baseline.json").write_text('{"rust": {}, "swift": {}, "waived": {"rust": {}, "swift": {}}}\n')
        # Corrupt on purpose: any read of it raises.
        (here / "crash-safety-report-baseline.json").write_text("{ not json\n")
        git(self.repo, "init", "--quiet")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "--quiet", "-m", "fixture")

    def ratchet(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(self.repo / "scripts/cmux-next/crash_ratchet.py"),
                               "--repo", str(self.repo), *args], capture_output=True, text=True)

    def test_the_ci_compare_never_opens_the_report_baseline(self):
        compare = self.ratchet()
        self.assertEqual(compare.returncode, 0, compare.stdout + compare.stderr)
        self.assertIn("crash-ratchet: ok", compare.stdout)
        exported = self.ratchet("--exported-tree")
        self.assertEqual(exported.returncode, 0, exported.stdout + exported.stderr)

    def test_the_ci_baseline_update_gains_no_report_class_row(self):
        update = self.ratchet("--update-baseline")
        self.assertEqual(update.returncode, 0, update.stdout + update.stderr)
        data = json.loads((self.repo / "scripts/cmux-next/crash-safety-baseline.json").read_text())
        written = {kind for section in (data, data.get("waived", {})) for lang in ("swift", "rust")
                   for kind in section.get(lang, {})}
        self.assertEqual(written, set())

    def test_report_reads_the_report_baseline(self):
        report = self.ratchet("--report", "trap_api")
        self.assertNotEqual(report.returncode, 0, "--report must read the (corrupt) report baseline")
        self.assertIn("JSONDecodeError", report.stderr)


class RustPanicReportBaselineTests(unittest.TestCase):
    """rust_panic_ratchet.py: report-only rows are read by --report only; CI's baseline holds workspace crates only."""

    def setUp(self):
        self.ratchet = load("cmux_next_rust_panic_local_tier", "rust_panic_ratchet.py")
        self.dir = Path(tempfile.mkdtemp(prefix="local-tier-rust-"))
        self.addCleanup(shutil.rmtree, self.dir, True)
        (self.dir / "cmux-tui").mkdir()
        (self.dir / "cmux-tui/Cargo.toml").write_text('[workspace]\nmembers = ["crates/cmux-pty"]\n')
        self.baseline = self.dir / "baseline.json"
        self.baseline.write_text(json.dumps({"crates": {"cmux-pty": {lint: 0 for lint in self.ratchet.LINTS}}}))
        self.report_baseline = self.dir / "report.json"
        self.extra_baseline = self.dir / "extra.json"
        self.ratchet.BASELINE = str(self.baseline)
        self.ratchet.REPORT_BASELINES = [str(self.report_baseline), str(self.extra_baseline)]

    def clippy(self, *crates: str, hits: int = 0) -> str:
        items = []
        for crate in crates:
            items.append({"reason": "compiler-artifact", "package_id": f"path+file:///w/cmux-tui/crates/{crate}#0.1.0",
                          "target": {"kind": ["lib"]}})
        for line in range(hits):
            items.append({"reason": "compiler-message", "package_id": f"path+file:///w/cmux-tui/crates/{crates[-1]}#0.1.0",
                          "target": {"kind": ["lib"]}, "message": {"code": {"code": "clippy::unwrap_used"}, "spans": [
                              {"is_primary": True, "file_name": f"crates/{crates[-1]}/src/lib.rs",
                               "line_start": line + 1, "column_start": 1}]}})
        items.append({"reason": "build-finished", "success": True})
        path = self.dir / "clippy.jsonl"
        path.write_text("".join(json.dumps(item) + "\n" for item in items))
        return str(path)

    def run_main(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", ["rust_panic_ratchet.py", "--repo", str(self.dir), *argv]), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = self.ratchet.main()
            except SystemExit as exit_:
                code = exit_.code
        return code, out.getvalue(), err.getvalue()

    def test_the_ci_compare_never_opens_the_report_baselines(self):
        self.report_baseline.write_text("{ not json\n")
        self.extra_baseline.write_text("{ not json\n")
        code, _, err = self.run_main("--clippy-json", self.clippy("cmux-pty"))
        self.assertEqual(code, 0, err)

    def test_report_shows_the_report_rows_and_does_not_change_the_exit(self):
        self.extra_baseline.write_text(json.dumps({"crates": {"cmux-pty": {"unwrap_used": 1}}}))
        self.baseline.write_text(json.dumps({"crates": {"cmux-pty": {lint: 0 for lint in self.ratchet.LINTS}
                                                        | {"unwrap_used": 5}}}))
        code, out, err = self.run_main("--clippy-json", self.clippy("cmux-pty", hits=3), "--report", "json")
        self.assertEqual(code, 0, err)
        row = json.loads(out)["cmux-pty"]
        self.assertEqual(row["report_baseline"], {"unwrap_used": 1})
        self.assertEqual(row["report_over"], {"unwrap_used": {"baseline": 1, "now": 3}})
        code, out, _ = self.run_main("--clippy-json", self.clippy("cmux-pty", hits=3), "--report", "md")
        self.assertEqual(code, 0)
        self.assertIn("### Over the report-only baselines (1; not a gate)", out)
        self.assertIn("| cmux-pty | unwrap | 1 | 3 |", out)

    def test_a_crate_outside_the_workspace_never_gets_a_ci_row(self):
        before = self.baseline.read_text()
        for flag in ("--update-baseline", "--init-baseline"):
            with self.subTest(flag=flag):
                code, _, err = self.run_main("--clippy-json", self.clippy("cmux-pty", "cmux-mobile-host"), flag)
                self.assertEqual(code, 2)
                self.assertIn("cmux-mobile-host", err)
                self.assertIn("rust-panic-extra-baseline.json", err)
                self.assertEqual(self.baseline.read_text(), before)

    def test_a_workspace_run_still_updates_the_ci_baseline(self):
        code, _, err = self.run_main("--clippy-json", self.clippy("cmux-pty"), "--init-baseline")
        self.assertEqual(code, 0, err)
        self.assertEqual(set(json.loads(self.baseline.read_text())["crates"]), {"cmux-pty"})


class CheckedInBaselineTests(unittest.TestCase):
    """The checked-in CI-read baselines hold no report-only class and no crate outside the cmux-tui workspace."""

    def test_crash_safety_baseline_has_no_report_only_class(self):
        crash = load("cmux_next_crash_ratchet_local_tier", "crash_ratchet.py")
        report_only = set(crash.REPORT_CLASSES) - set(crash.SWIFT_KINDS)
        self.assertTrue(report_only, "trap_api and raw_continuation are report-only")
        data = json.loads((SCRIPTS / "crash-safety-baseline.json").read_text())
        written = {kind for section in (data, data.get("waived", {})) for lang in ("swift", "rust")
                   for kind in section.get(lang, {})}
        self.assertFalse(written & report_only)
        self.assertLessEqual(written, set(crash.SWIFT_KINDS) | set(crash.RUST))

    def test_rust_panic_baseline_holds_workspace_crates_and_ci_lints_only(self):
        rust = load("cmux_next_rust_panic_checked_in", "rust_panic_ratchet.py")
        data = json.loads((SCRIPTS / "rust-panic-baseline.json").read_text())
        members = rust.workspace_crates(str(REPO))
        self.assertIsNotNone(members)
        self.assertLessEqual(set(data["crates"]), members)
        self.assertEqual(data["lints"], rust.LINTS)
        for crate, lints in data["crates"].items():
            self.assertLessEqual(set(lints), set(rust.LINTS), crate)


if __name__ == "__main__":
    unittest.main()
