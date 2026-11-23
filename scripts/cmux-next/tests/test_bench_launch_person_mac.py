#!/usr/bin/env python3
"""A bench that takes focus never runs on a person's Mac (Leo, 2026-11-16: "when i tried to do a screen recording of
another part of the app everything just got completely [messed up] i couldnt stop the recording and you guys kept
fighting focus").

1. A Mac the fleet registry lists with a person's role (by key, alias or hostname) is refused, with the registry key
   and role in the reason; a fleet GUI host and a missing registry (a fleet worker account) are not. A Mac the
   registry does not name is refused while its console was used in the last 10 minutes.
2. BenchApp.launch() refuses a launch that lets the app activate on such a Mac before it starts anything; a launch
   that keeps CMUX_NEXT_NO_ACTIVATE (the default) still runs there.
3. require_no_person_mac, for a script that takes focus without BenchApp, exits 1 with one BENCH-LAUNCH line, and
   every script that posts real input (CGEventPost) calls it before its first event.

Runs anywhere (registry and names injected, no app started):

    python3 scripts/cmux-next/tests/test_bench_launch_person_mac.py
"""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import bench_launch as bl  # noqa: E402

MACHINES = {
    "cosmic-gray": {"aliases": ["mbp"], "roles": ["mac-build", "leo-mac", "codex-lanes"]},
    "air-blue": {"aliases": ["macbook-air"], "roles": ["attended", "leo-mac"]},
    "apps-mini": {"roles": ["leo-apps"]},
    "desk-mini": {"hostnames": ["Desk-Mini"], "roles": ["interactive"]},
    "aws-m4pro-1": {"roles": ["aws-mac"]},
    "cmux16": {"roles": ["session-host", "mac-build"]},
}


class PersonMac(unittest.TestCase):
    def test_a_person_role_by_key_alias_or_hostname_is_refused(self):
        for names, key in ((["cosmic-gray"], "cosmic-gray"), (["mbp"], "cosmic-gray"),
                           (["macbook-air", "air-blue"], "air-blue"), (["apps-mini"], "apps-mini"),
                           (["desk-mini"], "desk-mini")):
            problem = bl.person_mac_problem(names, MACHINES)
            self.assertIsNotNone(problem, names)
            self.assertIn(f"fleet registry {key}", problem)

    def test_fleet_hosts_and_no_registry_are_not_refused_and_never_read_idle_time(self):
        asked = lambda: self.fail("idle time read")  # noqa: E731
        for names in (["aws-m4pro-1"], ["cmux16"]):
            self.assertIsNone(bl.person_mac_problem(names, MACHINES, idle=asked), names)
        self.assertIsNone(bl.person_mac_problem(["someones-laptop"], {}, idle=asked))
        self.assertIsNone(bl.person_mac(["cosmic-gray"], None))
        self.assertIsNone(bl.person_mac(["cosmic-gray"], {"cosmic-gray": "not an entry"}))

    def test_a_mac_the_registry_does_not_name_is_refused_while_its_console_is_in_use(self):
        # A person's Mac whose LocalHostName is not its registry key (Leos-MacBook-Pro) on an agent host account.
        for idle in (lambda: 4.0, lambda: None):
            problem = bl.person_mac_problem(["leos-macbook-pro"], MACHINES, idle=idle)
            self.assertIn("not in the fleet registry", problem)
        self.assertIsNone(bl.person_mac_problem(["leos-macbook-pro"], MACHINES, idle=lambda: bl.IDLE_REQUIRED_S + 1))
        self.assertIsNotNone(bl.person_mac_problem([], MACHINES, idle=lambda: 1.0))

    def test_every_script_that_posts_real_input_checks_first(self):
        # The detector for a new one: any script here that calls CGEventPost must call the check before it.
        posting = sorted(p for p in HERE.glob("*.py") if "CGEventPost(" in p.read_text())
        self.assertGreaterEqual(len(posting), 7)
        for path in posting:
            text = path.read_text()
            self.assertIn(f'require_no_person_mac("{path.stem}")', text, path.name)
            self.assertLess(text.index("require_no_person_mac("), text.index("CGEventPost("), path.name)

    def test_the_registry_comes_from_the_environment_or_the_accounts_projects(self):
        with tempfile.TemporaryDirectory() as home:
            path = Path(home, "Projects", "leo-workspace", "machines", "fleet-registry.json")
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({"machines": MACHINES}))
            with mock.patch.dict(os.environ, {"BENCH_LAUNCH_FLEET_REGISTRY": ""}):
                self.assertEqual(bl.fleet_machines(home), MACHINES)
                self.assertIsNone(bl.fleet_machines(os.path.join(home, "nothing")))
            with mock.patch.dict(os.environ, {"BENCH_LAUNCH_FLEET_REGISTRY": str(path)}):
                self.assertEqual(bl.fleet_machines("/nonexistent"), MACHINES)
            path.write_text("{not json")
            with mock.patch.dict(os.environ, {"BENCH_LAUNCH_FLEET_REGISTRY": str(path)}):
                self.assertIsNone(bl.fleet_machines())

    def test_only_a_launch_without_no_activate_takes_focus(self):
        self.assertFalse(bl.activates({}))
        self.assertFalse(bl.activates({"CMUX_NEXT_NO_ACTIVATE": "1"}))
        self.assertTrue(bl.activates({"CMUX_NEXT_NO_ACTIVATE": None}))
        self.assertTrue(bl.activates({"CMUX_NEXT_NO_ACTIVATE": "0"}))


class Launch(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="bench-person-mac-")
        app = Path(self.folder, "cmux DEV person.app")
        (app / "Contents" / "MacOS").mkdir(parents=True)
        self.app = str(app)
        self.ok = lambda: {"ok": True, "user": "me", "console_user": "me", "screen_locked": False, "detail": "ok"}

    def bench(self, env):
        return bl.BenchApp(self.app, out=os.path.join(self.folder, "out"), env=env, teardown=False, session=self.ok)

    def test_an_activating_launch_on_a_persons_mac_starts_nothing(self):
        bench = self.bench({"CMUX_NEXT_NO_ACTIVATE": None})
        with mock.patch.object(bl, "person_mac_problem", return_value="this Mac is a person's"), \
                mock.patch.object(bl, "host_facts", return_value={"host": "cosmic-gray"}), \
                mock.patch.object(bl.subprocess, "Popen") as popen, redirect_stdout(io.StringIO()):
            with self.assertRaises(bl.LaunchError) as raised:
                bench.launch(timeout=1)
        self.assertEqual(raised.exception.reason, "person-mac")
        popen.assert_not_called()
        self.assertIsNone(bench.process)

    def test_a_no_activate_launch_never_asks(self):
        bench = self.bench({})
        with mock.patch.object(bl, "person_mac_problem", side_effect=AssertionError("asked")), \
                mock.patch.object(bl, "lpm_switch_problem", side_effect=RuntimeError("past the guard")):
            with self.assertRaisesRegex(RuntimeError, "past the guard"):
                bench.launch(timeout=1)

    def test_require_no_person_mac_exits_with_one_line(self):
        out = io.StringIO()
        with redirect_stdout(out), self.assertRaises(SystemExit) as raised:
            bl.require_no_person_mac("proof", ["mbp"], MACHINES)
        self.assertEqual(raised.exception.code, 1)
        line = next(l for l in out.getvalue().splitlines() if l.startswith("BENCH-LAUNCH "))
        self.assertEqual(json.loads(line[len("BENCH-LAUNCH "):])["reason"], "person-mac")
        bl.require_no_person_mac("proof", ["aws-m4pro-1"], MACHINES)  # returns


if __name__ == "__main__":
    unittest.main()
