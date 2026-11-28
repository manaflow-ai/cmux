"""rust-workspaces.yml's plan job skips the lock check and the checker's own tests on a pull request whose diff cannot
fail them (11-27: 30-40 s of the 63-67 s plan on 20 ready-to-land heads that changed no manifest), and runs both on a
push, with no base, or when the diff cannot be read."""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

SOURCE = Path(__file__).resolve().parents[1]
WORKFLOW = SOURCE / ".github/workflows/rust-workspaces.yml"


def plan_steps() -> list[dict]:
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]["plan"]["steps"]


def step(name: str) -> dict:
    return next(s for s in plan_steps() if s.get("name") == name)


class DiffGate(unittest.TestCase):
    def run_gate(self, files: list[str], event: str = "pull_request", base: bool = True) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@t"}
            git = lambda *a: subprocess.run(["git", *a], cwd=tmp, env=env, check=True, capture_output=True, text=True)
            git("init", "-q")
            (Path(tmp) / "README").write_text("a\n")
            git("add", "-A")
            git("commit", "-qm", "base")
            base_sha = git("rev-parse", "HEAD").stdout.strip()
            for f in files:
                (Path(tmp) / f).parent.mkdir(parents=True, exist_ok=True)
                (Path(tmp) / f).write_text("x\n")
            git("add", "-A")
            git("commit", "-qm", "head", "--allow-empty")
            out = Path(tmp) / "out"
            out.write_text("")
            subprocess.run(["bash", "-e", "-c", step("What this pull request changes")["run"]], cwd=tmp, check=True,
                           capture_output=True, env={**env, "EVENT_NAME": event, "BASE_SHA": base_sha if base else "",
                                                     "GITHUB_OUTPUT": str(out)})
            return dict(line.split("=", 1) for line in out.read_text().split())

    def test_rust_source_only_skips_both(self):
        self.assertEqual(self.run_gate(["cmux-tui/crates/acpmux/src/hub/mod.rs"]), {"locks": "false", "checker": "false"})

    def test_manifest_lock_cargo_config_or_toolchain_runs_the_lock_check(self):
        for f in ("cmux-tui/crates/acpmux/Cargo.toml", "cmux-next-ios/rust/Cargo.lock", "Native/x/.cargo/config.toml",
                  "cmux-tui/rust-toolchain.toml", "rust-toolchain"):
            with self.subTest(f=f):
                self.assertEqual(self.run_gate([f])["locks"], "true")

    def test_checker_files_run_its_tests(self):
        for f in (".github/scripts/rust-workspaces.py", ".github/scripts/test_rust_workspaces.py",
                  ".github/rust-workspaces.toml"):
            with self.subTest(f=f):
                self.assertEqual(self.run_gate([f])["checker"], "true")

    def test_push_or_no_base_runs_both(self):
        self.assertEqual(self.run_gate(["a.rs"], event="push"), {"locks": "true", "checker": "true"})
        self.assertEqual(self.run_gate(["a.rs"], base=False), {"locks": "true", "checker": "true"})

    def test_steps_read_the_gate_after_the_base(self):
        names = [s.get("name") for s in plan_steps()]
        gate = names.index("What this pull request changes")
        self.assertLess(names.index("Fetch the comparison base"), gate)
        for name, key in (("Test the workspace check", "checker"), ("Set up pinned Rust (lock check)", "locks"),
                          ("Every Cargo.lock matches its manifests", "locks")):
            self.assertLess(gate, names.index(name))
            self.assertIn(f"steps.diff.outputs.{key} != 'false'", step(name)["if"])


if __name__ == "__main__":
    unittest.main()
