#!/usr/bin/env python3
"""run.py releases its capture lease on every path (cmux-ad 09:05Z): no fleet, no ssh.

    python3 scripts/journeys/test_run_release.py

A stand-in capture-host logs each call. The round fails inside the lease (the driver's ssh call raises), or run.py
gets SIGTERM while the driver runs, or while it waits in acquire: each time `release LEASE` is logged (or, stopped in
acquire, the acquire itself is ended, which unreserves), and the build is fetched into the per-mini cache, not the slot.
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent

FAKE_CH = r"""#!/bin/sh
echo "$*" >> "$CH_LOG"
case "$1" in
  acquire) if [ -n "$CH_ACQUIRE_LATE" ]; then trap 'echo slot-cmux99-late; echo acquire-ended-late >> "$CH_LOG"; exit 143' TERM; sleep 30 & wait; fi
           [ -n "$CH_ACQUIRE_SLEEP" ] && { trap 'echo acquire-ended >> "$CH_LOG"; exit 143' TERM; sleep "$CH_ACQUIRE_SLEEP" & wait; }
           echo "slot-cmux99-abc" ;;
  slot-info) echo "host=cmux99 slot=1 root=/tmp/fake-root" ;;
  launch) echo "pid=1 socket=/tmp/fake.sock bundle_id=x app=/tmp/fake.app" ;;
  phase) echo "phase $3" >> "$CH_LOG" ;;
  release) echo release-start >> "$CH_LOG"; sleep "${CH_RELEASE_SLEEP:-0}"; echo release-done >> "$CH_LOG"; echo released ;;
esac
"""

# Imports run.py, replaces its ssh with MODE, plays one lease.
DRIVE = r"""
import json, os, sys, time
sys.path.insert(0, sys.argv[1]); sys.path.insert(0, os.path.join(sys.argv[1], "..", "cmux-next"))
import run
mode = sys.argv[2]
calls = []
def remote(host, script, input=None, timeout=600, check=True):
    calls.append(script)
    with open(os.environ["CH_LOG"], "a") as f:
        f.write("remote " + ("driver" if "driver.py" in script else "download" if "cmux-ci artifact" in script else "other") + "\n")
        if "cmux-ci artifact" in script:
            f.write("cache " + ("yes" if ".cache/cmux-journeys/builds/JOB1" in script else "no") + "\n")
    if "driver.py" in script:
        if mode == "raise":
            raise RuntimeError("ssh: the mini went away")
        if mode == "sleep":
            print("driving", flush=True); time.sleep(60)
    class R: stdout = b"/tmp/x/build/cmux DEV t.app"; stderr = b""; returncode = 0
    return R()
run.remote = remote
import signal
signal.signal(signal.SIGTERM, run._terminated)
try:
    res = run.run_lease([{"id": "action-fuzz", "budget_seconds": 60, "steps": []}],
                        {"id": "JOB1", "commit": "a" * 40, "tag": "t"}, run.Path(os.environ["OUT"]), 1.0)
    print(json.dumps(res["action-fuzz"]["status"]))
except run.Terminated:
    print("terminated", flush=True)
    sys.exit(143)
"""


class Release(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        ch = self.tmp / "capture-host"
        ch.write_text(FAKE_CH)
        ch.chmod(0o755)
        self.log = self.tmp / "ch.log"
        self.env = {**os.environ, "CAPTURE_HOST": str(ch), "CH_LOG": str(self.log), "OUT": str(self.tmp / "out")}
        (self.tmp / "drive.py").write_text(DRIVE)

    def start(self, mode, **env):
        return subprocess.Popen([sys.executable, str(self.tmp / "drive.py"), str(HERE), mode], env={**self.env, **env},
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def lines(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_error_inside_the_round_releases(self):
        p = self.start("raise")
        out, err = p.communicate(timeout=60)
        self.assertIn("release slot-cmux99-abc", self.lines(), err)
        self.assertIn("not run", out)
        self.assertIn("cache yes", self.lines())  # the build goes to the per-mini cache, not the slot
        self.assertIn("phase download", self.lines())  # the controller sees what the lease does

    def test_sigterm_while_driving_releases(self):
        p = self.start("sleep")
        end = time.time() + 30
        while time.time() < end and "remote driver" not in self.lines():
            time.sleep(0.1)
        p.send_signal(signal.SIGTERM)
        out, err = p.communicate(timeout=60)
        self.assertEqual(p.returncode, 143, err)
        self.assertIn("release slot-cmux99-abc", self.lines())
        self.assertIn("phase journey", self.lines())

    def test_sigterm_while_acquiring_ends_the_acquire(self):
        p = self.start("sleep", CH_ACQUIRE_SLEEP="30")
        end = time.time() + 10
        while time.time() < end and not any(l.startswith("acquire") for l in self.lines()):
            time.sleep(0.1)
        time.sleep(0.5)
        p.send_signal(signal.SIGTERM)
        out, err = p.communicate(timeout=90)
        self.assertEqual(p.returncode, 143, err)
        self.assertIn("acquire-ended", self.lines())
        self.assertFalse(any(l.startswith("launch") for l in self.lines()))


class LateLease(unittest.TestCase):
    def test_a_lease_printed_as_the_stop_arrives_is_released(self):
        t = Release("test_error_inside_the_round_releases")
        t.setUp()
        p = t.start("sleep", CH_ACQUIRE_LATE="1")
        end = time.time() + 10
        while time.time() < end and not any(l.startswith("acquire") for l in t.lines()):
            time.sleep(0.1)
        time.sleep(0.5)
        p.send_signal(signal.SIGTERM)
        p.communicate(timeout=90)
        self.assertEqual(p.returncode, 143)
        self.assertIn("release slot-cmux99-late", t.lines())
        self.assertFalse(any(l.startswith("launch") for l in t.lines()))


class DoubleStop(unittest.TestCase):
    def test_a_second_term_during_the_release_does_not_kill_it(self):
        t = Release("test_error_inside_the_round_releases")
        t.setUp()
        p = t.start("sleep", CH_RELEASE_SLEEP="3")
        end = time.time() + 30
        while time.time() < end and "remote driver" not in t.lines():
            time.sleep(0.1)
        p.send_signal(signal.SIGTERM)
        end = time.time() + 30
        while time.time() < end and "release-start" not in t.lines():
            time.sleep(0.05)
        p.send_signal(signal.SIGTERM)  # the second stop (^C to the group, then fuzz.py's TERM)
        p.send_signal(signal.SIGINT)
        p.communicate(timeout=60)
        self.assertIn("release-done", t.lines())


class FuzzStop(unittest.TestCase):
    def test_sigterm_of_fuzz_py_reaches_run_py_as_term(self):
        tmp = Path(tempfile.mkdtemp())
        runner = tmp / "fake_run.py"
        mark = tmp / "got-term"
        runner.write_text("import signal, sys, time, os\n"
                          "def h(s, f):\n    open(%r, 'w').write('term'); sys.exit(143)\n"
                          "signal.signal(signal.SIGTERM, h)\n"
                          "args = sys.argv[1:]; os.makedirs(args[args.index('--out') + 1], exist_ok=True)\n"
                          "open(%r + '.started', 'w').write('1')\n"
                          "time.sleep(60)\n" % (str(mark), str(mark)))
        p = subprocess.Popen([sys.executable, str(HERE / "fuzz.py"), "--build", "jobT", "--base", "jobB", "--minutes", "1", "--diagnostic",
                              "--out", str(tmp / "out"), "--handoff", str(tmp / "h"), "--runner", str(runner)],
                             env={**os.environ, "SMOKE_GATE_CMUX_CI": "/nonexistent"},
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        end = time.time() + 30
        while time.time() < end and not Path(str(mark) + ".started").exists():
            time.sleep(0.1)
        p.send_signal(signal.SIGTERM)
        p.communicate(timeout=60)
        self.assertEqual(mark.read_text(), "term")


if __name__ == "__main__":
    unittest.main()
