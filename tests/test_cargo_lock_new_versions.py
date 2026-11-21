"""scripts/cmux-next/cargo-lock-new-versions.py and its pre-push gate check: a changed Cargo.lock adds no crate version
that no base Cargo.lock has, unless a pushed commit says `Cargo-Lock-New-Versions: <why>`.

2026-11-12: #42155 called itself a lock alignment that added no versions; it added seven.
"""
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures/cargo-lock-new-versions"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


git_fixture_env = load("git_fixture_env", Path(__file__).resolve().parent / "git_fixture_env.py")
check = load("cargo_lock_new_versions", SOURCE / "scripts/cmux-next/cargo-lock-new-versions.py")
BASE_A, BASE_B, HEAD_A = ((FIXTURES / name).read_text() for name in ("base-a.lock", "base-b.lock", "head-a.lock"))


class ParseAndCompare(unittest.TestCase):
    def test_parses_packages_and_sources(self):
        self.assertEqual([(n, v, s is not None) for n, v, s in check.parse_lock(HEAD_A)],
                         [("app", "0.2.0", False), ("libc", "0.2.170", True), ("serde", "1.0.201", True),
                          ("tiny-git", "0.3.0", True)])

    def test_flags_only_versions_absent_from_every_base_lock(self):
        # libc 0.2.170 is in the other base lock: not new. app is a path package: skipped.
        self.assertEqual(check.new_versions(check.base_set([BASE_A, BASE_B]), [("a/Cargo.lock", HEAD_A)]),
                         [("a/Cargo.lock", "serde", "1.0.201"), ("a/Cargo.lock", "tiny-git", "0.3.0")])

    def test_an_unchanged_lock_has_nothing_new(self):
        self.assertEqual(check.new_versions(check.base_set([BASE_A, BASE_B]), [("a/Cargo.lock", BASE_A)]), [])

    def test_allow_line_needs_a_reason_at_line_start(self):
        self.assertEqual(check.allowed("subject\n\nCargo-Lock-New-Versions: serde for a CVE\n"), "serde for a CVE")
        self.assertIsNone(check.allowed("Cargo-Lock-New-Versions:   \n"))
        # The reason is on the key's own line, and a subject naming the tool is not the key.
        self.assertIsNone(check.allowed("Cargo-Lock-New-Versions:\nnext paragraph"))
        self.assertIsNone(check.allowed("cargo-lock-new-versions: name the parser's entry type"))
        self.assertIsNone(check.allowed("this adds no Cargo-Lock-New-Versions: x"))
        self.assertIsNone(check.allowed(""))


class GitRange(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cmux-new-versions-test-")
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.env = git_fixture_env.fixture_env({
            **os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "F", "GIT_AUTHOR_EMAIL": "f@e",
            "GIT_COMMITTER_NAME": "F", "GIT_COMMITTER_EMAIL": "f@e"})
        git_fixture_env.init_repo(self.repo, env=self.env)
        self.write("a/Cargo.lock", BASE_A)
        self.write("b/Cargo.lock", BASE_B)
        # The gate runs the check only at a commit that has it (check_script).
        self.write("scripts/cmux-next/cargo-lock-new-versions.py",
                   (SOURCE / "scripts/cmux-next/cargo-lock-new-versions.py").read_text())
        self.base = self.commit("base")

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message):
        subprocess.run(["git", "-C", str(self.repo), "add", "-A"], env=self.env, check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", message], env=self.env, check=True)
        return subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"], env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def run_check(self, head):
        return subprocess.run([sys.executable, "-I", str(SOURCE / "scripts/cmux-next/cargo-lock-new-versions.py"),
                               "--repo", str(self.repo), "--base", self.base, "--head", head],
                              env=self.env, capture_output=True, text=True)

    def test_a_lock_change_adding_versions_is_refused_unless_a_commit_says_so(self):
        self.write("a/Cargo.lock", HEAD_A)
        head = self.commit("cargo: align versions, adds none")
        result = self.run_check(head)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         ["new: a/Cargo.lock: serde 1.0.201", "new: a/Cargo.lock: tiny-git 0.3.0"])
        self.write("README", "x")
        allowed = self.commit("docs\n\nCargo-Lock-New-Versions: serde 1.0.201 fixes a parse bug")
        result = self.run_check(allowed)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("allowed", result.stdout)

    def test_a_range_without_a_lock_change_passes(self):
        self.write("README", "x")
        self.assertEqual(self.run_check(self.commit("docs")).returncode, 0)

    def test_the_gate_reports_the_findings_and_skips_a_range_without_locks(self):
        gate = load("cmux_next_prepush_gate_new_versions", SOURCE / "scripts/cmux-next/prepush-gate.py")
        self.write("a/Cargo.lock", HEAD_A)
        head = self.commit("align")
        # A hook run reads the installed copy (TRUSTED), never the pushed one.
        script = SOURCE / "scripts/cmux-next/cargo-lock-new-versions.py"
        with tempfile.TemporaryDirectory() as trusted:
            (Path(trusted) / script.name).write_bytes(script.read_bytes())
            self.assertEqual(gate.new_crate_versions(self.repo, self.base, head, Path(trusted)),
                             ["a/Cargo.lock: serde 1.0.201", "a/Cargo.lock: tiny-git 0.3.0"])
        self.assertEqual(gate.new_crate_versions(self.repo, self.base, head),
                         ["a/Cargo.lock: serde 1.0.201", "a/Cargo.lock: tiny-git 0.3.0"])
        self.write("README", "x")
        docs = self.commit("docs")
        self.assertEqual(gate.new_crate_versions(self.repo, head, docs), [])


if __name__ == "__main__":
    unittest.main()
