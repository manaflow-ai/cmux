#!/usr/bin/env python3
"""cmux-next guards' vt-link-graph job, run as the workflow runs it, fails a pull
request whose package-notices.json libghostty-vt texts are for another
ghostty-next commit than vt-link-graph.json.

#19508 moved the ghostty-next gitlink and package-notices.json, and the graph
followed only with #19662 seven hours later: every release-path dogfood
package-distributions job failed in package_notices.py generate meanwhile, and
so does every branch cut in that window. The job checked only the graph
against the gitlink; this runs each of its steps in a sparse clone of this
checkout, with the notices on base and with them one commit behind.
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-guards.yml"
NOTICES = "cmux-tui/dist/notices/package-notices.json"
SPARSE = [
    "/scripts/cmux-next/notices/",
    "/cmux-tui/dist/",
    "/cmux-tui/build-support/notices/",
    "/cmux-tui/rust-toolchain.toml",
    # test_check_bundle_notices.py reads the repository notices (83cb35f5b2bd).
    "/THIRD_PARTY_LICENSES.md",
]
OTHER_COMMIT = "673a6369c4ba43cddcc94ff67361872824ffa528"


def job_scripts() -> list[str]:
    job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["vt-link-graph"]
    return [step["run"] for step in job["steps"] if "run" in step]


class Checkout:
    """A sparse clone of this checkout's HEAD: git objects for the gitlink and build.rs, the notices files on disk."""

    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / "repo"
        subprocess.run(["git", "clone", "-q", "--shared", "--no-checkout", str(ROOT), str(self.path)], check=True)
        subprocess.run(["git", "-C", str(self.path), "sparse-checkout", "set", "--no-cone", *SPARSE], check=True)
        # The worktree's own HEAD, so uncommitted notices edits are not what runs.
        head = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], check=True, capture_output=True,
                              text=True).stdout.strip()
        subprocess.run(["git", "-C", str(self.path), "checkout", "-q", "--detach", head], check=True)

    def set_notices_commit(self, commit: str):
        path = self.path / NOTICES
        data = json.loads(path.read_text(encoding="utf-8"))
        data["libghostty_vt"]["commit"] = commit
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

    def run_job(self) -> subprocess.CompletedProcess:
        output = []
        for script in job_scripts():
            result = subprocess.run(["bash", "-e", "-c", script], cwd=self.path, capture_output=True, text=True,
                                    timeout=120)
            output.append(result.stdout + result.stderr)
            if result.returncode != 0:
                return subprocess.CompletedProcess(script, result.returncode, "".join(output), "")
        return subprocess.CompletedProcess("job", 0, "".join(output), "")

    def close(self):
        self.temporary.cleanup()


class NoticesPairTests(unittest.TestCase):
    def checkout(self) -> Checkout:
        checkout = Checkout()
        self.addCleanup(checkout.close)
        return checkout

    def test_base_passes(self):
        result = self.checkout().run_job()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_notices_for_another_ghostty_next_commit_fail(self):
        checkout = self.checkout()
        checkout.set_notices_commit(OTHER_COMMIT)
        result = checkout.run_job()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"package-notices.json has libghostty-vt texts for ghostty-next {OTHER_COMMIT}", result.stdout)


if __name__ == "__main__":
    sys.exit(unittest.main())
