#!/usr/bin/env python3
"""The pr router's cmux/land-tier post survives a spent GITHUB_TOKEN budget.

The router posts `cmux/land-tier` (pending on the cheap tier, success once the full tier runs). It used to post on the
job's GITHUB_TOKEN alone, under continue-on-error: when the repository's token budget was spent ("API rate limit
exceeded for installation", run 45657671903, 2026-11-25 16:47Z), the run read green, the status stayed the cheap
tier's `pending` at a head the full tier had run on, and land-judge waited on it as a running check: 29 of the 119 cmux
lands waiting on running checks at 17:50Z waited on that status alone.

Now it posts on the cmux-bot App's token first (minted with statuses: write, as cmux-next.yml's same-tree statuses
are), tries pool tokens and the job token, retries transient errors, and when none got through says so in an ::error and the step's
`unposted` output. A warning was not enough: cmux#57743 kept the cheap tier's `pending` for 6 h (2026-11-26) while four
router runs computed `success` and none was posted ("Description is too long", then "API rate limit exceeded"), each
run green. The `land tier status post` job waits once for a nearby quota reset (at most one minute),
retries transient failures briefly, and goes red when it still cannot post.

Run: python3 tests/test_ci_land_tier_status_post.py
"""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/pr-router.yml"

FAKE_GH = """#!/bin/sh
echo "$GH_TOKEN $*" >> "$CALLS"
if [ "$2" = rate_limit ]; then
  case "$GH_TOKEN" in
    app) echo "$APP_RESET_AT";;
    *) echo "$RESET_AT";;
  esac
  exit 0
fi
case " $DENY_TOKENS " in *" $GH_TOKEN "*)
  echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1;;
esac
if [ "$RECOVER_AFTER_SLEEP" = 1 ] && [ -s "$SLEEPS" ]; then exit 0; fi
case " $FAIL_TOKENS " in *" $GH_TOKEN "*)
  echo "$FAIL_MESSAGE" >&2; exit 1;;
esac
exit 0
"""


def route_steps() -> list[dict]:
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]["route"]["steps"]


def step(name: str) -> dict:
    found = [s for s in route_steps() if s.get("name") == name]
    assert found, f"pr-router.yml's route job has no step {name!r}"
    return found[0]


class LandTierStatusPost(unittest.TestCase):
    def run_post(self, app_token: str, fail: str, state: str = "success", rounds: str = "",
                 script: str = "", pools: str = "", failure: str = "gh: API rate limit exceeded for installation.",
                 max_wait: str = "0", reset: str = "4600", app_reset: str = "", recover: bool = False,
                 deny: str = "") -> tuple[int, list[str], str]:
        script = script or step("Post the land tier status")["run"]
        with tempfile.TemporaryDirectory() as tmp:
            for name, body in {
                "date": 'echo 1000\n',
                "sleep": 'echo "$1" >> "$SLEEPS"\n',
            }.items():
                stub = Path(tmp, name)
                stub.write_text("#!/bin/sh\n" + body)
                stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
            gh = Path(tmp, "gh")
            gh.write_text(FAKE_GH)
            gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
            calls = Path(tmp, "calls")
            env = {"PATH": f"{tmp}:{os.environ['PATH']}", "CALLS": str(calls), "FAIL_TOKENS": fail,
                   "APP_TOKEN": app_token, "JOB_TOKEN": "job", "REPO": "manaflow-ai/cmux", "SHA": "a" * 40,
                   "STATE": state, "RUN_URL": "https://example.invalid/run", "LAND_STATUS_RETRY_S": "0",
                   "GITHUB_RUN_ID": "123", "GITHUB_OUTPUT": str(Path(tmp, "output")), "POOL_TOKENS": pools,
                   "FAIL_MESSAGE": failure, "LAND_STATUS_MAX_WAIT_S": max_wait, "RESET_AT": reset,
                   "APP_RESET_AT": app_reset or reset, "RECOVER_AFTER_SLEEP": "1" if recover else "0",
                   "SLEEPS": str(Path(tmp, "sleeps")), "DENY_TOKENS": deny}
            if rounds:
                env["LAND_STATUS_ROUNDS"] = rounds
            done = subprocess.run(["bash", "-e", "-c", script], env=env, capture_output=True, text=True, timeout=30)
            requests = calls.read_text().splitlines() if calls.exists() else []
            lines = [line for line in requests if "/statuses/" in line]
            self.probes = [line.split()[0] for line in requests if " api rate_limit " in line]
            sleeps = Path(tmp, "sleeps")
            self.sleeps = sleeps.read_text().splitlines() if sleeps.exists() else []
            output = Path(tmp, "output")
            self.output = output.read_text() if output.exists() else ""
        return done.returncode, lines, done.stdout + done.stderr

    def test_the_description_fits_githubs_140_character_limit(self) -> None:
        # the regression: run 45839458055 posted a 145-character success description; GitHub refused it on both
        # tokens ("Description is too long (maximum is 140 characters)") and cmux/land-tier stayed unposted
        for state in ("success", "pending"):
            code, calls, _ = self.run_post("app", fail="", state=state)
            self.assertEqual(code, 0)
            desc = calls[0].split("description=", 1)[1].rsplit(" -f target_url=", 1)[0]
            self.assertLessEqual(len(desc), 140, (state, desc))
            self.assertTrue(desc, state)

    def test_the_app_token_posts_first(self) -> None:
        code, calls, _ = self.run_post("app", fail="")
        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0].startswith("app api repos/manaflow-ai/cmux/statuses/"), calls)
        self.assertIn("state=success", calls[0])
        self.assertIn("context=cmux/land-tier", calls[0])

    def test_a_spent_job_token_does_not_leave_the_status_unposted(self) -> None:
        # the regression: GITHUB_TOKEN refused for the installation's rate limit; the App's token posts it
        code, calls, _ = self.run_post("app", fail="job")
        self.assertEqual(code, 0)
        self.assertEqual([c.split()[0] for c in calls], ["app"])

    def test_a_refused_app_token_falls_back_to_the_job_token(self) -> None:
        code, calls, _ = self.run_post("app", fail="app")
        self.assertEqual(code, 0)
        self.assertEqual([c.split()[0] for c in calls], ["app", "job"])

    def test_no_app_token_posts_on_the_job_token(self) -> None:
        code, calls, _ = self.run_post("", fail="")
        self.assertEqual(code, 0)
        self.assertEqual([c.split()[0] for c in calls], ["job"])

    def test_both_rate_limited_fail_visibly_without_blind_retries(self) -> None:
        code, calls, said = self.run_post("app", fail="app job", state="pending")
        self.assertEqual(code, 1)
        self.assertEqual([c.split()[0] for c in calls], ["app", "job"])
        self.assertEqual(self.probes, ["app", "job"])
        self.assertEqual(self.sleeps, [])
        self.assertIn("::error::cmux/land-tier (pending) was not posted", said)
        self.assertNotIn("::warning::", said)
        self.assertIn("last: gh: API rate limit exceeded for installation.", said)
        self.assertIn("gh run rerun 123 --failed", said)
        self.assertEqual(self.output.strip(), "unposted=true")

    def test_a_post_that_gets_through_sets_no_unposted_output(self) -> None:
        code, _, _ = self.run_post("app", fail="")
        self.assertEqual(code, 0)
        self.assertEqual(self.output, "")

    def test_the_route_job_exports_the_unposted_flag(self) -> None:
        route = yaml.safe_load(WORKFLOW.read_text())["jobs"]["route"]
        self.assertEqual(step("Post the land tier status").get("id"), "land-status-post")
        self.assertIn("steps.land-status-post.outputs.unposted", route["outputs"]["land_status_unposted"])
        self.assertIn("steps.route.outputs.land_status", route["outputs"]["land_status"])

    def test_an_unposted_status_gets_a_job_that_retries_and_goes_red(self) -> None:
        job = yaml.safe_load(WORKFLOW.read_text())["jobs"]["land-tier-status"]
        self.assertEqual(job["needs"], ["route"])
        self.assertIn("needs.route.outputs.land_status_unposted == 'true'", job["if"])
        post = [s for s in job["steps"] if s.get("name") == "Post the land tier status"][0]
        self.assertFalse(post.get("continue-on-error"), "the retry job must go red when it cannot post")
        self.assertFalse(job.get("continue-on-error"))
        self.assertEqual(post["run"], step("Post the land tier status")["run"], "one script for both posts")
        self.assertIn("needs.route.outputs.land_status", post["env"]["STATE"])
        rounds, wait = int(post["env"]["LAND_STATUS_ROUNDS"]), int(post["env"]["LAND_STATUS_RETRY_S"])
        max_wait = int(post["env"]["LAND_STATUS_MAX_WAIT_S"])
        self.assertGreaterEqual(rounds, 2, "transient failures get another attempt")
        self.assertGreater(wait, 0)
        self.assertLessEqual(wait * sum(range(1, rounds)), 60, "transient retries must stay short")
        self.assertGreater(max_wait, 0)
        self.assertLessEqual(max_wait, 600, "do not hold a runner for a distant quota reset")
        self.assertGreaterEqual(max_wait, 600, "an hourly reset up to 10 minutes away is waited out, not a false red")
        self.assertLessEqual(post["timeout-minutes"], job["timeout-minutes"] - 1)
        self.assertLess((max_wait + wait * sum(range(1, rounds))) / 60, post["timeout-minutes"])
        mint = [s for s in job["steps"] if s.get("name") == "Mint the land tier status token"][0]
        self.assertEqual(mint["with"]["permission-statuses"], "write")
        # the retry job runs the rounds it is given
        code, calls, said = self.run_post("app", fail="app job", rounds="4", script=post["run"],
                                          failure="gh: HTTP 502 Bad Gateway")
        self.assertEqual((code, len(calls)), (1, 8), said)
        self.assertEqual(self.probes, [], "only quota refusals need a reset-time probe")
        self.assertEqual(len(self.sleeps), 3)

    def test_the_earliest_near_reset_is_waited_for_once_and_can_recover(self) -> None:
        code, calls, said = self.run_post("app", "app job", max_wait="10", app_reset="1020", reset="1005",
                                          recover=True)
        self.assertEqual(code, 0, said)
        self.assertEqual([c.split()[0] for c in calls], ["app", "job", "app"])
        self.assertEqual(self.probes, ["app", "job"])
        self.assertEqual(self.sleeps, ["10"])  # earliest reset plus the five-second margin
        self.assertEqual(self.output, "")

    def test_a_reset_beyond_the_wait_budget_fails_without_sleeping(self) -> None:
        code, calls, said = self.run_post("app", "app job", max_wait="9", reset="1005")
        self.assertEqual(code, 1, said)
        self.assertEqual(len(calls), 2)
        self.assertEqual(self.sleeps, [])
        self.assertEqual(self.output.strip(), "unposted=true")

    def test_a_reset_that_still_refuses_never_waits_twice(self) -> None:
        code, calls, said = self.run_post("app", "app job", max_wait="10", reset="1005")
        self.assertEqual(code, 1, said)
        self.assertEqual([c.split()[0] for c in calls], ["app", "job", "app", "job"])
        self.assertEqual(self.sleeps, ["10"])
        self.assertEqual(self.output.strip(), "unposted=true")

    def test_a_spent_budget_names_the_rerun_time(self) -> None:
        code, _, said = self.run_post("app", fail="app job", state="pending")
        self.assertEqual(code, 1)
        self.assertRegex(said, r"rerun after \S+: gh run rerun 123 --failed")

    def test_pool_tokens_without_permission_do_not_block_the_wait(self) -> None:
        # the regression: job 140277453358 (2026-11-27 02:34Z), cmux-bot and the job token rate limited, both pool
        # tokens "Resource not accessible by integration": the near-reset wait never ran
        code, calls, said = self.run_post("app", "app job", deny="pool1 pool2", pools="pool1 pool2",
                                          max_wait="10", reset="1005", recover=True)
        self.assertEqual(code, 0, said)
        self.assertEqual(self.sleeps, ["10"])
        self.assertEqual(self.probes, ["app", "job"])

    def test_only_permission_refusals_are_not_waited_on(self) -> None:
        code, _, said = self.run_post("app", fail="", deny="app job", max_wait="60", reset="1005")
        self.assertEqual(code, 1)
        self.assertEqual(self.probes, [])
        self.assertEqual([w for w in self.sleeps if w != "0"], [])  # round backoff only, no reset wait
        self.assertNotIn("rerun after", said)

    def test_every_description_fits_githubs_140_characters(self) -> None:
        # GitHub refuses a longer one ("Description is too long (maximum is 140 characters)", run 45827285472).
        for state in ("success", "pending"):
            code, lines, out = self.run_post("app", "", state=state)
            self.assertEqual(code, 0, out)
            desc = lines[0].split("description=", 1)[1].split(" -f target_url=", 1)[0]
            self.assertLessEqual(len(desc), 140, desc)

    def test_a_spent_app_and_job_token_post_on_a_pool(self) -> None:
        # the regression: 2026-11-26 job 140020669492 slept 61 s through three rounds with cmux-bot and the job
        # token both refused for their spent hour, then left the status unposted
        code, calls, _ = self.run_post("app", fail="app job pool1", pools="pool1 pool2")
        self.assertEqual(code, 0)
        self.assertEqual([c.split()[0] for c in calls], ["app", "pool1", "pool2"])

    def test_the_post_reads_the_pool_tokens(self) -> None:
        env = step("Post the land tier status")["env"]
        self.assertIn("secrets.CI_POOL_TOKEN_1", env["POOL_TOKENS"])
        self.assertIn("secrets.CI_POOL_TOKEN_2", env["POOL_TOKENS"])

    def test_the_token_is_minted_with_statuses_write_for_same_repo_heads_only(self) -> None:
        mint = step("Mint the land tier status token")
        self.assertTrue(str(mint["uses"]).startswith("actions/create-github-app-token@"))
        self.assertEqual(mint["with"]["permission-statuses"], "write")
        self.assertTrue(mint.get("continue-on-error"))
        self.assertIn("head.repo.full_name == github.repository", mint["if"])
        names = [s.get("name") for s in route_steps()]
        self.assertLess(names.index("Mint the land tier status token"), names.index("Post the land tier status"))
        post = step("Post the land tier status")
        self.assertIn("steps.land-status-token.outputs.token", post["env"]["APP_TOKEN"])


if __name__ == "__main__":
    unittest.main()
