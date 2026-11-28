"""The readiness workflow's "Wait for the gate's verdict" step, run with a fake gh.

A gate run the fleet's runner rescue cancels is rerun as a new attempt under the
same id (gate run 46143301440). Readiness run 46142606751 read it as cancelled
13 s before attempt 2 started and failed main, which reset the ios-app-store-live
probe's readiness count. The step must wait out a cancelled run with nothing
newer for a rerun, follow a newer run, and never turn "cancelled" into a red.
"""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ios-app-review-readiness.yml"


def wait_step_script() -> str:
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    for job in doc["jobs"].values():
        for step in job.get("steps", []):
            if step.get("name") == "Wait for the gate's verdict":
                return step["run"]
    raise AssertionError("no 'Wait for the gate's verdict' step")


FAKE_GH = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    # args: api [-X POST] PATH ...; states come one per run read from $FAKE/states
    echo "$*" >> "$FAKE/calls"
    if [[ "$2" == "-X" ]]; then echo "$4" >> "$FAKE/posts"; exit 0; fi
    case "$2" in
      *"/actions/runs?"*) cat "$FAKE/next" 2>/dev/null; exit 0 ;;
      *"/actions/runs/"*)
        line="$(head -n1 "$FAKE/states")"
        [[ "$(wc -l < "$FAKE/states")" -gt 1 ]] && sed -i '1d' "$FAKE/states"
        echo "$line" ;;
    esac
    """
)
# Each date call moves 120 s on, as each loop's sleep would.
FAKE_DATE = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    n=$(cat "$FAKE/clock" 2>/dev/null || echo 1000); echo $((n + 120)) > "$FAKE/clock"; echo "$n"
    """
)


class GateWaitTest(unittest.TestCase):
    def run_step(self, states: list[str], next_run: str = "", grace: str = "1800"):
        d = Path(tempfile.mkdtemp())
        bin_ = d / "bin"
        bin_.mkdir()
        for name, body in (("gh", FAKE_GH), ("date", FAKE_DATE), ("sleep", "#!/bin/sh\nexit 0\n")):
            f = bin_ / name
            f.write_text(body)
            f.chmod(f.stat().st_mode | stat.S_IEXEC)
        (d / "states").write_text("\n".join(states) + "\n")
        (d / "next").write_text(next_run)
        env = dict(
            os.environ,
            PATH=f"{bin_}:{os.environ['PATH']}",
            FAKE=str(d),
            RUN_ID="100",
            CANCEL_GRACE_S=grace,
            GITHUB_SERVER_URL="https://github.com",
            GITHUB_REPOSITORY="o/r",
            GITHUB_RUN_ID="999",
        )
        p = subprocess.run(["bash", "-c", wait_step_script()], env=env, capture_output=True, text=True, timeout=60)
        posts = (d / "posts").read_text() if (d / "posts").exists() else ""
        return p, posts

    def test_rerun_after_a_cancel_carries_its_pass(self):
        # Before the fix this exited 1 on the first "completed cancelled" read.
        p, posts = self.run_step(["completed cancelled", "queued ", "in_progress ", "completed success"])
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("The App Review gate passed", p.stdout)
        self.assertEqual(posts, "")

    def test_rerun_that_fails_is_a_red(self):
        p, _ = self.run_step(["completed cancelled", "in_progress ", "completed failure"])
        self.assertEqual(p.returncode, 1)
        self.assertIn("concluded failure", p.stdout)

    def test_newer_run_is_followed(self):
        p, _ = self.run_step(["completed cancelled", "completed success"], next_run="101")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("following run 101", p.stdout)

    def test_cancel_with_nothing_after_grace_cancels_itself_not_a_red_verdict(self):
        p, posts = self.run_step(["completed cancelled"], grace="600")
        self.assertIn("repos/o/r/actions/runs/999/cancel", posts)
        self.assertIn("no verdict", p.stdout + p.stderr)
        self.assertNotIn("concluded cancelled", p.stdout)


if __name__ == "__main__":
    unittest.main()
