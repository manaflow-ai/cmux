#!/usr/bin/env python3
"""Compile the real `cmux agents` command with a fake socket and exercise it without an app build."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def item(ref, label, agents, placement=("local", "local"), cwd="/work/cmux", attention=(), prs=()):
    return {
        "resource_ref": ref,
        "label": label,
        "kind": "terminal",
        "placement": {"kind": placement[0], "machine": placement[1]},
        "projections": [{"resource_ref": ref, "workspace_id": "ws-" + ref[-1], "panel_id": "panel-" + ref[-1]}],
        "cwd": cwd,
        "agents": list(agents),
        "attention": [{"kind": kind} for kind in attention],
        "pull_requests": list(prs),
    }


def agent(kind, state, session, last="2026-09-28T09:00:00Z"):
    return {"kind": kind, "state": state, "session_id": session, "last_activity_at": last}


SNAPSHOT = {
    "schema_version": 1,
    "observed_at": "2026-09-28T09:05:00Z",
    "truncated": False,
    "owner_availability": {"agent_sessions": "available"},
    "items": [
        item("local/browser/b", "Docs", []),
        item("local/terminal/a", "Review outside PR 6923",
             [agent("claude", "working", "aaaaaaaa-1111", "2026-09-28T09:01:00Z")], prs=[{"number": 6923, "status": "open"}]),
        item("local/terminal/c", "Fix focus flicker",
             [agent("claude", "needs_input", "cccccccc-3333")], attention=["unread"]),
        item("local/terminal/d", "Review sidebar PR",
             [agent("claude", "working", "dddddddd-4444", "2026-09-28T09:04:00Z"),
              agent("claude", "ended", "dddddddd-0000", "2026-09-27T09:00:00Z")]),
        item("vm-47d0/terminal/term_e", "codex pilot",
             [agent("codex", "idle", "eeeeeeee-5555")], placement=("cloud", "vm-47d0"), cwd="/home/cmux"),
        item("vm-47d043680f5640e0a6b812d34e309afb/terminal/term_g", "",
             [{"kind": "hook", "state": "idle"}], placement=("cloud", "vm-47d043680f5640e0a6b812d34e309afb"), cwd="/home/cmux"),
        item("local/terminal/f", "Old session",
             [agent("claude", "ended", "ffffffff-6666")]),
    ],
}


class AgentsCommandFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        state = ROOT / ".local"
        state.mkdir(exist_ok=True)
        cls.temp = tempfile.TemporaryDirectory(prefix="agents-cli-fixture-", dir=state)
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / "agents-fixture"
        build = subprocess.run([
            "xcrun", "swiftc", "-o", str(cls.binary), "-module-cache-path", str(Path(cls.temp.name) / "cache"),
            str(ROOT / "CLI/CLIError.swift"), str(ROOT / "CLI/CMUXCLI+Agents.swift"),
            str(ROOT / "CLI/CMUXCLI+WindowDispatch.swift"), str(ROOT / "tests/fixtures/AgentsCommandFixture.swift"),
        ], capture_output=True, text=True, timeout=120)
        if build.returncode:
            raise RuntimeError(build.stderr)

    def invoke(self, *args, payload=None):
        return subprocess.run([str(self.binary), *args], input=json.dumps(SNAPSHOT if payload is None else payload),
                              text=True, capture_output=True, timeout=5)

    def calls(self, result):
        return [json.loads(line) for line in result.stderr.splitlines() if line.startswith("{")]

    def test_json_rows_are_agent_keyed_ordered_and_hide_ended(self):
        result = self.invoke("--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["schema_version"], 1)
        rows = payload["agents"]
        self.assertEqual([row.get("session_id") for row in rows],
                         ["cccccccc-3333", "dddddddd-4444", "aaaaaaaa-1111", "eeeeeeee-5555", None])
        untitled = rows[-1]
        self.assertEqual(untitled["name"], "term_g")
        self.assertEqual(untitled["agent"], "unknown")
        cloud = rows[-2]
        self.assertEqual(cloud["placement"], {"kind": "cloud", "machine": "vm-47d0"})
        self.assertEqual(cloud["resource_ref"], "vm-47d0/terminal/term_e")
        self.assertEqual(rows[2]["pull_requests"][0]["number"], 6923)
        self.assertEqual(rows[0]["attention"], ["unread"])
        self.assertEqual(self.calls(result), [{"method": "current.list", "params": {"limit": 200}}])

    def test_all_and_state_filters(self):
        rows = json.loads(self.invoke("--all", "--json").stdout)["agents"]
        self.assertEqual(len(rows), 7)
        self.assertEqual(rows[-1]["state"], "ended")
        only = json.loads(self.invoke("--state", "needs-input", "--state=idle", "--json").stdout)["agents"]
        self.assertEqual({row["state"] for row in only}, {"needs_input", "idle"})

    def test_text_is_one_line_per_agent_with_hints(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertRegex(lines[0], r"^needs_input  claude +Fix focus flicker +local  /work/cmux$")
        self.assertIn("cloud:vm-47d0 ", result.stdout)
        self.assertIn("cloud:vm-47d043680f56…", result.stdout)
        self.assertRegex(result.stdout, r"idle +unknown  term_g ")
        self.assertIn("#6923", result.stdout)
        self.assertIn("--all shows them", result.stdout)
        self.assertIn("cmux agents open", result.stdout)
        self.assertNotIn("Docs", result.stdout)

    def test_open_resolves_by_unique_name_part_and_projects_with_focus(self):
        result = self.invoke("open", "FOCUS")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(result)[-1],
                         {"method": "surface.project", "params": {"resource": "local/terminal/c", "focus": True}})
        self.assertIn("Fix focus flicker", result.stdout)

    def test_open_by_session_prefix_and_resource_ref(self):
        by_prefix = self.calls(self.invoke("open", "eeeeeeee"))[-1]
        self.assertEqual(by_prefix["params"]["resource"], "vm-47d0/terminal/term_e")
        by_ref = self.calls(self.invoke("open", "local/terminal/f"))[-1]
        self.assertEqual(by_ref["params"]["resource"], "local/terminal/f")

    def test_open_counts_one_terminal_once_and_refuses_ambiguity(self):
        # Two agent records on local/terminal/d are one candidate, not an ambiguity.
        single = self.invoke("open", "sidebar")
        self.assertEqual(single.returncode, 0, single.stderr)
        ambiguous = self.invoke("open", "review")
        self.assertNotEqual(ambiguous.returncode, 0)
        self.assertIn("more than one agent", ambiguous.stderr)
        self.assertIn("local/terminal/a", ambiguous.stderr)
        self.assertIn("local/terminal/d", ambiguous.stderr)
        self.assertNotIn("surface.project", ambiguous.stderr)
        missing = self.invoke("open", "nothing like this")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("no agent matches", missing.stderr)

    def test_bad_arguments_never_dispatch(self):
        for args in (("--state", "busy"), ("--state",), ("--refresh",), ("open",), ("kill", "x"), ("ls", "extra")):
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("agents:", result.stderr)
                self.assertEqual(self.calls(result), [])

    def test_listing_never_prefocuses_a_window(self):
        self.assertEqual(self.invoke("focus", "agents").stdout.strip(), "false")
        self.assertEqual(self.invoke("focus", "agents", "open", "x").stdout.strip(), "false")

    def test_empty_malformed_and_control_characters(self):
        self.assertIn("No agents observed", self.invoke(payload={"items": []}).stdout)
        malformed = self.invoke(payload={})
        self.assertNotEqual(malformed.returncode, 0)
        self.assertIn("invalid response", malformed.stderr)
        payload = json.loads(json.dumps(SNAPSHOT))
        payload["items"][2]["label"] = "evil\nrow\x1b[2J"
        text = self.invoke(payload=payload).stdout
        self.assertIn("evil row [2J", text)
        self.assertNotIn("\x1b", text)


if __name__ == "__main__":
    unittest.main()
