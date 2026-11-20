"""Run the workflow's submission step and check the commit handed to the fleet.

This is a manual regression check, not an additional CI gate. The existing
workflow expression evaluator resolves the run's environment.
The fleet client and tip lookup are recording fixtures; no build is submitted.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tests"))
from test_seed_derived_data import evaluate  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/cmux-next-perf-bench.yml"


class WorkflowRef(unittest.TestCase):
    def test_submission_measures_the_selected_commit(self):
        step = yaml.safe_load(WORKFLOW.read_text())["jobs"]["bench"]["steps"][0]
        expression = step["env"]["RUN_SHA"]
        selected, tip = "a" * 40, "b" * 40
        cases = (
            ("workflow_dispatch", "refs/heads/lane/bench-fix", selected),
            ("workflow_dispatch", "refs/heads/feat-cmux-next", selected),
            ("workflow_dispatch", "refs/heads/main", tip),
            ("schedule", "refs/heads/main", tip),
            ("schedule", "refs/heads/feat-cmux-next", selected),
        )
        for event, ref, expected in cases:
            with self.subTest(event=event, ref=ref), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                context = {"event_name": event, "ref": ref, "sha": selected}
                run_sha = evaluate(expression, {"github": context})
                client = root / "cmux-ci"
                client.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$PROOF_ARGS"\n')
                client.chmod(0o700)
                curl = root / "curl"
                curl.write_text("#!/bin/sh\nprintf '%s\\n' '" + tip + "'\n")
                curl.chmod(0o700)
                env = {
                    **os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                    "CMUX_CI_CLIENT": str(client), "PROOF_ARGS": str(root / "args"),
                    "RUN_SHA": run_sha, "RUNNER_TEMP": folder,
                    "GITHUB_STEP_SUMMARY": str(root / "summary"), "GH_TOKEN": "fixture",
                    "GITHUB_API_URL": "https://fixture.invalid", "GITHUB_REPOSITORY": "owner/repo",
                    "WORKER": "", "ROUNDS": "1", "BROWSERS": "cmux-budget",
                    "GATE": "1", "TABSWITCH": "off", "PALETTE": "off",
                }
                done = subprocess.run(["bash", "-c", step["run"]], env=env,
                                      capture_output=True, text=True, timeout=10)
                self.assertEqual(done.returncode, 0, done.stderr)
                args = (root / "args").read_text().splitlines()
                self.assertEqual(args[args.index("--ref") + 1], expected)


if __name__ == "__main__":
    unittest.main()
