#!/usr/bin/env python3
"""run.py makes the display a journey needs, measures it, and refuses before the lease a journey it cannot give
that display: no fleet, no ssh.

    python3 -I scripts/journeys/test_run_vdisplay.py

The minis' own displays run at 60 Hz. A pacing journey needs 120 Hz (`require_hz: 120`, on the journey or on a
step such as the kits' video_start), so it runs only on the lease's own virtual display (`--vdisplay HZxSCALE`,
whole host only, from the kits' vdisplay120.m). On 2026-11-03 resize-keyboard spent its leases on cmux19 and cmux23
and was not run inside them, because its runner gave no --vdisplay (STATUS 9145, 9156). Now (REWRITE R-HARNESS S2,
DESIGN.md rule R11):
- a journey whose required rate --vdisplay does not give is "not run" with "needs --vdisplay <hz>x1 or <hz>x2", and
  run.py takes no lease for it, submits no build and waits for none when no other journey runs;
- --vdisplay without --whole-host and a malformed --vdisplay are usage errors (exit 2), before anything;
- in the lease, the display is measured by a fresh process: it must be the main display, run at the asked rate
  (median link interval within 0.35 ms of 1000/HZ, the kits' video_start tolerance) and have the asked pixel
  density; else every journey of the lease is "not run" with what was measured, and the lease is released.
  OUT/display.json keeps the measurement.
"""
import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "cmux-next"))
import run  # noqa: E402

FAKE_CH = r"""#!/bin/sh
echo "$*" >> "$CH_LOG"
case "$1" in
  acquire) echo "slot-cmux99-abc" ;;
  slot-info) echo "host=cmux99 slot=1 root=/tmp/fake-root" ;;
  launch) echo "pid=1 socket=/tmp/fake.sock bundle_id=x app=/tmp/fake.app" ;;
  release) echo released ;;
esac
"""

# What a fresh `VD check` prints on a mini whose main display is the lease's own 120 Hz 2x display.
VD_120x2 = b"ready 7 8.333\nmain 7 mode 1512x982 pixels 3024x1964 refresh 120.00 interval 8.334 displays 2\n"


def journey(jid, require_hz=None, step_hz=None):
    steps = [{"do": "expect", "all": [{"app_pane": {}}, {"daemon_prompt": {}}, {"frame_text": "x"}]}]
    if step_hz is not None:
        steps.insert(0, {"do": "new_terminal", "require_hz": step_hz})
    spec = {"id": jid, "priority": "P0", "title": jid, "why": "test", "budget_seconds": 60, "steps": steps,
            "_path": f"scripts/journeys/journeys/test/{jid}.json"}
    if require_hz is not None:
        spec["require_hz"] = require_hz
    return spec


class Done:
    def __init__(self, stdout=b"", returncode=0):
        self.stdout, self.stderr, self.returncode = stdout, b"", returncode


class Harness(unittest.TestCase):
    """A stand-in capture-host (it logs each call), ssh calls answered here, a done build, a clean checkout."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="run-vdisplay-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        ch = self.tmp / "capture-host"
        ch.write_text(FAKE_CH)
        ch.chmod(0o755)
        self.saved_env = dict(os.environ)
        os.environ.update(CAPTURE_HOST=str(ch), CH_LOG=str(self.tmp / "ch.log"))
        self.saved = {name: getattr(run, name) for name in ("remote", "job_status", "harness_state", "load_journeys",
                                                             "build_for_commit")}
        self.scripts, self.inputs, self.vd_answer, self.statuses = [], [], VD_120x2, []
        self.specs, self.runs, self.vd_raises = [], 0, None

        def remote(host, script, input=None, timeout=600, check=True):
            self.scripts.append(script)
            self.inputs.append(input)
            kind = "vdisplay" if "vdisplay120.m" in script else "driver" if "driver.py" in script else "other"
            with open(self.tmp / "ch.log", "a") as f:  # one ordered log with the capture-host calls
                f.write(f"remote {kind}\n")
            if "vdisplay120.m" in script:
                if self.vd_raises:
                    raise self.vd_raises
                return Done(self.vd_answer)
            if "build_cache" in script:
                return Done(b"/tmp/x/build/cmux DEV t.app")
            if "driver.py" in script:
                return Done(b"journeys: done\n")
            return Done()

        def job_status(job):
            self.statuses.append(job)
            return {"id": job, "state": "done", "ref": "a" * 40, "tag": "t"}

        def build_for_commit(sha, out_root):
            raise AssertionError("a build was submitted")

        run.remote, run.job_status, run.build_for_commit = remote, job_status, build_for_commit
        run.harness_state = lambda: {"commit": "c" * 40, "dirty": [], "detached": True}
        run.load_journeys = lambda directory=None: (self.specs, [])

    def tearDown(self):
        for name, value in self.saved.items():
            setattr(run, name, value)
        os.environ.clear()
        os.environ.update(self.saved_env)

    def calls(self):
        log = self.tmp / "ch.log"
        return log.read_text().splitlines() if log.exists() else []

    def main(self, *args):
        self.runs += 1
        out = self.tmp / f"out-{self.runs}"
        code = run.main([*args, "--out", str(out)])
        rows = {}
        if (out / "results.jsonl").exists():
            rows = {r["id"]: r for r in map(json.loads, (out / "results.jsonl").read_text().splitlines())}
        return code, rows


class Preflight(Harness):
    def test_a_journey_that_needs_120_hz_without_vdisplay_takes_no_lease(self):
        self.specs = [journey("pacing", require_hz=120)]
        code, rows = self.main("--build", "JOB1", "--journey", "pacing", "--whole-host")
        self.assertEqual(code, 75)
        self.assertEqual(rows["pacing"]["status"], "not run")
        self.assertIn("needs --vdisplay 120x1 or 120x2", rows["pacing"]["reason"])
        self.assertFalse(any(c.startswith("acquire") for c in self.calls()), self.calls())

    def test_the_kits_step_form_of_require_hz_counts_too(self):
        self.specs = [journey("pacing-step", step_hz=120)]
        code, rows = self.main("--build", "JOB1", "--journey", "pacing-step", "--whole-host")
        self.assertEqual(rows["pacing-step"]["status"], "not run")
        self.assertIn("needs --vdisplay 120x", rows["pacing-step"]["reason"])
        self.assertFalse(any(c.startswith("acquire") for c in self.calls()))

    def test_a_require_hz_inside_a_step_group_counts_too(self):
        # cp/pixel-perfect-kit: 27 of its 39 rate journeys say it in a px_film group's px_record_start (review 1).
        spec = journey("pacing-group")
        spec["steps"].insert(0, {"do": "px_film", "steps": [{"do": "wait"}, {"do": "px_record_start", "require_hz": 120}],
                                 "after": []})
        self.specs = [spec]
        code, rows = self.main("--build", "JOB1", "--journey", "pacing-group", "--whole-host")
        self.assertEqual(rows["pacing-group"]["status"], "not run")
        self.assertIn("needs --vdisplay 120x1 or 120x2", rows["pacing-group"]["reason"])
        self.assertFalse(any(c.startswith("acquire") for c in self.calls()))
        self.assertEqual(self.statuses, [])

    def test_a_journey_that_needs_two_rates_is_a_check_problem(self):
        spec = journey("two-rates", require_hz=120)
        spec["steps"].insert(0, {"do": "new_terminal", "options": {"film": {"require_hz": 60}}})
        problems = [p for p in run.validate(spec) if "require_hz" in p]
        self.assertTrue(any("60" in p and "120" in p for p in problems), problems)

    def test_require_hz_is_found_at_any_depth(self):
        spec = journey("deep")
        spec["steps"].insert(0, {"do": "new_terminal", "groups": [{"steps": [{"film": {"require_hz": 120}}]}]})
        self.assertEqual(run.required_hz(spec), 120)
        bad = journey("deep-bad")
        bad["steps"].insert(0, {"do": "new_terminal", "groups": [{"steps": [{"require_hz": 120.5}]}]})
        self.assertTrue(any("require_hz" in p for p in run.validate(bad)), run.validate(bad))

    def test_a_60_hz_journey_is_told_what_to_pass_without_a_contradiction(self):
        self.specs = [journey("sixty", require_hz=60)]
        code, rows = self.main("--build", "JOB1", "--journey", "sixty", "--whole-host")
        self.assertIn("needs --vdisplay 60x1 or 60x2", rows["sixty"]["reason"])
        self.assertNotIn("run at 60 Hz", rows["sixty"]["reason"])

    def test_vdisplay_reaches_the_lease_through_main(self):
        # The flag's one way to the lease (main to run_lease): the display is made with the asked arguments, before the
        # launch, for a rate journey and for one that names no rate (the P0 runner passes --vdisplay for typing-load-l6).
        for jid, hz in (("pacing", 120), ("plain", None)):
            with self.subTest(journey=jid):
                self.scripts.clear()
                (self.tmp / "ch.log").unlink(missing_ok=True)
                self.specs = [journey(jid, require_hz=hz)]
                self.main("--build", "JOB1", "--journey", jid, "--whole-host", "--vdisplay", "120x2")
                log = self.calls()
                made = [s for s in self.scripts if "vdisplay120.m" in s]
                self.assertEqual(len(made), 1, log)
                self.assertIn("VD.app --args 120 2 0 0", made[0])
                self.assertLess(log.index("remote vdisplay"), next(i for i, c in enumerate(log) if c.startswith("launch ")),
                                log)
                self.assertTrue(any("driver.py" in s for s in self.scripts))
                self.assertIn("release slot-cmux99-abc", log)

    def test_a_higher_rate_is_refused_before_the_lease_too(self):
        self.specs = [journey("pacing", require_hz=120)]
        code, rows = self.main("--build", "JOB1", "--journey", "pacing", "--whole-host", "--vdisplay", "240x1")
        self.assertIn("gives 240 Hz", rows["pacing"]["reason"])
        self.assertFalse(any(c.startswith("acquire") for c in self.calls()))

    def test_another_rate_is_refused_before_the_lease(self):
        self.specs = [journey("pacing", require_hz=120)]
        code, rows = self.main("--build", "JOB1", "--journey", "pacing", "--whole-host", "--vdisplay", "60x1")
        self.assertEqual(rows["pacing"]["status"], "not run")
        self.assertIn("gives 60 Hz", rows["pacing"]["reason"])
        self.assertFalse(any(c.startswith("acquire") for c in self.calls()))

    def test_a_refused_run_neither_waits_for_nor_submits_a_build(self):
        self.specs = [journey("pacing", require_hz=120)]
        self.main("--build", "JOB1", "--journey", "pacing", "--whole-host")
        self.assertEqual(self.statuses, [])
        code, rows = self.main("--commit", "b" * 40, "--journey", "pacing", "--whole-host")  # submits nothing
        self.assertEqual(rows["pacing"]["status"], "not run")

    def test_the_other_journeys_of_a_run_still_run(self):
        self.specs = [journey("pacing", require_hz=120), journey("plain")]
        code, rows = self.main("--build", "JOB1", "--journey", "pacing", "--journey", "plain")
        self.assertEqual(rows["pacing"]["status"], "not run")
        self.assertIn("acquire --slot", self.calls())
        self.assertTrue(any("driver.py" in s for s in self.scripts))
        kit = next(i for s, i in zip(self.scripts, self.inputs) if "tar x" in s)  # the kit the lease unpacks
        packed = json.load(tarfile.open(fileobj=io.BytesIO(kit)).extractfile("journeys.json"))
        self.assertEqual([j["id"] for j in packed], ["plain"])
        self.assertNotIn("needs --vdisplay", rows["plain"]["reason"])

    def test_vdisplay_without_whole_host_is_a_usage_error_before_anything(self):
        self.specs = [journey("pacing", require_hz=120)]
        err = io.StringIO()
        with self.assertRaises(SystemExit) as caught, contextlib.redirect_stderr(err):
            run.main(["--build", "JOB1", "--journey", "pacing", "--vdisplay", "120x1", "--out", str(self.tmp / "o")])
        self.assertEqual(caught.exception.code, 2)
        self.assertIn("--vdisplay needs --whole-host", err.getvalue())
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.statuses, [])

    def test_a_malformed_vdisplay_is_a_usage_error(self):
        self.specs = [journey("plain")]
        for bad in ("120", "120x3", "0x1", "241x1", "x2", "120x", "120X2 ", "2x1", "23x1"):
            err = io.StringIO()
            with self.subTest(vdisplay=bad):
                with self.assertRaises(SystemExit) as caught, contextlib.redirect_stderr(err):
                    run.main(["--build", "JOB1", "--journey", "plain", "--whole-host", "--vdisplay", bad,
                              "--out", str(self.tmp / "o")])
                self.assertEqual(caught.exception.code, 2)
                self.assertIn("--vdisplay takes HZxSCALE", err.getvalue())
        self.assertEqual(self.calls(), [])

    def test_require_hz_must_be_a_whole_number_of_hz(self):
        for bad in (120.5, "120", 0, 241, True, 2, 23):
            with self.subTest(require_hz=bad):
                problems = run.validate(dict(journey("pacing"), require_hz=bad))
                self.assertTrue(any("require_hz" in p for p in problems), problems)
        self.assertFalse([p for p in run.validate(dict(journey("pacing"), require_hz=120)) if "require_hz" in p])


class VirtualDisplay(Harness):
    def lease(self, mode, answer=VD_120x2):
        self.vd_answer = answer
        out = self.tmp / "lease"
        got = run.run_lease([journey("pacing", require_hz=120)], {"id": "JOB1", "commit": "a" * 40, "tag": "t"}, out,
                            1.0, whole_host=True, vdisplay=mode)
        return got["pacing"], out

    def test_the_lease_makes_measures_and_records_the_display_then_stops_it(self):
        result, out = self.lease("120x2")
        made = next(s for s in self.scripts if "vdisplay120.m" in s)
        self.assertIn("VD.app --args 120 2 0 0", made)
        facts = json.loads((out / "display.json").read_text())
        self.assertEqual((facts["asked"], facts["main_interval_ms"], facts["pixels"]),
                         ({"hz": 120, "scale": 2}, 8.334, "3024x1964"))
        self.assertTrue(any("driver.py" in s for s in self.scripts))
        # The display runs under the lease's root, so capture-host's release stops it with every process there.
        made = next(s for s in self.scripts if "vdisplay120.m" in s)
        # The release stops only what runs from under the lease's root: one cd into it, first, and every VD.app path
        # relative to it (review 3 of #34161: a bundle outside the root would survive the release).
        self.assertTrue(made.startswith("set -e; cd '/tmp/fake-root/journeys'; "), made)
        self.assertEqual(len(re.findall(r"\bcd\b", made)), 1, made)
        self.assertEqual(set(re.findall(r"(\S*)VD\.app", made)), {""}, "every VD.app path is under that cd")
        self.assertIn("release slot-cmux99-abc", self.calls())
        self.assertFalse(any("kill" in s for s in self.scripts), "run.py signals nothing by name or pattern")

    def test_a_virtual_display_that_is_not_the_main_display_is_not_run(self):
        answer = b"ready 7 8.333\nmain 1 mode 1920x1080 pixels 1920x1080 refresh 60.00 interval 16.667 displays 2\n"
        result, out = self.lease("120x1", answer)
        self.assertEqual(result["status"], "not run")
        self.assertIn("not the main display", result["reason"])
        self.assertFalse(any("driver.py" in s for s in self.scripts))
        self.assertIn("release slot-cmux99-abc", self.calls())

    def test_a_measured_rate_other_than_asked_is_not_run(self):
        answer = b"ready 7 16.667\nmain 7 mode 1920x1080 pixels 1920x1080 refresh 120.00 interval 16.667 displays 2\n"
        result, out = self.lease("120x1", answer)
        self.assertEqual(result["status"], "not run")
        self.assertIn("16.667 ms", result["reason"])
        self.assertFalse(any("driver.py" in s for s in self.scripts))
        self.assertTrue((out / "display.json").exists())

    def test_a_pixel_density_other_than_asked_is_not_run(self):
        answer = b"ready 7 8.333\nmain 7 mode 1512x982 pixels 1512x982 refresh 120.00 interval 8.333 displays 2\n"
        result, out = self.lease("120x2", answer)
        self.assertEqual(result["status"], "not run")
        self.assertIn("1512x982 pixels", result["reason"])
        self.assertFalse(any("driver.py" in s for s in self.scripts))

    def refused(self, mode, answer, why):
        result, out = self.lease(mode, answer)
        self.assertEqual(result["status"], "not run", result)
        self.assertIn(why, result["reason"])
        self.assertFalse(any("driver.py" in s for s in self.scripts))
        self.assertIn("release slot-cmux99-abc", self.calls())
        return result

    def test_a_measured_interval_that_is_no_number_is_refused(self):
        self.refused("120x1", b"ready 7 8.333\nmain 7 mode 1920x1080 pixels 1920x1080 refresh 120.00 interval nan displays 1\n",
                     "no main line")

    def test_a_mode_of_zero_points_is_refused(self):
        self.refused("120x2", b"ready 7 8.333\nmain 7 mode 0x0 pixels 0x0 refresh 0.00 interval 8.333 displays 1\n",
                     "0x0 points")

    def test_a_main_line_with_other_labels_is_refused(self):
        self.refused("120x1", b"ready 7 8.333\nmain 7 foo 1920x1080 bar 1920x1080 baz 120.00 qux 8.334 quux 2\n",
                     "no main line")

    def test_a_line_with_a_word_after_its_form_is_no_measurement(self):
        self.refused("120x1", b"ready 7 8.333\nmain 7 mode 1920x1080 pixels 1920x1080 refresh 120.00 interval 8.334 "
                              b"displays 1 extra\n", "no main line")
        self.refused("120x1", b"ready 7 8.333 extra\nmain 7 mode 1920x1080 pixels 1920x1080 refresh 120.00 interval "
                              b"8.334 displays 1\n", "no ready line")

    def test_the_helpers_error_is_its_own_reason(self):
        self.refused("120x1", b"error: CGVirtualDisplay unavailable\nmain 1 mode 1920x1080 pixels 1920x1080 refresh 60.00 "
                              b"interval 16.667 displays 1\n", "the display helper failed: error: CGVirtualDisplay unavailable")

    def test_no_ready_line_is_its_own_reason(self):
        self.refused("120x1", b"main 1 mode 1920x1080 pixels 1920x1080 refresh 60.00 interval 16.667 displays 1\n",
                     "no ready line")

    def test_the_rate_is_the_fresh_processs_measurement_not_the_helpers(self):
        # The helper measured 8.333 ms as it made the display; the fresh process sees 16.667 ms: what the app gets.
        self.refused("120x1", b"ready 7 8.333\nmain 7 mode 1920x1080 pixels 1920x1080 refresh 120.00 interval 16.667 "
                              b"displays 1\n", "16.667 ms")

    def test_the_tolerance_is_0_35_ms(self):
        # 1000/120 = 8.333 ms: 8.680 is 0.347 ms off (runs), 8.690 is 0.357 ms off (refused).
        near = b"ready 7 %s\nmain 7 mode 1920x1080 pixels 1920x1080 refresh 120.00 interval %s displays 1\n"
        self.lease("120x1", near % (b"8.680", b"8.680"))
        self.assertTrue(any("driver.py" in s for s in self.scripts), "8.680 ms on 120 Hz is within 0.35 ms: it runs")
        self.scripts.clear()
        self.refused("120x1", near % (b"8.690", b"8.690"), "8.69 ms")

    def test_a_display_start_that_times_out_still_releases_the_lease_which_stops_it(self):
        self.vd_raises = subprocess.TimeoutExpired("ssh", 90)
        result, out = self.lease("120x1")
        self.assertEqual(result["status"], "not run")
        self.assertIn("release slot-cmux99-abc", self.calls())
        self.assertFalse(any("kill" in s for s in self.scripts), "run.py signals nothing by name or pattern")

    def test_run_py_has_no_kill_by_name_or_pattern(self):
        # The fleet rule (tests/test_ci_fleet_rule_lints.py): signal only processes you started, never by name or
        # pattern. The two tool names are built here, so this file does not name them itself.
        text = (HERE / "run.py").read_text()
        names = ["p" + "kill", "kill" + "all"]
        self.assertFalse([n for n in names if re.search(r"(?<![\w-])" + n + r"(?![\w-])", text)])

    def test_the_display_is_held_no_longer_than_the_lease(self):
        self.lease("120x1")
        made = next(s for s in self.scripts if "vdisplay120.m" in s)
        hold = int(made.split("VD.app --args 120 1 0 0 ")[1].split(";")[0])
        # It ends by itself 30 s before the lease does (the hog's margin; the driver's budget ends 45 s before).
        self.assertLessEqual(hold, run.LEASE_SECONDS - 30)
        self.assertGreater(hold, 0)

    def test_the_kit_carries_the_display_helper(self):
        names = tarfile.open(fileobj=io.BytesIO(run.kit_tar([journey("plain")]))).getnames()
        self.assertIn("vdisplay120.m", names)


if __name__ == "__main__":
    unittest.main()
