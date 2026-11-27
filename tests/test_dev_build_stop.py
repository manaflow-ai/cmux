#!/usr/bin/env python3
"""scripts/dev-build.py: which processes a tagged dev build owns, and what `stop` ends (issue 55842)."""

from __future__ import annotations

import importlib.util
import os
import signal
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Dict, List

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/dev-build.py"


def load():
    spec = importlib.util.spec_from_file_location("dev_build", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


dev_build = load()
P = dev_build.Process
B = "/Users/me/dev-builds/t/cmux DEV t.app"

LEFT_BEHIND = [
    P(1, 0, "/sbin/launchd"),
    P(100, 1, f"{B}/Contents/Library/cmux Files (dev).app/Contents/MacOS/cmux-files-host run -- {B}/Contents/Resources/bin/cmux-tui --headless",
      f"{B}/Contents/Library/cmux Files (dev).app/Contents/MacOS/cmux-files-host"),
    P(101, 100, f"/Users/me/Library/Application Support/cmux/files-host/app/d0/cmux Files (dev).app/Contents/MacOS/cmux-files-host host -- {B}/Contents/Resources/bin/cmux-tui --headless",
      "/Users/me/Library/Application Support/cmux/files-host/app/d0/cmux Files (dev).app/Contents/MacOS/cmux-files-host"),
    P(102, 101, f"{B}/Contents/Resources/bin/cmux-tui --headless --session cmux-app-t", f"{B}/Contents/Resources/bin/cmux-tui"),
    P(103, 102, "/bin/zsh -l"),
    P(110, 1, f"{B}/Contents/Resources/bin/acpmux daemon run", f"{B}/Contents/Resources/bin/acpmux"),
    P(111, 110, "/opt/homebrew/bin/claude"),
    P(112, 1, "/private/Users/me/dev-builds/t/cmux DEV t.app/Contents/Resources/bin/cmux-cloud",
      "/private/Users/me/dev-builds/t/cmux DEV t.app/Contents/Resources/bin/cmux-cloud"),
    P(113, 1, "cmux-holder --socket /tmp/cmux-hd-501/0.sock --owner com.cmuxterm.app.debug.t:t@99"),
    P(114, 113, "-zsh"),
    P(200, 1, "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux daemon run"),
    P(201, 1, "cmux-holder --socket /tmp/cmux-hd-501/1.sock --owner com.cmuxterm.app.debug.tt:tt@98"),
    P(300, 1, "/x/cmux DEV tt.app/Contents/Resources/bin/cmux-tui --headless", "/x/cmux DEV tt.app/Contents/Resources/bin/cmux-tui"),
    P(301, 300, "/x/cmux DEV tt.app/Contents/Frameworks/cmux DEV Helper.app/Contents/MacOS/cmux DEV Helper --type=gpu",
      "/x/cmux DEV tt.app/Contents/Frameworks/cmux DEV Helper.app/Contents/MacOS/cmux DEV Helper"),
    # An agent's shell and a script that only name the bundle in arguments, and a grep for the owner.
    P(400, 1, f"/bin/bash -c ls '{B}/Contents/Resources/bin'", "/bin/bash"),
    P(401, 1, f"/usr/bin/python3 quit-live.py t {B}", "/usr/bin/python3"),
    P(402, 1, "/usr/bin/grep -- --owner com.cmuxterm.app.debug.t: log", "/usr/bin/grep"),
]
APP = P(500, 1, f"{B}/Contents/MacOS/cmux DEV", f"{B}/Contents/MacOS/cmux DEV")


class Fake(dev_build.System):
    """SIGTERM ends a process unless it is stubborn; SIGKILL always does."""

    def __init__(self, processes: List[P], stubborn=()):
        self.processes: Dict[int, P] = {p.pid: p for p in processes}
        self.stubborn = set(stubborn)
        self.signals: List[tuple] = []

    def snapshot(self):
        return list(self.processes.values())

    def signal(self, pid, sig):
        self.signals.append((pid, sig))
        if sig == signal.SIGKILL or pid not in self.stubborn:
            self.processes.pop(pid, None)

    def alive(self, pid):
        return pid in self.processes

    def launch_env(self, pid):
        return ""

    def wait(self, pids, timeout):
        return [pid for pid in pids if pid in self.processes]


class DevBuildStopTests(unittest.TestCase):
    def setUp(self):
        self.claims = tempfile.TemporaryDirectory()
        dev_build.CLAIMS_DIR = Path(self.claims.name)

    def tearDown(self):
        self.claims.cleanup()

    def test_tree_is_the_bundle_its_holders_and_their_descendants(self):
        chosen = [p.pid for p in dev_build.tree("t", LEFT_BEHIND, {os.getpid()})]
        self.assertEqual(chosen, [100, 101, 102, 103, 110, 111, 112, 113, 114])

    def test_tags_skip_nested_helpers_and_the_daily(self):
        processes = LEFT_BEHIND + [P(600, 1, "/A/cmux DEV next.app/Contents/MacOS/cmux DEV", "/A/cmux DEV next.app/Contents/MacOS/cmux DEV"),
                                   P(601, 1, "grep /x/cmux DEV other.app/Contents", "grep")]
        self.assertEqual(dev_build.tags_in(processes), {"t", "tt"})

    def test_the_app_is_only_its_own_executable(self):
        self.assertEqual(dev_build.app_pids("t", LEFT_BEHIND + [APP]), [500])
        self.assertEqual(dev_build.app_pids("t", LEFT_BEHIND), [])

    def test_stop_quits_the_app_then_ends_the_tree_and_kills_the_stubborn(self):
        fake = Fake(LEFT_BEHIND + [APP], stubborn=[110])
        survivors = dev_build.stop("t", fake, log=lambda _: None)
        self.assertEqual(survivors, [])
        self.assertEqual(fake.signals[0], (500, signal.SIGTERM))
        self.assertIn((110, signal.SIGKILL), fake.signals)
        self.assertEqual(sorted(fake.processes), [1, 200, 201, 300, 301, 400, 401, 402])

    def test_stop_refuses_the_daily_and_bad_tags(self):
        for tag in ("next", "a b", "../x", ""):
            with self.assertRaises(SystemExit):
                dev_build.stop(tag, Fake([]), log=lambda _: None)

    def test_dry_run_signals_nothing(self):
        fake = Fake(LEFT_BEHIND + [APP])
        lines = []
        dev_build.stop("t", fake, dry_run=True, log=lines.append)
        self.assertEqual(fake.signals, [])
        self.assertEqual(len(lines), 10, "the tree and the app")

    def test_idle_means_no_app_or_a_finished_claiming_chat(self):
        with_app = LEFT_BEHIND + [APP]
        self.assertTrue(dev_build.verdict("t", LEFT_BEHIND, None).startswith("idle"))
        self.assertTrue(dev_build.verdict("t", with_app, {}).startswith("keep"), "no claim")
        dev_build.claim("t", "s-1")
        self.assertTrue(dev_build.verdict("t", with_app, None).startswith("keep"), "acpmux unreachable")
        self.assertTrue(dev_build.verdict("t", with_app, {"s-1": "running"}).startswith("keep"))
        self.assertTrue(dev_build.verdict("t", with_app, {"s-1": "idle"}).startswith("keep"), "idle, no time known")
        self.assertTrue(dev_build.verdict("t", with_app, {"s-1": "closed"}).startswith("idle"))
        self.assertTrue(dev_build.verdict("t", with_app, {"other": "running"}).startswith("idle"))

    def test_a_chat_idle_past_the_limit_is_done_with_its_build(self):
        # Issue 63351: the owning chat's last turn ended 42 hours ago and its build kept 83 processes.
        with_app = LEFT_BEHIND + [APP]
        dev_build.claim("t", "s-1")
        now = 1_795_821_955.0
        hours_ago = lambda h: (now - h * 3600) * 1000  # noqa: E731
        row = dev_build.chat_row({"state": "idle", "lastTurn": {"endedAt": hours_ago(42)}, "updatedAt": hours_ago(42),
                                  "bgTasksRunning": 0, "commandsRunning": 0})
        self.assertTrue(dev_build.verdict("t", with_app, {"s-1": row}, now=now).startswith("idle: its chat s-1 has been idle for 42h"))
        # Recent, busy, running or waiting on the person: kept.
        recent = dev_build.chat_row({"state": "idle", "lastTurn": {"endedAt": hours_ago(1)}})
        self.assertTrue(dev_build.verdict("t", with_app, {"s-1": recent}, now=now).startswith("keep"))
        touched = dev_build.chat_row({"state": "idle", "lastTurn": {"endedAt": hours_ago(42)}, "updatedAt": hours_ago(1)})
        self.assertTrue(dev_build.verdict("t", with_app, {"s-1": touched}, now=now).startswith("keep"), "newest stamp wins")
        busy = dev_build.chat_row({"state": "idle", "lastTurn": {"endedAt": hours_ago(42)}, "bgTasksRunning": 1})
        self.assertTrue(dev_build.verdict("t", with_app, {"s-1": busy}, now=now).startswith("keep"), "a background task runs")
        for state in ("running", "waiting", "stuck"):
            row = dev_build.chat_row({"state": state, "lastTurn": {"endedAt": hours_ago(42)}})
            self.assertTrue(dev_build.verdict("t", with_app, {"s-1": row}, now=now).startswith("keep"), state)

    def test_the_chat_that_launched_an_unclaimed_app_owns_it(self):
        # A build opened with `open` or unzipped from a fleet artifact never ran `claim`; the app's
        # own environment still names the chat whose shell launched it.
        class Launched(Fake):
            def launch_env(self, pid):
                assert pid == APP.pid
                return f"{APP.command} ACPMUX_SESSION_ID=fake-arg TERM=xterm ACPMUX_SESSION_ID=s-9 CMUX_TAG=t"
        with_app = LEFT_BEHIND + [APP]
        system = Launched(with_app)
        self.assertEqual(dev_build.owner("t", with_app, system)["session"], "s-9")
        self.assertTrue(dev_build.verdict("t", with_app, {"s-9": "closed"}, system).startswith("idle: its chat s-9"))
        self.assertTrue(dev_build.verdict("t", with_app, {"s-9": "running"}, system).startswith("keep"))
        # A claim wins over the launch environment; no session anywhere (the Tag Opener) is kept.
        dev_build.claim("t", "s-1")
        self.assertEqual(dev_build.owner("t", with_app, system)["session"], "s-1")
        (dev_build.CLAIMS_DIR / "t.json").unlink()
        self.assertTrue(dev_build.verdict("t", with_app, {}, Fake(with_app)).startswith("keep: app running, no chat owns it"))

    def test_all_idle_ends_finished_tags_but_spares_the_one_being_launched(self):
        fake = Fake(LEFT_BEHIND)
        original_system, original_states = dev_build.System, dev_build.acpmux_states
        dev_build.System, dev_build.acpmux_states = (lambda: fake), (lambda: {})
        try:
            self.assertEqual(dev_build.main(["stop", "--all-idle", "--except", "t"]), 0)
            self.assertIn(103, fake.processes, "the spared tag's helpers")
            self.assertEqual(dev_build.main(["stop", "--all-idle"]), 0)
            self.assertNotIn(103, fake.processes)
        finally:
            dev_build.System, dev_build.acpmux_states = original_system, original_states

    def test_parse_ps_keeps_spaces_in_commands(self):
        rows = dev_build.parse_ps("  1     0 /sbin/launchd\n 42 1 /a b/cmux DEV t.app/Contents/MacOS/cmux DEV -psn\n 7 1 gone\nbad\n",
                                  "  1 /sbin/launchd\n 42 /a b/cmux DEV t.app/Contents/MacOS/cmux DEV\n")
        self.assertEqual(rows, [P(1, 0, "/sbin/launchd", "/sbin/launchd"),
                                P(42, 1, "/a b/cmux DEV t.app/Contents/MacOS/cmux DEV -psn", "/a b/cmux DEV t.app/Contents/MacOS/cmux DEV")])

    def test_reload_ends_the_old_tree_and_claims_for_the_launching_chat(self):
        reload = (ROOT / "scripts/reload.sh").read_text()
        self.assertIn('python3 "$SCRIPT_DIR/dev-build.py" stop --tag "$TAG_SLUG"', reload)
        self.assertIn('python3 "$SCRIPT_DIR/dev-build.py" claim --tag "$TAG_SLUG" --quiet', reload)
        self.assertIn('python3 "$SCRIPT_DIR/dev-build.py" stop --all-idle --except "$TAG_SLUG"', reload)


if __name__ == "__main__":
    sys.exit(unittest.main())
