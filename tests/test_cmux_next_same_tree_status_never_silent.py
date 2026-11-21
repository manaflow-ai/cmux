#!/usr/bin/env python3
"""A pull request's required `cmux-next daemon tests (same-tree)` status always posts or turns something red.

SAME_TREE_STATUS_NEVER_SILENT (2026-11-14, hq#11114). Besides the publish-side notify (#43429, NOTIFY_NEVER_LOST),
these let the status go missing with nothing red:
- cmux#43335 and #43370: the same-tree daemon tests passed, the status POST got HTTP 403 (the workflow token's
  budget), the step warned and passed;
- cmux#43400 and #43027: path routing could not compare the active artifacts runs with the merge tree (fetch
  budget or GitHub API), deferred, and no publish ever ended that wait;
- STATUS_FROM_OUTSIDE (2026-11-15, cmux#43368 at 9cc846fc, run 43666282494): the daemon tests lost their Mac
  runner, so no step ran, the post was a step of that job, and nothing posted. The scheme compile's post sat in
  crash-ends-app with `permissions: {}`. Now a reporter job outside the tested jobs posts every same-tree status
  (scripts/ci/cmux_next_same_tree_status.py).
"""

from __future__ import annotations

import json
import os
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
CMUX_NEXT = WORKFLOWS / "cmux-next.yml"
PIN = ROOT / "scripts" / "cmux-next" / "pin-cmux-tui.sh"
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cmux_next_same_tree_status as status  # noqa: E402

HEAD = "9cc846fc" + "0" * 32
STATUS_POST = re.compile(r"/statuses/")
OWN_RESULT = re.compile(r"\$\{\{\s*job\.status\s*\}\}")
LOST = "The self-hosted runner lost communication with the server. Verify the machine is running."


def jobs() -> dict:
    return yaml.safe_load(CMUX_NEXT.read_text())["jobs"]


class FakeApi:
    def __init__(self, listing: list[dict] | None = None, annotations: dict[int, list[dict]] | None = None,
                 post_codes: list[int] | None = None,
                 post_answers: list[tuple[int, bytes, dict]] | None = None):
        self.listing = listing or []
        self.annotations = annotations or {}
        # Each post's (status, body, headers), as cmux_next_tree_notify.GitHub keeps its last answer.
        self.post_answers = list(post_answers or [(code, b"", {}) for code in (post_codes or [201])])
        self.last: tuple[int, bytes, dict] = (0, b"", {})
        self.posts: list[tuple[str, dict]] = []
        self.gets: list[str] = []

    def get(self, path: str):
        self.gets.append(path)
        if "/jobs?" in path:
            return {"jobs": self.listing}
        if "/annotations" in path:
            return self.annotations.get(int(path.split("check-runs/")[1].split("/")[0]), [])
        raise RuntimeError(f"GET {path}: HTTP 404")

    def post(self, path: str, body: dict) -> int:
        self.posts.append((path, body))
        self.last = self.post_answers.pop(0) if self.post_answers else (201, b"", {})
        return self.last[0]


def run(api: FakeApi, *, tier: str = "daemon", state: str = "ready", needs: dict, reason: str = "",
        dev_daily: bool = False) -> int:
    argv = ["--tier", tier, "--repo", "o/r", "--status-sha", HEAD, "--state", state, "--needs", json.dumps(needs),
            "--reason", reason, "--run-id", "43666282494", "--attempt", "1"] + (["--dev-daily"] if dev_daily else [])
    return status.main(argv, api=api, sleep=lambda _s: None)


def result(value: str) -> dict:
    return {"result": value, "outputs": {}}


class StatusFromOutside(unittest.TestCase):
    """The detector: no workflow posts a commit status from inside the job whose result it reports."""

    def test_no_status_is_posted_from_inside_the_job_it_reports(self):
        found = []
        for path in sorted(WORKFLOWS.glob("*.yml")):
            for job_id, job in (yaml.safe_load(path.read_text()).get("jobs") or {}).items():
                for step in job.get("steps") or []:
                    text = (step.get("run") or "") + json.dumps(step.get("env") or {})
                    if STATUS_POST.search(text) and OWN_RESULT.search(text):
                        found.append(f"{path.name}: {job_id}: {step.get('name')}")
        self.assertEqual(found, [], "a status that reports its own job's result dies with that job's runner: post it "
                                    "from a job that `needs:` the tested job and runs `if: always()` "
                                    "(cmuxterm-hq docs/handbook/status-posted-by-the-job-it-reports.md)")

    def test_every_same_tree_tier_has_a_reporter_outside_its_tested_jobs(self):
        all_jobs = jobs()
        for tier, tested in status.TESTED.items():
            with self.subTest(tier=tier):
                reporter = all_jobs[f"same-tree-status-{tier}"]
                # Runs after a failed or skipped tested job; a cancelled run queues no tail job (#48396), and its
                # status stays pending (never a pass) until a re-run posts it.
                self.assertTrue(reporter["if"].replace("${{", "").strip().startswith(("always()", "!cancelled()")),
                                reporter["if"])
                self.assertIn("inputs.same_tree_status_sha != ''", reporter["if"])
                self.assertEqual(set(reporter["needs"]), {"same-tree-cmux-tui", *tested})
                self.assertEqual(reporter["permissions"].get("statuses"), "write")
                # Only the spare token's mint may fail soft (SAME_TREE_STATUS_SPARE_TOKEN): the post never does.
                soft = [s.get("name") for s in reporter["steps"] if "continue-on-error" in s]
                self.assertEqual(soft, ["Mint the cmux-bot same-tree status token"])
                self.assertNotIn("continue-on-error", reporter)
                [post] = [s for s in reporter["steps"] if s.get("name") == "Post the same-tree status"]
                self.assertIn(f"--tier {tier}", post["run"])
                self.assertIn("toJSON(needs)", post["env"]["NEEDS"])
                # Not on the Mac pool whose loss it reports.
                self.assertNotIn("macos", reporter["runs-on"])
                for job in tested:
                    for step in all_jobs[job].get("steps") or []:
                        self.assertNotRegex(step.get("run") or "", STATUS_POST, f"{job} posts a status itself")

    def test_the_tested_jobs_hold_no_status_permission(self):
        for job in ("daemon-test", "crash-ends-app"):
            self.assertNotIn("statuses", jobs()[job].get("permissions") or {})

    def test_a_pull_request_never_defers_to_a_publisher_it_could_not_find(self):
        probe = PIN.read_text().split("probe_checkout_tree() {", 1)[1].split("\n}\n", 1)[0]
        # The head's push publishes a merge that keeps the head's tree: read from git, before any API search.
        head_branch = probe.index("rev-parse --verify -q HEAD^2")
        self.assertLess(probe.index("pull_request_base_key"), head_branch)
        self.assertLess(head_branch, probe.index('await_outside_publisher "$key"'))
        self.assertIn('source="commit:$head_sha"', probe)
        # A pull request's merge tree with no publisher it could find is red, never deferred.
        unknown = probe.index('-n "$publisher_unknown" && "${GITHUB_EVENT_NAME:-}" == pull_request')
        self.assertIn("state=failed", probe[unknown:].split("elif", 1)[0])
        self.assertLess(unknown, probe.index('elif [[ -z "$source" && -n "$publisher_unknown" ]]; then'))


class Verdicts(unittest.TestCase):
    def posted(self, api: FakeApi) -> dict:
        self.assertEqual(len(api.posts), 1, api.posts)
        path, body = api.posts[0]
        self.assertEqual(path, f"repos/o/r/statuses/{HEAD}")
        self.assertLessEqual(len(body["description"]), status.DESCRIPTION_MAX)
        self.assertEqual(body["target_url"], "https://github.com/o/r/actions/runs/43666282494")
        return body

    def test_run_43666282494_a_lost_runner_posts_no_verdict_with_the_reason(self):
        api = FakeApi([{"id": 7, "name": "cmux-next daemon tests", "conclusion": "failure", "steps": []}],
                      {7: [{"annotation_level": "failure", "message": LOST}]})
        self.assertEqual(run(api, needs={"same-tree-cmux-tui": result("success"), "daemon-test": result("failure")}), 0)
        body = self.posted(api)
        self.assertEqual(body["context"], "cmux-next daemon tests (same-tree)")
        self.assertEqual(body["state"], "error")
        self.assertTrue(body["description"].startswith("no verdict: cmux-next daemon tests: The self-hosted runner"))

    def test_a_test_failure_is_a_failure_naming_its_first_error(self):
        api = FakeApi([{"id": 8, "name": "cmux-next daemon tests", "conclusion": "failure", "steps": []}],
                      {8: [{"annotation_level": "warning", "message": "slow"},
                           {"annotation_level": "failure", "message": "DaemonAttachTests failed"}]})
        run(api, needs={"daemon-test": result("failure")})
        body = self.posted(api)
        self.assertEqual(body["state"], "failure")
        self.assertEqual(body["description"], "cmux-next daemon tests failed: DaemonAttachTests failed")

    def test_a_failure_whose_jobs_cannot_be_read_still_posts(self):
        class Broken(FakeApi):
            def get(self, path):
                raise RuntimeError("GET: HTTP 403")
        api = Broken()
        run(api, needs={"daemon-test": result("failure")})
        self.assertEqual(self.posted(api)["state"], "failure")

    def test_a_pass_is_success(self):
        api = FakeApi()
        run(api, needs={"daemon-test": result("success")})
        self.assertEqual(self.posted(api)["state"], "success")
        self.assertEqual(api.gets, [])

    def test_a_skipped_tested_job_names_the_red_upstream(self):
        api = FakeApi([{"id": 1, "name": "cmux-next web bundles (source-keyed cache)", "conclusion": "failure"},
                       {"id": 2, "name": "cmux-next daemon tests", "conclusion": "skipped"},
                       {"id": 3, "name": "same-tree status (scheme)", "conclusion": "failure"}])
        run(api, needs={"daemon-test": result("skipped")})
        body = self.posted(api)
        self.assertEqual(body["state"], "error")
        self.assertIn("no verdict: cmux-next daemon tests skipped", body["description"])
        self.assertIn("web bundles", body["description"])
        self.assertNotIn("same-tree status", body["description"])

    def test_the_scheme_status_reads_the_compile_and_the_crash_gate(self):
        api = FakeApi()
        run(api, tier="scheme", needs={"cmux-scheme-compile": result("success"), "crash-ends-app": result("failure")})
        body = self.posted(api)
        self.assertEqual(body["context"], "cmux app scheme compile (Debug) (same-tree)")
        self.assertEqual(body["state"], "failure")
        self.assertIn("cmux-next crash ends the app", body["description"])

    def test_a_dev_daily_scheme_status_has_no_crash_gate(self):
        api = FakeApi()
        run(api, tier="scheme", dev_daily=True,
            needs={"cmux-scheme-compile": result("success"), "crash-ends-app": result("skipped")})
        body = self.posted(api)
        self.assertEqual(body["context"], "cmux NEXT DEV Release compile (same-tree)")
        self.assertEqual(body["state"], "success")

    def test_a_cancelled_run_is_no_verdict(self):
        api = FakeApi()
        run(api, needs={"daemon-test": result("cancelled")})
        body = self.posted(api)
        self.assertEqual(body["state"], "error")
        self.assertIn("cancelled", body["description"])

    def test_a_failed_tree_is_red_with_its_reason_unless_the_gate_healed_it(self):
        api = FakeApi()
        run(api, state="failed", reason="tree abc: the artifacts run failed",
            needs={"same-tree-cmux-tui": result("failure"), "daemon-test": result("skipped")})
        body = self.posted(api)
        self.assertEqual(body["state"], "failure")
        self.assertEqual(body["description"], "same-tree cmux-tui unavailable: tree abc: the artifacts run failed")
        # A pull request's failed tree: same-tree-cmux-tui is skipped by design, the reporter still posts red.
        api = FakeApi()
        run(api, state="failed", reason="x", needs={"same-tree-cmux-tui": result("skipped")})
        self.assertEqual(self.posted(api)["state"], "failure")
        # Re-dispatched (the tree was published since) or taken over: that job said so; nothing posts.
        api = FakeApi()
        self.assertEqual(run(api, state="failed", needs={"same-tree-cmux-tui": result("success")}), 0)
        self.assertEqual(api.posts, [])

    def test_a_post_refused_three_times_is_red(self):
        api = FakeApi(post_codes=[500, 502, 500])
        self.assertEqual(run(api, needs={"daemon-test": result("success")}), 1)
        self.assertEqual(len(api.posts), 3)
        api = FakeApi(post_codes=[500, 201])
        self.assertEqual(run(api, needs={"daemon-test": result("success")}), 0)

    def test_a_bad_status_sha_is_red(self):
        argv = ["--tier", "daemon", "--repo", "o/r", "--status-sha", "nope", "--state", "ready", "--needs", "{}"]
        self.assertEqual(status.main(argv, api=FakeApi(), sleep=lambda _s: None), 1)


SPENT = b'{"message":"API rate limit exceeded for installation ID 1."}'
SECONDARY = b'{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}'
NOT_ALLOWED = b'{"message":"Resource not accessible by integration"}'


class RateLimitWait(unittest.TestCase):
    """RATE_LIMIT_WAIT (job 132784475164): a post refused on a rate limit waits for it to lift, bounded; only a
    403 that is no rate limit is red at once."""

    NOW = 1_800_000_000.0

    def post(self, answers: list[tuple[int, bytes, dict]]) -> tuple[bool, FakeApi, list[float], list[str]]:
        api, slept, logged = FakeApi(post_answers=answers), [], []
        clock = [self.NOW]

        def sleep(seconds: float) -> None:
            slept.append(seconds)
            clock[0] += seconds

        args = status.parse(["--tier", "daemon", "--repo", "o/r", "--status-sha", HEAD, "--state", "ready",
                             "--needs", "{}"])
        ok = status.post(api, args, "success", "same-tree cmux-tui run: success", "", sleep=sleep,
                         log=logged.append, now=lambda: clock[0])
        return ok, api, [s for s in slept if s], logged

    def test_job_132784475164_three_rate_limited_refusals_then_the_post_lands(self):
        # Both tokens spent: three 403s on a rate limit (no Retry-After, no reset), then the limit lifts.
        ok, api, slept, _ = self.post([(403, SPENT, {})] * 3 + [(201, b"{}", {})])
        self.assertTrue(ok)
        self.assertEqual(len(api.posts), 4)
        self.assertEqual(slept, [30.0, 60.0, 120.0])

    def test_retry_after_is_honored(self):
        ok, api, slept, _ = self.post([(429, b"", {"Retry-After": "45"}), (201, b"{}", {})])
        self.assertTrue(ok)
        self.assertEqual(slept, [45.0])

    def test_the_reset_is_honored(self):
        reset = {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(self.NOW) + 200)}
        ok, api, slept, _ = self.post([(403, SPENT, reset), (201, b"{}", {})])
        self.assertTrue(ok)
        self.assertEqual(slept, [201.0])

    def test_cmux_43659_a_spent_installation_is_waited_out_to_its_reset(self):
        # hq#11485: the installation's reset was ~50 min away; a 600 s budget gave up at once and the status sat
        # pending 2.5 h. The wait now runs to the reset, inside the spare token's hour.
        reset = {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(self.NOW) + 3000)}
        ok, api, slept, _ = self.post([(403, SPENT, reset), (201, b"{}", {})])
        self.assertTrue(ok)
        self.assertEqual((len(api.posts), slept), (2, [3001.0]))

    def test_a_reset_past_the_budget_is_a_no_verdict_red_without_waiting(self):
        reset = {"x-ratelimit-remaining": "0",
                 "x-ratelimit-reset": str(int(self.NOW) + status.RATE_LIMIT_BUDGET_S + 100)}
        ok, api, slept, logged = self.post([(403, SPENT, reset), (201, b"{}", {})])
        self.assertFalse(ok)
        self.assertEqual((len(api.posts), slept), (1, []))
        self.assertIn("rate limit", logged[-1])
        self.assertIn("NO_VERDICT", logged[-1])
        self.assertIn("re-run this job", logged[-1])

    def test_the_budget_ends_inside_the_spare_tokens_hour(self):
        self.assertGreaterEqual(status.RATE_LIMIT_BUDGET_S, 3000)
        self.assertLess(status.RATE_LIMIT_BUDGET_S, 3600)

    def test_a_limit_that_never_lifts_is_red_within_the_budget(self):
        ok, api, slept, logged = self.post([(403, SECONDARY, {})] * 50)
        self.assertFalse(ok)
        self.assertLessEqual(sum(slept), status.RATE_LIMIT_BUDGET_S)
        self.assertGreaterEqual(sum(slept), status.RATE_LIMIT_BUDGET_S / 2)
        self.assertIn("::error", logged[-1])

    def test_a_403_that_is_no_rate_limit_is_red_at_once(self):
        ok, api, slept, logged = self.post([(403, NOT_ALLOWED, {"x-ratelimit-remaining": "4000"}),
                                            (201, b"{}", {})])
        self.assertFalse(ok)
        self.assertEqual((len(api.posts), slept), (1, []))
        self.assertIn("Resource not accessible by integration", logged[-1])

    def test_the_reporters_time_out_after_the_budget(self):
        all_jobs = jobs()
        for tier in status.TESTED:
            with self.subTest(tier=tier):
                minutes = all_jobs[f"same-tree-status-{tier}"]["timeout-minutes"]
                self.assertGreaterEqual(minutes * 60, status.RATE_LIMIT_BUDGET_S + 4 * 60)

    def test_the_client_keeps_the_answer_the_wait_reads(self):
        client = status.notify.GitHub("workflow", "http://api.invalid")
        client._send = lambda method, url, body=None: (403, SPENT, {"retry-after": "7"})
        self.assertEqual(client.post("repos/o/r/statuses/" + HEAD, {"state": "success"}), 403)
        self.assertEqual(client.last, (403, SPENT, {"retry-after": "7"}))


class SpareToken(unittest.TestCase):
    """SAME_TREE_STATUS_SPARE_TOKEN (hq#11150): a spent github.token budget never leaves the status unposted."""

    def test_each_reporter_mints_the_app_token_and_passes_it_as_the_spare(self):
        all_jobs = jobs()
        for tier in status.TESTED:
            with self.subTest(tier=tier):
                reporter = all_jobs[f"same-tree-status-{tier}"]
                self.assertIn("'ci-routing-agent'", reporter["environment"])
                self.assertIn("pull_request", reporter["environment"])
                names = [s.get("name") for s in reporter["steps"]]
                mint = reporter["steps"][names.index("Mint the cmux-bot same-tree status token")]
                post = reporter["steps"][names.index("Post the same-tree status")]
                self.assertLess(names.index(mint["name"]), names.index(post["name"]))
                self.assertTrue(mint["continue-on-error"])
                self.assertEqual(mint["with"]["permission-statuses"], "write")
                self.assertEqual(post["env"]["GH_TOKEN_SPARE"], "${{ steps.%s.outputs.token }}" % mint["id"])

    def test_the_script_hands_the_spare_to_the_client(self):
        seen = {}

        class Client:
            def __init__(self, token, api_url="", spare=""):
                seen.update(token=token, spare=spare)

        argv = ["--tier", "daemon", "--repo", "o/r", "--status-sha", HEAD, "--state", "ready", "--needs", "{}"]
        original, env = status.notify.GitHub, dict(os.environ)
        status.notify.GitHub = Client
        os.environ.update(GH_TOKEN="workflow", GH_TOKEN_SPARE="app")
        try:
            status.main(argv, sleep=lambda _s: None)
        except Exception:  # noqa: BLE001 - the stub has no get/post; only the construction is under test
            pass
        finally:
            status.notify.GitHub = original
            os.environ.clear()
            os.environ.update(env)
        self.assertEqual(seen, {"token": "workflow", "spare": "app"})

    def test_the_client_moves_to_the_spare_on_a_spent_rate_limit(self):
        client = status.notify.GitHub("workflow", "http://api.invalid", "app")
        sent = []

        def send(method, url, body=None):
            sent.append(client.token)
            if client.token == "workflow":
                return 403, b'{"message":"API rate limit exceeded for installation."}', {"x-ratelimit-remaining": "0"}
            return 201, b"{}", {}

        client._send = send
        code = client.post("repos/o/r/statuses/" + HEAD, {"state": "success"})
        self.assertEqual(sent, ["workflow", "app"])
        self.assertEqual(code, 201)


if __name__ == "__main__":
    unittest.main()
