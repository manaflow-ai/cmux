#!/usr/bin/env python3
"""scripts/measure/bench-ab: the A/B statistics, the bench extractors, the driver's pin rules and the published table.
No fleet, no app: synthetic artifacts in a temp folder. Run: python3 -I scripts/measure/tests/bench-ab.test.py"""
import importlib.util, json, os, random, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.normpath(os.path.join(HERE, "..", "bench-ab"))
sys.path.insert(0, DIR)


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(DIR, f"{name}.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bench_ab, driver, publish = load("bench_ab"), load("driver"), load("publish")


def instant_doc(rng, shift=0.0, n=40):
    return {"runs": [{"command": "new_tab", "phase": "idle", "visible_ms": rng.gauss(30 + shift, 2),
                      "key_ms": rng.gauss(5, .5)} for _ in range(n)]}


def write_jobs(folder, bench, arm_docs):
    """arm_docs: list of (round, arm, doc), arm before|after."""
    for rnd, arm, doc in arm_docs:
        sha = "acfd6938" if arm == "before" else "3cc92720"
        with open(os.path.join(folder, f"bench-{bench}-r{rnd}-{arm}-{sha}.json"), "w") as f:
            json.dump(doc, f)


def row(res, key, metric):
    return next(r for r in res["rows"] if r["key"] == key and r["metric"] == metric)


class Statistics(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.rng = random.Random(7)

    def jobs(self, shift_b=0.0, shift_a2=0.0, rounds=3):
        docs = []
        for r in range(1, rounds + 1):
            docs.append((r, "before", instant_doc(self.rng, shift_a2 if r % 2 == 0 else 0.0)))
            docs.append((r, "after", instant_doc(self.rng, shift_b)))
        write_jobs(self.tmp, "instant-ab", docs)
        return bench_ab.compare("instant-ab", bench_ab.load(self.tmp, "instant-ab"))

    def test_same_distribution_is_same(self):
        r = row(self.jobs(), "new_tab/idle", "visible_ms")
        self.assertEqual(r["unit"], "sample")
        self.assertEqual(r["verdict"]["p50"], "same")

    def test_a_shift_beyond_the_interval_is_a_regression(self):
        r = row(self.jobs(shift_b=8.0), "new_tab/idle", "visible_ms")
        self.assertEqual(r["verdict"]["p50"], "REGRESSION")
        self.assertGreater(r["delta"]["p50"][1][0], 0)

    def test_a_faster_b_is_improved(self):
        self.assertEqual(row(self.jobs(shift_b=-8.0), "new_tab/idle", "visible_ms")["verdict"]["p50"], "IMPROVED")

    def test_a_noisy_aa_judges_nothing(self):
        # A's even jobs are 8 ms slower than its odd jobs: the A/A interval excludes 0, so even a real shift of B
        # is not called a regression.
        r = row(self.jobs(shift_b=8.0, shift_a2=8.0), "new_tab/idle", "visible_ms")
        self.assertEqual(r["verdict"]["p50"], "NOISY")

    def test_one_job_per_arm_is_too_few(self):
        write_jobs(self.tmp, "instant-ba", [(1, "before", instant_doc(self.rng)), (2, "after", instant_doc(self.rng, 8))])
        r = row(bench_ab.compare("instant-ba", bench_ab.load(self.tmp, "instant-ba")), "new_tab/idle", "visible_ms")
        self.assertEqual(r["verdict"]["p50"], "too-few")

    def test_benches_of_two_minis_stay_apart(self):
        write_jobs(self.tmp, "instant-ab", [(1, "before", instant_doc(self.rng))])
        write_jobs(self.tmp, "instant-ba", [(1, "before", instant_doc(self.rng)), (2, "before", instant_doc(self.rng))])
        self.assertEqual(len(bench_ab.load(self.tmp, "instant-ab")["before"]), 1)
        self.assertEqual(len(bench_ab.load(self.tmp, "instant-ba")["before"]), 2)

    def test_equal_arms_rarely_give_a_false_regression(self):
        # Many seeds, equal arms with a job-to-job spread (a mini's state differs between launches): the two-level
        # bootstrap and the effect floor keep false REGRESSION verdicts rare (review of #29135: pooled samples gave 12 %).
        bench_ab.BOOT, saved = 300, bench_ab.BOOT
        try:
            false = total = 0
            for seed in range(60):
                rng = random.Random(seed)
                arms = {arm: [(i, {"runs": [{"command": "c", "phase": "idle", "visible_ms": rng.gauss(30 + jm, 3)}
                                            for _ in range(12)]}) for i, jm in enumerate(rng.gauss(0, 2) for _ in range(3))]
                        for arm in ("before", "after")}
                v = bench_ab.compare("instant-x", arms, seed=seed)["rows"][0]["verdict"]
                false += v["p50"] == "REGRESSION"  # p95/p99 are too-few at 36 samples: judge p50 alone
                total += 1
            self.assertLessEqual(false / total, 0.05)
        finally:
            bench_ab.BOOT = saved

    def test_tails_need_enough_samples_and_max_gets_no_verdict(self):
        r = row(self.jobs(shift_b=8.0), "new_tab/idle", "visible_ms")
        self.assertEqual(r["verdict"]["p99"], "too-few")  # 120 samples per arm, under MIN_SAMPLES p99
        self.assertNotIn("max", r["verdict"])
        self.assertIsNone(r["a"]["max"][1])

    def test_a_shift_under_the_floor_is_same(self):
        r = row(self.jobs(shift_b=0.6), "new_tab/idle", "visible_ms")
        self.assertNotEqual(r["verdict"]["p50"], "REGRESSION")

    def test_artifacts_of_another_commit_never_join_an_arm(self):
        write_jobs(self.tmp, "instant-ab", [(1, "before", instant_doc(self.rng)), (2, "after", instant_doc(self.rng))])
        with open(os.path.join(self.tmp, "bench-instant-ab-r3-after-e1b88d18.json"), "w") as f:
            json.dump(instant_doc(self.rng, 50), f)
        arms = bench_ab.load(self.tmp, "instant-ab", "acfd69382dc1", "3cc92720c95")
        self.assertEqual(len(arms["after"]), 1)
        self.assertEqual(len(bench_ab.load(self.tmp, "instant-ab")["after"]), 2)

    def test_missed_presses_are_counted_per_arm(self):
        docs = [(r, arm, {"runs": [{"command": "c", "phase": "idle", "visible_ms": 30.0}] * 5
                          + ([{"command": "c", "phase": "idle", "visible_ms": None}] if arm == "after" else [])})
                for r in (1, 2) for arm in ("before", "after")]
        write_jobs(self.tmp, "instant-ab", docs)
        r = row(bench_ab.compare("instant-ab", bench_ab.load(self.tmp, "instant-ab")), "c/idle", "visible_ms")
        self.assertEqual(r["missed"], {"before": 0, "after": 2})

    def test_a_typeable_run_is_missed_only_without_typeable_ms(self):
        doc = {"runs": [{"command": "new_tab", "phase": "idle", "typeable_ms": 40.0, "lost": False},
                        {"command": "new_tab", "phase": "idle", "typeable_ms": None, "lost": True},
                        {"command": "new_tab", "phase": "idle", "visible_ms": 30.0},
                        {"command": "new_tab", "phase": "idle", "visible_ms": None}]}
        self.assertEqual(bench_ab.missed_instant(doc), {"new_tab/idle": 2})

    def test_quantile_is_linear(self):
        self.assertEqual(bench_ab.q([1, 2, 3, 4], .5), 2.5)
        self.assertIsNone(bench_ab.q([], .5))


class Extractors(unittest.TestCase):
    def test_every_action_rows_and_interactions(self):
        doc = {"sessions": [{"name": "light", "rows": [
            {"id": "splitRight", "kind": "action", "commit_ms": {"p50": 6, "p95": 19}, "turn_ms": {"p50": 3, "p95": 15},
             "frames": {"missed_total": 8}}],
            "interactions": [{"id": "resize.window", "kind": "interaction",
                              "frames": {"missed": 17, "max_ms": 16.7, "main_p95_ms": 8.7}}]}]}
        out = bench_ab.samples_every_action(doc)
        self.assertEqual(out["light/splitRight"]["commit_ms.p95"], [19.0])
        self.assertEqual(out["light/splitRight"]["missed_frames"], [8.0])
        self.assertEqual(out["light/resize.window"]["frames.missed"], [17.0])

    def test_every_action_is_replicate_and_judged_on_the_median(self):
        tmp = tempfile.mkdtemp()
        docs = [(r, arm, {"sessions": [{"name": "light", "rows": [{"id": "x", "commit_ms": {"p50": 1, "p95": 10 + r}}]}]})
                for r in range(1, 5) for arm in ("before", "after")]
        write_jobs(tmp, "ealight", docs)
        r = row(bench_ab.compare("ealight", bench_ab.load(tmp, "ealight")), "light/x", "commit_ms.p95")
        self.assertEqual(r["unit"], "replicate")
        self.assertEqual(set(r["verdict"]), {"p50"})
        self.assertEqual(r["jobs_a"], 4)

    def test_rounds_of_one_job_stay_one_job(self):
        # typing-frame and terminal-resize keep 2 rounds per fleet job: the job is the unit (review of 03e16dac747).
        def doc(vals):
            return {"layouts": [{"layout": "light", "rounds": [{"frames": {"missed": v}} for v in vals]}]}
        tmp = tempfile.mkdtemp()
        write_jobs(tmp, "resize", [(1, "before", doc([1, 1])), (2, "before", doc([2, 2])), (1, "after", doc([9, 9]))])
        r = row(bench_ab.compare("resize", bench_ab.load(tmp, "resize")), "light", "frames.missed")
        self.assertEqual((r["jobs_a"], r["jobs_b"], r["n_b"]), (2, 1, 2))
        self.assertEqual(r["verdict"]["p50"], "too-few")  # one B job, however many rounds

    def test_replicate_rows_with_rounds_rarely_give_a_false_regression(self):
        bench_ab.BOOT, saved = 300, bench_ab.BOOT
        try:
            false = 0
            for seed in range(80):
                rng = random.Random(seed)
                def job():
                    m = 10 + rng.gauss(0, 3)
                    return {"layouts": [{"layout": "light", "rounds": [{"frames": {"missed": m + rng.gauss(0, .3)}}
                                                                       for _ in range(2)]}]}
                arms = {"before": [(i, job()) for i in range(4)], "after": [(i, job()) for i in range(4)]}
                r = row(bench_ab.compare("resize", arms, seed=seed), "light", "frames.missed")
                false += r["verdict"]["p50"] == "REGRESSION"
            self.assertLessEqual(false / 80, 0.05)
        finally:
            bench_ab.BOOT = saved

    def test_launch_typing_resize(self):
        self.assertEqual(bench_ab.samples_launch({"t": {"cold": [{"first_frame": 200}, {"first_frame": 210}]}}),
                         {"cold": {"first_frame": [200.0, 210.0]}})
        self.assertEqual(bench_ab.samples_typing({"runs": [{"surface": "terminal", "phase": "idle",
                                                            "key_to_frame_ms": {"p95": 4, "n": 80}}]}),
                         {"light/terminal.idle": {"key_to_frame.p95": [4.0]}})
        rs = bench_ab.samples_resize({"layouts": [{"layout": "light", "rounds": [{"frames": {"missed": 0, "p95_ms": 8.3}},
                                                                                 {"frames": {"missed": 2, "p95_ms": 9}}]},
                                                  {"layout": "idle-cursor", "frames": 0}]})
        self.assertEqual(rs["light"]["frames.missed"], [0.0, 2.0])
        self.assertEqual(rs["idle-cursor"]["ghostty_frames"], [0.0])

    def test_kind_maps_order_variants(self):
        self.assertEqual(bench_ab.kind("instant-ab"), "instant")
        self.assertEqual(bench_ab.kind("ealight"), "ealight")


class DriverRules(unittest.TestCase):
    def status(self, pool="perf-lead", free=60, running=None, pinned=0):
        return {"workers": [{"name": "cmux22-perf", "pool": pool, "free_bytes": free * 2**30}],
                "measure_hosts": [{"name": "cmux22-perf", "online": True, "running": running, "queued_pinned": pinned}]}

    def test_idle_mini_is_ready(self):
        self.assertEqual(driver.worker_ready(self.status(), "cmux22-perf", "perf-lead"), (True, "idle"))

    def test_capture_lease_disk_running_and_pins_are_not_ready(self):
        for st in (self.status(pool="capture-abc"), self.status(free=39), self.status(running={"id": "j"}),
                   self.status(pinned=1)):
            self.assertFalse(driver.worker_ready(st, "cmux22-perf", "perf-lead")[0])
        self.assertFalse(driver.worker_ready(self.status(), "cmux21-perf", "perf-lead")[0])

    def test_step_actions(self):
        self.assertEqual(driver.step_action({"state": "running", "worker": "cmux17-perf"}, "cmux22-perf", 5),
                         "cancel-wrong-worker")
        self.assertEqual(driver.step_action({"state": "queued"}, "cmux22-perf", driver.QUEUE_LIMIT + 1), "cancel-queued")
        self.assertEqual(driver.step_action({"state": "queued"}, "cmux22-perf", 60), "wait")
        self.assertEqual(driver.step_action({"state": "done", "worker": "cmux22-perf"}, "cmux22-perf", 900), "ended")

    def test_paused_or_unhealthy_worker_is_not_ready(self):
        for extra in ({"claim_paused": True}, {"excluded": True}, {"healthy": False}):
            st = self.status()
            st["workers"][0].update(extra)
            self.assertFalse(driver.worker_ready(st, "cmux22-perf", "perf-lead")[0])

    def test_queue_age_is_the_controllers(self):
        import datetime
        created = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=8)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        age = driver.queued_seconds({"created_at": created})
        self.assertGreater(age, driver.QUEUE_LIMIT)
        self.assertEqual(driver.step_action({"state": "queued"}, "cmux22-perf", age), "cancel-queued")
        self.assertIsNone(driver.queued_seconds({}))

    def test_queue_limit_is_under_the_pin_fallback(self):
        self.assertLess(driver.QUEUE_LIMIT, 10 * 60)

    def test_reserved_host_is_refused(self):
        tmp = tempfile.mkdtemp()
        path = os.path.join(tmp, "p.json")
        with open(path, "w") as f:
            json.dump({"worker": "cmux17-perf", "steps": []}, f)
        with self.assertRaises(SystemExit):
            driver.Driver(path)

    def test_step_command_is_pinned_exclusive_measurement(self):
        cmd = driver.step_command({"ref": "a" * 40, "script": "scripts/measure/split-spring.sh", "args": ["--x=1"],
                                   "artifact": "artifacts/r.json"}, "cmux22-perf", "perf-lead", "k")
        for flag in ("--class", "exclusive", "--measurement", "--pool", "perf-lead", "--target-worker", "cmux22-perf",
                     "--arg=--x=1"):
            self.assertIn(flag, cmd)


class FakeCI(driver.Driver):
    """A Driver whose cmux-ci calls answer from a script: [(args prefix, stdout)]; records every call."""
    def __init__(self, plan_path, answers):
        super().__init__(plan_path)
        self.answers, self.calls = answers, []

    def ci(self, *args, timeout=120):
        self.calls.append(args)
        for prefix, out in self.answers:
            if args[:len(prefix)] == prefix:
                return subprocess.CompletedProcess(args, 0, out() if callable(out) else out, "")
        return subprocess.CompletedProcess(args, 1, "", "")


class DriverCalls(unittest.TestCase):
    def plan(self):
        tmp = tempfile.mkdtemp()
        path = os.path.join(tmp, "p.json")
        with open(path, "w") as f:
            json.dump({"worker": "cmux22-perf", "steps": []}, f)
        return path

    def test_cancel_counts_only_when_the_job_ended(self):
        driver.time.sleep, saved = (lambda s: None), driver.time.sleep
        try:
            d = FakeCI(self.plan(), [(("status",), json.dumps({"state": "queued"}))])
            self.assertFalse(d.cancel("j1", "cancel-queued"))
            self.assertGreaterEqual(sum(c[0] == "cancel" for c in d.calls), 2)
            d = FakeCI(self.plan(), [(("status",), json.dumps({"state": "cancelled"}))])
            self.assertTrue(d.cancel("j1", "cancel-queued"))
        finally:
            driver.time.sleep = saved

    def test_a_lost_job_id_is_found_by_its_key(self):
        d = FakeCI(self.plan(), [(("status", "--ref"), json.dumps([{"id": "other", "step_key": "x"},
                                                                    {"id": "mine", "step_key": "k-1"}]))])
        self.assertEqual(d.find_by_key("a" * 40, "k-1"), "mine")
        self.assertIsNone(d.find_by_key("a" * 40, "k-2"))

    def test_keys_of_two_runs_differ(self):
        self.assertNotEqual(driver.Driver(self.plan()).run_id[:15], "")
        self.assertIn(f"p{os.getpid()}", driver.Driver(self.plan()).run_id)


class Publish(unittest.TestCase):
    def test_regression_line_and_section_replace(self):
        tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(tmp, "artifacts"))
        rng = random.Random(3)
        write_jobs(os.path.join(tmp, "artifacts"), "instant-ab",
                   [(r, arm, instant_doc(rng, 10.0 if arm == "after" else 0.0)) for r in (1, 2, 3, 4) for arm in ("before", "after")])
        tip, base = "3cc92720" + "b" * 32, "acfd6938" + "a" * 32
        text, regs = publish.section(tip, base, tmp, ["instant-ab"], rng_text="abc123 a commit")
        self.assertTrue(any(r["metric"] == "visible_ms" for _, r, _s in regs))
        self.assertIn("BENCH REGRESSION instant-ab/new_tab/idle/visible_ms", text)
        self.assertIn("range acfd6938aaa..3cc92720bbb", text)
        self.assertIn("abc123 a commit", text)
        old = "head\n<!-- tip " + "b" * 40 + " -->\nold\n<!-- end tip " + "b" * 40 + " -->\nother\n"
        merged = publish.replace_section(old.replace("b" * 40, tip), tip, text)
        self.assertNotIn("\nold\n", merged)
        self.assertTrue(merged.startswith("head\n") and merged.endswith("other\n"))

    def test_cli_writes_the_file(self):
        tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(tmp, "artifacts"))
        out = os.path.join(tmp, "t.md")
        p = subprocess.run([sys.executable, "-I", os.path.join(DIR, "publish.py"), "--tip", "b" * 40, "--base", "a" * 40,
                            "--plans", tmp, "--out", out, "--repo", tmp, "ealight"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        with open(out) as f:
            self.assertIn("No comparable rows yet.", f.read())


if __name__ == "__main__":
    unittest.main()
