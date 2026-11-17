"""scripts/measure/bounded-phase.py: a fleet measurement phase that cannot sit silent past its limits.

update-click-ab.sh sent each side's build to a file, so the step log said nothing for 45 min and the controller
stopped it as hung right after the `UCA host` line, naming no step (fleet step 7cb681720391, 2026-11-17). Here a fake
app that never answers (a command that prints nothing and never exits) must end as a named UCA-STALL or UCA-TIMEOUT
with its whole process group gone, a slow phase that keeps writing its log must print UCA-PROGRESS lines and finish,
and update-click-ab.sh must run every build step and every round through the phase runner. No build, no app.
"""
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PHASE = ROOT / "scripts" / "measure" / "bounded-phase.py"
SCRIPT = ROOT / "scripts" / "measure" / "update-click-ab.sh"


def run_phase(*args, timeout=60):
    started = time.monotonic()
    r = subprocess.run([sys.executable, "-I", str(PHASE), "--tag", "UCA", *args], capture_output=True, text=True,
                       timeout=timeout)
    return r, time.monotonic() - started


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # A zombie left for init to reap counts as gone.
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


class BoundedPhaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="bounded-phase."))

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def test_an_app_that_never_answers_ends_as_a_named_stall_with_its_group(self):
        pidfile = self.tmp / "child.pid"
        # The "app": prints one line, starts a grandchild that never answers, then waits on it forever.
        app = f"echo waiting for the app socket; sleep 1000 & echo $! > {pidfile}; wait"
        r, took = run_phase("--name", "round 1 base", "--deadline", "60", "--stall", "2", "--heartbeat", "1",
                            "--grace", "2", "--", "bash", "-c", app)
        self.assertEqual(r.returncode, 124, r.stdout + r.stderr)
        self.assertRegex(r.stdout, r"UCA-STALL round 1 base: no output for \d+ s \(stall limit 2 s\)")
        self.assertIn("latest output: waiting for the app socket", r.stdout)
        self.assertLess(took, 30)
        grandchild = int(pidfile.read_text())
        for _ in range(50):
            if not alive(grandchild):
                break
            time.sleep(0.1)
        self.assertFalse(alive(grandchild), "the phase's process group outlived it")

    def test_a_phase_past_its_deadline_ends_as_a_named_timeout(self):
        # Output every 0.2 s: never a stall, but it never ends either.
        r, took = run_phase("--name", "base app build", "--deadline", "2", "--stall", "30", "--grace", "2", "--",
                            "bash", "-c", "while :; do echo compiling; sleep 0.2; done")
        self.assertEqual(r.returncode, 124)
        self.assertRegex(r.stdout, r"UCA-TIMEOUT base app build: still running after \d+ s \(deadline 2 s\); latest output: compiling")
        self.assertLess(took, 30)

    def test_a_slow_build_writing_its_log_prints_progress_and_its_status(self):
        log = self.tmp / "build.log"
        follow = self.tmp / "reload.log"
        build = (f"for i in 1 2 3 4; do echo step $i; echo CompileSwift file$i.swift >> {follow}; sleep 0.7; done; "
                 "echo App path:; exit 7")
        r, _ = run_phase("--name", "head app build", "--deadline", "60", "--stall", "5", "--heartbeat", "1",
                         "--log", str(log), "--follow", str(follow), "--", "bash", "-c", build)
        self.assertEqual(r.returncode, 7, r.stdout + r.stderr)
        progress = [line for line in r.stdout.splitlines() if line.startswith("UCA-PROGRESS head app build: ")]
        self.assertTrue(progress, r.stdout)
        self.assertTrue(any(re.search(r"(reload|build)\.log: (CompileSwift|step)", line) for line in progress), progress)
        self.assertNotIn("step 1", r.stdout.splitlines(), "with --log the output goes to the file")
        self.assertIn("App path:", log.read_text())

    def test_streamed_output_passes_through_and_keeps_the_phase_alive(self):
        r, _ = run_phase("--name", "round 2 head", "--deadline", "60", "--stall", "2", "--", "bash", "-c",
                         "for i in 1 2 3 4 5 6; do echo line $i; sleep 0.5; done")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual([line for line in r.stdout.splitlines() if line.startswith("line ")],
                         [f"line {i}" for i in range(1, 7)])


class UpdateClickAbPhasesTests(unittest.TestCase):
    """Every step after the UCA host line that can take minutes goes through `phase`, from the copied tools."""

    def test_every_long_step_runs_as_a_phase(self):
        text = re.sub(r"\\\n\s*", " ", SCRIPT.read_text())
        for command in ("git submodule update", "./scripts/download-prebuilt-ghosttykit.sh",
                        "./scripts/cmux-next/build-acpmux.sh", "./scripts/reload.sh", "update-harness/run.py"):
            lines = [line for line in text.splitlines() if command in line and not line.lstrip().startswith("#")]
            self.assertTrue(lines, command)
            for line in lines:
                self.assertRegex(line, r"\bphase \"[^\"]+\" \"\$[A-Z]+_DEADLINE\" \"\$[A-Z]+_STALL\"",
                                 f"{command} runs outside a phase: {line.strip()}")
        self.assertIn('cp scripts/measure/bounded-phase.py "$tools/"', text)

    def test_the_stall_limits_stay_under_the_controllers_silent_limit(self):
        limits = dict(re.findall(r"\b([A-Z]+_STALL)=(\d+)", SCRIPT.read_text()))
        self.assertTrue(limits)
        for name, seconds in limits.items():
            self.assertLess(int(seconds), 45 * 60, f"{name} must end a stuck phase before the controller does")


if __name__ == "__main__":
    unittest.main()
