"""cmux-next-hot-verify.yml: a reused pool workspace's dropped .git comes back seeded with the VM's git mirror.

Dropping .git used to drop the mirror alternate the runner's job-start hook lends a pool workspace, so
actions/checkout cloned from github.com, and a stalled fetch there failed the plan (cmux#57667 run 45787715231).
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-hot-verify.yml"
DROP = "Drop a reused workspace's repository"


def drop_steps() -> list[tuple[str, dict]]:
    doc = yaml.safe_load(WORKFLOW.read_text())
    out = []
    for name, job in doc["jobs"].items():
        for step in job.get("steps", []):
            if step.get("name") == DROP:
                out.append((name, step))
    return out


def git(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class HotVerifyMirrorSeedTest(unittest.TestCase):
    def _publisher_steps(self) -> tuple[dict, dict]:
        doc = yaml.safe_load(WORKFLOW.read_text())
        steps = doc["jobs"]["publish"]["steps"]
        action_index = next(i for i, step in enumerate(steps) if step.get("name") == "Checkout the publisher")
        mirror_index = next(i for i, step in enumerate(steps) if step.get("name") == "Pool mirror: checkout the publisher")
        self.assertGreater(mirror_index, action_index)
        return steps[action_index], steps[mirror_index]

    def test_publisher_pool_mirror_replaces_blobless_action_checkout(self) -> None:
        action, mirror = self._publisher_steps()
        self.assertEqual(action["if"], "${{ !startsWith(runner.name, 'cmux-runner-pool-') }}")
        self.assertEqual(mirror["if"], "${{ startsWith(runner.name, 'cmux-runner-pool-') }}")
        self.assertEqual(mirror["timeout-minutes"], 8)
        self.assertEqual(mirror["env"]["SPARSE"], action["with"]["sparse-checkout"])
        run = mirror["run"]
        for expected in (
            "/var/lib/cmux-git/cmux.git",
            'mirror="${CMUX_GIT_MIRROR:-/var/lib/cmux-git/cmux.git}/objects"',
            "objects/info/alternates",
            "git fetch --no-tags --no-recurse-submodules --depth=1",
            "git config core.sparseCheckout true",
            "git checkout -q --detach \"$SHA\"",
        ):
            self.assertIn(expected, run)
        self.assertNotIn("--filter", run)

    def test_every_drop_step_seeds_the_mirror(self) -> None:
        steps = drop_steps()
        self.assertEqual(len(steps), 5, [n for n, _ in steps])
        for name, step in steps:
            run = step["run"]
            self.assertIn("/var/lib/cmux-git/cmux.git", run, name)
            self.assertIn("objects/info/alternates", run, name)
            self.assertIn("update-ref --no-deref HEAD", run, name)

    def test_plan_fetches_are_retried_with_a_low_speed_bound(self) -> None:
        doc = yaml.safe_load(WORKFLOW.read_text())
        plan = next(s for s in doc["jobs"]["plan"]["steps"] if s.get("name") == "Plan")["run"]
        self.assertIn("http.lowSpeedTime=30", plan)
        self.assertNotIn("timeout 600 git fetch -q --no-tags --filter=blob:none --shallow-since=\"$since\"", plan)
        self.assertNotIn('timeout 120 git fetch -q --no-tags --filter=blob:none --deepen=', plan)

    def _run(self, ws: Path, mirror: Path) -> subprocess.CompletedProcess:
        _, step = drop_steps()[0]
        env = dict(os.environ, GITHUB_WORKSPACE=str(ws), GITHUB_REPOSITORY="manaflow-ai/cmux",
                   GITHUB_SERVER_URL="https://github.com", CMUX_GIT_MIRROR=str(mirror))
        return subprocess.run(["bash", "-e", "-c", step["run"]], env=env, capture_output=True, text=True)

    def test_seeded_repository_survives_checkout_reuse_and_reads_the_mirror(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            src = t / "src"
            src.mkdir()
            git("init", "-q", str(src))
            (src / "scripts").mkdir()
            (src / "scripts" / "a.txt").write_text("a\n")
            git("-c", "user.name=t", "-c", "user.email=t@t", "add", ".", cwd=src)
            git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "c", cwd=src)
            sha = git("rev-parse", "HEAD", cwd=src)
            mirror = t / "cmux.git"
            git("clone", "-q", "--bare", str(src), str(mirror))
            (mirror / "cmux-ready").write_text("")
            ws = t / "ws"
            (ws / ".git").mkdir(parents=True)  # a reused workspace's old repository
            (ws / "stale.txt").write_text("old job\n")
            r = self._run(ws, mirror)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("seeded with the runner's git mirror", r.stdout)
            self.assertEqual(git("config", "remote.origin.url", cwd=ws), "https://github.com/manaflow-ai/cmux")
            # actions/checkout's reuse path: clean and reset --hard HEAD must pass
            git("clean", "-ffdx", cwd=ws)
            git("reset", "--hard", "HEAD", cwd=ws)
            self.assertFalse((ws / "stale.txt").exists())
            # the mirror's objects are readable with no fetch
            git("cat-file", "-e", f"{sha}^{{commit}}", cwd=ws)

    def test_no_mirror_keeps_the_plain_drop(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ws = Path(tmp) / "ws"
            (ws / ".git").mkdir(parents=True)
            r = self._run(ws, Path(tmp) / "absent.git")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertFalse((ws / ".git").exists())


if __name__ == "__main__":
    unittest.main()
