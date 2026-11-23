#!/usr/bin/env python3
"""scripts/cmux-next/owner_live.py and guardrails.owner_route: an OWNERS.md owner resolves to a live session.

The regression: cmux#50549's push into cmux-tui/crates/acpmux/ printed "owner PL-acpmux (session cmux-4f; lead
decision 2026-10-23)" on 2026-11-22, a month after cmux-4f had ended; the warning reached no one. Now the owner cell
resolves at push time (an `owns=` holder, the named session, its successor, the Performance Lead, the coordinator)
and that live session is sent one notice per area and pushed head.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent


def _load(name, rel):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


live = _load("cmux_next_owner_live", "scripts/cmux-next/owner_live.py")
CELL = "PL-acpmux (session cmux-4f; lead decision 2026-10-23)"


def row(name, status="idle", sid=None, updated=1, **tags):
    return {"name": name, "status": status, "sessionId": sid or f"id-{name}", "updatedAt": updated, "tags": tags or None}


class Holder(unittest.TestCase):
    def test_the_cell_of_2026_11_22_names_a_workstream_and_a_session(self):
        self.assertEqual(live.cell_names(CELL), (["PL-acpmux"], ["cmux-4f"]))
        self.assertEqual(live.cell_names("a590 (sidebar-owner agent)"), ([], []))

    def test_an_owns_tag_wins_over_the_named_session(self):
        rows = [row("host-a/cmux-4f"), row("host-b/acpmux-keeper", owns="PL-daemon,PL-acpmux")]
        self.assertEqual(live.holder(CELL, rows, ""), ("host-b/acpmux-keeper", "holds owns=PL-acpmux"))

    def test_the_named_session_while_it_is_live(self):
        self.assertEqual(live.holder(CELL, [row("host-a/cmux-4f", "running")], ""), ("host-a/cmux-4f", "named"))

    def test_a_gone_session_falls_to_its_successor_chain(self):
        rows = [row("host-a/cmux-4f", "closed", sid="A"),
                row("host-c/cmux-4f-2", "closed", sid="B", succeeds="A"),
                row("host-c/cmux-4f-3", "ready", sid="C", succeeds="B")]
        self.assertEqual(live.holder(CELL, rows, ""), ("host-c/cmux-4f-3", "successor of cmux-4f"))
        failover = [row("host-a/cmux-4f", "closed", failover="host-d/acpmux-next"), row("host-d/acpmux-next")]
        self.assertEqual(live.holder(CELL, failover, "")[0], "host-d/acpmux-next")

    def test_a_successor_loop_ends(self):
        rows = [row("x/cmux-4f", "closed", sid="A", failover="x/b"), row("x/b", "closed", sid="B", failover="x/cmux-4f")]
        self.assertEqual(live.successor(rows, "cmux-4f"), None)

    def test_no_successor_goes_to_the_performance_lead_then_the_coordinator(self):
        gone = [row("host-a/cmux-4f", "closed")]
        self.assertEqual(live.holder(CELL, gone + [row("h/perf", owns="PL-lead")], "")[0], "h/perf")
        who, how = live.holder(CELL, gone + [row("host-a/coordinator", "running")], "host-a/coordinator")
        self.assertEqual(who, "host-a/coordinator")
        self.assertIn("cmux-4f gone; the coordinator", how)
        self.assertEqual(live.holder(CELL, gone, "host-a/coordinator"),
                         (None, "cmux-4f gone; no live lead or coordinator"))

    def test_a_stale_row_is_not_live(self):
        self.assertFalse(live.is_live({"name": "a/b", "status": "idle", "stale": True}))
        self.assertTrue(live.is_live({"name": "a/b", "status": "idle", "stale": None}))

    def test_the_registry_coordinator_follows_retired_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "r.json"
            path.write_text(json.dumps({"coordinators": {"current": "c/old", "retired": {"c/old": "c/new"}}}))
            self.assertEqual(live.registry_coordinator(path), "c/new")
            path.write_text("{")
            self.assertIsNone(live.registry_coordinator(path))


class Notify(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {"CMUX_OWNER_NOTICES": str(Path(self.tmp.name) / "n.json")})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_one_notice_per_holder_area_and_head(self):
        ok = types.SimpleNamespace(returncode=0, stdout="id", stderr="")
        with mock.patch.object(live.subprocess, "run", return_value=ok) as run:
            self.assertIsNone(live.notify("h/s", "acpmux", "a" * 40, "text"))
            self.assertIsNone(live.notify("h/s", "acpmux", "a" * 40, "text"))
            self.assertIsNone(live.notify("h/s", "acpmux", "b" * 40, "text"))
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args.args[0], ["acpmux", "send", "--no-wait", "--class", "action", "h/s", "-"])

    def test_a_refused_send_is_named_and_retried_next_push(self):
        bad = types.SimpleNamespace(returncode=1, stdout="", stderr="no session h/s")
        with mock.patch.object(live.subprocess, "run", return_value=bad) as run:
            self.assertIn("no session h/s", live.notify("h/s", "acpmux", "a" * 40, "t"))
            live.notify("h/s", "acpmux", "a" * 40, "t")
        self.assertEqual(run.call_count, 2)

    def test_opt_out_sends_nothing(self):
        with mock.patch.dict(os.environ, {"CMUX_OWNER_NOTIFY": "0"}), mock.patch.object(live.subprocess, "run") as run:
            self.assertEqual(live.notify("h/s", "a", "h", "t"), "CMUX_OWNER_NOTIFY=0")
        run.assert_not_called()

    def test_ci_lists_nothing(self):
        with mock.patch.dict(os.environ, {"CI": "true"}):
            self.assertEqual(live.list_sessions(), (None, None))


class Route(unittest.TestCase):
    """guardrails.owner_route over a real commit: the push into the acpmux crate reaches the live holder."""

    def test_a_push_into_pl_acpmux_reaches_a_live_session(self):
        guardrails = _load("cmux_next_guardrails_owner_live_test", "scripts/cmux-next/guardrails.py")
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name)
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@t"}

        def git(*args):
            return subprocess.run(["git", *args], cwd=repo, env=env, check=True, capture_output=True,
                                  text=True).stdout.strip()

        git("init", "-q", "-b", "main")
        owners = repo / "plans/cmux-next/OWNERS.md"
        owners.parent.mkdir(parents=True)
        owners.write_text("| Area | Paths | Owner | Read first |\n|---|---|---|---|\n"
                          f"| acpmux daemon | `cmux-tui/crates/acpmux/` | {CELL} | [acpmux-audit.md](acpmux-audit.md) |\n")
        git("add", "-A")
        git("commit", "-qm", "base")
        base = git("rev-parse", "HEAD")
        crate = repo / "cmux-tui/crates/acpmux/src/lib.rs"
        crate.parent.mkdir(parents=True)
        crate.write_text("// change\n")
        git("add", "-A")
        git("commit", "-qm", "change")
        head = git("rev-parse", "HEAD")
        own = types.SimpleNamespace(base=base, head=head)
        rows = [row("host-a/cmux-4f", "closed"), row("host-a/coordinator", "running")]
        sent = []
        with mock.patch.object(live, "notify", side_effect=lambda *a: sent.append(a)):
            lines = guardrails.owner_route(repo, [own], (rows, None), "host-a/coordinator")
        self.assertEqual(len(lines), 1, lines)
        self.assertIn("acpmux daemon is held by host-a/coordinator (cmux-4f gone; the coordinator)", lines[0])
        # The coordinator stands in: one notice an area a UTC day, asking for a holder, not one per push.
        (to, area, key, text), = sent
        self.assertEqual((to, area), ("host-a/coordinator", "acpmux daemon"))
        self.assertRegex(key, r"^day \d{4}-\d\d-\d\d$")
        self.assertIn("has no live holder", text)
        self.assertIn("cmux-tui/crates/acpmux/src/lib.rs", text)
        # A holder that took the workstream hears of each pushed head.
        rows.append(row("host-b/acpmux-keeper", owns="PL-acpmux"))
        sent.clear()
        with mock.patch.object(live, "notify", side_effect=lambda *a: sent.append(a)):
            lines = guardrails.owner_route(repo, [own], (rows, None), "host-a/coordinator")
        self.assertIn("held by host-b/acpmux-keeper (holds owns=PL-acpmux); told of this push", lines[0])
        self.assertEqual(sent[0][:3], ("host-b/acpmux-keeper", "acpmux daemon", head))


if __name__ == "__main__":
    unittest.main()
