#!/usr/bin/env python3
"""Perf bisect with repeated runs and a noise threshold: perf-cron.py's commit_verdict, bisect_step, the culprit a
narrowed range names, and perf_bisect.py's replay walker. Pure functions only (no network, no git, no bench).
Run: python3 -I scripts/cmux-next/tests/test_perf_bisect.py (not a CI job, Lawrence 2026-10-23, since
lifted)."""
import datetime, importlib.util, os, random, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "..", filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cron = load("perf_cron", "perf-cron.py")
pb = load("perf_bisect", "perf_bisect.py")
budgets_mod = cron.load_budgets_module()
T0 = datetime.datetime(2026, 11, 19, 12, 0, tzinfo=datetime.timezone.utc)


def at(hours):
    return T0 + datetime.timedelta(hours=hours)


def row(p95, floor=1.0):
    return {"p50": p95, "p95": p95, "unit": "ms", "floor": floor, "budget": None}


def confirm_all(state, regs, cur, run_url, t, regression):
    return [{**r, "confirmed": True} for r in regs], [], set()


class CommitVerdictTests(unittest.TestCase):
    def test_three_agreeing_runs_decide(self):
        self.assertEqual(cron.commit_verdict([True, True, True]), cron.BAD)
        self.assertEqual(cron.commit_verdict([False, False, False]), cron.GOOD)

    def test_one_run_never_decides(self):
        self.assertEqual(cron.commit_verdict([True]), cron.AGAIN)
        self.assertEqual(cron.commit_verdict([False]), cron.AGAIN)

    def test_one_outlier_is_outvoted_with_one_more_run(self):
        self.assertEqual(cron.commit_verdict([True, False, False]), cron.AGAIN)
        self.assertEqual(cron.commit_verdict([True, False, False, False]), cron.GOOD)

    def test_a_split_commit_is_noise_after_the_max_runs(self):
        self.assertEqual(cron.commit_verdict([True, True, False, False]), cron.AGAIN)
        self.assertEqual(cron.commit_verdict([True, True, False, False, False]), cron.NOISE)

    def test_a_group_is_bad_when_one_row_is(self):
        self.assertEqual(cron.group_verdict([cron.GOOD, cron.BAD, cron.AGAIN]), cron.BAD)
        self.assertEqual(cron.group_verdict([cron.GOOD, cron.AGAIN]), cron.AGAIN)
        self.assertEqual(cron.group_verdict([cron.GOOD, cron.GOOD]), cron.GOOD)
        self.assertEqual(cron.group_verdict([cron.GOOD, cron.NOISE]), cron.NOISE)

    def test_the_threshold_is_the_rows_own_rule(self):
        self.assertEqual(cron.bisect_threshold(5.0, 1.0, 0.10), 1.0, "the floor when 10 % is smaller")
        self.assertEqual(cron.bisect_threshold(50.0, 1.0, 0.10), 5.0, "10 % of the reference when larger")


class CronBisectStepTests(unittest.TestCase):
    """A bisect step of the cron is one run: a commit moves the range only after BISECT_RUNS agreeing runs."""

    def setUp(self):
        for p in (mock.patch.object(cron, "confirm_regressions", confirm_all), mock.patch.object(cron, "RECOVER_RUNS", 1)):
            p.start()
            self.addCleanup(p.stop)
        self.state = cron.empty_state(T0)
        self.measured("a" * 40, 5.0, 0)
        self.measured("e" * 40, 9.0, 1)
        self.hour = 2

    def measured(self, sha, value, hours):
        state = self.state
        state["current"] = cron.new_measurement(sha, "tip", [], at(hours))
        state["current"]["parts"] = {"motion": {"state": "done"}}
        return cron.finish_measurement(state, {"t.e2e": row(value)}, 16.67, "bench", "r", at(hours), budgets_mod)

    def step(self, sha, value):
        rng = cron.bisect_groups(self.state)[0]["range"]
        self.state["current"] = cron.new_measurement(sha, "bisect", [], at(self.hour), rng)
        self.state["current"]["parts"] = {"motion": {"state": "done"}}
        rows = {} if value is None else {"t.e2e": row(value)}
        event = cron.finish_measurement(self.state, rows, 16.67, "bench", "r", at(self.hour), budgets_mod)
        self.hour += 1
        return event, self.state["history"][-1]["status"]

    def rng(self):
        r = self.state["regressions"][0]["range"]
        return r["good"], r["bad"]

    def test_one_bad_run_leaves_the_range_and_runs_the_commit_again(self):
        self.assertEqual(self.step("c" * 40, 9.1), ("skipped", "again"))
        self.assertEqual(self.rng(), ("a" * 40, "e" * 40), "one run moves nothing")
        self.assertEqual(self.state["regressions"][0]["range"]["runs"], {"c" * 40: [True]})

    def test_three_agreeing_runs_move_the_range(self):
        self.step("c" * 40, 9.1)
        self.step("c" * 40, 9.3)
        self.assertEqual(self.step("c" * 40, 9.0), ("narrowed", "bad"))
        self.assertEqual(self.rng(), ("a" * 40, "c" * 40))
        self.assertNotIn("runs", self.state["regressions"][0]["range"], "a decided commit's runs are dropped")

    def test_a_slow_runner_outlier_does_not_call_a_good_commit_bad(self):
        # 2026-11-15: one slow run called 48ec7aa (no web code) bad. Now it is outvoted.
        for v in (9.4, 5.1, 5.0):
            self.assertEqual(self.step("c" * 40, v)[1], "again")
        self.assertEqual(self.step("c" * 40, 5.2), ("narrowed", "good"))
        self.assertEqual(self.rng(), ("c" * 40, "e" * 40))

    def test_a_split_commit_is_skipped_as_within_noise(self):
        for v in (9.4, 9.2, 5.1, 5.0):
            self.step("c" * 40, v)
        self.assertEqual(self.step("c" * 40, 5.2), ("skipped", "skip"))
        self.assertIn("within noise", self.state["history"][-1]["note"])
        self.assertEqual(self.state["regressions"][0]["range"]["skip"], ["c" * 40])
        self.assertEqual(self.rng(), ("a" * 40, "e" * 40))

    def test_a_commit_that_does_not_build_is_skipped_at_once(self):
        self.assertEqual(self.step("c" * 40, None), ("skipped", "skip"))
        self.assertEqual(self.state["regressions"][0]["range"]["skip"], ["c" * 40])

    def test_runs_of_another_commit_start_again(self):
        self.step("c" * 40, 9.1)
        self.step("c" * 40, 9.1)
        self.step("d" * 40, 9.1)
        self.assertEqual(self.state["regressions"][0]["range"]["runs"], {"d" * 40: [True]})


class CulpritTests(unittest.TestCase):
    def test_nothing_between_names_the_bad_end(self):
        self.assertEqual(cron.range_culprit([], [], "b"), ("b", []))

    def test_only_skipped_commits_left_names_none(self):
        self.assertEqual(cron.range_culprit(["x"], ["x"], "b"), (None, ["x"]))

    def test_a_commit_left_to_try_names_nothing_yet(self):
        self.assertIsNone(cron.range_culprit(["x", "y"], ["x"], "b"))

    def test_the_nominee_carries_the_pr_of_a_squash(self):
        n = cron.culprit_nominee("f" * 40, "cmux next: agent chat folds a turn like the codex app (#41213)", "e" * 40,
                                 [{"name": "webui.transcript_replay.live.cls"}], 9)
        self.assertEqual((n["kind"], n["pr"], n["parent"], n["runs"]), ("perf", 41213, "e" * 40, cron.BISECT_RUNS))
        self.assertIsNone(cron.culprit_nominee("f" * 40, "direct push", "e" * 40, [], 1)["pr"])

    def state_with_range(self, good, bad):
        return {"regressions": [{"name": "t.e2e", "p95": 9.0, "ref": 5.0, "floor": 1.0,
                                 "range": {"good": good, "bad": bad, "skip": [], "steps": 4}}]}

    def test_name_culprit_records_once_and_the_issue_names_it(self):
        state = self.state_with_range("a" * 40, "b" * 40)
        group = cron.bisect_groups(state)[0]
        self.assertTrue(cron.name_culprit(state, group, ("b" * 40, []), "fold turns (#41213)", at(0)))
        self.assertFalse(cron.name_culprit(state, group, ("b" * 40, []), "fold turns (#41213)", at(1)), "once")
        self.assertEqual([c["pr"] for c in state["culprits"]], [41213])
        body = cron.issue_body(state, "o/r", at(1))
        self.assertIn("**Culprit** of t.e2e", body)
        self.assertIn("(#41213)", body)

    def test_an_unresolved_range_names_none_and_says_so(self):
        state = self.state_with_range("a" * 40, "b" * 40)
        group = cron.bisect_groups(state)[0]
        self.assertFalse(cron.name_culprit(state, group, (None, ["c" * 40]), "", at(0)))
        self.assertNotIn("culprits", state)
        self.assertIn("unresolved: only 1 commit(s)", cron.issue_body(state, "o/r", at(1)))


def commits(n):
    return [f"{i:040x}" for i in range(n)]


def noisy(values, sd, outliers=(), seed=1):
    """measure(sha): values[sha] plus gaussian noise; each sha in outliers reads 1.5x on its first run (a slow host)."""
    rnd, seen = random.Random(seed), set()

    def measure(sha):
        v = values[sha] + rnd.gauss(0, sd)
        if sha in outliers and sha not in seen:
            seen.add(sha)
            v *= 1.5
        return v
    return measure


class ReplayTests(unittest.TestCase):
    def test_a_step_is_named_at_its_commit(self):
        cs = commits(301)
        culprit = cs[187]
        values = {c: (0.14 if i < 187 else 1.16) for i, c in enumerate(cs)}
        out = pb.replay(cs, noisy(values, 0.01), floor=0.001)
        self.assertEqual(out["verdict"], "culprit")
        self.assertEqual(out["culprit"], culprit)
        self.assertEqual(out["parent"], cs[186])
        self.assertLessEqual(out["steps"], 10, "a binary search: about log2(299) steps")

    def test_slow_host_outliers_do_not_move_the_culprit(self):
        cs = commits(65)
        values = {c: (10.0 if i < 40 else 14.0) for i, c in enumerate(cs)}
        # Every good commit's first run reads 15 (a slow host): one-run bisect would call them all bad.
        out = pb.replay(cs, noisy(values, 0.2, outliers=set(cs[:40])), floor=1.0)
        self.assertEqual(out["culprit"], cs[40])

    def test_a_flat_range_is_within_noise(self):
        cs = commits(40)
        out = pb.replay(cs, noisy({c: 10.0 for c in cs}, 0.3), floor=1.0)
        self.assertEqual(out["verdict"], "within noise")
        self.assertNotIn("culprit", out)
        self.assertEqual(len(out["probes"]), 2, "only the ends ran")

    def test_a_flat_range_with_one_slow_run_at_the_bad_end_is_within_noise(self):
        cs = commits(40)
        out = pb.replay(cs, noisy({c: 10.0 for c in cs}, 0.3, outliers={cs[-1]}), floor=1.0)
        self.assertEqual(out["verdict"], "within noise")

    def test_a_commit_that_does_not_measure_is_skipped(self):
        cs = commits(9)
        values = {c: (1.0 if i < 5 else 3.0) for i, c in enumerate(cs)}
        base = noisy(values, 0.01)
        out = pb.replay(cs, lambda sha: None if sha == cs[5] else base(sha), floor=0.5)
        self.assertEqual(out["verdict"], "unresolved", "the culprit itself cannot be built")
        self.assertEqual((out["parent"], out["first_bad"], out["unjudged"]), (cs[4], cs[6], [cs[5]]))

    def test_an_unmeasurable_good_end_says_so(self):
        self.assertEqual(pb.replay(commits(5), lambda sha: None, floor=1.0)["verdict"], "unmeasured")

    def test_one_timed_out_run_is_tried_again_not_noise(self):
        # 2026-11-19: commit 8743439 read 0.81, then its bench timed out at 150 s, and the walk called it noise.
        cs = commits(9)
        values = {c: (0.01 if i < 4 else 0.9) for i, c in enumerate(cs)}
        base, timed_out = noisy(values, 0.001), set()

        def measure(sha):
            if sha == cs[4] and sha not in timed_out:
                timed_out.add(sha)
                return None
            return base(sha)
        out = pb.replay(cs, measure, floor=0.1)
        self.assertEqual(out["culprit"], cs[4])

    def test_two_failed_runs_in_a_row_end_a_commit(self):
        calls = []

        def measure(sha):
            calls.append(sha)
            return None
        self.assertEqual(pb.sample("x", measure, 1.0, 0.1, 3, 5), (cron.NOISE, []))
        self.assertEqual(len(calls), pb.FAILS_IN_A_ROW, "a commit that does not build costs two attempts, not five")

    def test_a_bad_end_that_never_measures_is_unmeasured_not_within_noise(self):
        cs = commits(6)
        out = pb.replay(cs, lambda sha: 1.0 if sha == cs[0] else None, floor=0.1)
        self.assertEqual(out["verdict"], "unmeasured")

    def test_a_failed_run_is_not_kept_so_a_resume_tries_it_again(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cache.json")
            first = pb.cached(lambda sha: None, path)
            self.assertIsNone(first("a"))
            again = pb.cached(lambda sha: 2.5, path)
            self.assertEqual(again("a"), 2.5, "the host's failure was not remembered as the commit's")

    def test_a_replay_started_again_resumes_from_its_cache(self):
        import tempfile
        cs = commits(33)
        values = {c: (1.0 if i < 20 else 5.0) for i, c in enumerate(cs)}
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cache.json")
            first = pb.replay(cs, pb.cached(noisy(values, 0.05), path), floor=1.0)
            runs = []

            def counted(sha):
                runs.append(sha)
                return values[sha]
            again = pb.replay(cs, pb.cached(counted, path), floor=1.0)
        self.assertEqual(first["culprit"], cs[20])
        self.assertEqual(again["culprit"], cs[20])
        self.assertEqual(runs, [], "every run of the second walk came from the cache")


if __name__ == "__main__":
    unittest.main()
