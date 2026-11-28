#!/usr/bin/env python3
"""A media tour whose base app does not build still records the afters.

Run 45875892479 (job 140104053998, glaeda-13) failed in "Build the base app" on the base tree's own
webviews error (a99f6659's VirtualTranscript.tsx declared layoutGeometry twice). The step exited 1, so
the job ended there and lost the afters of update-when-idle, looks-gallery, theme-flourishes and
agent-session-search. The step now warns and leaves base_app empty, the capture step leaves
--base-app off, and the clips step's record() skips a role with no app. This test runs the steps'
scripts from the workflow against a failing fake build.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-media.yml"


def step(step_id: str) -> dict:
    doc = yaml.safe_load(WORKFLOW.read_text())
    for s in doc["jobs"]["tour"]["steps"]:
        if s.get("id") == step_id:
            return s
    raise AssertionError(f"no step {step_id}")


def record_function(run: str) -> str:
    m = re.search(r"^record\(\) \{.*?^\}$", run, re.S | re.M)
    assert m, "record() not defined"
    return m.group(0)


class BaseBuildKeepsAftersTest(unittest.TestCase):
    def build_base(self, build_rc: int):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            ci = d / "ci"
            ci.mkdir()
            build = ci / "media_build_app.sh"
            build.write_text("#!/usr/bin/env bash\n"
                             f'[ {build_rc} -eq 0 ] && echo "$4=/apps/base.app" >> "$GITHUB_OUTPUT"\n'
                             f"exit {build_rc}\n")
            build.chmod(0o755)
            out = d / "out"
            out.touch()
            env = {**os.environ, "BASE_APP": "", "EVENT_NAME": "push", "MEDIA_TOUR_CI": str(ci),
                   "RUNNER_TEMP": str(d), "RUNNER_NAME": "r", "TOUR_TAG": "t", "GITHUB_OUTPUT": str(out),
                   "MERGE_BASE": "a99f6659", "HOME": str(d)}
            p = subprocess.run(["bash", "-e", "-c", step("build_base")["run"]], env=env,
                               capture_output=True, text=True)
            return p.returncode, out.read_text(), p.stdout

    def test_a_base_that_does_not_build_ends_the_step_green_with_no_app(self):
        rc, output, stdout = self.build_base(1)
        self.assertEqual(rc, 0)
        self.assertNotIn("base_app=", output)
        self.assertIn("did not build", stdout)

    def test_a_base_that_builds_names_its_app(self):
        rc, output, _ = self.build_base(0)
        self.assertEqual(rc, 0)
        self.assertIn("base_app=/apps/base.app", output)

    def test_capture_leaves_an_empty_base_app_off(self):
        s = step("capture")
        self.assertEqual(s["env"]["BASE_APP"], "${{ steps.build_base.outputs.base_app }}")
        self.assertIn('${BASE_APP:+--base-app "$BASE_APP"}', s["run"])
        self.assertNotIn("--base-app \"${{", s["run"])

    def test_record_skips_a_role_with_no_app(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            calls = d / "python-calls"
            fake = d / "python3"
            fake.write_text(f'#!/usr/bin/env bash\necho "$@" >> "{calls}"\n'
                            'case "$2" in tours) echo tour-a.json ;; esac\n')
            fake.chmod(0o755)
            script = (record_function(step("clips")["run"])
                      + '\nbounded() { "$@"; }\nout=/o clips=c.py RUNNER_TEMP=/t\n'
                        'record before "" --before abc\nrecord after /apps/head.app\n')
            env = {**os.environ, "PATH": f"{d}:{os.environ['PATH']}"}
            p = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn("no before app", p.stdout)
            lines = calls.read_text().splitlines()
            self.assertFalse(any("--role before" in l for l in lines), lines)
            self.assertTrue(any("tour.py --app /apps/head.app" in l for l in lines), lines)


if __name__ == "__main__":
    unittest.main()
