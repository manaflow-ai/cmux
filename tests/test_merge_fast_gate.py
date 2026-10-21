"""scripts/ci/merge_fast_gate.py against a fake PR: no network, no sleeping."""
import contextlib
import importlib.util
import io
import re
import subprocess
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("merge_fast_gate", ROOT / "scripts/ci/merge_fast_gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
HEAD = "a" * 40


def check(name, status="COMPLETED", conclusion="SUCCESS", started=None, completed=None):
    return {"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion,
            "startedAt": started, "completedAt": completed}


class Reader:
    """Returns one rollup per poll; the last one repeats."""

    def __init__(self, *polls, files=("Packages/macOS/CmuxNext/Sources/A.swift",), head=HEAD, bases=("feat-cmux-next",)):
        self.polls, self.files, self.head, self.bases, self.calls, self.args = list(polls), files, head, bases, 0, None

    def __call__(self, *args):
        self.calls += 1
        self.args = args
        rollup = self.polls[min(self.calls, len(self.polls)) - 1]
        base = self.bases[min(self.calls, len(self.bases)) - 1]
        return {"headRefOid": self.head, "baseRefName": base, "files": [{"path": f} for f in self.files],
                "statusCheckRollup": rollup}


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def run(reader, timeout=600, covered=True):
    clock = Clock()
    return gate.run("manaflow-ai/cmux", "42", HEAD, timeout, 30, covered, read=reader, clock=clock, sleep=clock.sleep,
                    base="feat-cmux-next")


NEXT_WORKFLOW = """name: cmux-next
on:
  pull_request:
    paths:
      - Packages/macOS/CmuxNext/**
jobs:
  path_route:
    name: cmux-next path routing
    runs-on: ubuntu-latest
  checks:
    name: cmux-next checks (god files, concurrency, crash safety, l10n)
  swift-canary:
    name: cmux-next Swift canary
  fast-tier:
    name: cmux-next fast tier
  swift-test:
    name: cmux-next swift test
  release-compile:
    name: cmux-next Release compile (Xcode 26)
  cmux-scheme-compile:
    name: ${{ inputs.dev_daily == true && 'cmux NEXT DEV Release compile' || 'cmux app scheme compile (Debug)' }}
"""
CI_WORKFLOW = """name: CI
jobs:
  changes:
    runs-on: ubuntu-latest
  web:
    needs: [changes]
    uses: ./.github/workflows/ci-web.yml
"""
WEB_WORKFLOW = """name: Web
on:
  workflow_call:
jobs:
  react-apps-check-shard:
    name: react-apps-check (${{ matrix.shard }})
  react-apps-check:
    needs: [react-apps-check-shard]
"""


GREEN = [check("cmux-next path routing"), check("cmux-next fast tier"), check("cmux-next Swift canary"),
         check("cmux app scheme compile (Debug)", conclusion="SKIPPED"), check("cmux-next swift test", "IN_PROGRESS", "")]


class FastGate(unittest.TestCase):
    def test_passes_when_the_fast_lanes_are_green_while_the_full_suites_run(self):
        waited, seen, reds = run(Reader(GREEN))
        self.assertEqual(waited, 0)
        self.assertEqual(seen, ["cmux-next Swift canary", "cmux-next fast tier", "cmux-next path routing"])
        self.assertEqual(reds, [])

    def test_waits_for_routing_then_the_fast_tier(self):
        polls = ([], [check("cmux-next path routing", "IN_PROGRESS", "")],
                 [check("cmux-next path routing")], [check("cmux-next path routing"), check("cmux-next fast tier")])
        reader = Reader(*polls)
        waited, seen, _ = run(reader)
        self.assertEqual(reader.calls, 4)
        self.assertEqual(waited, 90)
        self.assertIn("cmux-next fast tier", seen)

    def test_a_change_outside_cmux_next_and_webviews_needs_no_lane(self):
        waited, seen, reds = run(Reader([], files=("docs/README.md",)), covered=False)
        self.assertEqual((waited, seen, reds), (0, [], []))

    def test_a_webviews_change_waits_for_react_apps_check(self):
        reader = Reader([], [check("web / react-apps-check", "IN_PROGRESS", "")], [check("web / react-apps-check")],
                        files=("webviews/src/a.ts",))
        waited, seen, _ = run(reader, covered=False)
        self.assertEqual(seen, ["web / react-apps-check"])
        self.assertEqual(waited, 60)

    def test_completed_reds_in_fast_lanes_and_gating_families_are_reported_pending_ones_are_not(self):
        rollup = GREEN + [check("app-size", conclusion="FAILURE"), check("render (head, 0)", conclusion="FAILURE"),
                          check("web / Web status", "IN_PROGRESS", "")]
        rollup[1] = check("cmux-next fast tier", conclusion="FAILURE")
        _, _, reds = run(Reader(rollup))
        self.assertEqual(reds, ["app-size", "cmux-next fast tier"])

    def test_a_red_cargo_fast_tier_is_reported(self):
        """The fast tier's cargo entries run in their own Linux job; its red is a fast-lane red."""
        _, seen, reds = run(Reader(GREEN + [check("cmux-next fast tier (cargo)", conclusion="FAILURE")]))
        self.assertIn("cmux-next fast tier (cargo)", seen)
        self.assertEqual(reds, ["cmux-next fast tier (cargo)"])

    def test_completed_reds_in_the_full_gate_lanes_are_reported_pending_ones_are_not(self):
        """The fast gate does not wait for ci-status, the swift test or the Release compile,
        but a completed red one is judged as the full gate judges it."""
        names = ("ci-status", "cmux-next swift test", "cmux-next Release compile (Xcode 26)")
        rollup = [c for c in GREEN if c["name"] not in names] + [check(n, conclusion="FAILURE") for n in names]
        _, _, reds = run(Reader(rollup))
        self.assertEqual(reds, sorted(names))
        rollup = [c for c in GREEN if c["name"] not in names] + [check(n, "IN_PROGRESS", "") for n in names]
        self.assertEqual(run(Reader(rollup))[2], [])

    def test_lint_checks_are_waited_for_and_a_red_one_goes_to_the_base(self):
        """Like the full gate (#22128): god-file, l10n and concurrency lint must complete on
        the exact head. A red one goes to gh-merge-green, which asks the base whether it
        prints every finding too or takes a human --override. One with no verdict refuses,
        as in the full gate, which takes only success, neutral, skipped or failure."""
        lint = "cmux-next checks (god files, concurrency, crash safety, l10n)"
        with self.assertRaisesRegex(gate.Refused, "still waiting on " + re.escape(lint)):
            run(Reader(GREEN + [check(lint, "IN_PROGRESS", "")]), timeout=60)
        for conclusion in ("CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"):
            with self.subTest(conclusion=conclusion):
                with self.assertRaisesRegex(gate.Refused, re.escape(lint) + ".*no verdict"):
                    run(Reader(GREEN + [check(lint, conclusion=conclusion)]))
        _, seen, reds = run(Reader(GREEN + [check(lint, conclusion="FAILURE")]))
        self.assertIn(lint, seen)
        self.assertEqual(reds, [lint])
        _, seen, reds = run(Reader(GREEN + [check(lint)]))
        self.assertIn(lint, seen)
        self.assertEqual(reds, [])

    def test_a_red_risk_evidence_refuses(self):
        with self.assertRaisesRegex(gate.Refused, "risk evidence.*never waived"):
            run(Reader(GREEN + [check("risk evidence", conclusion="FAILURE")]))

    def test_a_rerun_replaces_the_earlier_verdict(self):
        rollup = GREEN + [check("cmux-next fast tier", conclusion="FAILURE"), check("cmux-next fast tier")]
        rollup.pop(1)
        _, _, reds = run(Reader(rollup))
        self.assertEqual(reds, [])

    def test_the_latest_started_run_wins_whatever_the_rollup_order(self):
        """The rollup is not ordered by time: an older green listed after a newer red must not hide it."""
        rollup = [c for c in GREEN if c["name"] != "cmux-next fast tier"] + [
            check("cmux-next fast tier", conclusion="FAILURE", started="2026-10-14T10:05:00Z", completed="2026-10-14T10:09:00Z"),
            check("cmux-next fast tier", started="2026-10-14T09:00:00Z", completed="2026-10-14T09:04:00Z")]
        _, _, reds = run(Reader(rollup))
        self.assertEqual(reds, ["cmux-next fast tier"])
        rollup[-2] = check("cmux-next fast tier", conclusion="CANCELLED", started="2026-10-14T10:05:00Z", completed="2026-10-14T10:09:00Z")
        with self.assertRaisesRegex(gate.Refused, "no verdict"):
            run(Reader(rollup))
        # Equal start times fall back to completedAt, then list order.
        rollup = [c for c in GREEN if c["name"] != "cmux-next fast tier"] + [
            check("cmux-next fast tier", conclusion="FAILURE", started="2026-10-14T10:00:00Z", completed="2026-10-14T10:09:00Z"),
            check("cmux-next fast tier", started="2026-10-14T10:00:00Z", completed="2026-10-14T10:02:00Z")]
        _, _, reds = run(Reader(rollup))
        self.assertEqual(reds, ["cmux-next fast tier"])

    def test_a_webviews_change_stops_waiting_when_the_web_caller_finished_or_skipped_it(self):
        """No react-apps-check is coming once the caller job "web" finished, or react-apps-check was skipped."""
        for rollup in ([check("web")], [check("web", conclusion="SKIPPED")], [check("web / react-apps-check", conclusion="SKIPPED")]):
            with self.subTest(rollup=rollup):
                waited, _, reds = run(Reader(rollup, files=("webviews/src/a.ts",)), covered=False)
                self.assertEqual((waited, reds), (0, []))
        # A red caller with no react-apps-check is a red, not a pass.
        _, _, reds = run(Reader([check("web", conclusion="FAILURE")], files=("webviews/src/a.ts",)), covered=False)
        self.assertEqual(reds, ["web"])
        # A running caller still waits.
        with self.assertRaisesRegex(gate.Refused, "react-apps-check"):
            run(Reader([check("web", "IN_PROGRESS", "")], files=("webviews/src/a.ts",)), timeout=60, covered=False)

    def test_risk_evidence_is_waited_for_and_a_red_one_refuses(self):
        """Like the full gate (#21692): risk evidence reads only the description, so it is
        never base-red and never waived here; the risk:waived label is its waiver."""
        with self.assertRaisesRegex(gate.Refused, "still waiting on risk evidence"):
            run(Reader(GREEN + [check("risk evidence", "IN_PROGRESS", "")]), timeout=60)
        for conclusion in ("FAILURE", "CANCELLED"):
            with self.subTest(conclusion=conclusion):
                with self.assertRaisesRegex(gate.Refused, "risk evidence"):
                    run(Reader(GREEN + [check("risk evidence", conclusion=conclusion)]))
        _, seen, reds = run(Reader(GREEN + [check("risk evidence")]))
        self.assertIn("risk evidence", seen)
        self.assertEqual(reds, [])

    def test_a_retargeted_base_refuses_mid_wait(self):
        """gh pr merge --match-head-commit pins the head, not the base: a PR moved from
        feat-cmux-next to main while the gate waits must not merge on the fast gate."""
        reader = Reader([check("cmux-next path routing", "IN_PROGRESS", "")], GREEN, bases=("feat-cmux-next", "main"))
        with self.assertRaisesRegex(gate.Refused, "base changed to main"):
            run(reader)
        self.assertIn("baseRefName", ",".join(reader.args))

    def test_a_cancelled_or_timed_out_fast_lane_has_no_verdict_to_waive(self):
        for conclusion in ("CANCELLED", "TIMED_OUT", "STARTUP_FAILURE", "STALE"):
            rollup = [c for c in GREEN if c["name"] != "cmux-next fast tier"] + [check("cmux-next fast tier", conclusion=conclusion)]
            with self.subTest(conclusion=conclusion), self.assertRaisesRegex(gate.Refused, "cmux-next fast tier.*no verdict"):
                run(Reader(rollup))

    def test_a_skipped_fast_tier_has_no_verdict(self):
        """cmux-next.yml skips the fast tier on a PR when push-head-preflight is not current
        (a runner failure or its timeout): that is no verdict, not a pass."""
        rollup = [c for c in GREEN if c["name"] != "cmux-next fast tier"] + [check("cmux-next fast tier", conclusion="SKIPPED")]
        with self.assertRaisesRegex(gate.Refused, "cmux-next fast tier.*no verdict"):
            run(Reader(rollup))
        self.assertEqual(run(Reader(rollup, files=("docs/README.md",)), covered=False)[2], [])

    def test_the_callers_full_file_list_routes_web(self):
        """gh pr view --json files stops at 100 files; the helper passes its paginated list,
        so a web file past the first 100 still waits for react-apps-check."""
        clock = Clock()
        reader = Reader([], files=tuple(f"docs/{i}.md" for i in range(100)))
        with self.assertRaisesRegex(gate.Refused, "react-apps-check"):
            gate.run("manaflow-ai/cmux", "42", HEAD, 60, 30, False, read=reader, clock=clock, sleep=clock.sleep,
                     base="feat-cmux-next", files=[*reader.files, "webviews/src/a.ts"])

    def test_a_raw_expression_name_is_the_lane_it_names(self):
        """A job whose name is an expression can report under the raw text (#21981)."""
        raw = "inputs.dev_daily == true && 'cmux NEXT DEV Release compile' || 'cmux app scheme compile (Debug)'"
        base = [c for c in GREEN if not c["name"].startswith("cmux app scheme")]
        with self.assertRaisesRegex(gate.Refused, re.escape("still waiting on cmux app scheme compile (Debug)")):
            run(Reader(base + [check(raw, "QUEUED", "")]), timeout=60)
        _, _, reds = run(Reader(base + [check(raw, conclusion="FAILURE")]))
        self.assertEqual(reds, ["cmux app scheme compile (Debug)"])
        self.assertEqual(run(Reader(base + [check(raw, conclusion="SKIPPED")]))[2], [])

    def test_web_routing_follows_ci_change_areas_not_just_webviews(self):
        """react-apps-check runs behind ci.yml's web job, which detect_ci_change_areas.py routes."""
        for path in ("config/vite-plus/check.ts", "Resources/markdown-viewer/viewer.js", "webviews/src/a.ts"):
            with self.subTest(path=path), self.assertRaisesRegex(gate.Refused, "react-apps-check"):
                run(Reader([], files=(path,)), timeout=60, covered=False)
        self.assertEqual(run(Reader([], files=("docs/README.md",)), covered=False), (0, [], []))

    def test_a_running_web_caller_waits_for_react_apps_check_whatever_the_files(self):
        with self.assertRaisesRegex(gate.Refused, "react-apps-check"):
            run(Reader([check("web", "IN_PROGRESS", "")], files=("docs/README.md",)), timeout=60, covered=False)
        self.assertEqual(run(Reader([check("web", "IN_PROGRESS", ""), check("web / react-apps-check", conclusion="SKIPPED")],
                                    files=("docs/README.md",)), covered=False)[2], [])

    def test_every_name_the_gate_keys_on_is_a_job_name(self):
        self.assertEqual(gate.missing_job_names(NEXT_WORKFLOW, CI_WORKFLOW, WEB_WORKFLOW), [])
        renamed = NEXT_WORKFLOW.replace("cmux-next checks (god files, concurrency, crash safety, l10n)", "cmux-next checks")
        self.assertEqual(gate.missing_job_names(renamed, CI_WORKFLOW, WEB_WORKFLOW), ["a god-file, l10n or concurrency lint job"])
        renamed = NEXT_WORKFLOW.replace("'cmux app scheme compile (Debug)'", "'cmux app compile'")
        self.assertEqual(gate.missing_job_names(renamed, CI_WORKFLOW, WEB_WORKFLOW), ["cmux app scheme compile (Debug)"])
        self.assertEqual(gate.missing_job_names(NEXT_WORKFLOW, CI_WORKFLOW.replace("  web:", "  webs:"), WEB_WORKFLOW),
                         ["web / react-apps-check"])
        self.assertEqual(gate.missing_job_names(NEXT_WORKFLOW, CI_WORKFLOW, WEB_WORKFLOW.replace("  react-apps-check:", "  react-check:")),
                         ["web / react-apps-check"])
        self.assertEqual(gate.missing_job_names("", None, None)[0], "cmux-next path routing")

    def test_the_checked_in_workflows_still_name_every_lane(self):
        """The web side reads this tree's ci.yml and ci-web.yml. cmux-next.yml is a stub on main,
        so its side reads feat-cmux-next's when this clone has it; gh-merge-green also checks
        the PR head's copies at merge time and refuses a missing name."""
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        web = (ROOT / ".github/workflows/ci-web.yml").read_text()
        self.assertEqual([n for n in gate.missing_job_names(NEXT_WORKFLOW, ci, web)], [])
        shown = subprocess.run(["git", "-C", str(ROOT), "show", "refs/remotes/origin/feat-cmux-next:.github/workflows/cmux-next.yml"],
                               capture_output=True, text=True)
        if shown.returncode != 0:
            self.skipTest("this clone has no origin/feat-cmux-next; the merge-time check still applies")
        self.assertEqual(gate.missing_job_names(shown.stdout, ci, web), [])

    def test_times_out_naming_the_lane_and_refuses_a_moved_head(self):
        with self.assertRaisesRegex(gate.Refused, "still waiting on cmux-next fast tier"):
            run(Reader([check("cmux-next path routing"), check("cmux-next fast tier", "QUEUED", "")]), timeout=60)
        with self.assertRaisesRegex(gate.Refused, "head moved"):
            run(Reader(GREEN, head="b" * 40))

    def test_a_wait_that_runs_out_names_each_lane_still_queued(self):
        """2026-10-20: #22200's --wait ran out with a required lane still QUEUED, and the refusal
        read `fast gate: nothing reported; waited 0m00s, 898s in all`."""
        reader = Reader([check("cmux-next path routing"), check("cmux-next fast tier", "QUEUED", "")],
                        files=("Packages/macOS/CmuxNext/Sources/A.swift", "webviews/a.ts"))
        with self.assertRaises(gate.WaitRanOut) as caught:
            run(reader, timeout=60)
        error = caught.exception
        self.assertIn("--wait budget of 60s ran out", str(error))
        self.assertIn("cmux-next fast tier (queued)", str(error))
        self.assertIn("react-apps-check (not reported yet)", str(error))
        self.assertGreaterEqual(error.waited, 60)
        self.assertIn("cmux-next fast tier (queued)", error.waiting)

    def test_main_prints_the_wait_and_the_queued_lanes_when_the_wait_runs_out(self):
        rollup = [check("cmux-next path routing"), check("cmux-next fast tier", "QUEUED", "")]
        original = gate.gh_json
        gate.gh_json = Reader(rollup)
        try:
            with tempfile.TemporaryFile("w+") as out, contextlib.redirect_stdout(out), \
                    contextlib.redirect_stderr(io.StringIO()):
                status = gate.main(["manaflow-ai/cmux", "42", HEAD, "--next-covered", "--timeout", "0"])
                out.seek(0)
                printed = out.read()
        finally:
            gate.gh_json = original
        self.assertEqual(status, 1)
        self.assertIn("waited=0", printed)
        self.assertIn("waiting=cmux-next fast tier (queued)", printed)

    def test_a_rate_limited_read_refuses_at_once_with_the_reset_time(self):
        def limited(args):
            if args[:2] == ["api", "rate_limit"]:
                return '{"resources":{"graphql":{"limit":5000,"remaining":0,"reset":4102444800}}}'
            raise AssertionError(args)
        failed = subprocess.CompletedProcess([], 1, "", "GraphQL: API rate limit already exceeded for user ID 1.")
        original_run, original_limits = gate.subprocess.run, gate.read_limits
        gate.subprocess.run = lambda *a, **k: failed
        gate.read_limits = lambda: gate._rate.read_limits(limited)
        try:
            with self.assertRaisesRegex(gate.RateLimited, "graphql 0 of 5000 left, resets 00:00:00Z"):
                gate.gh_json("pr", "view", "42")
        finally:
            gate.subprocess.run, gate.read_limits = original_run, original_limits


if __name__ == "__main__":
    unittest.main()
