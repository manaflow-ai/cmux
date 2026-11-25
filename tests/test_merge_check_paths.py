"""scripts/ci/merge_check_paths.py against a fake GitHub: no network, no sleeping.

The check-path gate gh-merge-green applies into feat-cmux-next: a pull request whose fast gates ran before a check
path changed on the base is rerun against the current tip before it merges (2026-10-21: #22967, #22975 and #23094
merged after #23365 added check:fixed-waits and turned it red on the base).
"""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("merge_check_paths", ROOT / "scripts/ci/merge_check_paths.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
HEAD, OLD, TIP, NEWER = "a" * 40, "b" * 40, "c" * 40, "e" * 40
CHECK_PATHS = ("# a sample of the base's scripts/ci/check-paths.txt\n\nscripts/check-*\nwebviews/scripts/check-*\n"
               "webviews/scripts/*baseline*\nwebviews/package.json\n.github/workflows/ci-web.yml\n")
# #23365's files, which the base changed after #22975's fast gates ran, and #22975's own.
FILES_23365 = [".github/workflows/ci-web.yml", "webviews/package.json", "webviews/scripts/check-fixed-waits.ts",
               "webviews/scripts/fixed-waits-baseline.tsv", "webviews/test/check-fixed-waits.test.ts",
               "webviews/test/support/pageSwitch.ts"]
FILES_22975 = ["Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxPaneMethods+Params.swift",
               "cmux-tui/crates/cmux-agent-pane-policy/policy.json", "webviews/src/agent-session/acpmux/App.tsx",
               "webviews/src/agent-session/acpmux/ComposerQueue.tsx", "webviews/src/agent-session/acpmux/QueuedImages.tsx"]


def status(base, state="success", at="2026-10-21T13:00:00Z"):
    return {"context": gate.CONTEXT, "state": state, "description": f"base {base}", "updated_at": at,
            "target_url": "https://github.com/manaflow-ai/cmux/actions/runs/1"}


class FakeApi:
    def __init__(self, statuses, tips=(TIP,), compares=None, check_paths=CHECK_PATHS, run_ids=True,
                 mergeables=("MERGEABLE",)):
        self.statuses, self.tips, self.compares, self.text = list(statuses), list(tips), compares or {}, check_paths
        self.run_ids, self.mergeables, self.mergeable_reads = run_ids, list(mergeables), 0
        self.dispatched, self.reads = [], 0

    def mergeable(self, number):
        """GitHub's mergeable state at the 1st, 2nd... read (the last one repeats)."""
        self.mergeable_reads += 1
        return self.mergeables[min(self.mergeable_reads, len(self.mergeables)) - 1]

    def check_paths(self, branch):
        if isinstance(self.text, Exception):
            raise self.text
        return self.text

    def status(self, sha):
        self.reads += 1
        return self.statuses.pop(0) if len(self.statuses) > 1 else self.statuses[0]

    def tip(self, branch):
        return self.tips.pop(0) if len(self.tips) > 1 else self.tips[0]

    def compare(self, base, tip):
        return self.compares.get((base, tip)) or {"status": "diverged", "ahead_by": 0, "files": []}

    def dispatch(self, number, branch):
        """The run's id, as GitHub's 200 answer names it (run_ids=False: an empty answer, no id)."""
        self.dispatched.append((number, branch))
        return len(self.dispatched) if self.run_ids else None

    def run(self, run_id):
        # This fake's runs never end on their own: only their statuses decide.
        return {"status": "in_progress", "conclusion": None}


class MovingTipApi(FakeApi):
    """feat-cmux-next lands a check path change during each dispatched run, `moves` times.

    Dispatched run k (run id k) ends after `run_polls` status reads (an int, or one per run, the last repeating),
    at the tip it was dispatched on; the tip then reads one commit newer, which changes `moved` (by default
    scripts/check-pbxproj.sh). `results` are the runs' outcomes in order (the last one repeats): "success" or
    "failure" post that status; "stopped" posts the pending "stopped ..., no verdict" a cancelled gates job
    leaves; "cancelled" ends the whole run with no status (the post job skipped); "silent" never ends. `lists`
    are the base's check-paths.txt after 0, 1, 2... ended runs (the last one repeats).
    """

    def __init__(self, moves, run_polls=3, results=("success",), moved="scripts/check-pbxproj.sh", lists=None):
        tips = [format(index + 1, "040x") for index in range(moves + 1)]
        compares = {(OLD, tips[0]): {"status": "ahead", "ahead_by": 1, "files": FILES_23365}}
        for older, newer in zip(tips, tips[1:]):
            compares[(older, newer)] = {"status": "ahead", "ahead_by": 1, "files": [moved]}
        super().__init__([status(OLD)], compares=compares)
        self.tips = tips  # after FakeApi's own, which this fake's tip() replaces
        self.moves, self.results, self.lists = moves, list(results), list(lists or [CHECK_PATHS])
        self.run_polls = list(run_polls) if isinstance(run_polls, (list, tuple)) else [run_polls]
        self.index, self.pending, self.current, self.ended, self.runs = 0, None, status(OLD), 0, {}

    def _pick(self, values, run):
        return values[min(run, len(values)) - 1]

    def check_paths(self, branch):
        return self.lists[min(self.ended, len(self.lists) - 1)]

    def status(self, sha):
        self.reads += 1
        if self.pending is not None:
            self.pending -= 1
            if self.pending == 0:
                run = len(self.dispatched)
                outcome = self._pick(self.results, run)
                base = self.tips[self.index]
                if outcome in ("success", "failure"):
                    self.current = {**status(base, state=outcome, at=f"run {run}"),
                                    "target_url": f"https://github.com/manaflow-ai/cmux/actions/runs/{run}"}
                elif outcome == "stopped":
                    self.current = {**status(base, state="pending", at=f"run {run}"),
                                    "description": f"base {base}; stopped (gates cancelled, ratchet skipped), no verdict",
                                    "target_url": f"https://github.com/manaflow-ai/cmux/actions/runs/{run}"}
                self.runs[run] = {"status": "completed", "conclusion": "cancelled" if outcome != "success" else
                                  "success"}
                self.pending = None
                self.ended += 1
                self.index = min(self.index + 1, self.moves)
        return self.current

    def tip(self, branch):
        return self.tips[self.index]

    def dispatch(self, number, branch):
        super().dispatch(number, branch)
        run = len(self.dispatched)
        self.runs[run] = {"status": "in_progress", "conclusion": None}
        polls = self._pick(self.run_polls, run)
        self.pending = None if self._pick(self.results, run) == "silent" else polls
        return run

    def run(self, run_id):
        return self.runs[run_id]


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def run(api, timeout=900, check_only=False):
    clock = Clock()
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr):
        result = gate.gate(api, "42", HEAD, gate.BRANCH, timeout, 20, clock, clock.sleep, check_only=check_only)
    return result, stderr.getvalue()


class CheckPathGate(unittest.TestCase):
    def test_replay_of_22975_a_check_that_landed_since_reruns_the_fast_gates_before_the_merge(self):
        # Its fast gates ran at OLD; the base then changed #23365's files, none of them #22975's own. The gate
        # dispatches the fast gates against the tip and merges only on their fresh success.
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365}}
        api = FakeApi([status(OLD), status(OLD), status(TIP, at="2026-10-21T14:12:00Z")], compares=landed)
        (checked, waited), err = run(api)
        self.assertEqual(api.dispatched, [("42", "feat-cmux-next")])
        self.assertIn("has changed the check path .github/workflows/ci-web.yml since", err)
        self.assertEqual(checked, "check paths (fast gates rerun on the current tip)")
        self.assertEqual(waited, 40)

    def test_replay_of_22975_the_rerun_red_refuses(self):
        # On the tip, the webviews checks fail #22975 for its own new fixed wait.
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365}}
        api = FakeApi([status(OLD), status(TIP, state="failure", at="2026-10-21T14:12:00Z")], compares=landed)
        with self.assertRaisesRegex(gate.Refused, "cmux-next/fast-gates is failure on the pull request merged with "
                                                  "the current tip.*actions/runs/1"):
            run(api)

    def test_fresh_needs_no_dispatch(self):
        api = FakeApi([status(TIP)])
        self.assertEqual(run(api)[0], ("check paths fresh", 0.0))
        moved = {(OLD, TIP): {"status": "ahead", "ahead_by": 4, "files": FILES_22975[:2] + ["docs/ci.md"]}}
        api = FakeApi([status(OLD)], compares=moved)
        self.assertEqual(run(api)[0], ("check paths fresh", 0.0))
        self.assertEqual(api.dispatched, [])

    def test_stale_reasons_dispatch(self):
        cases = {
            "has not run on this head": (None, {}),
            "names no base": ({**status(OLD), "description": "something else"}, {}),
            "not an ancestor": (status(OLD), {(OLD, TIP): {"status": "diverged", "ahead_by": 2, "files": []}}),
            "commits behind": (status(OLD), {(OLD, TIP): {"status": "ahead", "ahead_by": 251, "files": []}}),
            "too many files": (status(OLD), {(OLD, TIP): {"status": "ahead", "ahead_by": 9,
                                                          "files": [f"f{i}" for i in range(300)]}}),
        }
        for why, (first, compares) in cases.items():
            with self.subTest(why):
                api = FakeApi([first, status(TIP, at="2026-10-21T14:12:00Z")], compares=compares)
                _, err = run(api)
                self.assertIn(why, err)
                self.assertEqual(len(api.dispatched), 1)

    def test_no_result_within_the_timeout_refuses(self):
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365}}
        api = FakeApi([status(OLD)], compares=landed)
        with self.assertRaisesRegex(gate.Refused, "posted no result within 120s"):
            run(api, timeout=120)

    def test_a_pending_or_unchanged_status_is_not_the_dispatched_result(self):
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365}}
        api = FakeApi([status(OLD), status(OLD), status(TIP, state="pending", at="2026-10-21T14:11:00Z"),
                       status(TIP, at="2026-10-21T14:12:00Z")], compares=landed)
        (_, waited), _ = run(api)
        self.assertEqual(waited, 60)

    # 2026-11-09: feat-cmux-next changed a check path while the dispatched run ran, and the gate refused with
    # "retry" (#39632, #39631 twice, #39705: crash-safety-baseline.json, check-menu-actions-baseline.txt). The
    # gate now dispatches again on the new tip and waits, inside the wait budget.
    def test_a_check_path_that_changed_once_during_the_run_merges_after_one_rerun(self):
        api = MovingTipApi(moves=1)
        (checked, waited), err = run(api)
        self.assertEqual(api.dispatched, [("42", "feat-cmux-next")] * 2)
        self.assertEqual(checked, "check paths (fast gates rerun on the current tip)")
        self.assertEqual(waited, 120)  # two runs of three 20s polls
        self.assertIn("scripts/check-pbxproj.sh", err)
        self.assertIn(f"again against the new tip {api.tips[1][:12]}", err)

    def test_the_static_fake_a_check_path_that_changed_again_dispatches_again(self):
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365},
                  (TIP, NEWER): {"status": "ahead", "ahead_by": 1, "files": ["scripts/check-pbxproj.sh"]}}
        api = FakeApi([status(OLD), status(TIP, at="2026-10-21T14:12:00Z"), status(NEWER, at="2026-10-21T14:30:00Z")],
                      tips=(TIP, NEWER), compares=landed)
        (checked, _), err = run(api)
        self.assertEqual(len(api.dispatched), 2)
        self.assertEqual(checked, "check paths (fast gates rerun on the current tip)")
        self.assertIn("has changed the check path scripts/check-pbxproj.sh since", err)

    def test_a_tip_that_moves_a_check_path_on_every_run_refuses_at_the_wait_budget(self):
        # Each run takes 300s and a rerun needs 370s of a 1500s budget left: runs start at 0, 300, 600 and 900s;
        # at 1200s only 300s are left, so it refuses there, naming the budget and the last check path that changed.
        api = MovingTipApi(moves=1000, run_polls=15)
        clock = Clock()
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(gate.Refused, r"wait budget of 1500s.*scripts/check-pbxproj.sh"):
                gate.gate(api, "42", HEAD, gate.BRANCH, 900, 20, clock, clock.sleep, budget=1500)
        self.assertEqual(len(api.dispatched), 4)
        self.assertEqual(clock.now, 1200)

    def test_a_budget_below_one_run_still_waits_for_the_first_run_but_never_dispatches_again(self):
        # gh-merge-green passes what its --wait left; the first run keeps its own --timeout, as before the rerun.
        api = MovingTipApi(moves=1000, run_polls=15)  # one run: 300s
        clock = Clock()
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(gate.Refused, r"wait budget of 100s.*scripts/check-pbxproj.sh"):
                gate.gate(api, "42", HEAD, gate.BRANCH, 900, 20, clock, clock.sleep, budget=100)
        self.assertEqual(len(api.dispatched), 1)

    def test_a_red_dispatched_run_refuses_at_once_with_no_rerun(self):
        api = MovingTipApi(moves=1000, results=("failure",))
        with self.assertRaisesRegex(gate.Refused, "cmux-next/fast-gates is failure on the pull request merged with "
                                                  "the current tip"):
            run(api)
        self.assertEqual(len(api.dispatched), 1)

    def test_a_red_rerun_refuses_at_once(self):
        api = MovingTipApi(moves=1000, results=("success", "failure"))
        with self.assertRaisesRegex(gate.Refused, "cmux-next/fast-gates is failure on the pull request merged with "
                                                  "the current tip"):
            run(api)
        self.assertEqual(len(api.dispatched), 2)

    # Review of #39725 (cprerun-1): reruns that cannot report, stopped runs, and a list that changes meanwhile.
    def test_no_rerun_when_less_than_one_fast_gates_run_of_budget_is_left(self):
        # A run takes 60s here, but a real one takes at least 370s: with 240s left the rerun could not report.
        api = MovingTipApi(moves=1000)
        clock = Clock()
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(gate.Refused, r"wait budget of 300s.*less than one.*"
                                                      r"scripts/check-pbxproj.sh"):
                gate.gate(api, "42", HEAD, gate.BRANCH, 900, 20, clock, clock.sleep, budget=300)
        self.assertEqual(len(api.dispatched), 1)
        self.assertEqual(clock.now, 60)

    def test_a_rerun_that_does_not_report_before_the_budget_ends_refuses(self):
        api = MovingTipApi(moves=1000, run_polls=(3, 1000))
        clock = Clock()
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(gate.Refused, r"wait budget of 600s.*ran out before dispatched run 2"):
                gate.gate(api, "42", HEAD, gate.BRANCH, 900, 20, clock, clock.sleep, budget=600)
        self.assertEqual(len(api.dispatched), 2)
        self.assertLessEqual(clock.now, 600 + 20)

    def test_a_stopped_run_with_no_verdict_dispatches_again(self):
        # cmux-next-fast-gates.yml posts pending "base X; stopped (...), no verdict" when its gates job was
        # cancelled or timed out: no verdict, so the gate dispatches again rather than wait out its timeout.
        api = MovingTipApi(moves=1, results=("success", "stopped", "success"))
        (checked, waited), err = run(api)
        self.assertEqual(len(api.dispatched), 3)
        self.assertEqual(checked, "check paths (fast gates rerun on the current tip)")
        self.assertEqual(waited, 180)
        self.assertIn("dispatched run 2 stopped with no verdict", err)

    def test_a_cancelled_run_that_posts_no_status_dispatches_again(self):
        # A run-level cancel (the fast-gates-<PR> concurrency group, or by hand) skips the post job: no status
        # comes, and only the dispatched run's own state shows it ended.
        api = MovingTipApi(moves=1, results=("success", "cancelled", "success"))
        (checked, _), err = run(api)
        self.assertEqual(len(api.dispatched), 3)
        self.assertEqual(checked, "check paths (fast gates rerun on the current tip)")
        self.assertIn("dispatched run 2 stopped with no verdict", err)

    def test_a_stopped_run_still_refuses_at_the_budget(self):
        api = MovingTipApi(moves=1, results=("success", "stopped"))
        clock = Clock()
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(gate.Refused, r"wait budget of 900s.*stopped with no verdict"):
                gate.gate(api, "42", HEAD, gate.BRANCH, 900, 20, clock, clock.sleep, budget=900)
        self.assertLessEqual(clock.now, 900 + 20)

    def test_the_list_is_read_again_before_each_rerun(self):
        # During run 1 the base adds a pattern for the file the tip then changes: run 1 proves nothing for it.
        api = MovingTipApi(moves=1, moved="scripts/cmux-next/crash-safety-baseline.json",
                           lists=[CHECK_PATHS, CHECK_PATHS + "scripts/cmux-next/*baseline*\n"])
        (checked, _), err = run(api)
        self.assertEqual(len(api.dispatched), 2)
        self.assertIn("scripts/cmux-next/crash-safety-baseline.json", err)

    def test_no_rerun_with_less_than_the_fastest_real_run_left(self):
        # The fastest successful dispatched run on 2026-11-09 took 370s: with 360s left, no rerun.
        api = MovingTipApi(moves=1000)
        clock = Clock()
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(gate.Refused, r"wait budget of 420s.*less than one run \(370s\)"):
                gate.gate(api, "42", HEAD, gate.BRANCH, 900, 20, clock, clock.sleep, budget=420)
        self.assertEqual(len(api.dispatched), 1)

    def test_a_dispatch_that_answers_no_run_id_refuses_without_waiting(self):
        # Without the run's id a stop or a whole-run cancel of it cannot be told from another run's: fail closed.
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365}}
        api = FakeApi([status(OLD), status(TIP, at="2026-10-21T14:12:00Z")], compares=landed, run_ids=False)
        clock = Clock()
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(gate.Refused, "no workflow_run_id"):
                gate.gate(api, "42", HEAD, gate.BRANCH, 900, 20, clock, clock.sleep)
        self.assertEqual(len(api.dispatched), 1)
        self.assertEqual(clock.now, 0)

    def test_each_run_waits_up_to_1200s_by_default(self):
        # Successful dispatched runs took up to 826s on 2026-11-09, close to the old 900s; main() passes 1200s.
        seen = {}

        def fake_gate(api, number, sha, branch, timeout, interval, **kwargs):
            seen.update(timeout=timeout, budget=kwargs.get("budget"))
            return "check paths fresh", 0.0

        saved = gate.gate
        gate.gate = fake_gate
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate.main(["manaflow-ai/cmux", "42", HEAD]), 0)
        finally:
            gate.gate = saved
        self.assertEqual(seen, {"timeout": 1200, "budget": None})

    # Review of #39764 (basecur-1): a red or "no verdict" status whose base is fresh read as "check paths fresh".
    def test_a_status_that_is_not_success_at_a_fresh_base_dispatches(self):
        stopped = f"base {TIP}; stopped (gates cancelled, ratchet skipped), no verdict"
        for state, description in (("failure", None), ("error", None), ("pending", stopped)):
            with self.subTest(state):
                first = {**status(TIP, state=state), **({"description": description} if description else {})}
                api = FakeApi([first, status(TIP, at="2026-10-21T14:12:00Z")])
                (checked, _), err = run(api)
                self.assertEqual(len(api.dispatched), 1)
                self.assertEqual(checked, "check paths (fast gates rerun on the current tip)")
                self.assertIn(f"cmux-next/fast-gates is {state}", err)

    def test_a_red_status_at_a_fresh_base_whose_rerun_is_red_refuses(self):
        api = FakeApi([status(TIP, state="failure"), status(TIP, state="failure", at="2026-10-21T14:12:00Z")])
        with self.assertRaisesRegex(gate.Refused, "cmux-next/fast-gates is failure on the pull request merged with "
                                                  "the current tip"):
            run(api)
        self.assertEqual(len(api.dispatched), 1)

    # 2026-11-09: the #39027 try dispatched the fast gates, then gh pr merge refused for a conflict.
    def test_a_conflicting_pr_dispatches_nothing(self):
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365}}
        api = FakeApi([status(OLD)], compares=landed, mergeables=("CONFLICTING",))
        with self.assertRaisesRegex(gate.Refused, "conflicting: rebase"):
            run(api)
        self.assertEqual(api.dispatched, [])

    def test_a_pr_that_turns_conflicting_before_a_rerun_is_not_rerun(self):
        api = MovingTipApi(moves=1)
        api.mergeables = ["MERGEABLE", "CONFLICTING"]
        with self.assertRaisesRegex(gate.Refused, "conflicting: rebase"):
            run(api)
        self.assertEqual(len(api.dispatched), 1)

    def test_an_unknown_mergeable_state_goes_on_at_once_with_no_re_read(self):
        # UNKNOWN is no evidence of a conflict, and the gate never polls for it: one read per dispatch, no wait
        # before the dispatch (the 40s are the run's own two polls).
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365}}
        api = FakeApi([status(OLD), status(OLD), status(TIP, at="2026-10-21T14:12:00Z")], compares=landed,
                      mergeables=("UNKNOWN",))
        (checked, waited), err = run(api)
        self.assertEqual(checked, "check paths (fast gates rerun on the current tip)")
        self.assertEqual(api.mergeable_reads, 1)
        self.assertEqual(len(api.dispatched), 1)
        self.assertEqual(waited, 40)
        self.assertIn("still computing", err)

    def test_an_unknown_state_that_turns_conflicting_refuses_before_the_rerun(self):
        api = MovingTipApi(moves=1)
        api.mergeables = ["UNKNOWN", "CONFLICTING"]
        with self.assertRaisesRegex(gate.Refused, "conflicting: rebase"):
            run(api)
        self.assertEqual(len(api.dispatched), 1)
        self.assertEqual(api.mergeable_reads, 2)

    # Review of #39764 at af898c35 (comment 6750889962): without return_run_details=true GitHub answers the dispatch
    # 204 with no body, so no run id, and every gate that needs a run refused after spending one Linux run.
    def test_the_dispatch_asks_github_for_the_run_id(self):
        class GitHub(gate.Api):
            """The real Api over a fake `gh api` that answers as GitHub does for API version 2022-11-28."""

            def __init__(self):
                super().__init__("manaflow-ai/cmux")
                self.calls = []

            def gh(self, *args):
                self.calls.append(args)
                if "return_run_details=true" not in args:
                    return ""
                return '{"workflow_run_id": 42687, "run_url": "https://api.github.com/x", "html_url": "https://github.com/x"}'

        api = GitHub()
        self.assertEqual(api.dispatch("42", gate.BRANCH), 42687)
        self.assertIn("-F", api.calls[0])

    def test_check_only_dispatches_nothing(self):
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365}}
        api = FakeApi([status(OLD)], compares=landed)
        (checked, _), err = run(api, check_only=True)
        self.assertEqual(api.dispatched, [])
        self.assertIn("a merge would dispatch", err)
        self.assertIn("check only", checked)

    def test_no_list_on_the_base_yet_passes(self):
        api = FakeApi([status(OLD)], check_paths=None)
        (checked, _), err = run(api)
        self.assertIn("is not on feat-cmux-next", err)
        self.assertEqual(api.dispatched, [])

    def test_an_unreadable_list_refuses(self):
        api = FakeApi([status(OLD)], check_paths=gate.Refused("gh api repos/x failed: HTTP 502"))
        with self.assertRaises(gate.Refused):
            run(api)

    def test_patterns_and_hits(self):
        pats = gate.patterns(CHECK_PATHS)
        self.assertEqual(pats[0], "scripts/check-*")
        self.assertEqual(gate.hits(FILES_23365, pats), [".github/workflows/ci-web.yml", "webviews/package.json",
                                                         "webviews/scripts/check-fixed-waits.ts",
                                                         "webviews/scripts/fixed-waits-baseline.tsv"])
        self.assertEqual(gate.hits(FILES_22975, pats), [])

    def test_main_skips_other_bases_and_checks_its_arguments(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(gate.main(["manaflow-ai/cmux", "42", HEAD, "--base", "main"]), 0)
        self.assertIn("not feat-cmux-next", out.getvalue())
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(gate.main(["manaflow-ai/cmux", "42", "abc"]), 1)


if __name__ == "__main__":
    unittest.main()
