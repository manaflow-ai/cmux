#!/usr/bin/env python3
"""scripts/ci/gh_budget_wait.sh: a rate-limited gh call waits for the reset and tries again.

The nightly's publish path calls gh on the shared installation budget; when another workflow
had spent it, a finished nightly failed on its next call (2026-10-26, run 40298250989). These
tests drive the wrapper against a fake gh, and check that nightly.yml installs it before the
gh calls of every job on the publish path, with room in timeout-minutes for the hour it may wait.
"""

from __future__ import annotations

import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "gh_budget_wait.sh"
NIGHTLY = ROOT / ".github" / "workflows" / "nightly.yml"

# The fake gh: `api rate_limit` reports an exhausted core budget that reset a moment ago (so a
# wait is the secondary-limit backoff, capped by GH_BUDGET_WAIT_MAX_SECONDS); any other call fails for
# the rate limit while REFUSALS has calls left, then prints its arguments and stdin.
FAKE_GH = r"""#!/bin/bash
state="$FAKE_STATE"
if [ "$1 $2" = "api rate_limit" ]; then
  echo "rate_limit" >> "$state/log"
  if [ "${4:-}" = ".resources.core.remaining" ]; then echo "${CORE_LEFT:-5000}"; else echo 0; fi
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
        self.assertNotIn("rate limit exceeded", result.stderr)
        self.assertEqual(h.calls(), ["call release upload v1 a.dmg", "rate_limit", "call release upload v1 a.dmg"])
        self.assertEqual(h.waited(), 1)

    def test_a_secondary_limit_in_the_json_body_counts(self) -> None:
        h = self.harness(refusals=1, GH_BUDGET_WAIT_MAX_SECONDS="1",
                    FAKE_ERROR='{"message": "You have exceeded a secondary rate limit"}')
        self.assertEqual(h.gh("api", "x").returncode, 0)

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

    def test_a_429_counts(self) -> None:
        h = self.harness(refusals=1, GH_BUDGET_WAIT_MAX_SECONDS="1", FAKE_ERROR="HTTP 429: Too Many Requests")
        self.assertEqual(h.gh("api", "x").returncode, 0)

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

    def test_backoff_waits_by_try_and_never_fails(self) -> None:
        # An action's call (the attestation) is refused outside gh; --backoff TRY waits as a refused gh call's try would.
        h = self.harness(GH_BUDGET_WAIT_MAX_SECONDS="900")
        fake_sleep = Path(h.env["PATH"].split(":")[0]) / "sleep"
        fake_sleep.write_text('#!/bin/bash\necho "$1" >> "$FAKE_STATE/slept"\n')
        fake_sleep.chmod(0o755)
        for try_number in ("1", "2", "3"):
            result = subprocess.run([str(h.shim), "--backoff", try_number, "the attestation"], env=h.env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result)
            self.assertIn(f"the attestation failed (try {try_number})", result.stderr)
        self.assertEqual((h.state / "slept").read_text().split(), ["60", "120", "240"])
        self.assertEqual(h.waited(), 420)
        # The job total bounds it, and a spent total still exits 0 (the next try decides).
        result = subprocess.run([str(h.shim), "--backoff", "4"], env={**h.env, "GH_BUDGET_WAIT_MAX_SECONDS": "500"},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual((h.state / "slept").read_text().split(), ["60", "120", "240", "80"])
        result = subprocess.run([str(h.shim), "--backoff", "5"], env={**h.env, "GH_BUDGET_WAIT_MAX_SECONDS": "500"},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(h.waited(), 500)

    def test_install_without_gh_is_a_warning(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = {"PATH": "/nonexistent", "RUNNER_TEMP": tmp, "GITHUB_PATH": f"{tmp}/p"}
            result = subprocess.run(["/bin/bash", str(SCRIPT), "--install"], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertIn("::warning", result.stdout)
            self.assertFalse(os.path.exists(f"{tmp}/p"))


# Jobs on the nightly publish path whose gh calls go through the wrapper.
PUBLISH_PATH = (
    "resolve-nightly-cmux-tui-client", "prepare-nightly-variant-primary", "prepare-nightly-variant-fallback",
    "find-nightly-next-recovery", "recover-nightly-next-notarization", "publish-nightly", "publish-nightly-next-github", "publish-nightly-next-github-names", "keep-published-dsyms",
    "legacy-identity-target", "sign-nightly-identity-legacy", "publish-nightly-identity-legacy",
    "generate-nightly-deltas", "republish-nightly-deltas", "published-in", "sign-release-notes",
    "publish-release-notes", "publish-nightly-reel", "build-nightly-app",
)
INSTALL = re.compile(r"bash (\.publish-tooling/)?scripts/ci/gh_budget_wait\.sh --install")
# A job timeout that differs on nightly-next: `${{ ... track == 'nightly-next' && NEXT || OTHER }}`.
NEXT_TIMEOUT = re.compile(r"\$\{\{ needs\.decide\.outputs\.track == 'nightly-next' && (\d+) \|\| (\d+) \}\}")
# Publish-path jobs whose nightly-next path makes no gh call (republish-nightly-deltas writes
# deltas and feed to R2), so their nightly-next timeout needs no room for the hour's wait.
NO_GH_ON_NIGHTLY_NEXT = ("republish-nightly-deltas",)


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        import yaml
        cls.jobs = yaml.safe_load(NIGHTLY.read_text(encoding="utf-8"))["jobs"]

    def test_publish_path_jobs_install_the_wrapper_before_their_gh_calls(self) -> None:
        for name in PUBLISH_PATH:
            steps = self.jobs[name]["steps"]
            installs = [i for i, s in enumerate(steps) if INSTALL.search(str(s.get("run", "")))]
            self.assertEqual(len(installs), 1, name)
            at = installs[0]
            self.assertTrue(any("actions/checkout" in str(s.get("uses", "")) for s in steps[:at]), name)
            later_gh = [i for i, s in enumerate(steps)
                        if "github.token" in str(s.get("env", {})) or "release-tag-token" in str(s.get("env", {}))]
            # Only prepare's reuse probe (before any checkout; a refusal prepares here), the nightly
            # product lookup (no gh: a bounded REST lookup whose every refusal is a miss) and the
            # unsigned-resume restore (a hand-run recovery, not the publish path) come first.
            early = [i for i in later_gh if i < at]
            for i in early:
                resume = "nightly_next_unsigned_run != ''" in str(steps[i].get("if", ""))
                # gh_app_token.sh installs first so this wrapper wraps it (tests/test_gh_app_token.py).
                app_token = "gh_app_token.sh --install" in str(steps[i].get("run", ""))
                self.assertTrue(steps[i].get("id") in ("reuse", "nightly-product") or resume or app_token, (name, steps[i].get("name")))

    def test_publish_path_timeouts_leave_room_for_the_wait(self) -> None:
        for name in PUBLISH_PATH:
            timeout = str(self.jobs[name].get("timeout-minutes", 360))
            by_track = NEXT_TIMEOUT.fullmatch(timeout)
            if by_track:
                # A shorter nightly-next bound only where that track makes no gh call.
                self.assertIn(name, NO_GH_ON_NIGHTLY_NEXT, name)
                timeout = by_track.group(2)
            self.assertGreaterEqual(int(timeout), 65, name)
            # A step bounded on its own that calls gh needs the hour too, or it times out mid-wait.
            for step in self.jobs[name]["steps"]:
                if "timeout-minutes" in step and "GH_TOKEN" in step.get("env", {}):
                    self.assertGreaterEqual(int(step["timeout-minutes"]), 65, (name, step.get("name")))

    def test_the_attestation_reserves_budget_and_its_retry_shares_the_ledger(self) -> None:
        steps = self.jobs["build-nightly-app"]["steps"]
        names = [s.get("name") for s in steps]
        attest = names.index("Attest immutable SSH daemon assets")
        self.assertIn("gh_budget_wait.sh --reserve 200", steps[attest - 1]["run"])
        # The retry waits through the same script (one ledger, an hour in all), only while the budget is short.
        wait = steps[names.index("Wait for the API budget before retrying the daemon attestation")]["run"]
        self.assertIn("gh_budget_wait.sh --reserve 200", wait)
        self.assertNotIn("sleep", wait)
        # The engine fetch's gh release fallback comes after the install too.
        self.assertLess(next(i for i, s in enumerate(steps) if INSTALL.search(str(s.get("run", "")))),
                        names.index("Fetch the Chromium engine"))
        self.assertGreaterEqual(int(self.jobs["build-nightly-app"]["timeout-minutes"]), 90 + 60)

    def test_prepare_builds_when_its_reuse_probe_is_refused(self) -> None:
        for name in ("prepare-nightly-variant-primary", "prepare-nightly-variant-fallback"):
            probe = next(s for s in self.jobs[name]["steps"] if s.get("id") == "reuse")["run"]
            self.assertIn('if ! count="$(gh api', probe, name)
            self.assertIn("count=0", probe, name)


if __name__ == "__main__":
    unittest.main()
