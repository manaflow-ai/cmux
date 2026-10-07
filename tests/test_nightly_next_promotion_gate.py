#!/usr/bin/env python3
"""main's promote-nightly-next job gates on the push run's Linux checks.

feat-cmux-next's cmux-next.yml requests a promotion once its Linux checks job passes. The
nightly build is the Release compile gate: it compiles Release itself and publishes nothing when
that fails. A gate on the mini Release compile held each green head for its queue (39 min) and
compile (8 min) before nightly-next could start (beb1773b2fb, 10-07).
"""

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
CHECKS_JOB = "cmux-next checks (god files, concurrency, crash safety, l10n)"


class PromotionGate(unittest.TestCase):
    def script(self) -> str:
        workflow = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8"))
        steps = workflow["jobs"]["promote-nightly-next"]["steps"]
        return next(step for step in steps if step.get("name") == "Move nightly-next")["with"]["script"]

    def test_the_linux_checks_job_gates_the_promotion(self):
        script = self.script()
        self.assertIn(f"const requiredJob = '{CHECKS_JOB}';", script)
        self.assertIn("job.name === requiredJob && job.conclusion === 'success'", script)

    def test_the_mini_release_compile_is_not_required(self):
        self.assertNotIn("cmux-next Release compile", self.script())


if __name__ == "__main__":
    unittest.main()
