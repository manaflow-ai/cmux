#!/usr/bin/env python3
"""scripts/measure/ios-sim-density.py: the sweep, its rows, its stop rule and its cleanup.

No simulator, no Xcode: `subprocess.run` and `subprocess.Popen` are replaced by a fake that answers simctl,
xcodebuild, vm_stat, sysctl, ps and iostat from a small model (memory grows by a fixed amount per booted
simulator; a count past the model's limit raises macOS's pressure level). So this proves the driver's own logic
(one base, N clones per count, rounds on the booted clones, the rows it prints, stopping at the first count under
pressure, deleting every device it made), NOT what a Mac does with N simulators.
Run: python3 -I scripts/measure/tests/ios-sim-density.test.py"""
import contextlib, importlib.util, io, json, os, subprocess, sys, tempfile, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("ios_sim_density_under_test", os.path.join(HERE, "..", "ios-sim-density.py"))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)

PAGE = 16384
GIB_PAGES = 2**30 // PAGE


class Host:
    """Booted simulators cost 4 GiB each over a 10 GiB idle host; more than `limit` booted is memory pressure."""

    def __init__(self, limit=3, fail_at=None):
        self.limit, self.fail_at = limit, fail_at
        self.devices, self.booted, self.calls, self.seq = {}, set(), [], 0

    def answer(self, cmd):
        self.calls.append(cmd)
        if cmd[:2] == ["xcrun", "simctl"]:
            verb = cmd[2]
            if verb in ("create", "clone"):
                if verb == "clone":
                    assert cmd[3] in self.devices and cmd[3] not in self.booted, "clone of a missing or booted base"
                self.seq += 1
                udid = f"UDID-{self.seq:04d}"
                self.devices[udid] = cmd[4] if verb == "clone" else cmd[3]
                return udid
            if verb == "boot":
                self.booted.add(cmd[3])
            elif verb == "shutdown":
                self.booted.discard(cmd[3])
            elif verb == "delete":
                self.devices.pop(cmd[3], None)
            return ""
        if cmd[0] == "vm_stat":
            used = (10 + 4 * len(self.booted)) * GIB_PAGES
            return f"Mach Virtual Memory Statistics: (page size of {PAGE} bytes)\nPages active: {used}.\nPages wired down: 0.\nPages occupied by compressor: 0.\n"
        if cmd[0] == "sysctl":
            name = cmd[-1]
            if name == "kern.memorystatus_vm_pressure_level":
                return "2" if len(self.booted) > self.limit else "1"
            return {"vm.swapusage": "total = 0.00M  used = 0.00M  free = 0.00M", "hw.memsize": str(48 * 2**30),
                    "machdep.cpu.brand_string": "Apple M4 Pro"}.get(name, "")
        if cmd[0] == "ps":
            return "" if "%cpu=" in cmd else ""
        if cmd[0] == "iostat":
            return "disk0\nKB/t xfrs MB\n10 10 100\n"
        if cmd[0] == "hostname":
            return "aws-m4pro-8"
        if cmd[0] == "sw_vers":
            return "26.4"
        if cmd[0] == "xcodebuild":
            return "Xcode 26.6\nBuild version 17E1"
        return ""


class FakeProc:
    def __init__(self, host, cmd, stdout=None, **_):
        self.cmd, self.host, self.stdout = cmd, host, stdout
        host.calls.append(cmd)
        if cmd[0] == "xcodebuild":
            udid = next(a.split("=", 1)[1] for a in cmd if a.startswith("id="))
            assert udid in host.booted, "a job ran on a device that is not booted"
            n = len(host.booted)
            fail = host.fail_at is not None and n >= host.fail_at
            self.rc = 65 if fail else 0
            text = ("Test Case '-[CmuxMobileAppUITests.DeepLinkUITests testOpen]' failed (3.2 seconds).\n" if fail else "")
            text += f"Executed 21 tests, with {1 if fail else 0} failures (0 unexpected) in 60.0 seconds\n"
            stdout.write(text)
            stdout.close()
        else:
            self.rc = 0

    def wait(self, timeout=None):
        return self.rc


class FakeSampler:
    """The driver's sampler without its thread: each finished job adds one sample of the model host."""
    live = []

    def __init__(self, every=5.0):
        self.samples, self.n, self.udids, self.stop_at = [], 0, [], mock.Mock()
        FakeSampler.live.append(self)

    def start(self):
        pass


def run_main(host, *args):
    out = tempfile.mkdtemp()
    os.makedirs(os.path.join(out, "work"))
    FakeSampler.live = []

    def fake_run(cmd, check=False, text=True, capture_output=True, timeout=None, **_):
        return subprocess.CompletedProcess(cmd, 0, stdout=host.answer(list(cmd)), stderr="")

    def fake_popen(cmd, **kw):
        proc = FakeProc(host, list(cmd), **kw)
        if proc.cmd[0] == "xcodebuild" and FakeSampler.live:
            s = FakeSampler.live[0]
            s.samples.append({"t": 0, "n": s.n, "mem_used_gib": M.mem_used_gib(), "swap_gib": 0.0,
                              "pressure": int(M.sysctl("kern.memorystatus_vm_pressure_level")), "cpu_pct": 50.0,
                              "disk_mb_s": 1.0, "sim_rss_gib": 0.0})
        return proc

    argv = ["ios-sim-density.py", "--xctestrun", "/x/App.xctestrun", "--runtime", "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            "--device-type", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "--suites", "DeepLinkUITests",
            "--prefix", "ios-sim-density-k", "--out", out, *args]
    buf = io.StringIO()
    with mock.patch.object(M.subprocess, "run", fake_run), mock.patch.object(M.subprocess, "Popen", fake_popen), \
         mock.patch.object(M, "Sampler", FakeSampler), mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(buf):
        rc = M.main()
    report = json.load(open(os.path.join(out, "report.json")))
    return rc, buf.getvalue(), report


class Sweep(unittest.TestCase):
    def test_every_count_runs_its_rounds_on_booted_clones_and_everything_is_deleted(self):
        host = Host(limit=10)
        rc, text, report = run_main(host, "--counts", "1,2,3", "--rounds", "2")
        self.assertEqual(rc, 0)
        jobs = [l for l in text.splitlines() if l.startswith("IOS-SIM-DENSITY-JOB ")]
        self.assertEqual(len(jobs), (1 + 2 + 3) * 2)
        rows = [l for l in text.splitlines() if l.startswith("IOS-SIM-DENSITY ")]
        self.assertEqual([r.split()[1] for r in rows], ["n=1", "n=2", "n=3"])
        self.assertIn("jobs=6", rows[2])
        self.assertIn("failed_jobs=0", rows[2])
        self.assertIn("mem_per_sim_gib=4.0", rows[2])
        clones = [c for c in host.calls if c[:3] == ["xcrun", "simctl", "clone"]]
        self.assertEqual(len(clones), 6)
        self.assertEqual({c[3] for c in clones}, {"UDID-0001"}, "every clone comes from the one base")
        self.assertEqual(len([c for c in host.calls if c[:3] == ["xcrun", "simctl", "create"]]), 1)
        self.assertEqual(host.devices, {}, "a device the run made was left behind")
        self.assertEqual([b["how"] for b in report["boots"]], ["create", "clone", "clone", "clone"])

    def test_failures_are_counted_and_named(self):
        host = Host(limit=10, fail_at=2)
        _, text, report = run_main(host, "--counts", "1,2", "--rounds", "1")
        rows = {l.split()[1]: l for l in text.splitlines() if l.startswith("IOS-SIM-DENSITY ")}
        self.assertIn("failed_jobs=0", rows["n=1"])
        self.assertIn("failed_jobs=2", rows["n=2"])
        self.assertEqual(report["counts"][1]["failed_test_names"], ["CmuxMobileAppUITests.DeepLinkUITests.testOpen"])

    def test_pressure_stops_the_sweep_before_the_next_count(self):
        host = Host(limit=2)
        _, text, report = run_main(host, "--counts", "1,2,3,4", "--rounds", "1")
        rows = [l.split()[1] for l in text.splitlines() if l.startswith("IOS-SIM-DENSITY ")]
        self.assertEqual(rows, ["n=1", "n=2", "n=3"])
        self.assertIn("IOS-SIM-DENSITY-STOP n=4 why=pressure_2", text)
        self.assertEqual(report["stopped"]["before"], 4)
        self.assertEqual(host.devices, {})

    def test_off_keeps_going_under_pressure(self):
        host = Host(limit=2)
        _, text, _ = run_main(host, "--counts", "1,3,4", "--rounds", "1", "--stop-on-pressure", "0")
        self.assertEqual([l.split()[1] for l in text.splitlines() if l.startswith("IOS-SIM-DENSITY ")], ["n=1", "n=3", "n=4"])


class Parse(unittest.TestCase):
    def test_xcodebuild_counts_and_failed_case_forms(self):
        self.assertEqual(M.EXECUTED.findall("Executed 12 tests, with 1 failure (0 unexpected) in 9.1 (9.2) seconds"), [("12", "1")])
        objc = M.FAILED_CASE.findall("Test Case '-[CmuxMobileAppUITests.FeedNewPillUITests testTap]' failed (2.0 seconds).")
        swift = M.FAILED_CASE.findall("Test case 'FeedNewPillUITests.testTap()' failed on 'Clone 1' (2.0 seconds)")
        self.assertEqual(objc[0][:2], ("CmuxMobileAppUITests.FeedNewPillUITests", "testTap"))
        self.assertEqual(swift[0][2], "FeedNewPillUITests.testTap")


if __name__ == "__main__":
    unittest.main()
