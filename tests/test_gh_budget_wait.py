#!/usr/bin/env python3
"""scripts/ci/gh_budget_wait.sh: a rate-limited gh call waits for the reset and tries again.

nightly-next-tick.yml (which runs from main) lost promotions to "API rate limit exceeded for
installation" (2026-10-26, run 40325957281). These tests drive the wrapper against a fake gh
and check that the tick installs this workflow commit's copy before its gh calls, with room
in timeout-minutes for the hour it may wait. feat-cmux-next's nightly.yml uses the same script.
"""

from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "gh_budget_wait.sh"
JS = ROOT / "scripts" / "ci" / "gh_budget_wait.cjs"
JS_TEST = ROOT / "tests" / "gh_budget_wait_cjs_test.cjs"
TICK = ROOT / ".github" / "workflows" / "nightly-next-tick.yml"
AUTO_RESUME = ROOT / ".github" / "workflows" / "auto-resume-nightly-notarization.yml"

# The fake gh: `api rate_limit` reports an exhausted core budget that reset a moment ago (so a
# wait is the secondary-limit backoff, capped by GH_BUDGET_WAIT_MAX_SECONDS); any other call fails for
# the rate limit while REFUSALS has calls left, then prints its arguments and stdin.
FAKE_GH = r"""#!/bin/bash
state="$FAKE_STATE"
if [ "$1 $2 $3" = "api --include rate_limit" ]; then
  printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 4321\r\nX-Ratelimit-Resource: core\r\n\r\n{"resources":{"core":{"limit":5000,"remaining":4321}}}\n'
  exit 0
fi
if [ "$1 $2" = "api rate_limit" ]; then
  echo "rate_limit" >> "$state/log"
  if [ "${4:-}" = ".resources.core.remaining" ]; then echo "${CORE_LEFT:-5000}";
  elif [ -n "${RESET_IN:-}" ]; then echo $(($(date +%s) + RESET_IN)); else echo 0; fi
  exit 0
fi
echo "call $*" >> "$state/log"
left="$(cat "$state/refusals" 2>/dev/null || echo 0)"
if [ "$left" -gt 0 ]; then
  echo $((left - 1)) > "$state/refusals"
  echo "${FAKE_ERROR:-gh: API rate limit exceeded for installation.}" >&2
  exit 1
fi
if [ -n "${FAKE_FAIL:-}" ]; then echo "$FAKE_FAIL" >&2; exit 4; fi
echo "ok $*"
if [ -n "${READS_STDIN:-}" ]; then cat; fi
"""


class Harness:
    def __init__(self, refusals: int = 0, **env: str) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.state = base / "state"
        self.state.mkdir()
        (self.state / "refusals").write_text(str(refusals))
        real = base / "real"
        real.mkdir()
        fake = real / "gh"
        fake.write_text(FAKE_GH)
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        self.runner_temp = base / "runner-temp"
        self.runner_temp.mkdir()
        self.github_path = base / "github_path"
        self.env = {
            "PATH": f"{real}:/usr/bin:/bin",
            "RUNNER_TEMP": str(self.runner_temp),
            "GITHUB_PATH": str(self.github_path),
            "FAKE_STATE": str(self.state),
            "GH_BUDGET_WAIT_MAX_SECONDS": "2",
            **env,
        }
        installed = subprocess.run(["bash", str(SCRIPT), "--install"], env=self.env,
                                   capture_output=True, text=True, check=True)
        assert "wait through a rate limit" in installed.stdout, installed
        self.shim = Path(self.github_path.read_text().strip()) / "gh"

    def gh(self, *args: str, stdin: str | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(self.shim), *args], env=self.env, input=stdin,
                              capture_output=True, text=True, timeout=30)

    def calls(self) -> list[str]:
        log = self.state / "log"
        return log.read_text().splitlines() if log.exists() else []

    def waited(self) -> int:
        ledger = self.runner_temp / "gh-budget-wait" / "waited"
        return int(ledger.read_text()) if ledger.exists() else 0


class WrapperTests(unittest.TestCase):
    def harness(self, refusals: int = 0, **env: str) -> Harness:
        h = Harness(refusals, **env)
        self.addCleanup(h.tmp.cleanup)
        return h

    def test_install_points_the_wrapper_at_the_real_gh(self) -> None:
        h = self.harness()
        self.assertTrue(h.shim.is_file())
        self.assertIn(f"REAL_GH='{h.env['PATH'].split(':')[0]}/gh'", h.shim.read_text())
        self.assertEqual(h.gh("api", "repos/o/r").stdout, "ok api repos/o/r\n")
        self.assertEqual(h.calls(), ["call api repos/o/r"])

    def test_a_rate_limited_call_waits_and_succeeds(self) -> None:
        h = self.harness(refusals=1, GH_BUDGET_WAIT_MAX_SECONDS="1")
        result = h.gh("release", "upload", "v1", "a.dmg")
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(result.stdout, "ok release upload v1 a.dmg\n")
        self.assertIn("::notice title=GitHub API budget::gh release upload was refused", result.stderr)
        # Only the notices name it: the refused call's own error is not passed on.
        self.assertFalse([line for line in result.stderr.splitlines()
                          if "rate limit exceeded" in line and not line.startswith("::notice")])
        self.assertEqual(h.calls(), ["call release upload v1 a.dmg", "rate_limit", "call release upload v1 a.dmg"])
        self.assertEqual(h.waited(), 1)

    def test_a_secondary_limit_in_the_json_body_counts(self) -> None:
        h = self.harness(refusals=1, GH_BUDGET_WAIT_MAX_SECONDS="1",
                    FAKE_ERROR='{"message": "You have exceeded a secondary rate limit"}')
        result = h.gh("api", "x")
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(result.stdout, "ok api x\n")
        self.assertEqual(h.calls().count("call api x"), 2)  # refused once, then sent again
        self.assertEqual(h.waited(), 1)

    def test_a_caller_reading_stderr_with_stdout_gets_only_the_data(self) -> None:
        # nightly-next-legacy-requirement.sh and -recovery-lineage.sh compare `$(gh api ... 2>&1)` exactly.
        h = self.harness(refusals=1, GH_BUDGET_WAIT_MAX_SECONDS="1")
        summary = h.runner_temp / "summary.md"
        h.env["GITHUB_STEP_SUMMARY"] = str(summary)
        out = subprocess.run(["bash", "-c", f'x="$("{h.shim}" api x 2>&1)"; printf "%s" "$x"'],
                             env=h.env, capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout, "ok api x")
        self.assertIn("GitHub API budget: gh api x was refused", summary.read_text())
        self.assertIn("gh api x was refused", (h.runner_temp / "gh-budget-wait" / "waits.log").read_text())

    def test_a_refusal_with_no_exhausted_budget_backs_off_exponentially(self) -> None:
        # GitHub's secondary limit sends no reset: 60, 120, 240, then 300 s per wait (sleep is faked).
        h = self.harness(refusals=5, GH_BUDGET_WAIT_MAX_SECONDS="3600")
        fake_sleep = Path(h.env["PATH"].split(":")[0]) / "sleep"
        fake_sleep.write_text('#!/bin/bash\necho "$1" >> "$FAKE_STATE/slept"\n')
        fake_sleep.chmod(0o755)
        result = h.gh("release", "upload", "v1", "a.dmg")
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual((h.state / "slept").read_text().split(), ["60", "120", "240", "300", "300"])
        self.assertEqual(h.waited(), 1020)

    def test_the_first_refusal_names_the_limiter(self) -> None:
        h = self.harness(refusals=1, GH_BUDGET_WAIT_MAX_SECONDS="2",
                         FAKE_ERROR="gh: API rate limit exceeded for installation. request ID AA9E:1")
        result = h.gh("api", "repos/o/r/actions/runs")
        self.assertEqual(result.returncode, 0, result)
        (h.state / "refusals").write_text("1")
        h.gh("api", "x")  # refused again (the job's wait is spent): not logged twice
        log = (h.runner_temp / "gh-budget-wait" / "waits.log").read_text()
        self.assertIn("refused: gh api repos/o/r/actions/runs: gh: API rate limit exceeded for installation. request ID AA9E:1", log)
        self.assertIn("X-Ratelimit-Remaining: 4321", log)
        self.assertIn("X-Ratelimit-Resource: core", log)
        self.assertEqual(log.count("refused:"), 1)  # once per job
        self.assertIn("::notice title=GitHub API refusal::", result.stderr)

    def test_a_429_counts(self) -> None:
        h = self.harness(refusals=1, GH_BUDGET_WAIT_MAX_SECONDS="1", FAKE_ERROR="HTTP 429: Too Many Requests")
        result = h.gh("api", "x")
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(result.stdout, "ok api x\n")
        self.assertEqual(h.calls().count("call api x"), 2)
        self.assertEqual(h.waited(), 1)

    def test_another_failure_is_not_retried(self) -> None:
        h = self.harness(FAKE_FAIL="HTTP 404: Not Found")
        result = h.gh("api", "repos/o/r/releases/tags/v9")
        self.assertEqual(result.returncode, 4)
        self.assertIn("HTTP 404", result.stderr)
        self.assertEqual(h.calls(), ["call api repos/o/r/releases/tags/v9"])
        self.assertEqual(h.waited(), 0)

    def test_the_job_total_bounds_every_wait(self) -> None:
        h = self.harness(refusals=5, GH_BUDGET_WAIT_MAX_SECONDS="1")
        result = h.gh("api", "x")
        self.assertEqual(result.returncode, 1)
        self.assertIn("rate limit exceeded", result.stderr)
        self.assertEqual(h.calls().count("call api x"), 2)  # one wait of the 1 s total, then no more
        self.assertEqual(h.waited(), 1)
        # A later call in the same job has nothing left to wait.
        (h.state / "refusals").write_text("1")
        self.assertEqual(h.gh("api", "y").returncode, 1)
        self.assertEqual(h.calls().count("call api y"), 1)

    def test_a_wait_is_counted_before_it_sleeps(self) -> None:
        # A caller's timeout can kill the wrapper mid-wait; the wait must already be in the ledger.
        h = self.harness(refusals=1, GH_BUDGET_WAIT_MAX_SECONDS="30")
        with self.assertRaises(subprocess.TimeoutExpired):
            subprocess.run([str(h.shim), "api", "repos/o/r"], env=h.env, capture_output=True,
                           text=True, timeout=3)
        self.assertEqual(h.waited(), 30)

    def test_an_unwritable_ledger_stops_the_wait(self) -> None:
        # A wait the ledger cannot record would be invisible to later steps: the refusal stands.
        if os.geteuid() == 0:
            self.skipTest("root writes through a read-only directory")
        h = self.harness(refusals=1, GH_BUDGET_WAIT_MAX_SECONDS="30")
        ledger_dir = h.runner_temp / "gh-budget-wait"
        ledger_dir.mkdir(exist_ok=True)
        ledger_dir.chmod(0o500)
        self.addCleanup(ledger_dir.chmod, 0o700)
        result = h.gh("api", "repos/o/r")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rate limit exceeded", result.stderr)
        self.assertEqual(h.calls().count("call api repos/o/r"), 1)

    def test_a_malformed_ledger_counts_as_spent(self) -> None:
        h = self.harness(refusals=1, GH_BUDGET_WAIT_MAX_SECONDS="60")
        (h.runner_temp / "gh-budget-wait").mkdir(exist_ok=True)
        (h.runner_temp / "gh-budget-wait" / "waited").write_text("garbage")
        self.assertEqual(h.gh("api", "x").returncode, 1)
        self.assertEqual(h.calls().count("call api x"), 1)

    def test_attempts_are_bounded(self) -> None:
        h = self.harness(refusals=9, GH_BUDGET_WAIT_MAX_SECONDS="60", GH_BUDGET_WAIT_ATTEMPTS="2")
        (h.runner_temp / "gh-budget-wait").mkdir(exist_ok=True)
        (h.runner_temp / "gh-budget-wait" / "waited").write_text("59")  # one second left
        self.assertEqual(h.gh("api", "x").returncode, 1)
        self.assertEqual(h.calls().count("call api x"), 2)

    def test_stdin_is_replayed_only_for_a_call_that_reads_it(self) -> None:
        h = self.harness(refusals=1, GH_BUDGET_WAIT_MAX_SECONDS="1", READS_STDIN="1")
        result = h.gh("api", "x", "--input", "-", stdin='{"a": 1}')
        self.assertEqual(result.stdout, 'ok api x --input -\n{"a": 1}')
        # Without `-` the caller's stdin is left alone (a `while read` loop keeps its input).
        h = self.harness()
        script = f'printf "1\\n2\\n" | while read n; do "{h.shim}" api "x$n" >/dev/null; echo "got $n"; done'
        out = subprocess.run(["bash", "-c", script], env=h.env, capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout, "got 1\ngot 2\n")

    def test_reserve_waits_only_under_the_margin(self) -> None:
        h = self.harness(CORE_LEFT="4000", GH_BUDGET_WAIT_MAX_SECONDS="1")
        subprocess.run([str(h.shim), "--reserve", "200"], env=h.env, check=True)
        self.assertEqual(h.waited(), 0)
        h = self.harness(CORE_LEFT="12", GH_BUDGET_WAIT_MAX_SECONDS="1")
        result = subprocess.run([str(h.shim), "--reserve", "200"], env=h.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("12 calls left, under 200", result.stderr)
        self.assertEqual(h.waited(), 1)

    def test_a_server_error_is_retried_with_a_short_backoff(self) -> None:
        # 2026-11-20, cmux NEXT Stable tick job 136340624244: "HTTP 500: Failed to run workflow dispatch".
        h = self.harness(refusals=2, GH_BUDGET_WAIT_MAX_SECONDS="3600",
                         FAKE_ERROR="HTTP 500: Failed to run workflow dispatch (https://api.github.com/x)")
        fake_sleep = Path(h.env["PATH"].split(":")[0]) / "sleep"
        fake_sleep.write_text('#!/bin/bash\necho "$1" >> "$FAKE_STATE/slept"\n')
        fake_sleep.chmod(0o755)
        result = h.gh("workflow", "run", "stable-next.yml")
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(result.stdout, "ok workflow run stable-next.yml\n")
        self.assertEqual((h.state / "slept").read_text().split(), ["10", "20"])
        self.assertNotIn("rate_limit", h.calls())  # a 5xx reads no budget
        self.assertIn("got a GitHub server error", result.stderr)

    def test_server_errors_are_bounded_and_fail_loud(self) -> None:
        h = self.harness(refusals=9, GH_BUDGET_WAIT_MAX_SECONDS="3600", GH_BUDGET_WAIT_5XX_ATTEMPTS="3",
                         FAKE_ERROR="HTTP 502: Bad Gateway")
        fake_sleep = Path(h.env["PATH"].split(":")[0]) / "sleep"
        fake_sleep.write_text("#!/bin/bash\n")
        fake_sleep.chmod(0o755)
        result = h.gh("api", "x")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(h.calls().count("call api x"), 3)
        self.assertIn("HTTP 502", result.stderr)
        self.assertIn("::error title=GitHub API::gh api x got a GitHub server error on all 3 tries; failing", result.stderr)

    def test_a_reset_past_the_cap_fails_at_once_and_loud(self) -> None:
        # Waiting part of the way to a reset gains nothing: the next try is refused the same.
        h = self.harness(refusals=1, GH_BUDGET_WAIT_MAX_SECONDS="900", RESET_IN="3000")
        fake_sleep = Path(h.env["PATH"].split(":")[0]) / "sleep"
        fake_sleep.write_text("#!/bin/bash\n")
        fake_sleep.chmod(0o755)
        result = h.gh("api", "repos/o/r/contents/x")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(h.calls().count("call api repos/o/r/contents/x"), 1)
        self.assertEqual(h.waited(), 0)
        self.assertIn("past this job's 900s left to wait", result.stderr)
        self.assertIn("::error title=GitHub API::", result.stderr)

    def test_a_reset_within_the_cap_is_waited_for(self) -> None:
        h = self.harness(refusals=1, GH_BUDGET_WAIT_MAX_SECONDS="900", RESET_IN="100")
        fake_sleep = Path(h.env["PATH"].split(":")[0]) / "sleep"
        fake_sleep.write_text('#!/bin/bash\necho "$1" >> "$FAKE_STATE/slept"\n')
        fake_sleep.chmod(0o755)
        result = h.gh("api", "x")
        self.assertEqual(result.returncode, 0, result)
        slept = int((h.state / "slept").read_text())
        self.assertTrue(100 <= slept <= 106, slept)

    def test_a_loud_failure_with_merged_streams_goes_to_the_summary(self) -> None:
        # billing-nightly.yml's storekit step reads `$(gh api ... 2>&1)`: no annotation in its data.
        h = self.harness(refusals=1, GH_BUDGET_WAIT_MAX_SECONDS="900", RESET_IN="3000")
        fake_sleep = Path(h.env["PATH"].split(":")[0]) / "sleep"
        fake_sleep.write_text("#!/bin/bash\n")
        fake_sleep.chmod(0o755)
        summary = h.runner_temp / "summary.md"
        h.env["GITHUB_STEP_SUMMARY"] = str(summary)
        out = subprocess.run(["bash", "-c", f'x="$("{h.shim}" api x 2>&1)"; printf "%s" "$x"'],
                             env=h.env, capture_output=True, text=True, timeout=30)
        self.assertNotIn("::error", out.stdout)
        self.assertIn("GitHub API: gh api x was refused", summary.read_text())

    def test_install_hands_github_script_the_octokit_half(self) -> None:
        h = self.harness()
        github_env = h.runner_temp / "github_env"
        h.env["GITHUB_ENV"] = str(github_env)
        subprocess.run(["bash", str(SCRIPT), "--install"], env=h.env, capture_output=True, text=True, check=True)
        line = github_env.read_text().strip()
        self.assertEqual(line, f"GH_BUDGET_WAIT_JS={h.runner_temp}/gh-budget-wait/gh_budget_wait.cjs")
        self.assertEqual(Path(line.split("=", 1)[1]).read_text(), JS.read_text())

    def test_install_without_gh_is_a_warning(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = {"PATH": "/nonexistent", "RUNNER_TEMP": tmp, "GITHUB_PATH": f"{tmp}/p"}
            result = subprocess.run(["/bin/bash", str(SCRIPT), "--install"], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertIn("::warning", result.stdout)
            self.assertFalse(os.path.exists(f"{tmp}/p"))


class OctokitTests(unittest.TestCase):
    """gh_budget_wait.cjs, the github-script half, driven by node against a fake octokit."""

    def test_the_octokit_hook(self) -> None:
        node = shutil.which("node")
        if not node:
            self.skipTest("node is not installed")
        result = subprocess.run([node, str(JS_TEST)], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ok ", result.stdout)


class TickTests(unittest.TestCase):
    def test_the_tick_installs_this_workflow_s_wrapper_before_its_gh_calls(self) -> None:
        import yaml
        job = yaml.safe_load(TICK.read_text(encoding="utf-8"))["jobs"]["request"]
        steps = job["steps"]
        names = [s.get("name") for s in steps]
        tooling = steps[names.index("Checkout the gh rate-limit wait")]
        self.assertEqual(tooling["with"]["ref"], "${{ github.sha }}")
        self.assertEqual(tooling["with"]["path"], ".tick-tooling")
        self.assertIn("scripts/ci/gh_budget_wait.sh", tooling["with"]["sparse-checkout"].split())
        install = names.index("Wait through GitHub API rate limits in this job's gh calls")
        self.assertEqual(steps[install]["run"].strip(), "bash .tick-tooling/scripts/ci/gh_budget_wait.sh --install")
        for i, step in enumerate(steps):
            if "GH_TOKEN" in step.get("env", {}):
                self.assertGreater(i, install, step.get("name"))
        self.assertGreaterEqual(int(job["timeout-minutes"]), 15 + 60)


class AutoResumeTests(unittest.TestCase):
    """auto-resume-nightly-notarization.yml publishes a finished, signed nightly with main's publisher."""

    def test_publish_jobs_wait_through_rate_limits(self) -> None:
        import yaml
        doc = yaml.safe_load(AUTO_RESUME.read_text(encoding="utf-8"))
        for name in ("publish", "republish-deltas"):
            job = doc["jobs"][name]
            self.assertEqual(job["env"]["CMUX_RELEASE_RATE_LIMIT_SECONDS"], "1800", name)
            steps = job["steps"]
            runs = [step.get("run", "") for step in steps]
            install = runs.index("bash scripts/ci/gh_budget_wait.sh --install")
            self.assertTrue(steps[install - 1].get("uses", "").startswith("actions/checkout@"), name)
            publisher = next(i for i, run in enumerate(runs) if "publish-release-assets.py" in run)
            self.assertLess(install, publisher, name)
            # No step timeout shorter than the publisher's 30 minutes plus the wrapper's hour.
            self.assertGreaterEqual(int(steps[publisher].get("timeout-minutes", 360)), 30, name)
            self.assertGreaterEqual(int(job.get("timeout-minutes", 360)), 120, name)


class PinnedAssetPublishTests(unittest.TestCase):
    """The cmux-next pinned-asset publish workflows wait through rate limits.

    Run 43888568476 (2026-11-16) of cmux-next-cua-helper-dev-sign.yml died in
    its first gh read with "API rate limit exceeded for installation", so a
    fix that needed a rebuilt cmux Remote could not even start.
    """

    GH_CALL = re.compile(r"(^|[\s;(|&`$!])gh\s")
    # Each job's timeout before the wrapper; the wrapper may add an hour.
    JOBS = {
        "cmux-next-cua-helper-dev-sign.yml": {"sdk": 10, "pin-pr": 10},
        "cmux-next-cef-publish.yml": {"resolve": 10, "publish": 45},
        "cmux-next-remote-browser-host-publish.yml": {"resolve": 5, "publish": 15},
    }

    def uses_gh(self, step: dict) -> bool:
        return "run" in step and (
            bool(self.GH_CALL.search(step["run"])) or "GH_TOKEN" in (step.get("env") or {})
        )

    def test_every_job_with_a_gh_call_installs_the_wrapper_first(self) -> None:
        import yaml
        for workflow, budgets in self.JOBS.items():
            doc = yaml.safe_load((ROOT / ".github" / "workflows" / workflow).read_text(encoding="utf-8"))
            using = {name for name, job in doc["jobs"].items() if any(self.uses_gh(s) for s in job.get("steps", []))}
            self.assertEqual(using, set(budgets), workflow)
            for name, before in budgets.items():
                where = f"{workflow}:{name}"
                job = doc["jobs"][name]
                steps = job["steps"]
                runs = [step.get("run", "").strip() for step in steps]
                install = runs.index("bash .gh-budget-tooling/scripts/ci/gh_budget_wait.sh --install")
                tooling = steps[install - 1]
                self.assertTrue(tooling.get("uses", "").startswith("actions/checkout@"), where)
                self.assertEqual(tooling["with"]["ref"], "${{ github.sha }}", where)
                self.assertEqual(tooling["with"]["path"], ".gh-budget-tooling", where)
                self.assertEqual(tooling["with"]["persist-credentials"], False, where)
                self.assertIn("scripts/ci/gh_budget_wait.sh", tooling["with"]["sparse-checkout"].split(), where)
                first = min(i for i, step in enumerate(steps) if self.uses_gh(step))
                self.assertLess(install, first, where)
                self.assertGreaterEqual(int(job["timeout-minutes"]), before + 60, where)

    def test_the_best_effort_approval_notice_does_not_wait(self) -> None:
        # Its failed read only skips a notice, and the steps after it wait for
        # the same budget anyway: one refused try, not up to the job's hour.
        import yaml
        doc = yaml.safe_load((ROOT / ".github" / "workflows" / "cmux-next-cua-helper-dev-sign.yml").read_text(encoding="utf-8"))
        step = next(s for s in doc["jobs"]["sdk"]["steps"] if s.get("name") == "Name runs still waiting for a publish approval")
        self.assertIn("|| exit 0", step["run"])
        self.assertEqual(step["env"].get("GH_BUDGET_WAIT_ATTEMPTS"), "1")


if __name__ == "__main__":
    unittest.main()
