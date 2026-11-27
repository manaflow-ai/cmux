#!/usr/bin/env python3
"""scripts/ci/app_spend_mark.py: each App-minting workflow job prints its spend and keeps a budget floor.

Leo, 2026-11-18: "each minting workflow prints its spend from X-RateLimit headers, and they are summed" and "Every
App caller checks remaining budget first and degrades gracefully (keeps the last state, never false conclusions)
below a floor." The cmux-bot installation ran dry by mid-hour every hour; the overflow watch's pool pass then marked
every large Linux pool dead (tests/test_ci_runner_pools.py has that pass).
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import app_spend_mark as mark  # noqa: E402
import cloud_overflow_switch as switch  # noqa: E402
import hosted_light_rescue as rescue  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
POOL = {"limit": 12500, "used": 9000, "remaining": 3500, "reset": 1_800_000_000}


def publisher_fields(line: str) -> dict[str, int]:
    """What cmuxterm-hq's app_spend_publish.pool_rows() reads from one line (the same split)."""
    at = line.find(mark.POOL_MARK)
    words = line[at + len(mark.POOL_MARK):].split()
    fields = dict(word.split("=", 1) for word in words[1:] if "=" in word)
    return {"tag": words[0], **{key: int(fields[key]) for key in ("at", "limit", "used", "remaining", "reset")}}


class Run:
    def __init__(self, **env: str) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.output = Path(self.tmp.name) / "output"
        self.env = {"RUNNER_TEMP": self.tmp.name, "GITHUB_OUTPUT": str(self.output), "APP_SPEND_TOKEN": "t", **env}
        self.lines: list[str] = []

    def outputs(self) -> dict[str, str]:
        if not self.output.exists():
            return {}
        return dict(line.split("=", 1) for line in self.output.read_text().splitlines())


class Mark(unittest.TestCase):
    def test_start_and_end_print_the_publishers_pool_lines_and_the_jobs_spend(self) -> None:
        run = Run()
        mark.start("wf/job", None, run.env, read=lambda token: dict(POOL), now=lambda: 100, out=run.lines.append)
        mark.end("wf/job", run.env, read=lambda token: {**POOL, "used": 9042, "remaining": 3458}, now=lambda: 160,
                 out=run.lines.append)
        pools = [publisher_fields(line) for line in run.lines if line.startswith(mark.POOL_MARK)]
        self.assertEqual(pools, [{"tag": "wf/job", "at": 100, **POOL},
                                 {"tag": "wf/job", "at": 160, **POOL, "used": 9042, "remaining": 3458}])
        self.assertIn("app-spend: wf/job bash rest=42 graphql=0 gh=0 gh_paginate=0", run.lines)
        self.assertTrue(any("upper bound" in line for line in run.lines))

    def test_no_spend_line_across_a_reset(self) -> None:
        run = Run()
        mark.start("wf/job", None, run.env, read=lambda token: dict(POOL), out=run.lines.append)
        mark.end("wf/job", run.env, read=lambda token: {**POOL, "used": 10, "reset": POOL["reset"] + 3600},
                 out=run.lines.append)
        self.assertFalse(any(line.startswith(mark.SPEND_MARK) for line in run.lines))
        self.assertTrue(any("reset between start and end" in line for line in run.lines))

    def test_below_the_floor_the_pass_is_low_and_says_why(self) -> None:
        run = Run()
        mark.start("wf/job", mark.DEFAULT_FLOOR, run.env, read=lambda token: {**POOL, "remaining": 2499},
                   out=run.lines.append)
        self.assertEqual(run.outputs(), {"low": "true", "remaining": "2499"})
        self.assertTrue(any(line.startswith("::warning title=App budget::wf/job") and "keeps its last state" in line
                            for line in run.lines))
        run = Run()
        mark.start("wf/job", mark.DEFAULT_FLOOR, run.env, read=lambda token: {**POOL, "remaining": 2500},
                   out=run.lines.append)
        self.assertEqual(run.outputs()["low"], "false")

    def test_an_unread_pool_or_no_token_is_never_low_and_never_fails(self) -> None:
        run = Run()
        self.assertEqual(mark.start("wf/job", 99999, run.env, read=lambda token: None, out=run.lines.append), 0)
        self.assertEqual(run.outputs()["low"], "false")
        run = Run(APP_SPEND_TOKEN="")
        self.assertEqual(mark.start("wf/job", 99999, run.env, out=run.lines.append), 0)
        self.assertEqual(mark.end("wf/job", run.env, out=run.lines.append), 0)
        self.assertEqual(run.outputs()["low"], "false")
        self.assertTrue(all(line.startswith("app-spend-note:") for line in run.lines))

    def test_read_pool_reads_core_and_survives_a_refusal(self) -> None:
        body = json.dumps({"resources": {"core": POOL}}).encode()

        class Answer(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        self.assertEqual(mark.read_pool("t", opener=lambda request, timeout: Answer(body)), POOL)

        def refuse(request, timeout):
            raise urllib.error.HTTPError("u", 401, "bad credentials", {}, None)  # type: ignore[arg-type]
        self.assertIsNone(mark.read_pool("t", opener=refuse))

    def test_no_floor_is_under_hq_nows_reserve(self) -> None:
        # Coordinator, 2026-11-18: no cmux caller spends below NOW_RESERVE in hq#13472's app_budget.py.
        self.assertEqual(mark.APP_BUDGET_NOW_RESERVE, 1500)
        # 2026-11-20: the cmux-bot pool was spent ~18 min after every reset and next-autoland (hq floor 1,500)
        # never ran; no cmux caller may go under HQ's default floor (2,500), so that band stays HQ's.
        self.assertEqual(mark.DEFAULT_FLOOR, 2500)
        self.assertEqual(mark.parse_floor("pass"), mark.DEFAULT_FLOOR)
        self.assertEqual(mark.parse_floor("landing"), mark.DEFAULT_FLOOR)
        self.assertEqual(mark.parse_floor("100"), mark.DEFAULT_FLOOR)
        self.assertEqual(mark.parse_floor("1500"), mark.DEFAULT_FLOOR)
        self.assertEqual(mark.parse_floor("4000"), 4000)


def steps(workflow: str, job: str) -> list[dict]:
    return yaml.safe_load((WORKFLOWS / workflow).read_text())["jobs"][job]["steps"]


def named(all_steps: list[dict], name: str) -> dict:
    return next(step for step in all_steps if step.get("name") == name)


class Workflows(unittest.TestCase):
    # (workflow, job, script path in the job, floor argument or None)
    MARKED = [
        ("ci-cloud-overflow-probe.yml", "watch", "scripts/ci/app_spend_mark.py", "pass"),
        ("ci-hosted-backlog-rescue.yml", "backlog", "scripts/ci/app_spend_mark.py", "pass"),
        ("nightly-next-tick.yml", "unstick", ".tick-tooling/scripts/ci/app_spend_mark.py", "pass"),
        ("nightly-next-tick.yml", "request", ".tick-tooling/scripts/ci/app_spend_mark.py", "pass"),
        ("ci-failure-attribution.yml", "attribute", "scripts/ci/app_spend_mark.py", "pass"),
        ("ci-guard-attribution.yml", "analyze", "scripts/ci/app_spend_mark.py", "pass"),
        ("ci-guard-attribution.yml", "report", "scripts/ci/app_spend_mark.py", "pass"),
        ("ci-compile-attribution.yml", "analyze", "scripts/ci/app_spend_mark.py", "pass"),
        ("ci-compile-attribution.yml", "report", "scripts/ci/app_spend_mark.py", "pass"),
        ("ci-compile-attribution.yml", "fix", "scripts/ci/app_spend_mark.py", "pass"),
        ("ci-owned-pool-rescue.yml", "rescue", "scripts/ci/app_spend_mark.py", None),
    ]

    def test_every_marked_job_reads_its_pool_after_the_mint_and_at_the_end(self) -> None:
        for workflow, job, script, floor in self.MARKED:
            with self.subTest(workflow=workflow, job=job):
                all_steps = steps(workflow, job)
                tag = f"{workflow.removesuffix('.yml')}/{job}"
                [start] = [s for s in all_steps if f"app_spend_mark.py start {tag}" in str(s.get("run"))]
                [end] = [s for s in all_steps if f"app_spend_mark.py end {tag}" in str(s.get("run"))]
                self.assertEqual(start["id"], "app-spend")
                self.assertEqual(start["run"], f"python3 {script} start {tag}" + (f" --floor {floor}" if floor else ""))
                self.assertTrue(start["continue-on-error"] and end["continue-on-error"])
                self.assertEqual(end["if"], "always()")
                mint = next(i for i, s in enumerate(all_steps) if s.get("id") in ("cmux-bot-token", "read-token"))
                self.assertLess(mint, all_steps.index(start))
                # The script is checked out before it runs.
                checkout = next(i for i, s in enumerate(all_steps) if "actions/checkout" in str(s.get("uses")))
                self.assertLess(checkout, all_steps.index(start))
                for step in (start, end):
                    self.assertIn(step["env"]["APP_SPEND_TOKEN"], ("${{ steps.cmux-bot-token.outputs.token }}",
                                                                   "${{ steps.read-token.outputs.token }}"))

    def test_below_the_floor_the_cmux_bot_token_is_not_spent(self) -> None:
        for workflow, job, _, floor in self.MARKED:
            if not floor:
                continue
            with self.subTest(workflow=workflow, job=job):
                for step in steps(workflow, job):
                    for name, value in (step.get("env") or {}).items():
                        if name == "APP_SPEND_TOKEN" or "cmux-bot-token.outputs.token" not in str(value):
                            continue
                        gated = "steps.app-spend.outputs.low != 'true'"
                        self.assertTrue(gated in str(value) or gated in str(step.get("if")),
                                        f"{step.get('name')}: {name}={value}")

    def test_the_overflow_pool_pass_keeps_the_last_pools_below_the_floor(self) -> None:
        # The step that marked every large Linux pool dead on 2026-11-18 is skipped, RUNNER_POOLS left as it is.
        all_steps = steps("ci-cloud-overflow-probe.yml", "watch")
        for name in ("Point the runner pools at live members", "Check out the reviewed linux pool spill"):
            self.assertIn("steps.app-spend.outputs.low != 'true'", named(all_steps, name)["if"])
        # The end reading comes before the stuck-probe cancel, which ends the run.
        end = named(all_steps, "Read the cmux-bot budget after the pass")
        self.assertLess(all_steps.index(end), all_steps.index(named(all_steps, "End this run's stuck probe")))

    def test_the_backlog_and_unstick_passes_are_skipped_below_the_floor(self) -> None:
        backlog = named(steps("ci-hosted-backlog-rescue.yml", "backlog"), "Cancel and re-run the hosted backlog")
        self.assertEqual(backlog["if"], "steps.app-spend.outputs.low != 'true'")
        unstick = steps("nightly-next-tick.yml", "unstick")
        for name in ("Report a stuck nightly-next run and re-run its lost jobs once it ends",
                     "Re-run a cancelled nightly-next tip"):
            self.assertEqual(named(unstick, name)["if"], "steps.app-spend.outputs.low != 'true'")
        tooling = next(s for s in unstick if s.get("with", {}).get("path") == ".tick-tooling")
        self.assertNotIn("sparse-checkout", tooling["with"])  # the whole tooling tree: scripts/ci/app_spend_mark.py is in it

    def test_below_the_floor_the_tick_request_sends_nothing_as_the_app(self) -> None:
        # The request job's whole gh traffic goes through the App wrapper, so below the floor it is
        # not installed and every call stays github.token's.
        request = steps("nightly-next-tick.yml", "request")
        install = named(request, "Send this job's gh calls as the cmux-bot App, github.token as the fallback")
        self.assertIn("steps.app-spend.outputs.low != 'true'", install["if"])
        names = [s.get("name") for s in request]
        self.assertLess(names.index("Read the cmux-bot budget before the tick"), names.index(install["name"]))
        tooling = next(s for s in request if s.get("with", {}).get("path") == ".tick-tooling")
        self.assertNotIn("sparse-checkout", tooling["with"])  # the whole tooling tree: scripts/ci/app_spend_mark.py is in it

    def test_the_dev_dispatcher_reads_its_app_budget_and_falls_back_below_the_floor(self) -> None:
        all_steps = steps("cmux-next-dev-daily-dispatch.yml", "dispatch")
        before = named(all_steps, "Read the dispatcher App budget before the tick")
        after = named(all_steps, "Read the dispatcher App budget after the tick")
        dispatch = named(all_steps, "Dispatch the current feat-cmux-next tip when needed")
        self.assertEqual(before["id"], "app-spend")
        self.assertEqual(int(before["env"]["FLOOR"]), mark.APP_BUDGET_NOW_RESERVE)
        self.assertIn(mark.POOL_MARK.strip(), before["with"]["script"])
        self.assertIn(mark.SPEND_MARK.strip(), after["with"]["script"])
        self.assertTrue(after["if"].startswith("always()"))
        self.assertEqual(dispatch["env"]["APP_TOKEN"],
                         "${{ steps.app-spend.outputs.low != 'true' && steps.app-token.outputs.token || '' }}")


class ConditionalReads(unittest.TestCase):
    """The overflow watch polls its own run's jobs every POLL_SECONDS: an unchanged listing answers 304 (free)."""

    class Answer(io.BytesIO):
        def __init__(self, body: bytes, etag: str | None) -> None:
            super().__init__(body)
            self.headers = {"ETag": etag} if etag else {}

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def test_a_repeated_read_is_conditional_and_a_304_returns_the_cached_body(self) -> None:
        api = switch.GitHub("bot", "manaflow-ai/cmux", "workflow")
        body = json.dumps({"jobs": [{"name": "Blacksmith probe (x)", "status": "queued"}]}).encode()
        sent = []

        def urlopen(request, timeout):
            sent.append(request.get_header("If-none-match"))
            if len(sent) == 1:
                return self.Answer(body, 'W/"abc"')
            raise urllib.error.HTTPError(request.full_url, 304, "Not Modified", {}, None)  # type: ignore[arg-type]

        with mock.patch.object(switch.urllib.request, "urlopen", side_effect=urlopen):
            first = api.jobs(7, 1)
            again = api.jobs(7, 1)
        self.assertEqual(sent, [None, 'W/"abc"'])
        self.assertEqual(first, again)
        self.assertEqual(again[0]["status"], "queued")

    def test_a_304_without_a_cached_body_is_still_an_error(self) -> None:
        api = switch.GitHub("bot", "manaflow-ai/cmux")

        def urlopen(request, timeout):
            raise urllib.error.HTTPError(request.full_url, 304, "Not Modified", {}, None)  # type: ignore[arg-type]

        with mock.patch.object(switch.urllib.request, "urlopen", side_effect=urlopen):
            with self.assertRaises(RuntimeError):
                api.jobs(7, 1)


class RescueReserve(unittest.TestCase):
    def test_the_cmux_bot_pool_stops_at_hqs_default_floor(self) -> None:
        client = rescue.GitHub("bot", "o/r", fallback="workflow")
        client.pools["primary"].remaining = mark.DEFAULT_FLOOR
        client.pools["primary"].reset = 2_000_000_000
        self.assertEqual(client.read_pool(now=1_900_000_000), "fallback")
        client.pools["primary"].remaining = mark.DEFAULT_FLOOR + 1
        self.assertEqual(client.read_pool(now=1_900_000_000), "primary")
        # A lone token (no fallback, so not necessarily the App) keeps the old reserve.
        alone = rescue.GitHub("only", "o/r")
        self.assertEqual(alone.pools["primary"].reserve, rescue.POOL_RESERVE)


if __name__ == "__main__":
    unittest.main()
