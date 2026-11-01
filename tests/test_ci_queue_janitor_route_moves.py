#!/usr/bin/env python3
"""The queue janitor re-runs jobs a route move left on the old label (scripts/ci/route_moves.py).

Coordinator, 2026-11-01: "Better: make it a queue-janitor action that does this automatically when the route
changes, so nobody re-runs by hand next time." About 2,000 cmux runs sat queued on
blacksmith-32vcpu-ubuntu-2404 after LINUX_RUNNER moved off it, because GitHub binds a job's label when it
creates the job."""

from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
from test_ci_queue_janitor import NOW, FakeGitHub, iso, janitor, make_pr, make_run  # noqa: E402
import route_moves  # noqa: E402

OLD = "blacksmith-32vcpu-ubuntu-2404"
NEW = "blacksmith-16vcpu-ubuntu-2404"
SMALL = "blacksmith-4vcpu-ubuntu-2404"
MOVED_AT = NOW - dt.timedelta(minutes=30)
MOVE = route_moves.Move("LINUX_RUNNER", OLD, NEW, MOVED_AT)
POOL_MOVE = route_moves.Move("RUNNER_POOLS.linux", OLD, NEW, MOVED_AT)
VALUES = {"LINUX_RUNNER": NEW, "RUNNER_POOLS": json.dumps({"linux": NEW}), "CI_CLOUD_OVERFLOW_SAVED": ""}
SAME_REPO = {"github.repository_owner": "manaflow-ai", "github.repository": "manaflow-ai/cmux",
             "github.event_name": "pull_request",
             "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux"}
OWNER = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
FORK = ("github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != "
        f"github.repository && '{SMALL}' || ")
SHAPES = {
    "plain": "${{ %svars.LINUX_RUNNER || '%s' }}" % (OWNER, SMALL),
    "fork guard": "${{ %s%svars.LINUX_RUNNER || '%s' }}" % (OWNER, FORK, SMALL),
    "allowlist": ("${{ %scontains(fromJSON('[\"%s\",\"%s\",\"%s\"]'), vars.LINUX_RUNNER) && vars.LINUX_RUNNER "
                  "|| '%s' }}" % (OWNER, SMALL, NEW, OLD, SMALL)),
}
PLAIN = SHAPES["plain"]
POOLED = "${{ %sfromJSON(vars.RUNNER_POOLS).linux }}" % OWNER


def workflow(jobs: dict) -> str:
    return yaml.safe_dump({"name": "Lint", "on": ["push", "pull_request"], "jobs": jobs}, sort_keys=False)


LINT = workflow({"lint": {"name": "Lint", "runs-on": PLAIN, "steps": [{"run": "true"}]},
                 "mac": {"name": "macOS", "runs-on": "blacksmith-6vcpu-macos-15", "steps": [{"run": "true"}]}})


def queued(name: str, label: str = OLD, age: float = 25, **extra) -> dict:
    return {"id": next(IDS), "status": "queued", "name": name, "labels": [label], "created_at": iso(age),
            "runner_id": 0, "runner_name": None, **extra}


IDS = iter(range(900000, 999999))


class Record(unittest.TestCase):
    def test_a_move_is_recorded_replaced_expired_and_dropped_when_it_moves_back(self) -> None:
        first = route_moves.record_moves([], [("LINUX_RUNNER", OLD, NEW)], current={"LINUX_RUNNER": NEW}, now=NOW)
        self.assertEqual(first, [{"variable": "LINUX_RUNNER", "from": OLD, "to": NEW, "at": route_moves.iso(NOW)}])
        # Nothing moved from an unset value or to the same label.
        self.assertEqual(route_moves.record_moves([], [("LINUX_RUNNER", None, NEW), ("LINUX_RUNNER", NEW, NEW)],
                                                  current={}, now=NOW), [])
        later = NOW + dt.timedelta(minutes=10)
        again = route_moves.record_moves(first, [("LINUX_RUNNER", OLD, SMALL)], current={"LINUX_RUNNER": SMALL},
                                         now=later)
        self.assertEqual([(e["from"], e["to"], e["at"]) for e in again], [(OLD, SMALL, route_moves.iso(later))])
        # Back on the old label: its jobs are where the route points, so the entry goes.
        self.assertEqual(route_moves.record_moves(first, [], current={"LINUX_RUNNER": OLD}, now=later), [])
        expired = NOW + route_moves.MOVE_TTL + dt.timedelta(minutes=1)
        self.assertEqual(route_moves.record_moves(first, [], current={"LINUX_RUNNER": NEW}, now=expired), [])
        self.assertEqual(route_moves.parse_moves(first, now=expired), [])
        self.assertEqual(route_moves.record_moves([{"variable": "x"}, "junk"], [], current={}, now=NOW), [])

    def test_the_janitor_reads_moves_from_the_runner_pools_value(self) -> None:
        raw = json.dumps({"linux": NEW, "_moved": [{"variable": "LINUX_RUNNER", "from": OLD, "to": NEW,
                                                    "at": route_moves.iso(MOVED_AT)}]})
        moves, why = route_moves.moves_in(raw, now=NOW)
        self.assertEqual((moves, why), ([MOVE], ""))
        self.assertEqual(route_moves.moves_in(None, now=NOW)[0], [])
        self.assertEqual(route_moves.moves_in("{nope", now=NOW)[0], [])
        self.assertEqual(route_moves.moves_in(json.dumps({"linux": NEW}), now=NOW)[0], [])


class Qualifies(unittest.TestCase):
    def test_every_linux_runner_shape_on_main_moves_to_the_new_label(self) -> None:
        for shape, runs_on in SHAPES.items():
            with self.subTest(shape=shape):
                self.assertEqual(route_moves.qualifies(runs_on, MOVE, VALUES, SAME_REPO)[0], NEW)
        self.assertEqual(route_moves.qualifies(POOLED, POOL_MOVE, VALUES, SAME_REPO)[0], NEW)

    def test_a_label_the_variable_did_not_give_is_left_alone(self) -> None:
        fork = dict(SAME_REPO, **{"github.event.pull_request.head.repo.full_name": "someone/cmux"})
        cases = {
            "literal": (f"{OLD}", MOVE, VALUES, SAME_REPO),
            "literal expression": ("${{ '%s' }}" % OLD, MOVE, VALUES, SAME_REPO),
            "fork pull request": (SHAPES["fork guard"], MOVE, VALUES, fork),
            "an input": ("${{ inputs.runner || vars.LINUX_RUNNER }}", MOVE, VALUES, SAME_REPO),
            "a variable not handed in": ("${{ vars.OTHER || vars.LINUX_RUNNER }}", MOVE, VALUES, SAME_REPO),
            "a re-run lands on the old label again": (PLAIN, MOVE, dict(VALUES, LINUX_RUNNER=OLD), SAME_REPO),
            "another variable": (POOLED, MOVE, VALUES, SAME_REPO),
            "unreadable": (None, MOVE, VALUES, SAME_REPO),
            "the old value falls back to a literal": (SHAPES["allowlist"].replace(f',"{OLD}"', ""), MOVE, VALUES,
                                                      SAME_REPO),
        }
        for case, (runs_on, move, values, context) in cases.items():
            with self.subTest(case=case):
                self.assertIsNone(route_moves.qualifies(runs_on, move, values, context)[0])

    def test_jobs_are_found_by_name_through_matrices_and_reusable_workflows(self) -> None:
        caller = workflow({"linux": {"uses": "./.github/workflows/linux.yml"},
                           "test": {"name": "test (${{ matrix.shard }})", "runs-on": PLAIN,
                                    "strategy": {"matrix": {"shard": [1, 2]}}, "steps": [{"run": "true"}]}})
        callee = workflow({"build": {"name": "Build", "runs-on": POOLED, "steps": [{"run": "true"}]}})
        files = {".github/workflows/ci.yml": caller, ".github/workflows/linux.yml": callee}
        self.assertEqual(route_moves.runs_on_of(files.get, ".github/workflows/ci.yml", "linux / Build"), POOLED)
        self.assertEqual(route_moves.runs_on_of(files.get, ".github/workflows/ci.yml", "test (2)"), PLAIN)
        self.assertIsNone(route_moves.runs_on_of(files.get, ".github/workflows/ci.yml", "nope"))


class RouteLost(unittest.TestCase):
    def find(self, runs, jobs, files=None, moves=(MOVE,)):
        texts = files or {".github/workflows/lint.yml": LINT}
        return janitor.route_lost(runs, jobs, list(moves), now=NOW, values=VALUES, repo="manaflow-ai/cmux",
                                  read=lambda sha, path: texts.get(path))

    def test_a_queued_job_on_the_old_label_is_lost_and_the_rest_are_left_alone(self) -> None:
        lint = dict(path=".github/workflows/lint.yml", name="Lint", status="queued", sha="a" * 40)
        moved = make_run(age=60, **lint)
        after = make_run(age=10, **lint)  # created after the move: its jobs read the new value
        assigned = make_run(age=60, **lint)
        gated = make_run(age=60, **lint)
        nightly = make_run(age=60, event="push", branch="nightly-next", **dict(lint, path=".github/workflows/nightly.yml",
                                                                              name="Nightly macOS build"))
        literal = make_run(age=60, **lint)
        jobs = {
            moved["id"]: [queued("Lint")],
            after["id"]: [queued("Lint", age=8)],
            assigned["id"]: [queued("Lint", runner_id=7, runner_name="blacksmith-abc")],
            gated["id"]: [queued("Lint"), {"id": 1, "status": "in_progress", "name": "macOS", "runner_id": 3,
                                           "labels": ["blacksmith-6vcpu-macos-15"], "created_at": iso(40)}],
            nightly["id"]: [queued("Lint")],
            literal["id"]: [queued("macOS")],
        }
        nightly_files = {".github/workflows/lint.yml": LINT, ".github/workflows/nightly.yml": LINT}
        found, lines = self.find([moved, after, assigned, gated, nightly, literal], jobs, nightly_files)
        self.assertEqual(set(found), {moved["id"]})
        self.assertIn("LINUX_RUNNER moved", found[moved["id"]].route)
        self.assertEqual(found[moved["id"]].labels, OLD)
        self.assertTrue(any("another job of the run is unfinished" in line for line in lines))

    def test_a_route_lost_job_takes_category_e_verdicts(self) -> None:
        run = make_run(age=60, prs=(5,), sha="b" * 40)
        lost = janitor.LostJob("Lint", OLD, NOW - dt.timedelta(minutes=50), 0, 1, (1,), route=MOVE.line())
        stale = janitor.classify_lost(run, [queued("Lint")], lost, [make_pr(5, state="MERGED", head=run["head_sha"])],
                                      now=NOW, rerun_state=True)
        self.assertEqual(stale.action, "cancel")
        self.assertIn("route moved", stale.reason)
        open_pr = [make_pr(5, head=run["head_sha"])]
        kept = janitor.classify_lost(run, [queued("Lint")], lost, open_pr, now=NOW, rerun_state=True, cmux_bot=False)
        self.assertEqual(kept.action, "skip")  # an open head without cmux-bot keeps OPEN_HEAD_RULE
        failover = janitor.classify_lost(run, [queued("Lint")], lost, open_pr, now=NOW, rerun_state=True,
                                         cmux_bot=True)
        self.assertEqual((failover.action, failover.open_head, failover.rerun), ("cancel", True, True))


class Sweep(unittest.TestCase):
    """main() end to end over FakeGitHub: a lint run on a linux-only workflow, so only the route pass lists it."""

    def sweep(self, *args, fake_class=FakeGitHub, pools=None):
        stale = make_run(age=60, prs=(5,), branch="stale", path=".github/workflows/lint.yml", name="Lint",
                         status="queued", sha="c" * 40)
        runs = {stale["id"]: dict(stale)}
        jobs = {stale["id"]: [queued("Lint")]}
        fake = fake_class(runs, jobs)
        fake.prs = {"stale": [make_pr(5, state="CLOSED", head=stale["head_sha"])]}
        raw = pools if pools is not None else json.dumps(
            {"linux": NEW, "_moved": [{"variable": "LINUX_RUNNER", "from": OLD, "to": NEW,
                                       "at": route_moves.iso(MOVED_AT)}]})

        class Files:
            def __init__(self, *a, **k):
                self.reads = 0

            def read(self, sha, path):
                self.reads += 1
                return {".github/workflows/lint.yml": LINT}.get(path) if sha == stale["head_sha"] else None

            def line(self):
                return f"{self.reads} workflow file reads"

        with tempfile.TemporaryDirectory() as temp:
            workflows = Path(temp) / "workflows"
            workflows.mkdir()
            # Linux-only on main, so the inventory does not list its runs; only the route pass does.
            (workflows / "lint.yml").write_text(workflow({"lint": {"name": "Lint", "runs-on": PLAIN,
                                                                   "steps": [{"run": "true"}]}}))
            summary = Path(temp) / "summary.md"
            argv = ["--repo", "manaflow-ai/cmux", "--summary", str(summary), "--workflows-dir", str(workflows), *args]
            env = {"GH_TOKEN": "t", "RUNNER_POOLS": raw, "LINUX_RUNNER": NEW, "CI_CLOUD_OVERFLOW_SAVED": ""}
            with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": fake), \
                    mock.patch.object(route_moves, "WorkflowFiles", Files), \
                    mock.patch.dict("os.environ", env), \
                    mock.patch.object(janitor.time, "sleep", lambda _: None), \
                    mock.patch.object(janitor, "utc_now", lambda: NOW), \
                    mock.patch("builtins.print"):
                code = janitor.main(argv)
            text = summary.read_text() if summary.exists() else ""
        return code, fake, text, stale

    def test_a_stale_run_left_on_the_old_label_is_cancelled(self) -> None:
        code, fake, text, stale = self.sweep()
        self.assertEqual(code, 0)
        self.assertEqual(fake.posts(), [[str(stale["id"]), "cancel"]])
        self.assertIn("### Route moves", text)
        self.assertIn(f"LINUX_RUNNER `{OLD}` -> `{NEW}`", text)
        self.assertIn("1 extra job listings for route moves", text)

    def test_dry_run_cancels_nothing_and_no_move_lists_nothing(self) -> None:
        code, fake, text, _ = self.sweep("--dry-run")
        self.assertEqual((code, fake.posts()), (0, []))
        self.assertIn("### Route moves (dry run)", text)
        code, fake, text, stale = self.sweep(pools=json.dumps({"linux": NEW}))
        self.assertEqual(fake.posts(), [])
        self.assertNotIn(("GET", f"/repos/manaflow-ai/cmux/actions/runs/{stale['id']}/jobs?filter=latest&per_page=100"
                          "&page=1"), fake.log)
        self.assertIn("Route moves: none", text)

    def test_a_rate_limit_on_a_route_listing_stops_before_any_cancel(self) -> None:
        class Limited(FakeGitHub):
            def jobs(self, run_id):
                raise janitor.RateLimited("GET /actions/runs/1/jobs failed (403: rate limit)")

        code, fake, _, _ = self.sweep(fake_class=Limited)
        # A rate limit ends the sweep green with a warning (main()), before anything is cancelled.
        self.assertEqual(code, 0)
        self.assertIn("rate limit", fake.rate_limited)
        self.assertEqual(fake.posts(), [])


class Wiring(unittest.TestCase):
    def test_the_janitor_step_hands_in_the_routing_values(self) -> None:
        doc = yaml.safe_load((ROOT / ".github/workflows/ci-queue-janitor.yml").read_text())
        step = next(step for step in doc["jobs"]["sweep"]["steps"] if "queue_janitor.py" in str(step.get("run")))
        for name in route_moves.VALUE_VARIABLES:
            self.assertEqual(step["env"].get(name), "${{ vars.%s }}" % name)


class GitReads(unittest.TestCase):
    def test_a_workflow_file_is_read_at_a_commit_over_git(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source"
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@t"}

            def git(*args):
                return subprocess.run(["git", "-C", str(source), *args], check=True, capture_output=True, text=True,
                                      env=env).stdout.strip()

            source.mkdir()
            git("init", "-q")
            git("config", "uploadpack.allowfilter", "true")
            git("config", "uploadpack.allowanysha1inwant", "true")
            (source / ".github/workflows").mkdir(parents=True)
            (source / ".github/workflows/lint.yml").write_text(LINT)
            git("add", ".")
            git("commit", "-q", "-m", "one")
            sha = git("rev-parse", "HEAD")
            (source / ".github/workflows/lint.yml").write_text("changed")
            git("commit", "-q", "-am", "two")
            api_calls = []
            files = route_moves.WorkflowFiles("manaflow-ai/cmux", api=lambda path: api_calls.append(path) or {},
                                              git_url=f"file://{source}", max_reads=2)
            self.assertEqual(files.read(sha, ".github/workflows/lint.yml"), LINT)
            self.assertEqual((files.git_reads, api_calls), (1, []))
            # Not a full sha, or past the cap: no read at all.
            self.assertIsNone(files.read("abc", ".github/workflows/lint.yml"))
            files.read(sha, ".github/workflows/missing.yml")  # git cannot: one API fallback
            self.assertEqual(len(api_calls), 1)
            self.assertIsNone(files.read(sha, ".github/workflows/other.yml"))
            self.assertEqual(files.refused, 1)


if __name__ == "__main__":
    unittest.main()
