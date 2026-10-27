#!/usr/bin/env python3
"""Offline tests of p15-oracle-096's e2e batch: its manifest and its four converted cases.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 5 item 4, and task p15-oracle-096 (MQ-e2e entries 45-55).
Stdlib only, Python 3.9+, safe under `python3 -I`.

- `tests/oracle/corpus/e2e/_scripts-096.json` names exactly the scripts at positions 45..55 of MQ-e2e
  (`ls scripts/cmux-next/*-e2e.py scripts/cmux-next/*-e2e.sh`, sorted), each converted (a case whose first step names
  the script, with the fix commit, its parent and the step `catches` names) or excluded with a reason.
- Each converted case runs through driver_app's real step runner against a fake app that answers only the facets the
  base build provides (AppServices+OracleHost.makeOracleFacets, plus the router's topology for snapshots only): a
  wait on topology or an unprovided facet is refused, as OracleSettleControl refuses it.
- The case passes against the fake head. Against a fake of the parent behavior the manifest describes, a `failure`
  catch ends the run Failure or Timeout at the `catches` step, and a `baseline` catch passes but records a different
  snapshot there. That shows the case tells the two apart. It is NOT the task's acceptance (red on the real parent):
  the parents predate debug.oracle.*, so that run waits for p15-oracle-202's overlay (the manifest's `red_on_parent`).

Chrome reference (chromium/src): third_party/blink/web_tests/TestExpectations keeps a reason on every test that does
not run; the manifest does the same for the scripts that do not convert.

    python3 -I scripts/cmux-next/oracle/e2e_096_cases_test.py
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import driver_app  # noqa: E402
import driver_app_test  # noqa: E402

REPO = HERE.parents[2]
SUITE = REPO / "tests" / "oracle" / "corpus" / "e2e"
MANIFEST = SUITE / "_scripts-096.json"
SHA = re.compile(r"^[0-9a-f]{40}$")

# The facets the base build's makeOracleFacets list provides, and the router's topology (debug.oracle.snapshot only).
SNAPSHOT_PROVIDED = ("topology", "focus", "layout", "tabs", "overlays", "settings", "intents", "windows", "history",
                     "notifications", "agents", "terminals", "webviews", "ax", "crashes", "liveObjects", "invariants")
# The provided facets wait_for answers: the settle control's list (no topology), read on the main actor or with their
# own change signal (OracleFacets.signalsChanges).
WAITABLE = ("focus", "layout", "tabs", "overlays", "settings", "windows", "invariants", "intents", "notifications",
            "liveObjects")


def mq_e2e() -> List[str]:
    """MQ-e2e: the e2e scripts in `ls` order, repo-relative."""
    scripts = REPO / "scripts" / "cmux-next"
    return sorted(f"scripts/cmux-next/{p.name}" for pattern in ("*-e2e.py", "*-e2e.sh") for p in scripts.glob(pattern))


def manifest() -> Dict[str, Any]:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


def converted() -> Dict[str, Dict[str, Any]]:
    return {e["case"]: e for e in manifest()["scripts"].values() if "case" in e}


def catches_step(entry: Mapping[str, Any]) -> str:
    return entry["catches"].split(":")[0]


def load(case_id: str) -> Dict[str, Any]:
    return json.loads((SUITE / f"{case_id.split('/')[1]}.json").read_text(encoding="utf-8"))


class ScriptedApp(driver_app_test.FakeApp):
    """A small model of the facets the cases read; a behavior sets the per-action and per-key answers."""

    def __init__(self, app: str, out: Path, env: Mapping[str, str]):
        super().__init__(app, out, env)
        self.names: List[str] = ["workspace-1"]
        self.shown = 0
        self.unread: Dict[str, int] = {}
        self.refused = 0
        self.hud = False
        self.panes: List[Dict[str, Any]] = [{"pane": "pane_1", "tabs": [("tab_1", "terminal")]}]
        self.focused = ("pane_1", "tab_1", "terminal")
        self.actions: Dict[str, Callable[[Dict[str, Any]], Dict[str, Any]]] = {}
        self.keys: Dict[str, Callable[[], Optional[str]]] = {}
        self.cli: Dict[str, Callable[[List[str]], Any]] = {}

    def ws(self, index: int) -> str:
        return f"ws_{index + 1}"

    def model(self) -> Dict[str, Any]:
        pane, tab, resolved = self.focused
        workspaces = [{"id": self.ws(i), "name": n, "unread": self.unread.get(self.ws(i), 0)}
                      for i, n in enumerate(self.names)]
        return {
            "topology": {"topology": {"workspaces": workspaces, "focus": {"workspace": self.ws(self.shown)}},
                         "tab_count": sum(len(p["tabs"]) for p in self.panes)},
            "focus": {"windows": [{"model": {"pane": pane, "resolved": resolved, "resolvedPane": pane,
                                             "resolvedTab": tab}}]},
            "layout": {"screens": [{"workspace": self.ws(self.shown), "panes": [p["pane"] for p in self.panes]}]},
            "tabs": {"panes": [{"pane": p["pane"], "tabs": [t for t, _ in p["tabs"]]} for p in self.panes]},
            "intents": {"pending": [], "totals": {"applied": 0, "rolledBack": 0, "refused": self.refused}},
            "overlays": {"stack": [{"kind": "refusalHud", "window": None}] if self.hud else []},
            "notifications": {"unread": sum(self.unread.values()),
                              "workspaces": [{"workspace": w, "unread": u} for w, u in sorted(self.unread.items())]},
            "liveObjects": {"workspaceModels": len(self.names)},
        }

    def facet(self, name: str) -> Any:
        if name in SNAPSHOT_PROVIDED:
            return self.model().get(name, {"value": name})
        return {"status": "not-comparable", "reason": f"no provider for {name} in this build", "task": "t"}

    def m_debug_oracle_snapshot(self, params):
        if params.get("list"):
            return {"ok": True, "result": [{"facet": f, "provided": f in SNAPSHOT_PROVIDED, "task": "t"}
                                           for f in driver_app.FACETS if f != "daemon"]}
        return {"ok": True, "result": {f: self.facet(f) for f in params["facets"]}}

    def m_debug_oracle_wait_for(self, params):
        facet = driver_app.decode_pointer(params["pointer"])[0]
        if facet not in WAITABLE:
            return {"ok": False, "error": {"code": "unavailable", "message": f"no provider for facet {facet}"}}
        value = driver_app.resolve_pointer(self.model(), params["pointer"])
        value = None if value is driver_app.MISSING else value
        predicate = params.get("predicate")
        if "equals" in params:
            ok = value == params["equals"]
        elif predicate == "changed":
            ok = value != params["since"]
        elif predicate == "empty":
            ok = value == [] or value == {}
        else:
            ok = value is not None
        return {"ok": True, "result": {"satisfied": ok, "value": value, "evaluations": 1, "elapsed_ms": 1}}

    def m_action_run(self, params):
        handler = self.actions.get(params["action"])
        if handler is None:
            return {"ok": False, "error": {"code": "not_found", "message": params["action"]}}
        self.sequence += 1
        reply = {"action": params["action"], "ran": True, "waited": True, "args": params["args"],
                 "created": [], "sequence": self.sequence}
        reply.update(handler(params))
        return {"ok": True, "result": reply}

    def m_debug_key(self, params):
        stroke = "+".join([*params["modifiers"], params["key"]])
        handler = self.keys.get(stroke)
        if handler is None:
            return {"ok": True, "result": {"handled_by": "responder", "action": None, "window_kind": "shell"}}
        self.sequence += 1
        return {"ok": True, "result": {"handled_by": "app", "window_kind": "shell", "action": handler()}}

    # -- model edits the behaviors compose

    def add_workspace(self, name: str) -> Dict[str, Any]:
        self.names.append(name)
        return {"created": [self.ws(len(self.names) - 1)]}

    def split(self, resolved: str) -> None:
        pane, tab = f"pane_{self.sequence}", f"tab_{self.sequence}"
        self.panes.append({"pane": pane, "tabs": [(tab, resolved)]})
        self.focused = (pane, tab, resolved)

    def add_tab(self, resolved: str) -> None:
        tab = f"tab_{self.sequence}"
        next(p for p in self.panes if p["pane"] == self.focused[0])["tabs"].append((tab, resolved))
        self.focused = (self.focused[0], tab, resolved)


def rapid_workspace(app: ScriptedApp, parent: bool) -> None:
    started = [len(app.names)]

    def create() -> str:
        # 21b316fd4d3: every create starts at once, so a create its close outran still takes a number: gaps. In a
        # lane (951211aeb48) a create a close took before it started never runs, so the numbers stay consecutive.
        started[0] += 1
        number = started[0] if parent else len(app.names) + 1
        app.names.append(f"workspace-{number}")
        app.shown = len(app.names) - 1
        return "newTab"

    def close() -> str:
        if parent and app.sequence % 6 == 0:
            # A close pressed before its workspace was mirrored took the one the window still showed, and a later
            # close of the gone workspace was refused ("no workspace <uuid>").
            app.names.pop(app.shown - 1)
            app.refused += 1
            app.hud = True
        else:
            app.names.pop(app.shown)
        app.shown = len(app.names) - 1
        return "closeWorkspace"

    app.keys["cmd+n"] = create
    app.keys["cmd+shift+w"] = close


def sidebar_archive(app: ScriptedApp, parent: bool) -> None:
    app.actions["newTab"] = lambda p: app.add_workspace(p["args"]["name"])
    app.actions["workspace.moveToNewGroup"] = lambda p: {}
    app.actions["workspace.newBelow"] = lambda p: app.add_workspace(f"workspace-{len(app.names) + 1}")
    if parent:
        return  # 0498645db2e has no archive actions
    app.actions["workspace.toggleArchive"] = lambda p: {}
    app.actions["workspaceGroup.toggleArchive"] = lambda p: {}


def sidebar_notification(app: ScriptedApp, parent: bool) -> None:
    app.actions["newTab"] = lambda p: app.add_workspace(p["args"]["name"])

    def notify(words: List[str]) -> Any:
        workspace = words[words.index("--workspace") + 1]
        if not workspace.startswith("ws_"):
            raise ValueError(f"notify --workspace {workspace}: not a ws_ id")
        app.unread[workspace] = app.unread.get(workspace, 0) + 1
        return {"ok": True}

    app.cli["notify"] = notify
    app.cli["snapshot.get"] = lambda words: app.model()["topology"]


def split_new_tab_page(app: ScriptedApp, parent: bool) -> None:
    def split() -> str:
        # b945566eb87: every split opens a terminal; cx-jfo7 opens the New Tab page from a browser tab, the page or a chat.
        source = app.focused[2]
        app.split("agentPage" if not parent and source in ("browserPage", "addressBar", "agentPage") else "terminal")
        return "splitRight"

    def new_tab_page() -> str:
        app.add_tab("agentPage")
        return "newTab.default"

    def browser() -> str:
        app.add_tab("addressBar")
        return "openBrowser"

    def chat() -> str:
        app.add_tab("agentPage")
        return "palette.newAgentChat"

    def open_tab(words: List[str]) -> Any:
        if app.focused[2] != "agentPage":
            raise ValueError("debug.new_tab open_tab: the focused tab is no New Tab page")
        pane = next(p for p in app.panes if p["pane"] == app.focused[0])
        pane["tabs"] = [("tab_1", "terminal")]
        app.panes[0]["tabs"] = [t for t in app.panes[0]["tabs"] if t[0] != "tab_1"] or [("tab_x", "terminal")]
        app.focused = (pane["pane"], "tab_1", "terminal")
        return {"moved": "tab_1"}

    app.keys["cmd+d"] = split
    app.keys["cmd+t"] = new_tab_page
    app.keys["cmd+shift+l"] = browser
    app.keys["cmd+i"] = chat
    app.cli["debug.new_tab"] = open_tab


# This batch's converted cases, by case id: the head behavior and the parent behavior the manifest describes.
BEHAVIOR: Dict[str, Callable[[ScriptedApp, bool], None]] = {
    "e2e/rapid-workspace": rapid_workspace,
    "e2e/sidebar-archive": sidebar_archive,
    "e2e/sidebar-notification": sidebar_notification,
    "e2e/split-new-tab-page": split_new_tab_page,
}


class CliRunner:
    """subprocess.run for cli steps: `cmux --app-socket PATH [--json] <verb ...>` answered by the behavior's cli
    handlers, keyed by the verb (`notify`) or the `app call` method."""

    def __init__(self, apps: List[ScriptedApp]):
        self.apps = apps

    def __call__(self, argv, **kwargs):
        words = [w for w in list(argv)[3:] if w != "--json"]
        key = words[2] if words[:2] == ["app", "call"] else words[0]
        handler = self.apps[-1].cli.get(key)
        if handler is None:
            return subprocess.CompletedProcess(argv, 2, "", f"unknown cli {words}")
        try:
            return subprocess.CompletedProcess(argv, 0, json.dumps(handler(words)), "")
        except ValueError as error:
            return subprocess.CompletedProcess(argv, 1, json.dumps({"error": {"code": "usage", "message": str(error)}}),
                                               "")


def run_as(case_id: str, parent: bool, out: str, case: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    apps: List[ScriptedApp] = []

    def make(app, out_dir, env):
        fake = ScriptedApp(app, out_dir, env)
        BEHAVIOR[case_id](fake, parent)
        apps.append(fake)
        return fake

    ctx = {"run_id": "r", "product": "app", "build": "bench", "binary": driver_app_test.APP, "out_dir": out}
    session = driver_app.AppSession(ctx, make_app=make, identity=driver_app_test.identity,
                                    canonicalizer=driver_app_test.identity_canonicalizer(), run=CliRunner(apps),
                                    host=lambda: {"os": "macOS 26.1", "arch": "arm64", "model": "Mac16,10"},
                                    root_base=Path(out) / "o")
    try:
        return session.run_case(case or load(case_id), {"case_id": case_id})
    finally:
        session.close()


def facets_at(result: Mapping[str, Any], step: str) -> List[Any]:
    """The recorded facet values of `step`'s checkpoints (the meta holds times and the run's sha)."""
    return [c["snapshot"]["facets"] for c in result["checkpoints"] if c["step"] == step]


class ManifestTest(unittest.TestCase):
    def test_manifest_covers_its_range_with_a_case_or_a_reason(self) -> None:
        batch = manifest()
        first, last = batch["range"]
        self.assertEqual((first, last), (45, 55), "p15-oracle-096 converts MQ-e2e entries 45-55")
        self.assertEqual(sorted(batch["scripts"]), mq_e2e()[first - 1:last], "the scripts at positions 45-55")
        self.assertIn("p15-oracle-202", batch.get("red_on_parent", ""), "say how and when red on parent is run")
        for script, entry in batch["scripts"].items():
            with self.subTest(script=script):
                self.assertTrue((REPO / script).is_file(), "the script stays")
                if "excluded" in entry:
                    self.assertNotIn("case", entry)
                    self.assertGreaterEqual(len(entry["excluded"]), 60, "say why it does not convert")
                    continue
                for key in ("case", "fix", "parent", "cited", "catches"):
                    self.assertIn(key, entry, key)
                self.assertRegex(entry["fix"], SHA)
                self.assertRegex(entry["parent"], SHA)
                case = load(entry["case"])
                self.assertEqual(f"{case['suite']}/{case['id']}", entry["case"])
                self.assertIn(script, case["steps"][0].get("note", ""), "its first step names the script")
                if entry["catches"] is None:
                    self.assertGreaterEqual(len(entry.get("gap", "")), 60, "catches null needs the gap")
                    continue
                self.assertIn(entry.get("shows"), ("failure", "baseline"))
                self.assertIn(catches_step(entry), [s["id"] for s in case["steps"]], "catches names a step")

    def test_cases_read_only_facets_the_base_provides(self) -> None:
        for case_id in converted():
            for step in load(case_id)["steps"]:
                with self.subTest(case=case_id, step=step["id"]):
                    for facet in (step.get("args") or {}).get("facets") or ():
                        self.assertIn(facet, SNAPSHOT_PROVIDED, "a snapshot of an unprovided facet is not-comparable")
                    if "waitFor" in step:
                        facet = driver_app.decode_pointer(step["waitFor"]["pointer"])[0]
                        self.assertIn(facet, WAITABLE, "wait_for refuses topology and facets with no change signal")

    def test_every_converted_case_has_a_behavior(self) -> None:
        self.assertEqual(sorted(converted()), sorted(BEHAVIOR))


class ConvertedCaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_each_case_passes_on_the_base_builds_facets(self) -> None:
        for case_id in BEHAVIOR:
            with self.subTest(case=case_id):
                head = run_as(case_id, False, self.tmp.name)
                self.assertEqual(head["status"], "Pass", head.get("message"))

    def test_each_case_tells_the_described_parent_behavior_apart_at_catches(self) -> None:
        for case_id, entry in converted().items():
            if entry["catches"] is None:
                continue
            with self.subTest(case=case_id):
                step = catches_step(entry)
                parent = run_as(case_id, True, self.tmp.name)
                if entry["shows"] == "failure":
                    self.assertIn(parent["status"], ("Failure", "Timeout"), parent.get("message"))
                    self.assertEqual(parent.get("step"), step, parent.get("message"))
                else:
                    head = run_as(case_id, False, self.tmp.name)
                    self.assertEqual(parent["status"], "Pass", parent.get("message"))
                    self.assertTrue(facets_at(head, step), f"{step} records a snapshot")
                    self.assertNotEqual(facets_at(parent, step), facets_at(head, step))

    def test_the_same_case_twice_records_the_same_facets(self) -> None:
        for case_id in BEHAVIOR:
            with self.subTest(case=case_id):
                first, second = (run_as(case_id, False, self.tmp.name) for _ in range(2))
                self.assertEqual([facets_at(first, c["step"]) for c in first["checkpoints"]],
                                 [facets_at(second, c["step"]) for c in second["checkpoints"]])

    def test_a_wait_on_topology_is_refused(self) -> None:
        """The guard behind the cases' waits: OracleSettleControl's facet list has no topology, so a wait on it
        crashes the case (the topology is a snapshot-only facet)."""
        case = load("e2e/split-new-tab-page")
        step = next(s for s in case["steps"] if s["id"] == "split-terminal")
        step["waitFor"] = {"pointer": "/topology/tab_count", "predicate": "changed", "maxMs": 1000}
        result = run_as("e2e/split-new-tab-page", False, self.tmp.name, case=case)
        self.assertEqual(result["status"], "Crash", result.get("message"))
        self.assertEqual(result.get("step"), "split-terminal")


if __name__ == "__main__":
    unittest.main()
