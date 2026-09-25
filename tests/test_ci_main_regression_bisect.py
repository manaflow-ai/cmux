"""Flake checks and bisects of new main full-suite failures, driven by fixtures (no network)."""

import importlib.util
import pathlib
import sys
import unittest
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/main_regression_bisect.py"
WORKFLOW = ROOT / ".github/workflows/main-regression-bisect.yml"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("main_regression_bisect", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)
attribution = MODULE.attribution

NOW = datetime(2026, 9, 25, 12, 0, tzinfo=timezone.utc)
PREV = "0" * 40
HEAD = "f" * 40
C = [f"{index:x}" * 40 for index in range(1, 8)]  # seven commits between PREV and HEAD


def data(run_id=7, tests=(("S/x()", [1, 2]),), commits=None, prs=None):
    commits = list(C if commits is None else commits)
    return {
        "v": 1, "run_id": run_id, "run_url": f"https://run/{run_id}", "head": HEAD, "prev": PREV,
        "prev_run_url": "https://run/prev",
        "tests": [{"test": test, "suspects": suspects, "how": "edits the suite"} for test, suspects in tests],
        "prs": prs if prs is not None else {sha: 100 + index for index, sha in enumerate(commits)},
        "commits": commits,
    }


class Harness:
    """Fake GitHub: `outcome(sha)` decides what a dispatched run at a commit reports."""

    def __init__(self, outcome):
        self.outcome = outcome
        self.dispatched = []
        self.runs = {}

    def dispatch(self, test, sha, retry):
        run_id = 1000 + len(self.dispatched)
        self.dispatched.append((test, sha, retry))
        self.runs[run_id] = sha
        return run_id, f"https://probe/{run_id}"

    def poll(self, run_id):
        return self.outcome(self.runs[run_id])

    def step(self, state, runs, now=NOW, per_day=24):
        return MODULE.advance(state, runs, poll=self.poll, dispatch=self.dispatch, per_day=per_day, now=now)


def drive(harness, state, runs, steps=12):
    events = []
    for _ in range(steps):
        events += harness.step(state, runs)
    return events


class StateMachineTests(unittest.TestCase):
    def test_a_failure_that_passes_on_rerun_is_flaky(self):
        harness = Harness(lambda sha: "pass")
        state, runs = MODULE.empty_state(), {7: data()}
        events = drive(harness, state, runs)
        self.assertEqual(harness.dispatched, [("S/x()", HEAD, False)])
        self.assertEqual([event.kind for event in events], ["flaky"])
        self.assertEqual(state["items"][0]["state"], "flaky")
        self.assertIn("did not reproduce", state["items"][0]["note"])

    def test_a_tied_failure_is_bisected_to_the_first_bad_commit(self):
        first_bad = 4  # C[4] broke it
        harness = Harness(lambda sha: "fail" if sha == HEAD or (sha in C and C.index(sha) >= first_bad) else "pass")
        state, runs = MODULE.empty_state(), {7: data()}
        events = drive(harness, state, runs)
        item = state["items"][0]
        self.assertEqual(item["state"], "confirmed")
        self.assertEqual(item["culprit"]["sha"], C[first_bad])
        self.assertEqual(item["culprit"]["pr"], 104)
        self.assertEqual(item["culprit"]["pass_sha"], C[first_bad - 1])
        self.assertTrue(item["culprit"]["pass_url"].startswith("https://probe/"))
        self.assertEqual([event.kind for event in events], ["reproduced", "bisecting", "confirmed"])
        # One flake check, then log2(8) probes, never the endpoints.
        probed = [sha for _, sha, _ in harness.dispatched]
        self.assertEqual(probed[0], HEAD)
        self.assertEqual(len(probed), 4)
        self.assertNotIn(PREV, probed)

    def test_the_first_commit_in_the_range_links_the_baseline_run_as_passing(self):
        harness = Harness(lambda sha: "fail")
        state, runs = MODULE.empty_state(), {7: data()}
        drive(harness, state, runs)
        item = state["items"][0]
        self.assertEqual(item["culprit"]["sha"], C[0])
        self.assertEqual(item["culprit"]["pass_url"], "https://run/prev")

    def test_a_range_with_one_commit_that_matters_is_confirmed_without_a_bisect(self):
        harness = Harness(lambda sha: "fail")
        state, runs = MODULE.empty_state(), {7: data(tests=(("S/x()", [5]),), commits=[C[2]])}
        events = drive(harness, state, runs)
        self.assertEqual([event.kind for event in events], ["confirmed"])
        self.assertEqual(len(harness.dispatched), 1)
        culprit = state["items"][0]["culprit"]
        self.assertEqual((culprit["sha"], culprit["pr"]), (C[2], 100))
        self.assertEqual(culprit["fail_url"], "https://probe/1000")  # the rerun at head

    def test_a_single_suspect_is_left_at_reproduced(self):
        harness = Harness(lambda sha: "fail")
        state, runs = MODULE.empty_state(), {7: data(tests=(("S/x()", [3]),))}
        events = drive(harness, state, runs)
        self.assertEqual([event.kind for event in events], ["reproduced"])
        self.assertEqual(state["items"][0]["state"], "reproduced")
        self.assertEqual(len(harness.dispatched), 1)

    def test_no_commit_that_matters_leaves_it_unresolved(self):
        harness = Harness(lambda sha: "fail")
        state, runs = MODULE.empty_state(), {7: data(commits=[])}
        events = drive(harness, state, runs)
        self.assertEqual([event.kind for event in events], ["unresolved"])

    def test_an_errored_probe_is_retried_once_with_force_then_given_up(self):
        harness = Harness(lambda sha: "error")
        state, runs = MODULE.empty_state(), {7: data()}
        events = drive(harness, state, runs)
        self.assertEqual([retry for _, _, retry in harness.dispatched], [False, True])
        self.assertEqual([event.kind for event in events], ["error"])

    def test_pending_runs_hold_the_item(self):
        harness = Harness(lambda sha: "pending")
        state, runs = MODULE.empty_state(), {7: data()}
        drive(harness, state, runs, steps=5)
        self.assertEqual(len(harness.dispatched), 1)
        self.assertEqual(state["items"][0]["state"], "flake-check")

    def test_checks_per_run_are_capped_and_runs_are_queued_once(self):
        tests = tuple((f"S/t{index}()", [1]) for index in range(MODULE.MAX_CHECKS_PER_RUN + 3))
        harness = Harness(lambda sha: "pending")
        state, runs = MODULE.empty_state(), {7: data(tests=tests)}
        harness.step(state, runs)
        harness.step(state, runs)
        self.assertEqual(len(state["items"]), MODULE.MAX_CHECKS_PER_RUN)
        self.assertEqual(state["seen"], [7])

    def test_the_state_stays_bounded_over_a_long_red_streak(self):
        tests = tuple((f"S/t{index}()", [1]) for index in range(MODULE.MAX_CHECKS_PER_RUN))
        outcome = ["pending"]
        harness = Harness(lambda sha: outcome[0])
        state = MODULE.empty_state()
        runs = {run_id: data(run_id=run_id, tests=tests) for run_id in range(1, 5)}
        harness.step(state, runs)
        self.assertEqual(len(state["items"]), MODULE.MAX_OPEN_ITEMS)
        self.assertEqual(state["seen"], [1, 2, 3, 4])
        outcome[0] = "pass"
        for run_id in range(5, 60):
            runs[run_id] = data(run_id=run_id, tests=tests)
            for _ in range(3):
                harness.step(state, runs, per_day=10_000)
        self.assertLessEqual(len(state["items"]), MODULE.MAX_OPEN_ITEMS + MODULE.MAX_FINISHED_ITEMS)
        self.assertLess(len(MODULE.render_state(state, 24)), 65_536 // 2)

    def test_dispatches_are_capped_per_invocation_and_per_day(self):
        tests = tuple((f"S/t{index}()", [1]) for index in range(5))
        harness = Harness(lambda sha: "pending")
        state = MODULE.empty_state()
        runs = {7: data(tests=tests), 8: data(run_id=8, tests=tests)}
        harness.step(state, runs)
        self.assertEqual(len(harness.dispatched), MODULE.MAX_DISPATCHES_PER_INVOCATION)
        harness.step(state, runs, per_day=6)
        self.assertEqual(len(harness.dispatched), 6)
        harness.step(state, runs, per_day=6)
        self.assertEqual(len(harness.dispatched), 6)
        # A day later the budget is back.
        harness.step(state, runs, now=NOW + timedelta(days=1, minutes=1), per_day=6)
        self.assertEqual(len(harness.dispatched), 10)

    def test_active_bisects_are_capped(self):
        tests = tuple((f"S/t{index}()", [1, 2]) for index in range(MODULE.MAX_ACTIVE_BISECTS + 1))
        harness = Harness(lambda sha: "fail" if sha == HEAD else "pending")
        state, runs = MODULE.empty_state(), {7: data(tests=tests)}
        drive(harness, state, runs, steps=4)
        states = [item["state"] for item in state["items"]]
        self.assertEqual(states.count("bisecting"), MODULE.MAX_ACTIVE_BISECTS)
        self.assertEqual(states.count("bisect-wait"), 1)

    def test_stale_or_orphaned_items_expire(self):
        harness = Harness(lambda sha: "pending")
        state, runs = MODULE.empty_state(), {7: data()}
        harness.step(state, runs)
        harness.step(state, {}, now=NOW + timedelta(minutes=15))
        self.assertEqual(state["items"][0]["state"], "expired")
        state, runs = MODULE.empty_state(), {7: data()}
        harness.step(state, runs)
        harness.step(state, runs, now=NOW + MODULE.ITEM_TTL + timedelta(hours=1))
        self.assertEqual(state["items"][0]["state"], "expired")

    def test_a_failed_dispatch_spends_an_attempt(self):
        state, runs = MODULE.empty_state(), {7: data()}
        for _ in range(3):
            MODULE.advance(state, runs, poll=lambda run_id: "pending", dispatch=lambda *a: None, per_day=24, now=NOW)
        self.assertEqual(state["items"][0]["state"], "error")


class ClassifyTests(unittest.TestCase):
    def test_only_a_failed_test_step_counts_as_a_failure(self):
        steps = lambda names: (lambda: names)  # noqa: E731
        self.assertEqual(MODULE.classify({"status": "in_progress"}, steps([])), "pending")
        self.assertEqual(MODULE.classify({"status": "completed", "conclusion": "success"}, steps([])), "pass")
        failed = {"status": "completed", "conclusion": "failure"}
        self.assertEqual(MODULE.classify(failed, steps(["Run selected tests"])), "fail")
        self.assertEqual(MODULE.classify(failed, steps(["Build the app-host and UI test product"])), "error")
        self.assertEqual(MODULE.classify({"status": "completed", "conclusion": "cancelled"}, steps([])), "error")


class MarkerTests(unittest.TestCase):
    def test_the_attribution_data_marker_round_trips(self):
        pr = attribution.PullRequest(number=5, title="t", url="u", merge_sha=C[0])
        marker = attribution.data_marker(
            run={"id": 7, "html_url": "https://run/7", "head_sha": HEAD},
            previous={"head_sha": PREV, "html_url": "https://run/prev"},
            failures={"S/x()": ["https://job"]},
            attributions={"S/x()": ([pr], "only pull request in the range")},
            prs=[pr], commits=[C[0]],
        )
        [parsed] = MODULE.hidden_json(f"table\n{marker}\nmore", attribution.DATA_PREFIX)
        self.assertTrue(MODULE.valid_data(parsed))
        self.assertEqual(parsed["tests"], [{"test": "S/x()", "suspects": [5], "how": "only pull request in the range"}])
        self.assertEqual(parsed["prs"], {C[0]: 5})

    def test_unsafe_data_is_refused(self):
        self.assertTrue(MODULE.valid_data(data()))
        self.assertFalse(MODULE.valid_data({**data(), "head": "main; rm -rf /"}))
        self.assertFalse(MODULE.valid_data(data(tests=(("S/x() --force", [1]),))))
        self.assertFalse(MODULE.valid_data({**data(), "run_id": "7"}))

    def test_state_renders_and_parses_back(self):
        harness = Harness(lambda sha: "pending")
        state, runs = MODULE.empty_state(), {7: data()}
        harness.step(state, runs)
        body = MODULE.render_state(state, 24)
        self.assertEqual(MODULE.hidden_json(body, MODULE.STATE_PREFIX), [state])
        self.assertIn("`S/x()` | [7](https://run/7) | rerunning", body)
        self.assertIn("Dispatches in the last 24 hours: 1 of 24.", body)
        self.assertNotIn("—", body)


SECTION = "\n".join([
    "### New since `0000000000`",
    "",
    "Test | Suspect | Jobs",
    "--- | --- | ---",
    "`S/x()` | #1, #2 (edits the suite) | [job](https://job/1)",
    "`T/y()` | unattributed (no pull request in the range reaches this suite) | [job](https://job/2)",
    "",
    f"{attribution.DATA_PREFIX}{{\"run_id\":7}} -->",
])


def suspect_comment(pr, tests):
    return "\n".join([
        attribution.marker(pr, tests, f"{PREV[:10]}..{HEAD[:10]}"),
        "These app-host tests newly fail...",
        "",
        *[f"- `{test}` (edits the suite) [job](https://job/1)" for test in tests],
        "",
        "Commits in the range: ...",
    ])


class EditTests(unittest.TestCase):
    def test_rows_take_the_latest_update(self):
        once = MODULE.annotate_row(SECTION, "S/x()", "reproduced")
        self.assertIn("`S/x()` | #1, #2 (edits the suite) · reproduced | [job](https://job/1)", once)
        twice = MODULE.annotate_row(once, "S/x()", "confirmed: #2")
        self.assertIn("`S/x()` | #1, #2 (edits the suite) · confirmed: #2 | [job](https://job/1)", twice)
        self.assertIn("`T/y()` | unattributed (no pull request", twice)

    def test_section_edits_only_touch_the_red_runs_own_section(self):
        other = SECTION.replace('"run_id":7', '"run_id":9')
        nodes = [MODULE.Comment(None, other, "issue"), MODULE.Comment(11, SECTION)]
        item = {"run": 7, "test": "S/x()", "note": "flaky"}
        edits = MODULE.section_edits([MODULE.Event("flaky", item)], {7: data()}, nodes)
        self.assertEqual(list(edits), [11])
        self.assertIn("· flaky", edits[11])

    def flaky_event(self, test="S/x()"):
        item = {"run": 7, "test": test, "suspects": [1, 2], "note": "",
                "probes": {HEAD: {"run_id": 1, "url": "https://probe/1", "result": "pass"}}}
        return MODULE.Event("flaky", item)

    def test_a_flaky_failure_clears_the_suspects_comments(self):
        comments = {
            1: [MODULE.Comment(21, suspect_comment(1, ["S/x()"]))],
            2: [MODULE.Comment(22, suspect_comment(2, ["S/x()", "T/y()"])),
                MODULE.Comment(23, suspect_comment(2, ["S/x()"]).replace(PREV[:10], "1111111111"))],
        }
        edits, posts = MODULE.pr_updates(self.flaky_event(), data(), lambda pr: comments[pr])
        self.assertEqual(posts, [])
        self.assertEqual(sorted(edits), [21, 22])  # 23 is another range's comment
        self.assertIn("- `S/x()` (edits the suite) [job](https://job/1) **Update:** did not reproduce", edits[21])
        # Every test in #1's comment is flaky, so it says so up top; #2 still has T/y().
        self.assertEqual(edits[21].split("\n")[1].split(" ")[0], "**Update:**")
        self.assertNotIn("look flaky", edits[22])

    def confirmed_event(self, pr=2, suspects=(1, 2)):
        item = {"run": 7, "test": "S/x()", "suspects": list(suspects), "note": "",
                "culprit": {"sha": C[3], "pr": pr, "pass_sha": C[2],
                            "pass_url": "https://probe/pass", "fail_url": "https://probe/fail"}}
        return MODULE.Event("confirmed", item)

    def test_a_confirmed_culprit_is_told_and_the_others_cleared(self):
        comments = {1: [MODULE.Comment(21, suspect_comment(1, ["S/x()"]))],
                    2: [MODULE.Comment(22, suspect_comment(2, ["S/x()"]))]}
        edits, posts = MODULE.pr_updates(self.confirmed_event(), data(), lambda pr: comments[pr])
        self.assertEqual(posts, [])
        self.assertIn("**Update:** **confirmed** by bisect: passes at", edits[22])
        self.assertIn("[run](https://probe/fail)", edits[22])
        self.assertIn("a bisect points at #2 instead", edits[21])

    def test_a_culprit_nobody_suspected_gets_one_comment(self):
        comments = {1: [MODULE.Comment(21, suspect_comment(1, ["S/x()"]))], 9: []}
        event = self.confirmed_event(pr=9, suspects=(1,))
        edits, posts = MODULE.pr_updates(event, data(), lambda pr: comments[pr])
        self.assertEqual([pr for pr, _ in posts], [9])
        self.assertTrue(posts[0][1].startswith("<!-- main-regression-bisect pr=9 test="))
        self.assertNotIn("—", posts[0][1])
        comments[9] = [MODULE.Comment(31, posts[0][1])]
        self.assertEqual(MODULE.pr_updates(event, data(), lambda pr: comments[pr])[1], [])


class WorkflowTests(unittest.TestCase):
    text = WORKFLOW.read_text(encoding="utf-8")

    def test_runs_on_main_only_with_the_permissions_it_needs(self):
        self.assertIn("github.ref == 'refs/heads/main'", self.text)
        self.assertIn("github.repository == 'manaflow-ai/cmux'", self.text)
        for permission in ("actions: write", "issues: write", "pull-requests: write", "contents: read"):
            self.assertIn(permission, self.text)
        self.assertIn("permissions: {}", self.text)

    def test_one_invocation_at_a_time_never_cancelled(self):
        self.assertIn("group: main-regression-bisect", self.text)
        self.assertIn("cancel-in-progress: false", self.text)

    def test_advances_on_a_schedule_and_after_each_report(self):
        self.assertIn('cron: "*/15 * * * *"', self.text)
        self.assertIn("workflows: [CI main full suite]", self.text)
        self.assertIn("github.event.workflow_run.event == 'workflow_run'", self.text)
        self.assertIn("scripts/ci/main_regression_bisect.py advance", self.text)
        self.assertIn("CMUX_MACOS_RUNNER_TESTS: ${{ vars.MACOS_RUNNER_TESTS }}", self.text)


if __name__ == "__main__":
    unittest.main()
