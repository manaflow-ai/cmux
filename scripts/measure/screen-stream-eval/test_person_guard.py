"""GUI-viewer targets never run on a Mac a person uses."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import person_guard as guard  # noqa: E402

MACHINES = {
    "owner-laptop": {"roles": ["attended", "leo-mac"], "aliases": ["laptop-alias"],
                 "address": {"lan": "owner-laptop.local", "tailnet": "100.64.0.1"}},
    "cmux17": {"roles": ["ci-runner"], "aliases": [], "address": {"tailnet": "cmux17.example.ts.net"}},
    "desk": {"roles": ["interactive"], "aliases": [], "address": {"tailnet": "desk-mini.example.ts.net"}},
}
IDLE_OUTPUT = '    | |   "HIDIdleTime" = 900000000000\n'


def runner(answers):
    return lambda argv: answers.get(" ".join(argv), "")


class DecideTests(unittest.TestCase):
    def test_persons_role_refused(self):
        target, reason = guard.decide(["apple-high"], ["owner-laptop"], MACHINES, 10_000)
        self.assertEqual(target, "apple-high")
        self.assertIn("person's Mac", reason)
        self.assertIn("leo-mac", reason)

    def test_interactive_role_refused(self):
        self.assertEqual(guard.decide(["moonlight"], ["desk"], MACHINES, 10_000)[0], "moonlight")

    def test_ci_runner_allowed_even_when_active(self):
        self.assertEqual(guard.decide(["apple-standard", "moonlight"], ["cmux17"], MACHINES, 0), (None, None))

    def test_alias_and_address_match(self):
        self.assertEqual(guard.decide(["apple-high"], ["laptop-alias"], MACHINES, 10_000)[0], "apple-high")
        self.assertEqual(guard.decide(["apple-high"], ["desk-mini"], MACHINES, 10_000)[0], "apple-high")
        self.assertEqual(guard.decide(["apple-high"], ["nobody"], {"x": {"roles": ["ci-runner"],
                         "address": {"tailnet": "100.1.2.3"}}}, 0)[0], "apple-high")

    def test_future_apple_target_covered(self):
        self.assertEqual(guard.decide(["rd", "apple-rfb"], ["owner-laptop"], MACHINES, None)[0], "apple-rfb")

    def test_unknown_host_active_console_refused(self):
        target, reason = guard.decide(["apple-high"], ["stranger"], MACHINES, 30)
        self.assertEqual(target, "apple-high")
        self.assertIn("not in the fleet registry", reason)
        target, reason = guard.decide(["apple-high"], ["stranger"], None, 30)
        self.assertIn("no fleet registry", reason)

    def test_unknown_host_idle_console_allowed(self):
        self.assertEqual(guard.decide(["apple-high"], ["stranger"], MACHINES, 600), (None, None))
        self.assertEqual(guard.decide(["apple-high"], ["stranger"], None, 3600), (None, None))

    def test_unreadable_idle_refused(self):
        target, reason = guard.decide(["moonlight"], ["stranger"], None, None)
        self.assertEqual(target, "moonlight")
        self.assertIn("unreadable", reason)
        self.assertIsNone(guard.idle_seconds(""))

    def test_idle_takes_most_recent_device(self):
        out = '"HIDIdleTime" = 900000000000\n"HIDIdleTime" = 5000000000\n'
        self.assertEqual(guard.idle_seconds(out), 5.0)

    def test_non_gui_targets_always_allowed(self):
        for names, machines, idle in ((["owner-laptop"], MACHINES, 0), (["stranger"], None, None)):
            self.assertEqual(guard.decide(["rd", "webrtc", "cu-png", "rd-window"], names, machines, idle), (None, None))


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.registry = os.path.join(self.tmp, "fleet-registry.json")
        Path(self.registry).write_text(json.dumps({"machines": MACHINES}))

    def test_message_names_target_host_and_next_step(self):
        run = runner({"hostname -s": "Owner-Laptop\n"})
        refusal = guard.check("rd,apple-high", self.registry, self.tmp, run)
        self.assertTrue(refusal.startswith("screen-stream-eval: refused: apple-high opens windows or posts input, and owner-laptop is "))
        self.assertIn('next: run it with the viewer and host on dedicated fleet Macs (README.md, "Two Macs")', refusal)
        self.assertNotIn("\n", refusal)

    def test_scutil_names_used_on_a_mac(self):
        run = runner({"scutil --get LocalHostName": "cmux17\n", "scutil --get ComputerName": "Build Box\n",
                      "hostname -s": "localhost\n"})
        self.assertEqual(guard.local_names(run), ["cmux17", "build box", "localhost"])
        self.assertIsNone(guard.check("apple-high", self.registry, self.tmp, run))

    def test_registry_found_under_home_projects(self):
        found = os.path.join(self.tmp, "Projects", "anything", "machines")
        os.makedirs(found)
        shutil.copy(self.registry, found)
        self.assertEqual(guard.find_registry("", self.tmp), os.path.join(found, "fleet-registry.json"))
        self.assertIsNone(guard.find_registry("", os.path.join(self.tmp, "empty")))

    def test_unknown_host_reads_idle(self):
        run = runner({"hostname -s": "stranger\n", "ioreg -c IOHIDSystem -d 4": IDLE_OUTPUT})
        self.assertIsNone(guard.check("apple-high", self.registry, self.tmp, run))
        run = runner({"hostname -s": "stranger\n"})
        self.assertIn("unreadable", guard.check("apple-high", self.registry, self.tmp, run))

    def test_cli_exit_codes(self):
        env = {**os.environ, "CMUX_FLEET_REGISTRY": self.registry}
        ok = subprocess.run([sys.executable, "-I", str(HERE / "person_guard.py"), "check", "rd,webrtc"],
                            env=env, capture_output=True, text=True)
        self.assertEqual((ok.returncode, ok.stderr), (0, ""))


class HarnessTests(unittest.TestCase):
    def test_harness_refuses_before_removing_anything(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        measure = tmp / "scripts" / "measure"
        measure.mkdir(parents=True)
        shutil.copy(HERE.parent / "screen-stream-eval.sh", measure)
        shutil.copytree(HERE, measure / "screen-stream-eval", ignore=shutil.ignore_patterns("__pycache__"))
        sentinel = tmp / "artifacts" / "screen-stream-eval" / "keep"
        sentinel.parent.mkdir(parents=True)
        sentinel.write_text("x")
        host = subprocess.run(["hostname", "-s"], capture_output=True, text=True).stdout.strip() or socket.gethostname()
        registry = tmp / "fleet-registry.json"
        registry.write_text(json.dumps({"machines": {host.lower(): {"roles": ["leo-mac"], "aliases": []}}}))
        env = {**os.environ, "CMUX_FLEET_REGISTRY": str(registry)}
        p = subprocess.run(["bash", str(measure / "screen-stream-eval.sh"), "targets=apple-high"],
                           env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 2, p.stderr)
        self.assertIn("refused: apple-high", p.stderr)
        self.assertTrue(sentinel.exists())
        self.assertFalse((tmp / ".build").exists())


if __name__ == "__main__":
    unittest.main()
