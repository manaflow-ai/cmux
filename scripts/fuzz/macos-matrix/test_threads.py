#!/usr/bin/env python3
"""Offline checks of threads.py's verdicts (no VM, no VNC, no app).

Run: python3 -I scripts/fuzz/macos-matrix/test_threads.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import smoke  # noqa: E402
import threads  # noqa: E402

SITES = {"task_detached": "CmuxNextControl/PoolContextControl.swift:120",
         "global_queue": "CmuxNextControl/PoolContextControl.swift:123",
         "lane_files": "CmuxNextControl/PoolContextControl.swift:125",
         "lane_cpu": "CmuxNextControl/PoolContextControl.swift:126"}
EXPECTED = {"task_detached": "pool", "global_queue": "pool", "lane_files": "lane", "lane_cpu": "cpu-lane"}


def pool_reply(**contexts) -> dict:
    """A debug.pool_context reply where each case got its expected context unless `contexts` names another."""
    return {"compiled_in": True,
            "cases": [{"name": name, "expected": EXPECTED[name], "context": contexts.get(name, EXPECTED[name]),
                       "label": "com.apple.root.utility-qos" if EXPECTED[name] == "pool" else "com.cmuxterm.next.work.x.0",
                       "site": SITES[name]} for name in SITES],
            "raise": {"before": {"qos": "utility", "priority": 20}, "after": {"qos": "utility", "priority": 37}}}


def blocking(*listed: tuple[str, str]) -> dict:
    return {"compiled_in": True, "pool_mode": "record",
            "sites": [{"location": SITES[name], "context": context} for name, context in listed]}


class CaseSteps(unittest.TestCase):
    def test_every_case_with_its_context_passes(self):
        steps = threads.judge_cases(pool_reply())
        self.assertEqual(set(steps), {"pool_task", "pool_global", "lane_files", "lane_cpu"})
        self.assertTrue(all(ok for ok, _ in steps.values()))

    def test_a_pool_case_read_as_dedicated_fails_its_step_only(self):
        # The label changed on this macOS: the detector no longer finds the pool.
        steps = threads.judge_cases(pool_reply(global_queue="dedicated"))
        self.assertFalse(steps["pool_global"][0])
        self.assertEqual(steps["pool_global"][1]["context"], "dedicated")
        self.assertTrue(steps["pool_task"][0] and steps["lane_files"][0] and steps["lane_cpu"][0])

    def test_an_old_build_or_a_refusal_fails_every_case(self):
        for reply in ({"error": "unknown method debug.pool_context"}, {"compiled_in": True, "refused": "trap"},
                      {"compiled_in": False, "cases": []}):
            steps = threads.judge_cases(reply)
            self.assertEqual(len(steps), 4)
            self.assertFalse(any(ok for ok, _ in steps.values()), reply)

    def test_a_missing_case_fails(self):
        reply = pool_reply()
        reply["cases"] = reply["cases"][1:]
        self.assertFalse(threads.judge_cases(reply)["pool_task"][0])


class RecordedStep(unittest.TestCase):
    def test_the_pool_and_cpu_sites_listed_and_the_lane_site_not(self):
        ok, detail = threads.judge_recorded(pool_reply(), blocking(("task_detached", "pool"), ("global_queue", "pool"),
                                                                   ("lane_cpu", "cpu-lane")))
        self.assertTrue(ok, detail)

    def test_a_pool_site_not_yet_listed_fails(self):
        ok, detail = threads.judge_recorded(pool_reply(), blocking(("task_detached", "pool"), ("lane_cpu", "cpu-lane")))
        self.assertFalse(ok)
        self.assertEqual(detail["wrong"], ["global_queue"])

    def test_a_listed_lane_site_fails(self):
        ok, detail = threads.judge_recorded(pool_reply(), blocking(("task_detached", "pool"), ("global_queue", "pool"),
                                                                   ("lane_files", "lane-sync"), ("lane_cpu", "cpu-lane")))
        self.assertFalse(ok)
        self.assertEqual(detail["wrong"], ["lane_files"])

    def test_a_pool_site_under_another_context_fails(self):
        ok, _ = threads.judge_recorded(pool_reply(), blocking(("task_detached", "main"), ("global_queue", "pool"),
                                                              ("lane_cpu", "cpu-lane")))
        self.assertFalse(ok)

    def test_no_cases_or_no_detector_fails(self):
        self.assertFalse(threads.judge_recorded({"error": "x"}, blocking())[0])
        listed = blocking(("task_detached", "pool"), ("global_queue", "pool"), ("lane_cpu", "cpu-lane"))
        listed["compiled_in"] = False
        self.assertFalse(threads.judge_recorded(pool_reply(), listed)[0])


class RaiseStep(unittest.TestCase):
    def test_a_higher_priority_at_the_same_qos_passes(self):
        self.assertTrue(threads.judge_raise(pool_reply())[0])

    def test_no_rise_fails(self):
        reply = pool_reply()
        reply["raise"]["after"]["priority"] = 20
        self.assertFalse(threads.judge_raise(reply)[0])

    def test_a_requested_qos_change_is_not_an_override(self):
        reply = pool_reply()
        reply["raise"]["after"]["qos"] = "user-initiated"
        self.assertFalse(threads.judge_raise(reply)[0])

    def test_an_unread_priority_fails(self):
        reply = pool_reply()
        reply["raise"]["before"]["priority"] = None
        self.assertFalse(threads.judge_raise(reply)[0])
        self.assertFalse(threads.judge_raise({"error": "x"})[0])


class ThreadsStep(unittest.TestCase):
    def reply(self, **overrides) -> dict:
        rows = [{"main": True, "requested_qos": "user-interactive", "label": "com.apple.main-thread"},
                {"main": False, "requested_qos": "utility", "label": "com.cmuxterm.next.control.accept"},
                {"main": False, "requested_qos": None, "label": None}]
        return {"thread_count": len(rows), "task_role": "foreground", "threads": rows, "mismatched": 2,
                "undeclared_cmux": 1, **overrides}

    def test_a_readable_thread_list_passes_and_the_audit_is_a_finding(self):
        ok, detail, audit = threads.judge_threads(self.reply())
        self.assertTrue(ok, detail)
        self.assertEqual(audit["mismatched"], 2)
        self.assertEqual(audit["undeclared_cmux"], 1)

    def test_no_labels_fails(self):
        rows = [dict(r, label=None) for r in self.reply()["threads"]]
        self.assertFalse(threads.judge_threads(self.reply(threads=rows))[0])

    def test_a_main_thread_below_user_interactive_fails(self):
        rows = self.reply()["threads"]
        rows[0] = dict(rows[0], requested_qos="user-initiated")
        self.assertFalse(threads.judge_threads(self.reply(threads=rows))[0])

    def test_an_unknown_task_role_or_an_error_fails(self):
        self.assertFalse(threads.judge_threads(self.reply(task_role="unknown"))[0])
        self.assertFalse(threads.judge_threads({"error": "unknown method"})[0])


class FakeVNC:
    def __init__(self, *_):
        pass

    def screenshot_png(self) -> bytes:
        return b"png"


class FakeGuest:
    """The guest commands threads.py's run sends: `answers` maps a method to its reply, or to a list of replies
    given in turn (the last one repeats)."""

    def __init__(self, answers: dict):
        self.app, self.socket, self.answers, self.calls = "/Users/admin/fuzzapp/cmux DEV.app", "/tmp/x.sock", answers, []

    def sh(self, cmd: str, timeout: float = 30) -> subprocess.CompletedProcess:
        return subprocess.CompletedProcess(cmd, 0, "14.7\n" if "sw_vers" in cmd else "", "")

    def launch(self, *_, **__) -> bool:
        return True

    def pid(self) -> int:
        return 4242

    def ping_ms(self, _timeout: float) -> int:
        return 3

    def cmux(self, args, timeout: float = 15) -> subprocess.CompletedProcess:
        method = args[2]
        self.calls.append(method)
        answer = self.answers.get(method, {})
        if isinstance(answer, list):
            answer = answer.pop(0) if len(answer) > 1 else answer[0]
        return subprocess.CompletedProcess(args, 0, json.dumps(answer) + "\n", "")


class Run(unittest.TestCase):
    def run_threads(self, answers: dict) -> dict:
        with tempfile.TemporaryDirectory() as out, mock.patch.object(smoke, "RFB", FakeVNC), \
                mock.patch.object(time, "sleep", lambda _: None):
            suite = threads.Threads(FakeGuest(answers), "127.0.0.1:5900:pw", out)
            suite.run()
            return suite.result

    def answers(self, **overrides) -> dict:
        rows = [{"main": True, "requested_qos": "user-interactive", "label": "com.apple.main-thread"}]
        return {"system.identify": {"ok": True}, "debug.windows": {"windows": [{"id": "w1"}]},
                "debug.pool_context": pool_reply(),
                "debug.blocking": blocking(("task_detached", "pool"), ("global_queue", "pool"), ("lane_cpu", "cpu-lane")),
                "debug.threads": {"threads": rows, "task_role": "foreground", "mismatched": 0}, **overrides}

    def test_every_step_passes_and_the_labels_are_kept(self):
        result = self.run_threads(self.answers())
        steps = result["steps"]
        self.assertEqual([n for n in threads.REQUIRED_STEPS if n != "quit"], list(steps))
        self.assertTrue(all(s["ok"] for s in steps.values()), steps)
        self.assertEqual(result["labels"]["global_queue"], "com.apple.root.utility-qos")
        self.assertEqual(result["pool_context_calls"], 1)

    def test_a_fenced_first_call_is_retried(self):
        result = self.run_threads(self.answers(**{"debug.pool_context": [{"error": "timeout"}, pool_reply()]}))
        self.assertTrue(result["steps"]["pool_task"]["ok"])
        self.assertEqual(result["pool_context_calls"], 2)


class Suite(unittest.TestCase):
    def test_the_suite_requires_every_step_and_names_itself(self):
        self.assertEqual(threads.Threads.suite, "threads")
        self.assertEqual(threads.Threads.required[:2], ("launch", "window"))
        self.assertEqual(threads.Threads.required[-2:], ("alive", "quit"))
        for step in ("pool_task", "pool_global", "lane_files", "lane_cpu", "recorded", "raise", "threads"):
            self.assertIn(step, threads.Threads.required)


def vm_summary_source() -> str:
    """The per-major summary program vm.sh feeds to `python3 -I -` (the last <<'PY' heredoc)."""
    with open(os.path.join(HERE, "vm.sh")) as f:
        text = f.read()
    start = text.index("\n", text.index('python3 -I - "$RUN" "$MAJORS"')) + 1
    return text[start:text.index("\nPY\n", start)]


class VmSummary(unittest.TestCase):
    """vm.sh's summary over a run folder: a crash there gives no MATRIX VERDICT and no results archive."""

    def summarize(self, suite: str, results: dict[str, dict]) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as run:
            for major, result in results.items():
                os.makedirs(os.path.join(run, major))
                with open(os.path.join(run, major, "result.json"), "w") as f:
                    json.dump(result, f)
            archive = os.path.join(run, "results.tgz")
            done = subprocess.run([sys.executable, "-I", "-", run, ",".join(results), suite, archive, "", HERE],
                                  input=vm_summary_source(), capture_output=True, text=True, timeout=60)
            done.archived = os.path.exists(archive)  # type: ignore[attr-defined]
            return done

    def test_smoke_and_threads_runs_give_a_verdict_and_an_archive(self):
        passed = {"os": "14.7", "ok": True, "failed_steps": [], "crashes": 0, "hang_reports": 0, "faults": 0}
        for suite in ("smoke", "threads"):
            done = self.summarize(suite, {"14": passed, "15": dict(passed, os="15.6")})
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn("MATRIX VERDICT PASS", done.stdout.splitlines())
            self.assertIn("14   14.7     %-5s PASS" % suite, done.stdout)
            self.assertTrue(done.archived)

    def test_a_failed_step_gives_fail(self):
        failed = {"os": "15.6", "ok": False, "failed_steps": ["raise"], "crashes": 0, "hang_reports": 0, "faults": 0}
        done = self.summarize("threads", {"15": failed})
        self.assertIn("MATRIX VERDICT FAIL", done.stdout.splitlines(), done.stderr)
        self.assertIn("failed=raise", done.stdout)


if __name__ == "__main__":
    unittest.main()
