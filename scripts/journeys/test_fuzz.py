#!/usr/bin/env python3
"""The action fuzzer's pure parts and its verdicts, with a stand-in for run.py: no fleet, no app.

    python3 scripts/journeys/test_fuzz.py

A seed always gives the same plan; bursts cut at slow actions; ddmin finds the minimal failing subsequence and stops
on no verdict; the speed table reds only a real, repeated slowdown; fuzz.py says CLEAN (and writes the .clean file)
only for a non-diagnostic run with no failure, no speed red and enough fuzz time; a failure is RED with its oracle,
seed and shrunk sequence, replayed in a fresh lease and written as a regression journey. The journey loads
(`run.py --check`).
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "cmux-next"))  # build_names.py, as run.py finds it
import ext_fuzz  # noqa: E402
import fuzz  # noqa: E402

# A stand-in for run.py: writes the round's results.jsonl and action-fuzz/fuzz.json from FUZZ_PLAN (JSON:
# {"<side>": {"fail_seeds": [...], "typeable_ms": N}}), the side read from the --build job id.
FAKE = r'''
import json, os, sys
args = sys.argv[1:]
out = args[args.index("--out") + 1]
build = args[args.index("--build") + 1]
opts = dict(a.split("=", 1) for i, a in enumerate(args) if i and args[i - 1] == "--journey-option")
plan = json.loads(os.environ["FUZZ_PLAN"])
side = plan.get(build, {})
os.makedirs(os.path.join(out, "action-fuzz"), exist_ok=True)
with open(os.path.join(os.environ["FUZZ_LOG"]), "a") as f:
    f.write(json.dumps({"build": build, "opts": opts, "hosts": args[args.index("--hosts") + 1],
                        "whole_host": "--whole-host" in args}) + "\n")
seed = int(opts.get("fuzz_seed", 0))
seq = json.loads(opts["fuzz_sequence"]) if "fuzz_sequence" in opts else [{"a": "split_right", "t": "pair"}] * 4
fail = seed in side.get("fail_seeds", []) or ("fuzz_sequence" in opts and side.get("fail_sequences"))
findings = [{"oracle": "desync", "signature": f, "detail": f, "count": 2, "first_n": 1, "sequence": []} for f in side.get("findings", [])]
failure = {"oracle": "create", "detail": "split_right+split_right: no terminal, no refusal", "index": len(seq)} if fail else None
split = {"played": 3, "hold": 1, "red": 0, "pass_hold": 1, "pass_not_judged": 2}
speed = [] if side.get("omit_speed") else [
    {"a": "new_terminal", "t": "slow", "shown_ms": side.get("typeable_ms", 100) - 20, "typeable_ms": side.get("typeable_ms", 100)}
    for _ in range(3)]
report = {"seed": seed, "played": len(seq), "seconds": float(side.get("seconds", 120)), "failure": failure,
          "shrunk": seq[:2] if fail else None, "speed": speed, "sequence": seq, "findings": findings, "split_type": split}
if not side.get("omit_report"):
    json.dump(report, open(os.path.join(out, "action-fuzz", "fuzz.json"), "w"))
row = {"id": "action-fuzz", "status": "fail" if fail else side.get("status", "pass"), "reason": "", "host": "cmux99", "build_job": build}
open(os.path.join(out, "results.jsonl"), "w").write(json.dumps(row) + "\n")
open(os.path.join(out, "acquire.log"), "w").write("capture-host: cmux99 is exclusive until 2026-10-31T09:00:00Z: the fleet controller places no step on its workers\n")
sys.exit(1 if fail else 0)
'''


class Pure(unittest.TestCase):
    def test_plan_is_seeded(self):
        self.assertEqual(ext_fuzz.plan(42, 50), ext_fuzz.plan(42, 50))
        self.assertNotEqual(ext_fuzz.plan(42, 50), ext_fuzz.plan(43, 50))
        for item in ext_fuzz.plan(5, 400):
            self.assertIn(item["a"], ext_fuzz.ACTIONS)
            self.assertIn(item["t"], ext_fuzz.TIMINGS)
            if ext_fuzz.ACTIONS[item["a"]].get("alone"):
                self.assertEqual(item["t"], "slow")

    def test_plan_has_every_action_and_same_pairs(self):
        seq = ext_fuzz.plan(1, 3000)
        names = {i["a"] for i in seq}
        # The full set: every action but the quit set's own (kept out so old seeds keep their plans).
        self.assertEqual(names, {a for a in ext_fuzz.ACTIONS if ext_fuzz.WEIGHTS.get(a, 0) > 0})
        self.assertEqual(set(ext_fuzz.ACTIONS) - names, {a for a in ext_fuzz.ACTIONS if ext_fuzz.ACTIONS[a].get("ends")})
        pairs = sum(1 for a, b in zip(seq, seq[1:]) if a["t"] == "pair" and a["a"] == b["a"] and ext_fuzz.ACTIONS[a["a"]].get("creates"))
        self.assertGreater(pairs, 50)

    def test_quit_set_plays_every_quit_kind_and_each_ends_its_burst(self):
        """QUIT P0: the quit set plays each quit kind and kill -9, and each one ends its burst, often right after a
        create, a resize or typed text (a kill during them)."""
        seq = ext_fuzz.plan(3, 2000, actions="quit")
        ends = {a for a in ext_fuzz.ACTIONS if ext_fuzz.ACTIONS[a].get("ends")}
        self.assertEqual(ends & {i["a"] for i in seq}, ends)
        during = 0
        for burst in ext_fuzz.bursts(seq):
            for item in burst[:-1]:
                self.assertNotIn(item["a"], ends, "a quit or kill in the middle of a burst")
            if burst[-1]["a"] in ends and len(burst) > 1:
                during += 1
        self.assertGreater(during, 20, "quits and kills that follow another action at once")

    def test_alone_action_ends_the_burst_before_it(self):
        seq = [{"a": "new_terminal", "t": "now"}, {"a": "close_all", "t": "slow"}]
        self.assertEqual([[i["a"] for i in b] for b in ext_fuzz.bursts(seq)], [["new_terminal"], ["close_all"]])
        seq = [{"a": "split_right", "t": "pair"}, {"a": "split_type", "t": "now"}, {"a": "new_column", "t": "slow"}]
        self.assertEqual([[i["a"] for i in b] for b in ext_fuzz.bursts(seq)], [["split_right"], ["split_type"], ["new_column"]])
        for burst in ext_fuzz.bursts(ext_fuzz.plan(9, 500)):
            self.assertLessEqual(len(burst), ext_fuzz.MAX_BURST)
            for item in burst[:-1]:
                self.assertNotEqual(item["t"], "slow")

    def test_new_refusals_when_the_list_is_full(self):
        full = [f"m{i}" for i in range(100)]
        self.assertEqual(ext_fuzz.new_refusals(full, full[1:] + ["split refused"]), ["split refused"])
        self.assertEqual(ext_fuzz.new_refusals(["a"], ["a", "b"]), ["b"])
        self.assertEqual(ext_fuzz.new_refusals(full, full), [])
        self.assertTrue(ext_fuzz.SPLIT_REFUSAL.search("Not enough room to split this column"))
        self.assertFalse(ext_fuzz.SPLIT_REFUSAL.search("The terminal could not start"))

    def test_ddmin_finds_the_pair(self):
        seq = [{"a": "x", "i": i} for i in range(20)]
        fails = lambda cand: {3, 11} <= {c["i"] for c in cand}
        small, tries = ext_fuzz.ddmin(seq, fails)
        self.assertEqual([c["i"] for c in small], [3, 11])
        self.assertGreater(tries, 0)

    def test_ddmin_stops_on_no_verdict(self):
        seq = list(range(10))
        calls = []

        def fails(cand):
            calls.append(cand)
            return None if len(calls) > 2 else 5 in cand
        small, _ = ext_fuzz.ddmin(seq, fails)
        self.assertIn(5, small)
        self.assertEqual(len(calls), 3)

    def test_corpus_uses_known_actions(self):
        for name, seq in ext_fuzz.CORPUS.items():
            self.assertTrue(name.startswith(("lawrence-", "tipred-")))
            for item in seq:
                self.assertIn(item["a"], ext_fuzz.ACTIONS)

    def test_signature_drops_window_ids_and_uuids(self):
        a = ext_fuzz.signature("focus", "window 3FA85F64-5717-4562-B3FC-2C963F66AFA6: model terminal vs first responder sidebar")
        b = ext_fuzz.signature("focus", "window 9C1D2E3F-1111-4222-8333-444455556666: model terminal vs first responder sidebar")
        self.assertEqual(a, b)
        self.assertEqual(ext_fuzz.signature("desync", "W5 win_ab12cd: x"), ext_fuzz.signature("desync", "W5 win_ff00ee: x"))

    def test_speed_table_reds_only_a_real_slowdown(self):
        rows = [{"build": "base", "seed": 1, "a": "new_tab", "t": "slow", "typeable_ms": v} for v in (200, 210, 190, 205, 220)]
        rows += [{"build": "test", "seed": 1, "a": "new_tab", "t": "slow", "typeable_ms": v} for v in (420, 400, 450, 390, 410)]
        rows += [{"build": "base", "seed": 1, "a": "split_right", "t": "pair", "shown_ms": v} for v in (100, 110, 90, 95)]
        rows += [{"build": "test", "seed": 1, "a": "split_right", "t": "pair", "shown_ms": v} for v in (105, 112, 99, 400)]
        table = {(r["action"], r["mark"]): r for r in fuzz.speed_table(rows)}
        self.assertTrue(table[("new_tab", "typeable_ms")]["red"])
        self.assertFalse(table[("split_right", "shown_ms")]["red"])  # one slow sample is not a red
        few = fuzz.speed_table([dict(r) for r in rows if r["a"] == "new_tab"][:3] + rows[5:8])
        self.assertFalse(any(r["red"] for r in few))


class Verdicts(unittest.TestCase):
    def run_fuzz(self, plan, *extra):
        if "--diagnostic" not in extra and "--whole-host" not in extra:
            extra = extra + ("--whole-host", "cmux99")  # normal mode needs a whole-host lease
        tmp = Path(tempfile.mkdtemp())
        fake = tmp / "fake_run.py"
        fake.write_text(FAKE)
        log = tmp / "calls.jsonl"
        env = {**os.environ, "FUZZ_PLAN": json.dumps(plan), "FUZZ_LOG": str(log), "SMOKE_GATE_CMUX_CI": "/nonexistent"}
        done = subprocess.run([sys.executable, str(HERE / "fuzz.py"), "--build", "jobT", "--minutes", "4", "--seed", "100",
                               "--out", str(tmp / "out"), "--handoff", str(tmp / "handoff"), "--runner", str(fake), *extra],
                              capture_output=True, text=True, env=env, timeout=120)
        summary = json.loads((tmp / "out" / "summary.json").read_text())
        calls = [json.loads(l) for l in log.read_text().splitlines()] if log.exists() else []
        return done, summary, calls, tmp

    def test_clean_writes_the_clean_file(self):
        done, summary, calls, tmp = self.run_fuzz({"jobT": {}, "jobB": {}}, "--base", "jobB")
        self.assertEqual(summary["verdict"], "CLEAN", done.stdout + done.stderr)
        self.assertEqual(done.returncode, 0)
        self.assertTrue((tmp / "handoff" / "jobT.clean").exists())
        builds = [c["build"] for c in calls]
        self.assertEqual(builds[:4], ["jobT", "jobB", "jobB", "jobT"])  # ABBA
        self.assertTrue(all("cmux17" not in c["hosts"] for c in calls))

    def test_failure_is_red_shrunk_confirmed_and_written(self):
        done, summary, calls, tmp = self.run_fuzz({"jobT": {"fail_seeds": [101], "fail_sequences": True}, "jobB": {}}, "--base", "jobB")
        self.assertEqual(summary["verdict"], "RED")
        self.assertEqual(done.returncode, 1)
        f = summary["failures"][0]
        self.assertEqual((f["seed"], f["failure"]["oracle"]), (101, "create"))
        self.assertEqual(len(f["shrunk"]), 1)  # the stand-in fails every replayed sequence: ddmin goes to one action
        self.assertGreater(f["shrink_leases"], 0)  # ddmin ran outside the round, one lease per try
        self.assertTrue(f["confirmed"])
        repro = json.loads(Path(f["repro"]).read_text())
        run = next(s for s in repro["steps"] if s["do"] == "fuzz_run")
        self.assertEqual((run["shrink"], len(run["sequence"])), (False, 1))
        self.assertFalse((tmp / "handoff" / "jobT.clean").exists())
        self.assertTrue(any("fuzz_sequence" in c["opts"] for c in calls[-1:]))

    def test_split_type_hold_counts_reported(self):
        done, summary, _, _ = self.run_fuzz({"jobT": {}, "jobB": {}}, "--base", "jobB")
        self.assertEqual(summary["split_type"]["played"] % 3, 0)
        self.assertGreater(summary["split_type"]["played"], 0)
        text = (Path(summary["out"]) / "summary.txt").read_text()
        self.assertIn("n(hold)/n(rounds) = ", text)

    def test_speed_regression_is_red(self):
        done, summary, _, _ = self.run_fuzz({"jobT": {"typeable_ms": 400}, "jobB": {"typeable_ms": 150}}, "--base", "jobB")
        self.assertEqual(summary["verdict"], "RED")
        self.assertTrue(summary["speed_reds"])
        self.assertIn("RED", (Path(summary["out"]) / "summary.txt").read_text())

    def test_finding_only_on_build_is_red_base_shared_is_not(self):
        done, summary, _, _ = self.run_fuzz({"jobT": {"findings": ["desync:W#"]}, "jobB": {"findings": ["desync:W#"]}}, "--base", "jobB")
        self.assertEqual(summary["verdict"], "CLEAN", done.stdout)
        self.assertTrue(summary["findings"][0]["on_base"])
        done, summary, _, _ = self.run_fuzz({"jobT": {"findings": ["desync:W#", "stall:x"]}, "jobB": {"findings": ["desync:W#"]}}, "--base", "jobB")
        self.assertEqual(summary["verdict"], "RED")
        self.assertEqual([f["signature"] for f in summary["findings"] if not f["on_base"]], ["stall:x"])

    def test_diagnostic_never_clean(self):
        done, summary, calls, tmp = self.run_fuzz({"jobT": {}}, "--diagnostic")
        self.assertEqual(summary["verdict"], "DIAGNOSTIC (NOT JUDGED)")
        self.assertEqual(done.returncode, 75)
        self.assertTrue(summary["weak_oracles"])
        self.assertTrue(all(c["opts"].get("fuzz_mode") == "diagnostic" for c in calls))
        self.assertFalse((tmp / "handoff" / "jobT.clean").exists())

    def test_failed_round_without_fuzz_failure_is_red(self):
        done, summary, _, tmp = self.run_fuzz({"jobT": {"status": "fail"}, "jobB": {}}, "--base", "jobB")
        self.assertEqual(summary["verdict"], "RED")
        self.assertFalse((tmp / "handoff" / "jobT.clean").exists())

    def test_unjudged_baseline_never_writes_a_clean_certificate(self):
        # The test build completes its actions and speed samples, but the A/B comparison was never
        # valid: the baseline fails outside the fuzz oracle, its report disappears, or its timings
        # are absent. Each of these previously wrote jobT.clean.
        for side in ({"status": "fail"}, {"omit_report": True}, {"omit_speed": True}):
            with self.subTest(baseline=side):
                done, summary, _, tmp = self.run_fuzz({"jobT": {}, "jobB": side}, "--base", "jobB")
                self.assertEqual(summary["verdict"], "NOT JUDGED", done.stdout + done.stderr)
                self.assertEqual(done.returncode, 75)
                self.assertFalse((tmp / "handoff" / "jobT.clean").exists())
                self.assertTrue(summary["unjudged_base_rounds"] or summary["base_speed_samples"] == 0)
                self.assertIn("UNJUDGED BASE", (tmp / "out" / "summary.txt").read_text())

    def test_a_real_baseline_fuzz_failure_is_still_judged(self):
        # Fixing an actual baseline-only bug is a useful clean comparison; the baseline's recorded
        # oracle is evidence, unlike a failed smoke step with no fuzz report.
        done, summary, _, tmp = self.run_fuzz({"jobT": {}, "jobB": {"fail_seeds": [100]}}, "--base", "jobB")
        self.assertEqual(summary["verdict"], "CLEAN", done.stdout + done.stderr)
        self.assertTrue(summary["base_failures"])
        self.assertEqual(summary["unjudged_base_rounds"], [])
        self.assertTrue((tmp / "handoff" / "jobT.clean").exists())

    def test_no_base_or_zero_minutes_never_clean(self):
        done, summary, _, tmp = self.run_fuzz({"jobT": {}})
        self.assertEqual(summary["verdict"], "NO A/B (NOT JUDGED)")
        self.assertFalse((tmp / "handoff" / "jobT.clean").exists())

    def test_not_run_round_is_not_judged(self):
        done, summary, _, _ = self.run_fuzz({"jobT": {"status": "not run", "seconds": 0}, "jobB": {}}, "--base", "jobB")
        self.assertEqual(summary["verdict"], "NOT JUDGED")

    def test_corpus_first(self):
        done, summary, calls, _ = self.run_fuzz({"jobT": {}}, "--corpus")
        corpus = [c for c in calls if "fuzz_sequence" in c["opts"]]
        self.assertEqual(len(corpus), 1)
        seq = json.loads(calls[0]["opts"]["fuzz_sequence"])
        self.assertEqual({i["corpus"] for i in seq}, set(ext_fuzz.CORPUS_SETS["layout"]))
        self.assertEqual(sum(1 for i in seq if i["a"] == "close_all"), len(ext_fuzz.CORPUS_SETS["layout"]) - 1)

    def test_normal_mode_needs_whole_host(self):
        tmp = Path(tempfile.mkdtemp())
        done = subprocess.run([sys.executable, str(HERE / "fuzz.py"), "--build", "j", "--base", "b", "--out", str(tmp / "o")],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)
        self.assertIn("--whole-host", done.stderr)

    def test_whole_host_is_passed_and_pins_the_host(self):
        done, summary, calls, _ = self.run_fuzz({"jobT": {}, "jobB": {}}, "--base", "jobB", "--whole-host", "cmux18")
        self.assertTrue(calls)
        self.assertTrue(all(c["hosts"] == "cmux18" and c.get("whole_host") for c in calls), calls[:2])
        self.assertTrue(all("fuzz_mode" not in c["opts"] for c in calls))

    def test_go_dir_gates_each_round(self):
        import threading
        tmp = Path(tempfile.mkdtemp())
        go = tmp / "go"
        seen = []

        def scheduler():
            for _ in range(4):
                go.mkdir(parents=True, exist_ok=True)
                before = len(list(go.glob("*.done"))) and (go / "fz.done").stat().st_mtime
                (go / "fz.go").write_text(json.dumps({"spec": "fz", "host": "cmux19", "until": time.time() + 300}))
                end = time.time() + 30
                while time.time() < end and (go / "fz.go").exists():
                    time.sleep(0.05)
                seen.append("go")
                end = time.time() + 30
                while time.time() < end and not ((go / "fz.done").exists() and (go / "fz.done").stat().st_mtime != before):
                    time.sleep(0.05)
        t = threading.Thread(target=scheduler, daemon=True)
        t.start()
        done, summary, calls, _ = self.run_fuzz({"jobT": {"seconds": 400}, "jobB": {}}, "--base", "jobB", "--diagnostic",
                                                "--hosts", "cmux19 cmux20", "--go-dir", str(go), "--go-spec", "fz")
        self.assertGreaterEqual(len(seen), 2)
        self.assertTrue(all(c["hosts"] == "cmux19" for c in calls), calls[:2])
        self.assertTrue((go / "fz.done").exists())

    def test_whole_host_with_go_dir_leases_only_the_held_mini(self):
        import threading
        tmp = Path(tempfile.mkdtemp())
        go = tmp / "go"
        go.mkdir()

        def scheduler():
            # A go for another mini (dropped: the run may lease only cmux18), then gos for cmux18.
            (go / "fz.go").write_text(json.dumps({"host": "cmux19", "until": time.time() + 300}))
            for _ in range(12):
                end = time.time() + 30
                while time.time() < end and (go / "fz.go").exists():
                    time.sleep(0.05)
                time.sleep(0.2)
                (go / "fz.go").write_text(json.dumps({"host": "cmux18", "until": time.time() + 300}))
        threading.Thread(target=scheduler, daemon=True).start()
        done, summary, calls, _ = self.run_fuzz({"jobT": {"seconds": 400}, "jobB": {}}, "--base", "jobB",
                                                "--whole-host", "cmux18", "--go-dir", str(go), "--go-spec", "fz")
        self.assertTrue(calls)
        self.assertTrue(all(c["hosts"] == "cmux18" for c in calls), [c["hosts"] for c in calls])

    def test_unreadable_until_is_dropped(self):
        import types, threading
        tmp = Path(tempfile.mkdtemp())
        (tmp / "fz.go").write_text(json.dumps({"host": "cmux19", "until": "soon"}))
        opts = types.SimpleNamespace(go_dir=str(tmp), go_spec="fz", host=None, hosts="cmux19", whole_host=None)
        def later():
            time.sleep(6)
            (tmp / "fz.go").write_text(json.dumps({"host": "cmux19", "until": time.time() + 300}))
        threading.Thread(target=later, daemon=True).start()
        t = time.time()
        self.assertEqual(fuzz.wait_go(opts, "r")[0], "cmux19")
        self.assertGreater(time.time() - t, 4)

    def test_go_gated_acquire_waits_only_the_hold_window(self):
        import types
        tmp = Path(tempfile.mkdtemp())
        runner = tmp / "fake_run.py"
        runner.write_text("import os, sys, json\nargs = sys.argv[1:]; out = args[args.index('--out') + 1]\n"
                          "os.makedirs(out, exist_ok=True)\n"
                          "json.dump({k: os.environ.get(k) for k in ('CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS', "
                          "'CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS')}, open(os.path.join(out, 'env.json'), 'w'))\n")
        (tmp / "fz.go").write_text(json.dumps({"host": "cmux19", "until": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 200))}))
        opts = types.SimpleNamespace(go_dir=str(tmp), go_spec="fz", host=None, hosts="cmux19", whole_host=None, runner=str(runner),
                                     allow_cmux17=False, hog_swap_gb=0, diagnostic=True)
        gate = types.SimpleNamespace(OWNER_POOL="perf-lead", idle_first=lambda h: h)
        fuzz.Runner(opts, gate).lease("job", tmp / "r1", {})
        env = json.loads((tmp / "r1" / "env.json").read_text())
        self.assertTrue(150 <= int(env["CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS"]) <= 200, env)
        self.assertEqual(env["CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS"], "0")

    def test_a_repeated_go_is_one_lease_and_done_names_its_go(self):
        import types, threading
        tmp = Path(tempfile.mkdtemp())
        until = time.time() + 300
        (tmp / "fz.go").write_text(json.dumps({"host": "cmux19", "until": until, "go": "2026-10-31T12:53:32Z"}))
        opts = types.SimpleNamespace(go_dir=str(tmp), go_spec="fz", host=None, hosts="cmux19", whole_host=None)
        self.assertEqual(fuzz.wait_go(opts, "r1")[0], "cmux19")
        fuzz.signal_done(opts, "r1", "cmux19", None)
        self.assertEqual(json.loads((tmp / "fz.done").read_text())["go"], "2026-10-31T12:53:32Z")
        def later():
            (tmp / "fz.go").write_text(json.dumps({"host": "cmux19", "until": until, "go": "2026-10-31T12:53:32Z"}))
            time.sleep(6)
            (tmp / "fz.go").write_text(json.dumps({"host": "cmux19", "until": until, "go": "2026-10-31T12:59:00Z"}))
        threading.Thread(target=later, daemon=True).start()
        t = time.time()
        fuzz.wait_go(opts, "r2")
        self.assertGreater(time.time() - t, 4)  # the repeat was dropped; the new GO was taken
        self.assertEqual(opts.last_go, "2026-10-31T12:59:00Z")

    def test_iso_until_is_utc(self):
        import types
        tmp = Path(tempfile.mkdtemp())
        soon = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 120))
        (tmp / "fz.go").write_text(json.dumps({"host": "cmux19", "until": soon}))
        opts = types.SimpleNamespace(go_dir=str(tmp), go_spec="fz", host=None, hosts="cmux19", whole_host=None)
        self.assertEqual(fuzz.wait_go(opts, "r")[0], "cmux19")

    def test_expired_or_foreign_go_is_dropped(self):
        import types
        tmp = Path(tempfile.mkdtemp())
        (tmp / "fz.go").write_text(json.dumps({"host": "cmux22", "until": time.time() + 300}))
        opts = types.SimpleNamespace(go_dir=str(tmp), go_spec="fz", host=None, hosts="cmux19", whole_host=None)
        import threading
        def later():
            time.sleep(6)
            (tmp / "fz.go").write_text(json.dumps({"host": "cmux19", "until": time.time() - 10}))
            time.sleep(6)
            (tmp / "fz.go").write_text(json.dumps({"host": "cmux19", "until": time.time() + 300}))
        threading.Thread(target=later, daemon=True).start()
        self.assertEqual(fuzz.wait_go(opts, "round 1 test")[0], "cmux19")

    def test_replay_is_never_shrunk(self):
        tmp = Path(tempfile.mkdtemp())
        rp = tmp / "r.json"
        rp.write_text(json.dumps([{"a": "split_right", "t": "pair"}, {"a": "split_right", "t": "slow"}]))
        done, summary, calls, _ = self.run_fuzz({"jobT": {"fail_sequences": True}}, "--diagnostic", "--replay", str(rp))
        self.assertEqual(summary["verdict"], "RED")
        self.assertEqual(len(calls), 1)  # the replay's own lease only: no ddmin tries, no confirm lease
        done, summary, calls, _ = self.run_fuzz({"jobT": {"fail_sequences": True}}, "--diagnostic", "--replay", str(rp),
                                                "--shrink-tries", "4")
        self.assertGreater(len(calls), 1)  # asked for: the replay is shrunk
        self.assertEqual(len(summary["failures"][0]["shrunk"]), 1)

    def test_unpinned_round_is_not_judged_not_broken(self):
        tmp = Path(tempfile.mkdtemp())
        (tmp / "action-fuzz").mkdir()
        (tmp / "action-fuzz" / "result.json").write_text(json.dumps({
            "status": "not run", "reason": "harness: unpinned (1 uncommitted harness files)",
            "harness": {"pinned": False}, "steps": [{"index": 4, "do": "fuzz_run", "ok": False, "error": "FUZZ r3b ..."}],
            "evidence": [{"check": "fuzz_daemon_agrees", "pass": False, "detail": {}}]}))
        self.assertEqual(fuzz.journey_problems(tmp, None), [])

    def test_cmux17_refused(self):
        tmp = Path(tempfile.mkdtemp())
        done = subprocess.run([sys.executable, str(HERE / "fuzz.py"), "--build", "j", "--host", "cmux17", "--out", str(tmp / "o")],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)


class Journey(unittest.TestCase):
    def test_journeys_validate(self):
        done = subprocess.run([sys.executable, str(HERE / "run.py"), "--check"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_driver_loads_the_group(self):
        import driver
        self.assertTrue(hasattr(driver.Journey, "step_fuzz_run"))
        self.assertIn("fuzz_clean", driver.KIND)


if __name__ == "__main__":
    unittest.main()
