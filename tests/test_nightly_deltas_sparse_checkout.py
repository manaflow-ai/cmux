#!/usr/bin/env python3
"""generate-nightly-deltas checks out only scripts/ of the build ref, and the reel's apt install retries.

The deltas job holds the whole nightly mini. Run 42033609306 spent 96 s of that hold (14:11:49-14:13:25Z) on a
full clone of the build ref, then read nothing from it outside scripts/ and the root .xcode-version that
select-ci-xcode.sh reads (cone mode keeps root files). republish-nightly-deltas shares the step through its
anchor and reads only .publish-tooling. Same shape as the signer's sparse controls checkout (#36162).

The same run's publish-nightly-reel timed out in "Install ffmpeg" at its 6 min limit on a slow apt mirror
(14:15:28Z), so apt now retries with a per-request timeout under a 10 min step limit.
"""

from pathlib import Path
import re
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
REEL_SCRIPT = ROOT / "scripts/ci/nightly-steps/reel-install-ffmpeg.sh"
CHECKOUT = "Checkout build ref"
JOBS = ("generate-nightly-deltas", "republish-nightly-deltas")
# A repo path a run line reads from the build checkout, not from .publish-tooling.
REPO_PATH = re.compile(r"(?<![\w./-])(?:\./)?((?:scripts|\.github)/[\w./-]+)")


def jobs() -> dict:
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]


def checkout(job: str) -> dict:
    return next(s for s in jobs()[job]["steps"] if s.get("name") == CHECKOUT)


class DeltasSparseCheckoutTests(unittest.TestCase):
    def test_build_ref_checkout_is_sparse(self) -> None:
        for job in JOBS:
            with self.subTest(job=job):
                step = checkout(job)["with"]
                self.assertEqual(step.get("filter"), "blob:none")
                self.assertEqual(step.get("sparse-checkout", "").split(), ["scripts"])
                # Cone mode keeps the root files, and select-ci-xcode.sh reads .xcode-version.
                self.assertNotIn("sparse-checkout-cone-mode", step)

    def test_every_path_the_job_reads_is_checked_out(self) -> None:
        sparse = checkout("generate-nightly-deltas")["with"]["sparse-checkout"].split()
        for job in JOBS:
            for step in jobs()[job]["steps"]:
                for path in REPO_PATH.findall(step.get("run", "")):
                    with self.subTest(job=job, step=step.get("name"), path=path):
                        self.assertTrue(any(path.startswith(f"{d}/") for d in sparse), path)
                        self.assertTrue((ROOT / path).exists(), path)


class ReelFfmpegInstallTests(unittest.TestCase):
    def test_apt_retries_inside_a_longer_step_limit(self) -> None:
        step = next(s for s in jobs()["publish-nightly-reel"]["steps"] if s.get("name") == "Install ffmpeg")
        self.assertGreaterEqual(step["timeout-minutes"], 10)
        script = REEL_SCRIPT.read_text()
        for command in ("apt-get update", "apt-get install"):
            line = next(l for l in script.splitlines() if command in l)
            self.assertIn("Acquire::Retries=", line)
            self.assertIn("Acquire::http::Timeout=", line)


if __name__ == "__main__":
    unittest.main()
