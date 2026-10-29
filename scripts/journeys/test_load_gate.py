#!/usr/bin/env python3
"""Journeys run on a quiet capture host, and a result from a loaded host says so. No fleet, no app.

    python3 scripts/journeys/test_load_gate.py

The v2.2.7-opt gate had three new-terminal failures (a 6 s timeout, a terminal the daemon did not know, an
empty screen) on hosts with a 1-minute load of 7-12; none repeated on a quieter host. The proof runs' rule:
1. Before a lease drives journeys (after the download), run.py reads the host's 1-minute load (one ssh read).
   At 4 or more it keeps the lease and reads again every 10 s while the lease has room for its journeys, then
   gives it back and waits. The whole run waits at most 10 minutes; then it drives anyway, load-invalid.
2. Each journey's result.json has the load at its start and its end.
4. The lease holds the mini's host.lock exclusively (a whole-host lease, the lock the proof runs' exclusive
   steps hold): the controller places no build on that Mac until the lease ends (cmux21 ran fleet Swift
   compiles at load 26 during an A/B beside a shared slot lease). Journeys draw the app's own window, so the
   lease needs no CuaDriver grant.
3. A failed journey with a start or end load of 4 or more stays a fail in the summary, with "(loaded host)"
   added as a fact (loaded_host, and the reason). It is never a pass or a skip: a person's Mac is always loaded.
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import driver as D  # noqa: E402

_spec = importlib.util.spec_from_file_location("journeys_run_load", HERE / "run.py")
RUN = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(RUN)


def done(stdout=b"", returncode=0):
    return subprocess.CompletedProcess([], returncode, stdout=stdout, stderr=b"")


class Fleet:
    """capture-host, the minis over ssh and the clock. `loads` is the 1-minute load each read of a host gives
    (the last one repeats); `journey_load` the load the driver records in each result.json."""

    def __init__(self, loads, journey_load=None, status="pass"):
        self.loads = {host: list(values) for host, values in loads.items()}
        self.journey_load, self.status = journey_load, status
        self.clock, self.events, self.leases, self.acquires = 0.0, [], 0, []
        self.out = None

    def monotonic(self):
        return self.clock

    def sleep(self, seconds):
        self.events.append(("sleep", seconds))
        self.clock += seconds

    def run(self, argv, *, input=None, timeout=None, check=True, env=None):
        verb = argv[1]
        if verb == "acquire":
            self.acquires.append((list(argv), env))
            self.leases += 1
            prefer = argv[argv.index("--prefer") + 1] if "--prefer" in argv else None
            self.events.append(("acquire", prefer))
            return done(f"lease-{self.leases}\n".encode())
        if verb == "slot-info":
            return done(f"host=cmux19 root=/slots/{argv[2]}\n".encode())
        if verb == "launch":
            return done(b"socket=/s.sock app=/a.app\n")
        raise AssertionError(f"unexpected {argv}")

    def subprocess_run(self, argv, **kwargs):
        assert argv[1] == "release", argv
        self.events.append(("release", argv[2]))
        return done()

    def remote(self, host, script, *, input=None, timeout=600, check=True):
        if "vm.loadavg" in script:
            values = self.loads[host]
            load = values.pop(0) if len(values) > 1 else values[0]
            self.events.append(("load", load))
            return done(f"{{ {load:.2f} 3.00 2.00 }}\n".encode())
        if "cmux-ci artifact" in script:
            return done(b"/slots/x/build/cmux.app\n")
        if "/kit/driver.py" in script:
            self.events.append(("drive", None))
            for spec_id in self.ids:
                result = {"id": spec_id, "status": self.status, "reason": "" if self.status == "pass" else "step 1 (x): y",
                          "evidence": []}
                if self.journey_load is not None:
                    result["load"] = {"start": self.journey_load, "end": self.journey_load}
                folder = self.out / spec_id
                folder.mkdir(parents=True, exist_ok=True)
                (folder / "result.json").write_text(json.dumps(result))
            return done()
        if script.startswith("cd ") and "tar c" in script:
            return done(b"")
        return done()


class LoadGate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)
        self.saved = (RUN.run, RUN.remote, RUN.subprocess.run, RUN.time.monotonic, RUN.time.sleep, RUN.kit_tar)

    def tearDown(self):
        RUN.run, RUN.remote, RUN.subprocess.run, RUN.time.monotonic, RUN.time.sleep, RUN.kit_tar = self.saved
        self.tmp.cleanup()

    def lease(self, fleet, ids=("ctrl-d",), **kw):
        fleet.out, fleet.ids = self.out, list(ids)
        RUN.run, RUN.remote, RUN.subprocess.run = fleet.run, fleet.remote, fleet.subprocess_run
        RUN.time.monotonic, RUN.time.sleep, RUN.kit_tar = fleet.monotonic, fleet.sleep, lambda specs: b""
        specs = [{"id": i, "priority": "P0", "budget_seconds": 90} for i in ids]
        return RUN.run_lease(specs, {"id": "job", "tag": "t"}, self.out, 1.0, **kw)

    def test_a_quiet_host_drives_at_once(self):
        fleet = Fleet({"cmux19": [1.5]})
        result = self.lease(fleet)["ctrl-d"]
        kinds = [e[0] for e in fleet.events]
        self.assertEqual(kinds.count("acquire"), 1, fleet.events)
        self.assertLess(kinds.index("load"), kinds.index("drive"), fleet.events)
        self.assertNotIn("sleep", kinds)
        self.assertFalse(result["load_invalid"], result)
        self.assertEqual(result["lease_load"]["start"], 1.5, result)

    def test_the_lease_holds_the_hosts_lock_exclusively(self):
        fleet = Fleet({"cmux19": [1.0]})
        result = self.lease(fleet)["ctrl-d"]
        argv, env = fleet.acquires[0]
        self.assertNotIn("--slot", argv)
        self.assertEqual((env or {}).get("CAPTURE_HOST_REMOTE_CUA_DRIVER"), "", env and {k: v for k, v in env.items() if k.startswith("CAPTURE")})
        self.assertTrue(result["lease_load"]["exclusive"], result)

    def test_a_shared_slot_lease_is_marked_not_exclusive(self):
        fleet = Fleet({"cmux19": [1.0]})
        result = self.lease(fleet, exclusive=False)["ctrl-d"]
        self.assertIn("--slot", fleet.acquires[0][0])
        self.assertFalse(result["lease_load"]["exclusive"], result)

    def test_a_held_lease_waits_while_a_drained_hosts_load_falls(self):
        # The exclusive acquire drained the builds; the 1-minute load falls 9 -> 5 -> 3 while the lease is held.
        fleet = Fleet({"cmux19": [9.0, 5.0, 3.0]})
        result = self.lease(fleet)["ctrl-d"]
        kinds = [e[0] for e in fleet.events]
        self.assertEqual(kinds.count("acquire"), 1, fleet.events)
        drive_at = kinds.index("drive")
        self.assertNotIn("release", kinds[:drive_at], fleet.events)
        self.assertEqual([e[1] for e in fleet.events[:drive_at] if e[0] == "load"], [9.0, 5.0, 3.0], fleet.events)
        self.assertEqual([e[1] for e in fleet.events[:drive_at] if e[0] == "sleep"], [10, 10], fleet.events)
        self.assertFalse(result["load_invalid"], result)
        self.assertEqual(result["lease_load"]["start"], 3.0, result)
        self.assertEqual(result["lease_load"]["waited_s"], 20, result)

    def test_a_lease_with_no_room_left_goes_back_and_the_host_is_preferred_again(self):
        # Loaded for longer than the lease has room for: it goes back, the host is read, and a new lease prefers it.
        fleet = Fleet({"cmux19": [9.0] * 34 + [2.0]})
        result = self.lease(fleet)["ctrl-d"]
        kinds = [e[0] for e in fleet.events]
        self.assertEqual(kinds.count("acquire"), 2, fleet.events)
        self.assertLess(kinds.index("release"), kinds.index("drive"), fleet.events)
        self.assertIn(("acquire", "cmux19"), fleet.events)
        self.assertFalse(result["load_invalid"], result)

    def test_after_ten_minutes_it_drives_anyway_and_marks_the_run_load_invalid(self):
        fleet = Fleet({"cmux19": [11.0]})
        result = self.lease(fleet)["ctrl-d"]
        self.assertIn(("drive", None), fleet.events)
        waited = sum(e[1] for e in fleet.events if e[0] == "sleep")
        self.assertLessEqual(waited, 600, fleet.events)
        self.assertGreaterEqual(waited, 590, fleet.events)
        self.assertTrue(result["load_invalid"], result)
        self.assertEqual(result["lease_load"]["start"], 11.0, result)

    def test_the_ten_minutes_are_for_the_whole_run_not_each_lease(self):
        budget = RUN.new_load_budget()
        fleet = Fleet({"cmux19": [11.0]})
        first = self.lease(fleet, load_budget=budget)["ctrl-d"]
        self.assertTrue(first["load_invalid"], first)
        waited = sum(e[1] for e in fleet.events if e[0] == "sleep")
        fleet.events.clear()
        second = self.lease(fleet, load_budget=budget)["ctrl-d"]
        # The run's wait is spent: the next lease drives at once, load-invalid, and waits no more.
        self.assertNotIn("sleep", [e[0] for e in fleet.events], fleet.events)
        self.assertTrue(second["load_invalid"], second)
        self.assertLessEqual(waited, 600)


class Summary(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = (RUN.wait_build, RUN.run_lease, RUN.make_clip, getattr(RUN, "clip_check", None))

    def tearDown(self):
        RUN.wait_build, RUN.run_lease, RUN.make_clip, clip_check = self.saved
        if clip_check is not None:
            RUN.clip_check = clip_check
        self.tmp.cleanup()

    def summary(self, result):
        RUN.wait_build = lambda job, seconds: {"id": job, "state": "done", "ref": "abc", "tag": "t"}
        RUN.run_lease = lambda specs, build, out, interval, **kw: {s["id"]: dict(result) for s in specs}
        if hasattr(RUN, "clip_check"):
            # The gate tree's run.py: a pass needs a clip of its action (not under test here).
            RUN.make_clip = lambda directory, interval: (directory / "clip.png", {1, 2})
            RUN.clip_check = lambda directory, result, kept: {"action_frames": 2, "action_distinct": 2, "ok": True}
        else:
            RUN.make_clip = lambda directory, interval: None
        (Path(self.tmp.name) / "ctrl-c").mkdir(exist_ok=True)
        code = RUN.main(["--build", "job", "--journey", "ctrl-c", "--out", self.tmp.name])
        line = json.loads((Path(self.tmp.name) / "results.jsonl").read_text().splitlines()[0])
        return code, line

    def test_a_fail_on_a_loaded_host_is_named_so(self):
        code, line = self.summary({"status": "fail", "reason": "step 1 (new_terminal): timeout",
                                   "load": {"start": 2.0, "end": 8.5}})
        self.assertEqual(line["status"], "fail", line)
        self.assertTrue(line["loaded_host"], line)
        self.assertTrue(line["reason"].startswith("(loaded host) step 1 (new_terminal)"), line)
        self.assertEqual(line["load"], {"start": 2.0, "end": 8.5}, line)
        self.assertTrue(line["load_invalid"], line)
        self.assertEqual(code, 1)

    def test_a_fail_on_a_quiet_host_stays_a_plain_fail(self):
        code, line = self.summary({"status": "fail", "reason": "step 1 (x): y", "load": {"start": 1.0, "end": 3.9}})
        self.assertEqual(line["status"], "fail", line)
        self.assertFalse(line["loaded_host"], line)
        self.assertEqual(line["reason"], "step 1 (x): y", line)
        self.assertEqual(line["load"], {"start": 1.0, "end": 3.9}, line)
        self.assertFalse(line["load_invalid"], line)
        self.assertEqual(code, 1)

    def test_a_pass_on_a_loaded_host_stays_a_pass_marked_load_invalid(self):
        code, line = self.summary({"status": "pass", "load": {"start": 5.0, "end": 1.0}})
        self.assertEqual(line["status"], "pass", line)
        self.assertFalse(line["loaded_host"], line)
        self.assertTrue(line["load_invalid"], line)
        self.assertEqual(code, 0)


class DriverRecordsTheLoad(unittest.TestCase):
    def test_each_result_has_the_load_at_its_start_and_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            loads = iter([(6.25, 1.0, 1.0), (2.5, 1.0, 1.0)])
            saved = D.os.getloadavg
            D.os.getloadavg = lambda: next(loads)

            class App:
                snapshot_window = None

                def snapshot(self, path):
                    raise OSError("no window in this test")

            try:
                j = D.Journey({"id": "empty", "priority": "P0", "steps": []}, App(), tmp, time_budget(), 1.0)
                result = j.run()
            finally:
                D.os.getloadavg = saved
            self.assertEqual(result["load"], {"start": 6.25, "end": 2.5}, result.get("load"))
            self.assertEqual(json.loads((Path(tmp) / "empty" / "result.json").read_text())["load"], result["load"])


def time_budget():
    return D.now() + 60


if __name__ == "__main__":
    unittest.main()
