#!/usr/bin/env python3
"""The pre-push gate's panic-allow layer: a reasonless allow of the Rust panic ratchet's lints in a file the push
changes is refused at push, with CI's own scan (rust_panic_ratchet.py allow_without_reason), not after CI's ratchet
needs a clippy build to say so (#47140 and #55721 each spent a commit after CI only to add `reason =`)."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


git_fixture_env = _load("git_fixture_env", ROOT / "tests" / "git_fixture_env.py")
gate = _load("prepush_gate_panic_allow", ROOT / "scripts" / "cmux-next" / "prepush-gate.py")

RATCHET = "scripts/cmux-next/rust_panic_ratchet.py"
CRATE = "cmux-tui/crates/demo/src"


class PanicAllowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="panic-allow-")
        self.addCleanup(self.tmp.cleanup)
        self.repo = git_fixture_env.init_repo(Path(self.tmp.name) / "repo", "-b", "feat-cmux-next")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.write(RATCHET, (ROOT / RATCHET).read_text())
        self.write(f"{CRATE}/old.rs", "#[allow(clippy::cast_possible_truncation)]\nfn old() {}\n")
        self.write(f"{CRATE}/ok.rs", "fn ok() {}\n")
        self.base = self.commit("base")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True,
                              text=True).stdout.strip()

    def write(self, path: str, text: str) -> None:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def findings(self, head: str) -> list[str]:
        return gate.panic_allow_reasons(self.repo, self.base, head)

    def test_an_added_reasonless_allow_is_refused(self):
        self.write(f"{CRATE}/ok.rs", "#[allow(clippy::cast_possible_truncation)]\nfn ok() {}\n")
        found = self.findings(self.commit("add allow"))
        self.assertEqual(len(found), 1)
        self.assertIn(f"{CRATE}/ok.rs:1: allow(cast_possible_truncation) needs reason", found[0])

    def test_an_allow_with_a_reason_passes(self):
        self.write(f"{CRATE}/ok.rs",
                   "#[allow(clippy::cast_possible_truncation, reason = \"fits in u32\")]\nfn ok() {}\n")
        self.assertEqual(self.findings(self.commit("add reasoned allow")), [])

    def test_a_base_allow_in_a_touched_file_is_refused_as_ci_does(self):
        self.write(f"{CRATE}/old.rs", "#[allow(clippy::cast_possible_truncation)]\nfn old() { let _ = 1; }\n")
        found = self.findings(self.commit("touch old"))
        self.assertEqual([f.split(":", 1)[0] for f in found], [f"{CRATE}/old.rs"])

    def test_a_base_allow_in_an_untouched_file_does_not_block(self):
        self.write(f"{CRATE}/ok.rs", "fn ok() { let _ = 2; }\n")
        self.assertEqual(self.findings(self.commit("touch ok only")), [])

    def test_tests_and_non_crate_paths_are_not_scanned(self):
        self.write("cmux-tui/crates/demo/tests/t.rs", "#[allow(clippy::cast_possible_truncation)]\nfn t() {}\n")
        self.write("cmux-tui/other/x.rs", "#[allow(clippy::cast_possible_truncation)]\nfn x() {}\n")
        self.assertEqual(self.findings(self.commit("tests only")), [])

    def test_only_panic_allow_runs_the_layer(self):
        self.write(f"{CRATE}/ok.rs", "#[allow(clippy::cast_possible_truncation)]\nfn ok() {}\n")
        head = self.commit("add allow")
        local = gate.gate(self.repo, self.base, head, {"panic-allow"}, False)
        self.assertEqual([name for name, _ in local], [gate.PANIC_ALLOW_CHECK])
        self.assertEqual(gate.gate(self.repo, self.base, head, {"crash-allow"}, False), [])


if __name__ == "__main__":
    unittest.main()
