#!/usr/bin/env python3
"""scripts/ci/tip-test-compile.sh: the per-push feat-cmux-next test compile.

Runs the script against a fake cmux-ci client and a fake GitHub API and checks
its verdict, report and exit: red only for a test target that does not compile,
a queued step cancelled when a newer push waits or the queue is too slow, and a
started step never cancelled.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "tip-test-compile.sh"
STEP = "0123456789abcdef01234567"
MARKER = "compile-tests: a test target did not compile"

# A fake client: `run` prints the step line, then waits until the step leaves the
# queue (a file holds its state) and prints the log; `status` and `cancel` read and
# write that state; every call is recorded.
CLIENT = r"""#!/usr/bin/env bash
dir="$(dirname "$0")"
echo "$*" >> "$dir/calls"
case "$1" in
  run)
    printf '%s\n' "$*" > "$dir/run-args"
    echo "cmux-ci: step __STEP__ (light, key k)" >&2
    while [ "$(cat "$dir/state")" = queued ]; do sleep 0.05; done
    [ "$(cat "$dir/state")" = cancelled ] && { echo "cmux-ci: step __STEP__ cancelled" >&2; exit 75; }
    cat "$dir/log"; exit "$(cat "$dir/exit")" ;;
  status) echo "{\"state\": \"$(cat "$dir/state")\"}" ;;
  cancel) echo cancelled > "$dir/state" ;;
esac
""".replace("__STEP__", STEP)


class TipTestCompileTests(unittest.TestCase):
    def run_script(self, *, log: str = "", exit: int = 0, state: str = "running", runs: list | None = None,
                   queue_limit: int = 600, client: bool = True, start_after: float | None = None):
        scratch = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(scratch)])
        fake = scratch / "cmux-ci"
        if client:
            fake.write_text(CLIENT)
            fake.chmod(0o755)
        (scratch / "state").write_text(state + "\n")
        (scratch / "log").write_text(log + "\n")
        (scratch / "exit").write_text(str(exit))
        api = scratch / "gh-api"
        api.write_text("#!/usr/bin/env bash\ncat \"$(dirname \"$0\")/runs.json\"\n")
        api.chmod(0o755)
        (scratch / "runs.json").write_text(json.dumps({"workflow_runs": runs or []}))
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "RUNNER_"))}
        env.update(REF="a" * 40, BASE="b" * 40, RUN_ID="100", GITHUB_REPOSITORY="manaflow-ai/cmux",
                   WORKFLOW_FILE="cmux-next-tip-test-compile.yml", CMUX_CI_CLIENT=str(fake), TIP_GH_API=str(api),
                   TIP_POLL_SECONDS="0.1", TIP_QUEUE_LIMIT_SECONDS=str(queue_limit), OUT_DIR=str(scratch / "out"))
        proc = subprocess.Popen(["bash", str(SCRIPT)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if start_after is not None:
            # The step leaves the queue and starts after a while (a worker took it).
            try:
                proc.wait(timeout=start_after)
            except subprocess.TimeoutExpired:
                (scratch / "state").write_text("running\n")
        out, _ = proc.communicate(timeout=60)
        verdict = (scratch / "out" / "verdict").read_text().strip()
        report = (scratch / "out" / "report.md").read_text()
        calls = (scratch / "calls").read_text() if (scratch / "calls").exists() else ""
        run_args = (scratch / "run-args").read_text() if (scratch / "run-args").exists() else ""
        return proc.returncode, verdict, report, calls, run_args, out

    def test_a_compiled_tip_passes_and_the_step_runs_in_the_background_class(self) -> None:
        code, verdict, report, calls, run_args, out = self.run_script(
            log="compile-tests: every planned test target compiled (7)")
        self.assertEqual((code, verdict), (0, "pass"), out)
        self.assertEqual(report, "")
        self.assertIn("--background", run_args)
        self.assertIn(f"--arg=compile-tests --arg={'b' * 40}", run_args)
        self.assertNotIn("cancel", calls)

    def test_a_target_that_does_not_compile_is_red_with_its_target_and_errors(self) -> None:
        log = "\n".join([
            "/Users/runner/w/1/Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests/AgentPaneTabRowHolesTests.swift:103:21: "
            "error: type 'HoleRecordingPage' does not conform to protocol 'PageChromiumPage'",
            "compile-tests results:",
            "CmuxNext                           build-tests                    FAILED        214s",
            "CMUXAuthCore                       build-tests                    compiled        7s",
            f"{MARKER} (1 of 7)",
        ])
        code, verdict, report, _, _, out = self.run_script(log=log, exit=1)
        self.assertEqual((code, verdict), (1, "fail"), out)
        self.assertIn("::error", out)
        self.assertIn("a" * 40, report)
        self.assertIn("CmuxNext                           build-tests                    FAILED", report)
        self.assertNotIn("CMUXAuthCore", report)
        self.assertIn("Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests/AgentPaneTabRowHolesTests.swift:103:21: error:", report)
        self.assertNotIn("/Users/runner", report)

    def test_the_marker_is_red_whatever_the_exit(self) -> None:
        code, verdict, *_ = self.run_script(log=f"{MARKER}: CmuxNext\nfatal: not a submodule", exit=128)
        self.assertEqual((code, verdict), (1, "fail"))

    def test_anything_else_is_no_verdict_and_never_red(self) -> None:
        for status in (1, 3, 124):
            with self.subTest(status=status):
                code, verdict, _, _, _, out = self.run_script(log="error: setup failed", exit=status)
                self.assertEqual((code, verdict), (0, "none"), out)
                self.assertNotIn("::error", out)

    def test_a_newer_push_waiting_cancels_the_queued_step(self) -> None:
        runs = [{"id": 101, "status": "pending", "head_sha": "c" * 40}, {"id": 100, "status": "in_progress", "head_sha": "a" * 40}]
        code, verdict, _, calls, _, out = self.run_script(state="queued", runs=runs)
        self.assertEqual((code, verdict), (0, "superseded"), out)
        self.assertIn(f"cancel {STEP}", calls)

    def test_an_older_or_finished_run_supersedes_nothing(self) -> None:
        runs = [{"id": 99, "status": "pending", "head_sha": "9" * 40}, {"id": 101, "status": "completed", "head_sha": "c" * 40}]
        code, verdict, _, calls, _, out = self.run_script(state="queued", runs=runs, start_after=1.0,
                                                          log="compile-tests: every planned test target compiled (1)")
        self.assertEqual((code, verdict), (0, "pass"), out)
        self.assertNotIn("cancel", calls)

    def test_a_started_step_is_never_cancelled_even_when_a_newer_push_waits(self) -> None:
        runs = [{"id": 101, "status": "pending", "head_sha": "c" * 40}]
        code, verdict, _, calls, _, out = self.run_script(state="queued", runs=runs, start_after=0.0,
                                                          log="compile-tests: every planned test target compiled (1)")
        self.assertEqual((code, verdict), (0, "pass"), out)
        self.assertNotIn("cancel", calls)

    def test_a_step_queued_past_the_limit_is_cancelled_with_no_verdict(self) -> None:
        code, verdict, _, calls, _, out = self.run_script(state="queued", queue_limit=0)
        self.assertEqual((code, verdict), (0, "none"), out)
        self.assertIn(f"cancel {STEP}", calls)
        self.assertIn("::warning", out)

    def test_no_client_is_no_verdict(self) -> None:
        code, verdict, _, _, _, out = self.run_script(client=False)
        self.assertEqual((code, verdict), (0, "none"), out)


if __name__ == "__main__":
    unittest.main()
