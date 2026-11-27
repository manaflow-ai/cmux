#!/usr/bin/env python3
"""Detector: a cmux-vm job never runs Bun under a HOME it cannot write.

Leo: "im pretty sue this is all problems on our end with either rendering or acpmux talking to claude or codex"

2026-11-27: pool runners 7 and 8 ran with HOME=/home/runner but without their own-home bind, so setup-bun and
bun install failed EACCES (cmux runs 46014738408, 46058588655) and cmux-vm production stayed on a build without
cmux#61044 for hours while Cloud machines failed to start. scripts/ci/job-own-home.sh moves such a job's HOME
under RUNNER_TEMP; this test checks the script and that every Bun job in cmux-vm.yml runs it first.
"""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/job-own-home.sh"
WORKFLOW = ROOT / ".github/workflows/cmux-vm.yml"


def run(home: Path, temp: Path) -> dict[str, str]:
    env_file = temp / "github_env"
    env_file.write_text("")
    env = {"PATH": os.environ["PATH"], "HOME": str(home), "RUNNER_TEMP": str(temp), "GITHUB_ENV": str(env_file)}
    done = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True, check=False)
    assert done.returncode == 0, done.stderr
    return dict(line.split("=", 1) for line in env_file.read_text().splitlines() if line)


class JobOwnHome(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.temp = self.tmp / "runner-temp"
        self.temp.mkdir()

    def tearDown(self) -> None:
        for path in [self.tmp, *self.tmp.rglob("*")]:
            if path.is_dir():
                path.chmod(stat.S_IRWXU)
        subprocess.run(["rm", "-rf", str(self.tmp)], check=False)

    def test_a_writable_home_stays_and_bun_gets_its_own_temp_dir(self) -> None:
        (self.home / ".bun/bin").mkdir(parents=True)
        out = run(self.home, self.temp)
        self.assertNotIn("HOME", out)
        self.assertEqual(out["BUN_TMPDIR"], str(self.temp / "bun-tmp"))
        self.assertTrue((self.temp / "bun-tmp").is_dir())

    @unittest.skipIf(os.geteuid() == 0, "root writes every directory")
    def test_an_unwritable_home_moves_under_runner_temp(self) -> None:
        (self.home / ".gitconfig").write_text("[user]\n\tname = ci\n")
        self.home.chmod(stat.S_IRUSR | stat.S_IXUSR)
        out = run(self.home, self.temp)
        self.assertEqual(out["HOME"], str(self.temp / "home"))
        self.assertIn("name = ci", (self.temp / "home/.gitconfig").read_text())

    @unittest.skipIf(os.geteuid() == 0, "root writes every directory")
    def test_an_unwritable_bun_dir_in_a_writable_home_moves_home(self) -> None:
        cache = self.home / ".bun/install/cache"
        cache.mkdir(parents=True)
        cache.chmod(stat.S_IRUSR | stat.S_IXUSR)
        out = run(self.home, self.temp)
        self.assertEqual(out["HOME"], str(self.temp / "home"))

    def test_every_bun_job_in_cmux_vm_runs_it_before_bun(self) -> None:
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        missing = []
        for name, job in jobs.items():
            steps = job.get("steps") or []
            bun = [i for i, s in enumerate(steps) if "setup-bun" in str(s.get("uses", "")) or "restore bun" in str(s.get("run", ""))]
            if not bun:
                continue
            own = [i for i, s in enumerate(steps) if "scripts/ci/job-own-home.sh" in str(s.get("run", ""))]
            if not own or own[0] > bun[0]:
                missing.append(name)
        self.assertEqual(missing, [], "jobs that set up Bun before scripts/ci/job-own-home.sh")


if __name__ == "__main__":
    unittest.main()
