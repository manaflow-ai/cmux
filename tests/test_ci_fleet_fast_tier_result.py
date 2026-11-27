#!/usr/bin/env python3
"""fleet_fast_tier_result.py: the fast tier's fleet verdict read from a Linux runner.

Trusts only a record that names phase fast-tier, this sha and repo, the asked number of steps, and steps that
ran this head; anything else (an old controller's tip receipt, an outage, a 404 past its budget) is unavailable
so the workflow's Mac fallback runs.
"""
import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from cmux_next_step_text import step_run  # noqa: E402
SPEC = importlib.util.spec_from_file_location("fleet_fast_tier_result", ROOT / "scripts/ci/fleet_fast_tier_result.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)

SHA = "a" * 40
REPO = "manaflow-ai/cmux"


def step(name, state, ref=SHA, **kw):
    return dict({"name": name, "package": name, "suites": "A", "state": state, "ref": ref, "job_id": "j-" + name}, **kw)


def record(state, steps, **kw):
    return dict({"version": 1, "repo": REPO, "sha": SHA, "phase": "fast-tier", "state": state, "steps": steps}, **kw)


class Clock:
    def __init__(self):
        self.t = 0.0

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += max(s, 0.001)


def run(answers, **kw):
    """read() against a list of (code, body) answers; the last one repeats."""
    clock = Clock()
    urls = []

    def fetch(url, timeout):
        urls.append(url)
        clock.t += 1
        a = answers[min(len(urls) - 1, len(answers) - 1)]
        return a if len(a) == 3 else (a[0], a[1], None)

    word, reasons = m.read(SHA, REPO, fetch=fetch, now=clock.now, sleep=clock.sleep, **kw)
    return word, reasons, urls, clock


class Judge(unittest.TestCase):
    def test_pass_and_fail(self):
        self.assertEqual(m.judge(record("pass", [step("a", "pass"), step("b", "pass")]), SHA, REPO, 2)[0], "pass")
        self.assertEqual(m.judge(record("fail", [step("a", "fail", exit_code=1), step("b", "pass")]), SHA, REPO, 2)[0], "fail")

    def test_old_controller_tip_receipt_is_unavailable(self):
        tip = {"repo": REPO, "sha": SHA, "phase": "tip", "state": "pass", "steps": []}
        self.assertEqual(m.judge(tip, SHA, REPO, 2)[0], "unavailable")
        no_phase = {"repo": REPO, "sha": SHA, "state": "pass"}
        self.assertEqual(m.judge(no_phase, SHA, REPO, 2)[0], "unavailable")

    def test_other_head_or_repo_is_unavailable(self):
        self.assertEqual(m.judge(record("pass", [step("a", "pass"), step("b", "pass")], sha="b" * 40), SHA, REPO, 2)[0], "unavailable")
        self.assertEqual(m.judge(record("pass", [step("a", "pass"), step("b", "pass")], repo="x/y"), SHA, REPO, 2)[0], "unavailable")

    def test_step_that_ran_another_ref_is_unavailable(self):
        r = record("pass", [step("a", "pass"), step("b", "pass", ref="c" * 40)])
        self.assertEqual(m.judge(r, SHA, REPO, 2)[0], "unavailable")

    def test_wrong_step_count_or_state_is_unavailable(self):
        self.assertEqual(m.judge(record("pass", [step("a", "pass")]), SHA, REPO, 2)[0], "unavailable")
        self.assertEqual(m.judge(record("great", [step("a", "pass"), step("b", "pass")]), SHA, REPO, 2)[0], "unavailable")
        self.assertEqual(m.judge("nope", SHA, REPO, 2)[0], "unavailable")


class Read(unittest.TestCase):
    def test_pass_after_running(self):
        running = record("running", [step("a", "running", ref=""), step("b", "pass")])
        done = record("pass", [step("a", "pass"), step("b", "pass")])
        word, _, urls, _ = run([(200, running), (200, done)])
        self.assertEqual(word, "pass")
        self.assertIn("phase=fast-tier", urls[0])
        self.assertIn("repo=manaflow-ai%2Fcmux", urls[0])
        self.assertRegex(urls[0], r"&wait=\d+$")

    def test_hold_never_exceeds_gateway_limit(self):
        _, _, urls, _ = run([(200, record("pass", [step("a", "pass"), step("b", "pass")]))])
        hold = int(urls[0].rsplit("wait=", 1)[1])
        self.assertLessEqual(hold, 90)

    def test_queries_carry_the_suites_or_ffi_repin(self):
        done = record("pass", [step("a", "pass"), step("b", "pass")])
        _, _, urls, _ = run([(200, done)], home_render="X,Y", cmux_next="Z")
        self.assertIn("home_render=X%2CY", urls[0])
        self.assertIn("cmux_next=Z", urls[0])
        word, _, urls, _ = run([(200, record("pass", [step("h", "pass")]))], ffi_repin=True, cmux_next="Z")
        self.assertEqual(word, "pass")
        self.assertIn("ffi_repin=1", urls[0])
        self.assertNotIn("cmux_next", urls[0])

    def test_queued_past_queue_wait_hands_back(self):
        q = record("queued", [step("a", "queued", ref=""), step("b", "queued", ref="")])
        word, reasons, _, clock = run([(200, q)], queue_wait=100)
        self.assertEqual(word, "queued")
        self.assertGreaterEqual(clock.t, 100)

    def test_running_past_wait_is_unavailable(self):
        r = record("running", [step("a", "running", ref=""), step("b", "running", ref="")])
        word, _, _, clock = run([(200, r)], wait=300)
        self.assertEqual(word, "unavailable")
        self.assertLessEqual(clock.t, 400)

    def test_404_until_no_record_is_unavailable(self):
        word, reasons, urls, _ = run([(404, None)], no_record=60)
        self.assertEqual(word, "unavailable")
        self.assertGreater(len(urls), 1)

    def test_404_then_record(self):
        done = record("fail", [step("a", "fail", exit_code=1), step("b", "pass")])
        self.assertEqual(run([(404, None), (200, done)])[0], "fail")

    def test_outage_is_unavailable_after_two_minutes(self):
        word, reasons, _, clock = run([(0, None)])
        self.assertEqual(word, "unavailable")
        self.assertLess(clock.t, 300)

    def test_busy_retries_then_reads(self):
        done = record("pass", [step("a", "pass"), step("b", "pass")])
        word, _, urls, _ = run([(503, None, 5), (429, None, None), (200, done)])
        self.assertEqual(word, "pass")
        self.assertEqual(len(urls), 3)

    def test_400_is_unavailable_at_once(self):
        word, _, urls, _ = run([(400, None)])
        self.assertEqual((word, len(urls)), ("unavailable", 1))

    def test_old_controller_is_unavailable_at_once(self):
        tip = {"version": 1, "repo": REPO, "sha": SHA, "state": "pass", "steps": []}
        word, _, urls, _ = run([(200, tip)])
        self.assertEqual((word, len(urls)), ("unavailable", 1))


class Main(unittest.TestCase):
    def test_bad_args_print_unavailable(self):
        import contextlib
        import io
        for argv in (["--sha", "nope", "--repo", REPO], ["--sha", SHA, "--repo", REPO, "--cmux-next", "A;rm"]):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(m.main(argv), 0)
            self.assertEqual(out.getvalue().strip(), "unavailable")


class Workflow(unittest.TestCase):
    def setUp(self):
        import yaml
        self.wf = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text())
        self.jobs = self.wf["jobs"]

    def test_fast_tier_fleet_runs_on_linux_and_reads_the_verdict(self):
        job = self.jobs["fast-tier-fleet"]
        self.assertEqual(job["name"], "cmux-next fast tier (build fleet)")
        self.assertEqual(job["runs-on"], "cmux-linux")
        self.assertIn("verdict", job["outputs"])
        text = "\n".join(step_run(s) for s in job["steps"])
        self.assertIn("fleet_fast_tier_result.py", text)
        self.assertNotIn("gateway_runner", str(job.get("if", "")))

    def test_mac_fallback_runs_only_on_unavailable(self):
        job = self.jobs["fast-tier-fleet-mac"]
        self.assertNotEqual(job["name"], "cmux-next fast tier (build fleet)")
        self.assertIn("fast-tier-fleet", job["needs"])
        self.assertIn("needs.fast-tier-fleet.outputs.verdict == 'unavailable'", job["if"])
        self.assertIn("gateway_runner", str(job["runs-on"]))
        text = "\n".join(step_run(s) for s in job["steps"])
        self.assertIn("::warning title=mac fallback::", text)
        self.assertIn("verdict", job["outputs"])

    def test_consumers_read_the_combined_verdict(self):
        for name in ("fast-tier-handback-placement",):
            self.assertIn("fast-tier-fleet-mac", self.jobs[name]["needs"])
            self.assertIn("needs.fast-tier-fleet-mac.outputs.verdict", str(self.jobs[name]))
        consumer = [j for j in self.jobs.values() if j.get("name") == "cmux-next fast tier"]
        self.assertEqual(len(consumer), 1)
        self.assertIn("fast-tier-fleet-mac", consumer[0]["needs"])
        self.assertIn("needs.fast-tier-fleet-mac.outputs.verdict", str(consumer[0]))


if __name__ == "__main__":
    unittest.main()
