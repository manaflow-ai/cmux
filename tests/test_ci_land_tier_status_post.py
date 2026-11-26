#!/usr/bin/env python3
"""The pr router's cmux/land-tier post survives spent installation budgets, and says so in red when it cannot.

The router posts `cmux/land-tier` (pending on the cheap tier, success once the full tier runs). It used to post on the
job's GITHUB_TOKEN alone, under continue-on-error: when the repository's token budget was spent ("API rate limit
exceeded for installation", run 45657671903, 2026-11-25 16:47Z), the run read green, the status stayed the cheap
tier's `pending` at a head the full tier had run on, and land-judge waited on it as a running check: 29 of the 119 cmux
lands waiting on running checks at 17:50Z waited on that status alone.

Then it posted on the cmux-bot App's token first, fell back to the job's token and retried both on a fixed 20 s and
40 s schedule. Run 45900568467 (cmux#57321, 2026-11-26 21:48Z) had both hours spent: six refusals, the run still read
green, and land stopped the PR as checks_stuck after 4.1 h.

Now scripts/ci/land_tier_status_post.sh sleeps only until a refused token's own Retry-After or X-RateLimit-Reset, and
only when that falls inside its bound; a post that got through on no token hands its state to the `land tier status`
job, which tries again with a longer bound and fails red when it still cannot post.

Run: python3 tests/test_ci_land_tier_status_post.py
"""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/pr-router.yml"
SCRIPT = "scripts/ci/land_tier_status_post.sh"

# A fake `gh api --include`: a token in FAIL_TOKENS is refused, with the headers HEADERS_<token> names (\n-separated)
# until its NTH_OK_<token>th call, when it posts.
FAKE_GH = r"""#!/bin/bash
echo "$GH_TOKEN $*" >> "$CALLS"
n=$(grep -c "^$GH_TOKEN " "$CALLS")
ok_var="NTH_OK_$GH_TOKEN"; ok=${!ok_var:-0}
case " $FAIL_TOKENS " in *" $GH_TOKEN "*)
  if [ "$ok" = 0 ] || [ "$n" -lt "$ok" ]; then
    hv="HEADERS_$GH_TOKEN"; code_var="CODE_$GH_TOKEN"
    printf 'HTTP/2.0 %s Forbidden\r\n' "${!code_var:-403}"
    printf '%b' "${!hv:-}" | sed 's/$/\r/'
    printf '\r\n{"message":"API rate limit exceeded for installation."}'
    echo "gh: API rate limit exceeded for installation. (HTTP 403)" >&2; exit 1
  fi;;
esac
printf 'HTTP/2.0 201 Created\r\nX-Ratelimit-Remaining: 9\r\n\r\n{}'
"""


def workflow() -> dict:
    return yaml.safe_load(WORKFLOW.read_text())


def step(job: str, name: str) -> dict:
    found = [s for s in workflow()["jobs"][job]["steps"] if s.get("name") == name]
    assert found, f"pr-router.yml's {job} job has no step {name!r}"
    return found[0]


class LandTierStatusPost(unittest.TestCase):
    def run_post(self, app_token: str, fail: str, state: str = "success", wait_s: int = 0, pools: str = "",
                 **extra: str) -> tuple[int, list[str], str, float]:
        script = step("route", "Post the land tier status")["run"]
        with tempfile.TemporaryDirectory() as tmp:
            gh = Path(tmp, "gh")
            gh.write_text(FAKE_GH)
            gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
            calls = Path(tmp, "calls")
            calls.touch()
            env = {"PATH": f"{tmp}:{os.environ['PATH']}", "CALLS": str(calls), "FAIL_TOKENS": fail,
                   "APP_TOKEN": app_token, "JOB_TOKEN": "job", "REPO": "manaflow-ai/cmux", "SHA": "a" * 40,
                   "STATE": state, "RUN_URL": "https://example.invalid/run", "LAND_STATUS_WAIT_S": str(wait_s),
                   "POOL_TOKENS": pools, **extra}
            began = time.monotonic()
            done = subprocess.run(["bash", "-e", "-c", script], env=env, cwd=ROOT, capture_output=True, text=True,
                                  timeout=30)
            took = time.monotonic() - began
            lines = calls.read_text().splitlines()
        return done.returncode, lines, done.stdout + done.stderr, took

    def test_the_route_step_runs_the_script(self) -> None:
        self.assertEqual(step("route", "Post the land tier status")["run"].strip(), SCRIPT)
        self.assertEqual(step("land-tier-status", "Post the land tier status")["run"].strip(), SCRIPT)

    def test_every_description_fits_githubs_140_characters(self) -> None:
        # the regression: run 45839458055 posted a 145-character success description; GitHub refused it on both
        # tokens ("Description is too long (maximum is 140 characters)") and cmux/land-tier stayed unposted
        for state in ("success", "pending"):
            code, calls, out, _ = self.run_post("app", fail="", state=state)
            self.assertEqual(code, 0, out)
            desc = calls[0].split("description=", 1)[1].rsplit(" -f target_url=", 1)[0]
            self.assertLessEqual(len(desc), 140, (state, desc))
            self.assertTrue(desc, state)

    def test_the_app_token_posts_first(self) -> None:
        code, calls, _, _ = self.run_post("app", fail="")
        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0].startswith("app api --include repos/manaflow-ai/cmux/statuses/"), calls)
        self.assertIn("state=success", calls[0])
        self.assertIn("context=cmux/land-tier", calls[0])

    def test_a_spent_job_token_does_not_leave_the_status_unposted(self) -> None:
        code, calls, _, _ = self.run_post("app", fail="job")
        self.assertEqual(code, 0)
        self.assertEqual([c.split()[0] for c in calls], ["app"])

    def test_a_refused_app_token_falls_back_to_the_job_token(self) -> None:
        code, calls, _, _ = self.run_post("app", fail="app")
        self.assertEqual(code, 0)
        self.assertEqual([c.split()[0] for c in calls], ["app", "job"])

    def test_pool_tokens_go_between_the_app_and_the_job_token(self) -> None:
        code, calls, _, _ = self.run_post("app", fail="app pool1", POOL_TOKENS="pool1 pool2")
        self.assertEqual(code, 0)
        self.assertEqual([c.split()[0] for c in calls], ["app", "pool1", "pool2"])

    def test_no_app_token_posts_on_the_job_token(self) -> None:
        code, calls, _, _ = self.run_post("", fail="")
        self.assertEqual(code, 0)
        self.assertEqual([c.split()[0] for c in calls], ["job"])

    def test_both_hours_spent_past_the_bound_stops_at_once_and_warns(self) -> None:
        # the regression: run 45900568467 slept 60 s on both spent hours and posted nothing; a reset 30 min away
        # is past any bound, so no sleep is spent on it
        reset = int(time.time()) + 1800
        hdr = f"X-Ratelimit-Remaining: 0\nX-Ratelimit-Reset: {reset}"
        code, calls, said, took = self.run_post("app", fail="app job", state="pending", wait_s=20,
                                                HEADERS_app=hdr, HEADERS_job=hdr)
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 2)
        self.assertLess(took, 5)
        self.assertIn("::warning::cmux/land-tier (pending) was not posted", said)
        self.assertIn("past this post's 20 s bound", said)

    def test_a_reset_inside_the_bound_is_waited_for(self) -> None:
        reset = int(time.time()) + 1
        code, calls, said, took = self.run_post(
            "app", fail="app job", wait_s=10, NTH_OK_job="2",
            HEADERS_app=f"X-Ratelimit-Remaining: 0\nX-Ratelimit-Reset: {reset + 600}",
            HEADERS_job=f"X-Ratelimit-Remaining: 0\nX-Ratelimit-Reset: {reset}")
        self.assertEqual(code, 0, said)
        self.assertEqual([c.split()[0] for c in calls], ["app", "job", "app", "job"])
        self.assertGreaterEqual(took, 0.5)

    def test_retry_after_is_honoured(self) -> None:
        code, calls, said, _ = self.run_post("app", fail="app job", wait_s=5, NTH_OK_app="2",
                                             HEADERS_app="Retry-After: 1", HEADERS_job="Retry-After: 60")
        self.assertEqual(code, 0, said)
        self.assertEqual([c.split()[0] for c in calls], ["app", "job", "app"])

    def test_a_bad_request_is_not_retried(self) -> None:
        code, calls, said, took = self.run_post("app", fail="app job", wait_s=20, CODE_app="422", CODE_job="422")
        self.assertEqual(code, 1, said)
        self.assertEqual(len(calls), 2)
        self.assertLess(took, 5)

    def test_a_spent_app_and_job_token_post_on_a_pool(self) -> None:
        # the regression: 2026-11-26 job 140020669492 slept 61 s through three rounds with cmux-bot and the job
        # token both refused for their spent hour, then left the status unposted
        code, calls, _, _ = self.run_post("app", fail="app job pool1", pools="pool1 pool2")
        self.assertEqual(code, 0)
        self.assertEqual([c.split()[0] for c in calls], ["app", "pool1", "pool2"])

    def test_the_post_reads_the_pool_tokens(self) -> None:
        for job in ("route", "land-tier-status"):
            env = step(job, "Post the land tier status")["env"]
            self.assertIn("secrets.CI_POOL_TOKEN_1", env["POOL_TOKENS"])
            self.assertIn("secrets.CI_POOL_TOKEN_2", env["POOL_TOKENS"])

    def test_the_token_is_minted_with_statuses_write_for_same_repo_heads_only(self) -> None:
        mint = step("route", "Mint the land tier status token")
        self.assertTrue(str(mint["uses"]).startswith("actions/create-github-app-token@"))
        self.assertEqual(mint["with"]["permission-statuses"], "write")
        self.assertTrue(mint.get("continue-on-error"))
        self.assertIn("head.repo.full_name == github.repository", mint["if"])
        names = [s.get("name") for s in workflow()["jobs"]["route"]["steps"]]
        self.assertLess(names.index("Mint the land tier status token"), names.index("Post the land tier status"))
        post = step("route", "Post the land tier status")
        self.assertIn("steps.land-status-token.outputs.token", post["env"]["APP_TOKEN"])
        sparse = workflow()["jobs"]["route"]["steps"][0]["with"]["sparse-checkout"]
        self.assertIn(SCRIPT, sparse.split())

    def test_an_unposted_state_fails_loudly_in_its_own_job(self) -> None:
        # the route's post stays continue-on-error (a red route would skip every callee); its state goes to a job
        # that tries again and is red when it still cannot post
        jobs = workflow()["jobs"]
        route = jobs["route"]
        post = step("route", "Post the land tier status")
        self.assertTrue(post.get("continue-on-error"))
        self.assertEqual(post["id"], "land-status-post")
        self.assertIn("steps.land-status-post.outcome == 'failure'", route["outputs"]["land_status_unposted"])
        self.assertIn("steps.route.outputs.land_status", route["outputs"]["land_status_unposted"])
        follow = jobs["land-tier-status"]
        self.assertEqual(follow["needs"], "route")
        self.assertIn("needs.route.outputs.land_status_unposted != ''", follow["if"])
        self.assertEqual(follow["permissions"].get("statuses"), "write")
        again = step("land-tier-status", "Post the land tier status")
        self.assertFalse(again.get("continue-on-error"))
        self.assertIn("needs.route.outputs.land_status_unposted", again["env"]["STATE"])
        self.assertIn("github.token", again["env"]["JOB_TOKEN"])
        self.assertGreater(int(again["env"]["LAND_STATUS_WAIT_S"]), int(post["env"]["LAND_STATUS_WAIT_S"]))
        self.assertGreater(again["timeout-minutes"] * 60, int(again["env"]["LAND_STATUS_WAIT_S"]))


if __name__ == "__main__":
    unittest.main()
