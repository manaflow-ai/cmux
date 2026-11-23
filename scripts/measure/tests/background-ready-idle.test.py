#!/usr/bin/env python3
"""background-ready-idle.py's readers on stand-in lsof and pmset output, and its stop on a stand-in process set.

procs.py needs macOS's libproc, so a stand-in procs module takes its place. The checks: lsof's open files are counted
by type per pid and sockets summed; only assertions owned by the copy's pids count, and one that prevents sleep makes
can_sleep false; a quit copy (pid 0) roots no descendants (never pid -1, which libproc's responsible-pid call returns
for a pid it cannot read); stop signals only the copy's pids, one positive pid at a time.
Run: python3 -I scripts/measure/tests/background-ready-idle.test.py
"""
import importlib.util
import signal
import subprocess
import sys
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
LSOF = "\n".join(["p100", "tREG", "tREG", "tunix", "tIPv4", "p200", "tDIR", "tKQUEUE", "tunix", ""])
PMSET = """Assertion status system-wide:
   PreventUserIdleSystemSleep     1
Listed by owning process:
   pid 100(cmux NEXT): [0x0001] 00:01:02 PreventUserIdleSystemSleep named: "agent running"
   pid 300(caffeinate): [0x0002] 00:00:10 PreventUserIdleSystemSleep named: "caffeinate"
   pid 200(cmux NEXT Helper): [0x0003] 00:00:01 PreventUserIdleDisplaySleep named: "video"
"""


def fake_procs(alive_pids):
    mod = types.ModuleType("procs")
    mod.MB = 1048576.0
    mod.CLONE_CLEANUP = "--type=code-sign-clone-cleanup"
    mod.CLONE_CLEANUP_WAIT_S = 0
    mod.made = []
    mod._alive = lambda pid: pid in alive_pids
    mod.kind_of = lambda cmd: "main" if "MacOS/cmux NEXT" in cmd and "Helper" not in cmd else "helper"
    mod.resident_mb = lambda: {100: 300.0, 200: 100.0}
    mod.counters = lambda pid: (0, 0, 0, {100: 200 * 1048576, 200: 50 * 1048576}[pid])
    mod.main_pid = lambda app: 100 if 100 in alive_pids else None
    mod.load_average = lambda: 1.0

    class Instance:
        def __init__(self, bundle, pid):
            self.pid = pid
            mod.made.append(pid)

        def pids(self):
            return {p: c for p, c in {100: "/x/cmux NEXT.app/Contents/MacOS/cmux NEXT",
                                      200: "/x/cmux NEXT.app/Contents/Frameworks/cmux NEXT Helper"}.items() if p in alive_pids}

    mod.Instance = Instance
    return mod


def load(alive_pids):
    sys.modules["procs"] = fake_procs(alive_pids)
    spec = importlib.util.spec_from_file_location("background_ready_idle", HERE.parent / "background-ready-idle.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Readers(unittest.TestCase):
    def setUp(self):
        self.module = load({100, 200})
        self.real_run = subprocess.run

        def run(argv, **kwargs):
            text = LSOF if argv[0] == "lsof" else PMSET if argv[0] == "pmset" else ""
            return subprocess.CompletedProcess(argv, 0, stdout=text, stderr="")
        self.module.subprocess.run = run

    def tearDown(self):
        self.module.subprocess.run = self.real_run

    def test_open_files(self):
        got = self.module.open_files({100: "/x/cmux NEXT.app/Contents/MacOS/cmux NEXT", 200: "helper"})
        self.assertEqual(got["total"], 7)
        self.assertEqual(got["sockets"], 3)
        first = got["pids"][0]
        self.assertEqual((first["pid"], first["files"], first["sockets"], first["types"]["REG"]), (100, 4, 2, 2))
        self.assertEqual(got["kinds"]["main"], {"files": 4, "sockets": 2})

    def test_assertions_are_the_copy_s_only(self):
        got = self.module.assertions({100, 200})
        self.assertEqual(len(got["lines"]), 2)
        self.assertFalse(any("caffeinate" in line for line in got["lines"]))
        self.assertFalse(got["can_sleep"])
        self.assertTrue(self.module.assertions({200})["can_sleep"])  # display sleep only: the Mac can still sleep

    def test_memory(self):
        got = self.module.memory({100: "/x/cmux NEXT.app/Contents/MacOS/cmux NEXT", 200: "helper"})
        self.assertEqual((got["footprint_mb"], got["rss_mb"], got["processes"]), (250.0, 400.0, 2))

    def test_quit_copy_roots_nothing(self):
        self.module.instance("/x/cmux NEXT.app", 0)
        root = sys.modules["procs"].made[-1]
        self.assertNotIn(root, (0, -1))
        self.assertGreater(root, 99_999)


class Stop(unittest.TestCase):
    def test_signals_only_the_copy_by_pid(self):
        alive = {100, 200}
        module = load(alive)
        sent = []

        def kill(pid, sig):
            self.assertGreater(pid, 0)
            sent.append((pid, sig))
            if sig in (signal.SIGTERM, signal.SIGKILL):
                alive.discard(pid)
        module.os.kill, real = kill, module.os.kill
        try:
            self.assertEqual(module.stop("/x/cmux NEXT.app"), 0)
        finally:
            module.os.kill = real
        self.assertEqual(sent[0], (100, signal.SIGTERM))
        self.assertEqual({pid for pid, _ in sent}, {100, 200})


if __name__ == "__main__":
    unittest.main()
