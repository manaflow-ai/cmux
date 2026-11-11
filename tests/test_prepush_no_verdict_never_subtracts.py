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
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

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

    def git(self, *args: str) -> str:
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
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

    def test_gate_own_never_takes_a_no_verdict_off(self) -> None:
        # A merge: the upstream range's run crashes the same way as the push's own, and must not take its refusal off.
        base, upstream = self.reserved_repo()
        self.write("own.txt", "own\n")
        head = self.commit("own")
        own = sys.modules[self.gate.PUSH_RANGE_MODULE].OwnRange(head=head, base=upstream, before=((base, upstream),))
        found = dict(self.quiet(self.gate.gate_own, self.repo, own, {"reserved"}, False, self.installed))
        self.assertIn(self.gate.RESERVED_CHECK, found, "the upstream run's crash took the push's own crash off")
        self.assertRefusedWithNoVerdict(found[self.gate.RESERVED_CHECK], "gate_own")


if __name__ == "__main__":
    sys.exit(unittest.main())
