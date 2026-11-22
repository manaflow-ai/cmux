#!/usr/bin/env python3
"""The cmux-tui leg built natively on an owned Mac starts from feat-cmux-next's warm target.

"Build cmux-tui (native)" in .github/workflows/cmux-tui-build-package.yml (the macOS fallback
of cmux-tui-artifacts.yml, and a feat-cmux-next push leg on a free mini) built into
cmux-tui/target, which actions/checkout's clean empties every job: every native leg compiled
cold. Run 44947539922 (2026-11-21): the step took 2h01m and the 120 min job timeout cancelled
the next step, so the fallback shipped nothing. scripts/ci/cmux-tui-mac-warm-target.sh keeps a
base tree that feat-cmux-next builds record, and every native leg on that Mac clones it.

This runs the script in a scratch repository and checks that:
- off an owned Mac it does nothing (cmux-tui/target stays the cold in-workspace directory);
- with no base it links cmux-tui/target to this runner's tree and says "miss";
- record makes this runner's tree the base, with the commit and source mtimes;
- another runner's restore clones the base ("hit"), so the build output is there, and an
  unchanged source gets the mtime it was built with while a changed one keeps its new mtime;
- the workflow restores before the native build and records only after "Stage binary", on
  feat-cmux-next and never for a pull request.

Run: python3 tests/test_ci_cmux_tui_mac_warm_target.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent
sys.path.insert(0, str(TESTS))
import git_fixture_env  # noqa: E402
import workflow_jobs  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-build-package.yml"
SCRIPT = "scripts/ci/cmux-tui-mac-warm-target.sh"
TRIPLE = "aarch64-apple-darwin"


class MacWarmTargetScript(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="mac-warm-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "repo"
        (self.repo / "scripts" / "ci").mkdir(parents=True)
        shutil.copy2(ROOT / SCRIPT, self.repo / SCRIPT)
        shutil.copy2(ROOT / "scripts" / "blacksmith-testbox-source-mtimes.py",
                     self.repo / "scripts" / "blacksmith-testbox-source-mtimes.py")
        (self.repo / "cmux-tui" / "src").mkdir(parents=True)
        (self.repo / "cmux-tui" / "rust-toolchain.toml").write_text('[toolchain]\nchannel = "1.95.0"\n')
        (self.repo / "cmux-tui" / "src" / "same.rs").write_text("fn same() {}\n")
        (self.repo / "cmux-tui" / "src" / "changed.rs").write_text("fn before() {}\n")
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("commit", "-qm", "fixture")
        self.cache = self.tmp / "cache"

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True, text=True,
                              env=git_fixture_env.fixture_env(os.environ.copy())).stdout

    def run_script(self, command: str, runner: str) -> str:
        env = {"PATH": os.environ["PATH"], "HOME": str(self.tmp), "RUNNER_NAME": runner,
               "RUNNER_TEMP": str(self.tmp), "LTO": "fat", "CMUX_TUI_MAC_WARM_ROOT": str(self.cache)}
        done = subprocess.run(["bash", str(self.repo / SCRIPT), command, TRIPLE], env=env,
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        return done.stdout + done.stderr

    @property
    def link(self) -> Path:
        return self.repo / "cmux-tui" / "target"

    def test_off_an_owned_mac_it_does_nothing(self) -> None:
        out = self.run_script("restore", "GitHub Actions 3")
        self.assertIn("not an owned Mac", out)
        self.assertFalse(self.link.exists() or self.link.is_symlink())
        self.assertFalse(self.cache.exists())

    def test_base_recorded_on_one_runner_warms_another(self) -> None:
        out = self.run_script("restore", "mini-1-glaeda-6")
        self.assertIn("mac warm target: miss", out)
        self.assertTrue(self.link.is_symlink())
        mine = Path(os.readlink(self.link))
        self.assertTrue(str(mine).startswith(str(self.cache)), mine)
        # The "build": output in the kept tree, sources at the mtime it was built with.
        built = mine / TRIPLE / "release" / "cmux-tui"
        built.parent.mkdir(parents=True)
        built.write_text("binary")
        for name in ("same.rs", "changed.rs"):
            os.utime(self.repo / "cmux-tui" / "src" / name, (1_000_000_000, 1_000_000_000))
        out = self.run_script("record", "mini-1-glaeda-6")
        self.assertIn("kept as feat-cmux-next's base", out)
        bases = list(self.cache.glob("*/base"))
        self.assertEqual(len(bases), 1, bases)
        self.assertEqual((bases[0] / ".cmux-tui-mac-warm-source").read_text().strip(),
                         self.git("rev-parse", "HEAD").strip())

        # The next job on another runner of the Mac: a fresh checkout (new mtimes), one file changed.
        self.link.unlink()
        for name in ("same.rs", "changed.rs"):
            os.utime(self.repo / "cmux-tui" / "src" / name, None)
        (self.repo / "cmux-tui" / "src" / "changed.rs").write_text("fn after() {}\n")
        out = self.run_script("restore", "mini-1-glaeda-11")
        self.assertIn("mac warm target: hit", out)
        theirs = Path(os.readlink(self.link))
        self.assertNotEqual(theirs, mine)
        self.assertEqual((self.link / TRIPLE / "release" / "cmux-tui").read_text(), "binary")
        self.assertEqual(int((self.repo / "cmux-tui" / "src" / "same.rs").stat().st_mtime), 1_000_000_000)
        self.assertGreater((self.repo / "cmux-tui" / "src" / "changed.rs").stat().st_mtime, 1_000_000_000)

    def test_record_without_the_kept_tree_records_nothing(self) -> None:
        out = self.run_script("record", "mini-1-glaeda-6")
        self.assertIn("nothing to record", out)
        self.assertEqual(list(self.cache.glob("*/base")), [])

    def test_an_existing_target_is_left_alone(self) -> None:
        self.link.mkdir()
        out = self.run_script("restore", "mini-1-glaeda-6")
        self.assertIn("already exists", out)
        self.assertFalse(self.link.is_symlink())


class MacWarmTargetWorkflow(unittest.TestCase):
    def steps(self) -> list[dict]:
        return workflow_jobs.jobs(WORKFLOW)["build"]["steps"]

    def index(self, name: str) -> int:
        names = [s.get("name") for s in self.steps()]
        self.assertIn(name, names)
        return names.index(name)

    def test_restore_before_the_native_build_and_record_after_staging(self) -> None:
        restore = self.index("Start from feat-cmux-next's warm Mac target")
        build = self.index("Build cmux-tui (native)")
        stage = self.index("Stage binary")
        record = self.index("Keep the warm Mac target (feat-cmux-next)")
        self.assertLess(restore, build)
        self.assertLess(stage, record)
        steps = self.steps()
        self.assertIn(f"{SCRIPT} restore", steps[restore]["run"])
        self.assertIn(f"{SCRIPT} record", steps[record]["run"])
        self.assertIn("matrix.cross == false", steps[restore]["if"])
        condition = steps[record]["if"]
        self.assertIn("success()", condition)
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", condition)
        self.assertIn("github.event_name != 'pull_request'", condition)


if __name__ == "__main__":
    unittest.main()
