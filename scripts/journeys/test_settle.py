#!/usr/bin/env python3
"""settle_host.py and run.py's settle step: wait out the Shortcuts load of a lease's new bundles before the first
measured journey (HARNESS CORES, STATUS 7817). No fleet, no ssh.

    python3 scripts/journeys/test_settle.py

On the M6 minis each LaunchServices registration of a new bundle makes siriactionsd run a BackgroundShortcutRunner
(about 3 s later for 0.6 s, about 14 s later for 5-6 s, at about 65 % CPU); a lease registers 3 to 4 bundles, the
last ones (the app's CEF helpers) up to 30 s after the launch, inside the first journeys. These cases use stand-in
`ps` and `lsregister` scripts and a fake clock:
- the wait ends only after quiet_seconds with no runner and siriactionsd under 2 %; a runner (or a busy
  siriactionsd) in the middle starts the quiet time again; the gap inside a runner pair (10.5 s) does not end it;
- the wait ends at max_seconds with quiet false when the load never stops, and a ps that fails is not quiet;
- every nested helper app of the clone is registered with lsregister -f; an lsregister failure is recorded;
- run.py packs settle_host.py, runs it on a film lease (--whole-host --vdisplay) after the launch and before the
  driver, writes OUT/settle-<lease>.json, and never fails the lease when it fails; it takes only lease time the
  journeys and the driver's OCR warm-up do not need (skipped when there is none; after a wait to its bound the
  driver's deadline still holds the budgets plus the warm-up); with --settle-seconds 0, on a slot lease or with no --vdisplay
  (the smoke gate) it does not run; a ps that fails or prints nothing is never quiet; the registrations are inside
  the bound.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "cmux-next"))
import settle_host  # noqa: E402


class FakeClock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.t += s


def ps_script(tmp, timeline):
    """A stand-in ps whose output depends on the fake time in TMP/now: TIMELINE [(from_s, to_s, line)]."""
    path = Path(tmp) / "ps"
    path.write_text("#!/usr/bin/env python3\nimport json, sys\nt = float(open(%r).read())\n"
                    "for a, b, line in json.load(open(%r)):\n    if a <= t < b: print(line)\nprint('  1  0.0 /sbin/launchd')\n"
                    % (str(Path(tmp) / "now"), str(Path(tmp) / "timeline.json")))
    path.chmod(0o755)
    (Path(tmp) / "timeline.json").write_text(json.dumps(timeline))
    return str(path)


RUNNER = "  901 64.0 /System/Library/PrivateFrameworks/WorkflowKit.framework/XPCServices/BackgroundShortcutRunner.xpc/Contents/MacOS/BackgroundShortcutRunner"
DAEMON_BUSY = "  558 27.0 /System/Library/PrivateFrameworks/VoiceShortcuts.framework/Versions/A/Support/siriactionsd"
DAEMON_IDLE = "  558  0.0 /System/Library/PrivateFrameworks/VoiceShortcuts.framework/Versions/A/Support/siriactionsd"


class SettleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.clock = FakeClock()
        (Path(self.tmp.name) / "now").write_text("0")

    def tearDown(self):
        self.tmp.cleanup()

    def run_settle(self, timeline, max_seconds=75, quiet=20):
        ps = ps_script(self.tmp.name, timeline)
        now_file = Path(self.tmp.name) / "now"

        def sleep(s):
            self.clock.sleep(s)
            now_file.write_text(str(self.clock.t))
        return settle_host.settle([ps], max_seconds, quiet, 0.5, clock=self.clock, sleep=sleep)

    def test_a_runner_pair_and_a_late_helper_burst_are_waited_out(self):
        # clone at 0: runner 3-3.6 and 14-19.5; helper at 26: runner 29-29.6 and 40-45.5 (cmux22, 14:50:06).
        timeline = [[3, 3.6, RUNNER], [14, 19.5, RUNNER], [14, 19.5, DAEMON_BUSY], [29, 29.6, RUNNER], [40, 45.5, RUNNER],
                    [0, 1000, DAEMON_IDLE]]
        got = self.run_settle(timeline)
        self.assertTrue(got["quiet"])
        # the last busy reading is at 45.0 s (0.5 s polls); then 20 s of quiet
        self.assertEqual(got["waited_s"], 65.0)
        self.assertEqual(got["runners_seen"], 1)  # one stand-in pid
        self.assertEqual(got["siriactionsd_max_pcpu"], 27.0)

    def test_quiet_host_waits_quiet_seconds_only(self):
        got = self.run_settle([[0, 1000, DAEMON_IDLE]])
        self.assertTrue(got["quiet"])
        self.assertEqual(got["waited_s"], 20.0)

    def test_load_that_never_stops_ends_at_the_bound(self):
        got = self.run_settle([[0, 1000, RUNNER]], max_seconds=30)
        self.assertFalse(got["quiet"])
        self.assertEqual(got["waited_s"], 30.0)

    def test_a_failing_ps_is_not_quiet(self):
        got = settle_host.settle(["/nonexistent/ps"], 5, 2, 0.5, clock=self.clock, sleep=self.clock.sleep)
        self.assertFalse(got["quiet"])
        silent = Path(self.tmp.name) / "silent-ps"
        silent.write_text("#!/bin/sh\nexit 1\n")
        silent.chmod(0o755)
        got = settle_host.settle([str(silent)], 5, 2, 0.5, clock=self.clock, sleep=self.clock.sleep)
        self.assertFalse(got["quiet"])


class RegisterTest(unittest.TestCase):
    def test_every_nested_helper_app_is_registered(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "cmux DEV x.app"
            for name in ("cmux Helper.app", "cmux Helper (Renderer).app", "cmux Helper (GPU).app"):
                (app / "Contents" / "Frameworks" / name).mkdir(parents=True)
            (app / "Contents" / "Frameworks" / "Sparkle.framework").mkdir()
            log = Path(tmp) / "log"
            lsreg = Path(tmp) / "lsregister"
            lsreg.write_text("#!/bin/sh\necho \"$@\" >> %s\ncase \"$2\" in *GPU*) echo nope >&2; exit 3;; esac\n" % log)
            lsreg.chmod(0o755)
            self.assertEqual(settle_host.register_helpers(str(app), [str(lsreg)], deadline=0.0, clock=lambda: 0.0)[0], [])
            registered, errors = settle_host.register_helpers(str(app), [str(lsreg)])
            self.assertEqual(registered, ["cmux Helper (Renderer).app", "cmux Helper.app"])
            self.assertEqual(len(errors), 1)
            self.assertIn("GPU", errors[0])
            self.assertEqual(log.read_text().count("-f "), 3)

    def test_main_prints_one_json_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            ps = Path(tmp) / "ps"
            ps.write_text("#!/bin/sh\necho '  1 0.0 /sbin/launchd'\n")
            ps.chmod(0o755)
            done = subprocess.run([sys.executable, str(HERE / "settle_host.py"), "--app", tmp, "--quiet-seconds", "0.2",
                                   "--interval", "0.05", "--ps", str(ps), "--lsregister", "/bin/true"],
                                  capture_output=True, text=True, timeout=30)
            self.assertEqual(done.returncode, 0, done.stderr)
            got = json.loads(done.stdout.strip().splitlines()[-1])
            self.assertTrue(got["quiet"])
            self.assertEqual(got["registered"], [])


class RunLeaseSettleTest(unittest.TestCase):
    """run_lease with a stand-in capture-host and stand-in remote calls (as test_run_stale.py)."""

    def setUp(self):
        import run
        import test_run_stale as base
        self.run, self.base = run, base
        self.tmp = Path(tempfile.mkdtemp())
        ch = self.tmp / "capture-host"
        ch.write_text(base.FAKE_CH)
        ch.chmod(0o755)
        self.saved_env = dict(os.environ)
        os.environ.update(CAPTURE_HOST=str(ch), CH_LOG=str(self.tmp / "ch.log"))
        self.saved = (run.remote, run.harness_state)
        run.harness_state = lambda: {"commit": "c" * 40, "dirty": [], "detached": True}
        self.calls = []
        self.settle_reply = base.Done(b'{"waited_s": 41.0, "quiet": true, "runners_seen": 2}\n')

        def remote(host, script, input=None, timeout=600, check=True):
            kind = ("settle" if "settle_host.py" in script else "driver" if "driver.py" in script else
                    "kit" if input is not None else "other")
            self.calls.append(kind)
            if kind == "settle":
                if isinstance(self.settle_reply, Exception):
                    raise self.settle_reply
                return self.settle_reply
            if kind == "driver":
                return base.Done(b"journey smoke-dogfood: done\n")
            if "cmux-ci artifact" in script:
                return base.Done(b"/tmp/x/build/cmux DEV t.app")
            return base.Done()
        run.remote = remote

    def tearDown(self):
        self.run.remote, self.run.harness_state = self.saved
        os.environ.clear()
        os.environ.update(self.saved_env)

    def lease(self, whole_host=True, settle_seconds=75, vdisplay="120x2", budget=60):
        out = self.tmp / f"out-{len(self.calls)}"
        saved = self.run.start_vdisplay
        self.run.start_vdisplay = lambda *a, **k: {"mode": "x"}
        try:
            self.run.run_lease([{"id": "smoke-dogfood", "budget_seconds": budget, "steps": []}],
                               {"id": "JOB1", "commit": "a" * 40, "tag": "t"}, out, 1.0, whole_host=whole_host,
                               settle_seconds=settle_seconds, vdisplay=vdisplay)
        finally:
            self.run.start_vdisplay = saved
        return out

    def test_whole_host_lease_settles_after_launch_and_before_the_driver(self):
        out = self.lease()
        self.assertIn("settle", self.calls)
        self.assertLess(self.calls.index("settle"), self.calls.index("driver"))
        [f] = list(out.glob("settle-*.json"))
        self.assertTrue(json.loads(f.read_text())["quiet"])

    def deadline_after(self, download, settle_seconds, budget=250):
        """The driver's --deadline-seconds on a fake clock: the download takes DOWNLOAD s, a settle its bound + 2 s."""
        import re
        clock, seen, run = [1000.0], [], self.run
        saved = (run.time.monotonic, run.time.sleep, run.remote)
        inner = run.remote

        def remote(host, script, input=None, timeout=600, check=True):
            if "cmux-ci artifact" in script:
                clock[0] += download
            if "settle_host.py" in script:
                clock[0] += int(re.search(r"--max-seconds (\d+)", script).group(1)) + 2
            if "driver.py" in script:
                seen.append(int(re.search(r"--deadline-seconds (\d+)", script).group(1)))
            return inner(host, script, input=input, timeout=timeout, check=check)
        run.time.monotonic = lambda: clock[0]
        run.time.sleep = lambda sec: clock.__setitem__(0, clock[0] + sec)
        run.remote = remote
        try:
            self.lease(budget=budget, settle_seconds=settle_seconds)
        finally:
            run.time.monotonic, run.time.sleep, run.remote = saved
        return seen[0] if seen else None

    def test_after_the_wait_the_driver_keeps_its_budget_and_the_ocr_warmup(self):
        # The reviewer's repro (a 250 s journey; the settle runs to its bound + 2 s). The wait takes only time above
        # budget + OCR warm-up: with it the driver's deadline is never under min(no-wait deadline, budget + warm-up).
        need = 250 + self.run.OCR_WARMUP_RESERVE
        for download in (60, 100, 150, 200, 250, 300, 380):
            base, settled = self.deadline_after(download, 0), self.deadline_after(download, 75)
            with self.subTest(download=download, base=base, settled=settled):
                self.assertIsNotNone(base)
                self.assertGreaterEqual(settled, min(base, need))
                self.assertGreaterEqual(settled, base - 75)

    def test_a_failing_settle_never_fails_the_lease(self):
        self.settle_reply = self.run.subprocess.TimeoutExpired("ssh", 135)
        out = self.lease()
        self.assertIn("driver", self.calls)
        [f] = list(out.glob("settle-*.json"))
        self.assertIn("error", json.loads(f.read_text()))

    def test_no_settle_with_zero_seconds_on_a_slot_or_without_a_film_display(self):
        self.lease(settle_seconds=0)
        self.lease(whole_host=False, vdisplay=None)
        self.lease(vdisplay=None)  # a whole-host lease with no --vdisplay: the smoke gate's
        self.assertNotIn("settle", self.calls)
        self.assertEqual(self.calls.count("driver"), 3)

    def test_the_wait_never_takes_the_journeys_time(self):
        # left - 45 s (fetch, release) - 60 s (OCR warm-up) - 20 s (ssh slack) - the journeys' budgets, at most 75 s
        self.assertEqual(self.run.settle_bound(75, 540, [{"budget_seconds": 260}]), 75)
        self.assertEqual(self.run.settle_bound(75, 420, [{"budget_seconds": 250}]), 45)
        self.assertEqual(self.run.settle_bound(75, 380, [{"budget_seconds": 250}]), 0)
        # a bound under 25 s could never see 20 s of quiet after the 5 s start: skipped
        self.assertEqual(self.run.settle_bound(75, 399, [{"budget_seconds": 250}]), 0)
        self.assertEqual(self.run.settle_bound(75, 400, [{"budget_seconds": 250}]), 25)
        out = self.lease(budget=400)
        self.assertNotIn("settle", self.calls)
        self.assertIn("driver", self.calls)
        [f] = list(out.glob("settle-*.json"))
        self.assertIn("skipped", json.loads(f.read_text())["error"])

    def test_the_kit_carries_settle_host(self):
        import io
        import tarfile
        data = self.run.kit_tar([])
        with tarfile.open(fileobj=io.BytesIO(data)) as tar:
            self.assertIn("settle_host.py", tar.getnames())

    def test_main_default_is_75_seconds(self):
        self.assertEqual(self.run.SETTLE_SECONDS, 75)
        import inspect
        self.assertIn("default=SETTLE_SECONDS", inspect.getsource(self.run.main))


if __name__ == "__main__":
    unittest.main()
