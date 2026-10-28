#!/usr/bin/env python3
"""Offline tests of p15-oracle-093's e2e batch: its manifest and its three converted cases.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 5 item 4, and task p15-oracle-093 (MQ-e2e entries 12-22).
Stdlib only, Python 3.9+, safe under `python3 -I`.

- `tests/oracle/corpus/e2e/_scripts-093.json` names exactly the scripts at positions 12..22 of MQ-e2e
  (`ls scripts/cmux-next/*-e2e.py scripts/cmux-next/*-e2e.sh`, sorted), each converted (a case whose first step names
  the script, with the fix commit, its parent and the step `catches` names) or excluded with a reason. The checks
  read only this batch's file and cases: the sibling batches (092, 094-097) keep their own manifests.
- Each converted case runs through driver_app's real step runner against a fake app that offers only the facets
  the base build has providers for (AppServices+OracleHost.makeOracleFacets): a wait on another facet is refused, as
  OracleSettleControl refuses it, and a snapshot answers it not-comparable. A static check also refuses a case whose
  own snapshot or wait names such a facet, so a case that leans on an unlanded facet fails here.
- The case passes against the fake head. Against a fake of the parent behavior the manifest describes, it fails
  at the `catches` step. That shows the case's assertion tells the two behaviors apart. It is NOT the task's
  acceptance (red on the real parent commit): the parents predate debug.oracle.*, so that run waits for the
  overlay of p15-oracle-202 (the manifest's `red_on_parent`).

Chrome reference (chromium/src): third_party/blink/web_tests/TestExpectations keeps a reason on every test that does
not run; the manifest does the same for scripts that do not convert.

    python3 -I scripts/cmux-next/oracle/e2e_093_cases_test.py
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
MANIFEST = SUITE / "_scripts-093.json"
SHA = re.compile(r"^[0-9a-f]{40}$")

# The facets the base build's makeOracleFacets list provides; `debug.oracle.snapshot` adds the router's topology
# (OracleControl), `debug.oracle.wait_for` does not (AppControl+Barrier passes the list as is). No sidebar
# (p15-oracle-036) and no switches (p15-oracle-027) provider yet.
SNAPSHOT_PROVIDED = ("topology", "focus", "layout", "tabs", "overlays", "settings", "intents", "windows", "history",
                     "notifications", "agents", "terminals", "webviews", "ax", "crashes", "liveObjects", "invariants")
# The provided facets wait_for can wait on: read on the main actor, or with their own change signal.
WAITABLE = ("focus", "layout", "tabs", "overlays", "settings", "windows", "invariants")


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


class ScriptedApp(driver_app_test.FakeApp):
    """The facets a case reads, as a small model of the base build, and per-method answers a behavior sets."""

    def __init__(self, app: str, out: Path, env: Mapping[str, str]):
        super().__init__(app, out, env)
        self.model: Dict[str, Any] = {
            "topology": {"topology": {"workspaces": [{"id": "ws_1", "panes": 1}], "focus": {"workspace": "ws_1"},
                                      "loaded": True}, "tab_count": 1},
            "focus": {"windows": [{"model": {"pane": "pane_1"}}], "paletteOpen": False},
            "layout": {"screens": [{"workspace": "ws_1", "root": {"kind": "leaf", "pane": "pane_1"}}]},
            "tabs": {"panes": []},
            "overlays": {"stack": [], "palette": {"open": False}},
            "settings": {"effectiveSha256": "0" * 64, "nonDefaultKeys": []},
        }
        self.actions: Dict[str, Callable[["ScriptedApp", Dict[str, Any]], Dict[str, Any]]] = {}
        self.keys: Dict[str, Callable[["ScriptedApp"], Dict[str, Any]]] = {}
        self.shown = "ws_1"

    @staticmethod
    def unavailable(facet: str) -> Dict[str, Any]:
        return {"ok": False, "error": {"code": "unavailable", "message": f"no provider for facet {facet} in this build"}}

    def m_debug_oracle_snapshot(self, params):
        if params.get("list"):
            return {"ok": True, "result": [{"facet": f, "provided": f in SNAPSHOT_PROVIDED, "task": "t"}
                                           for f in driver_app.FACETS if f != "daemon"]}
        # As OracleFacets answers: a facet with no provider is not-comparable, never absent. A case's own snapshot
        # step naming one is refused statically (test_cases_read_only_facets_the_base_provides).
        return {"ok": True, "result": {
            f: json.loads(json.dumps(self.model.get(f, {}))) if f in SNAPSHOT_PROVIDED
            else {"status": "not-comparable", "reason": f"no provider for {f} in this build", "task": "t"}
            for f in params["facets"]}}

    def m_debug_oracle_wait_for(self, params):
        facet = driver_app.decode_pointer(params["pointer"])[0]
        if facet not in WAITABLE:
            return self.unavailable(facet)
        value = driver_app.resolve_pointer(self.model, params["pointer"])
        value = None if value is driver_app.MISSING else value
        predicate = params.get("predicate")
        if "equals" in params:
            ok = value == params["equals"]
        elif predicate == "changed":
            ok = value != params["since"]
        elif isinstance(predicate, dict) and predicate["op"] == "contains":
            ok = isinstance(value, list) and predicate["value"] in value
        else:
            ok = value is not None
        return {"ok": True, "result": {"satisfied": ok, "value": value, "evaluations": 1, "elapsed_ms": 1}}

    def m_debug_oracle_recorder(self, params):
        if params.get("arm") is True and any(f not in SNAPSHOT_PROVIDED for f in params.get("facets") or ()):
            return {"ok": False, "error": {"code": "invalid_params", "message": "no provider"}}
        return super().m_debug_oracle_recorder(params)

    def m_action_run(self, params):
        handler = self.actions.get(params["action"])
        if handler is None:
            return {"ok": False, "error": {"code": "not_found", "message": params["action"]}}
        self.sequence += 1
        return handler(self, params)

    def m_debug_key(self, params):
        stroke = "+".join([*params["modifiers"], params["key"]])
        handler = self.keys.get(stroke)
        if handler is None:
            return {"ok": True, "result": {"handled_by": "responder", "action": None, "window_kind": "shell"}}
        self.sequence += 1
        return {"ok": True, "result": {"handled_by": "app", "window_kind": "shell", **handler(self)}}

    # -- model edits a behavior composes

    def ran(self, action: str, created=()) -> Dict[str, Any]:
        return {"ok": True, "result": {"action": action, "ran": True, "waited": True, "args": {},
                                       "created": list(created), "sequence": self.sequence}}

    def refused(self, code: str = "unavailable") -> Dict[str, Any]:
        return {"ok": False, "error": {"code": code, "message": "refused"}}

    def screen(self) -> Dict[str, Any]:
        return self.model["layout"]["screens"][0]

    def split(self) -> Dict[str, Any]:
        new = f"pane_{self.sequence}"
        self.model["focus"]["windows"][0]["model"]["pane"] = new
        self.screen()["root"] = {"kind": "split", "children": [self.screen()["root"], {"kind": "leaf", "pane": new}]}
        return {"action": "splitRight"}

    def dock(self, action: str) -> Dict[str, Any]:
        root = self.screen()["root"]
        self.screen()["root"] = {"kind": "strip", "dock": action, "children": [root["children"][0], root["children"][1]]}
        return self.ran(action)

    def new_workspace(self, action: str) -> Dict[str, Any]:
        # A socket run without focus files the workspace in the window and does not show it.
        new = f"ws_{self.sequence}"
        self.model["topology"]["topology"]["workspaces"].append({"id": new, "panes": 1})
        return self.ran(action, created=[new])

    def select_second(self) -> Dict[str, Any]:
        second = self.model["topology"]["topology"]["workspaces"][1]["id"]
        self.model["layout"]["screens"] = [{"workspace": second, "root": {"kind": "leaf", "pane": f"pane_{self.sequence}"}}]
        return {"action": "selectWorkspaceByNumber"}

    def set_setting(self, key: str, on: bool) -> None:
        keys = [k for k in self.model["settings"]["nonDefaultKeys"] if k != key] + ([key] if on else [])
        self.model["settings"]["nonDefaultKeys"] = keys
        self.model["settings"]["effectiveSha256"] = f"{len(keys):064x}"


def dock_split_pane(app: ScriptedApp, parent: bool) -> None:
    app.keys["cmd+d"] = ScriptedApp.split
    app.keys["cmd+2"] = ScriptedApp.select_second
    app.actions["workspace.newBelow"] = lambda a, p: a.new_workspace(p["action"])
    for action in ("column.dock", "column.dockLeft"):
        # cx-39lm's parent: the split pane's only tab left through its own pane and the daemon refused the move.
        app.actions[action] = (lambda a, p: {"ok": False, "error": {"code": "daemon_error",
                                                                     "message": "move-tab-to-column failed"}}) \
            if parent else (lambda a, p: a.dock(p["action"]))


def file_pages_r96(app: ScriptedApp, parent: bool) -> None:
    def open_picker(a: ScriptedApp, params: Dict[str, Any]) -> Dict[str, Any]:
        a.model["overlays"]["palette"]["open"] = True
        a.model["focus"]["paletteOpen"] = True
        return a.ran(params["action"])

    def directory_picker(a: ScriptedApp, params: Dict[str, Any]) -> Dict[str, Any]:
        if parent or params.get("origin") not in ("cli", "mcp", "script", "remote") or params.get("focus"):
            return open_picker(a, params)
        return a.refused()

    def diff(a: ScriptedApp, params: Dict[str, Any]) -> Dict[str, Any]:
        # openDiffViewer reads `path`'s repository, else the pane's folder; only a failed read reaches the picker.
        if params["args"].get("path") != "/var/empty":
            return a.ran(params["action"])
        return directory_picker(a, params)

    app.actions["palette.openDirectoryDiffViewer"] = directory_picker
    app.actions["openDiffViewer"] = diff


def hint_mode(app: ScriptedApp, parent: bool) -> None:
    if parent:
        return  # 9b0caf7793d has no hints.show and no Cmd-J F binding for it
    preview = "labs.previewFeatures"
    app.actions["hints.show"] = lambda a, p: a.ran("hints.show") \
        if preview in a.model["settings"]["nonDefaultKeys"] else a.refused()
    app.keys["cmd+j"] = lambda a: {"action": None}
    app.keys["f"] = lambda a: {"action": "hints.show"} if preview in a.model["settings"]["nonDefaultKeys"] \
        else {"action": None, "refused_action": "hints.show"}


# This batch's converted cases, by case id: the head behavior and the parent behavior the manifest describes.
BEHAVIOR: Dict[str, Callable[[ScriptedApp, bool], None]] = {
    "e2e/dock-split-pane": dock_split_pane,
    "e2e/file-pages-r96": file_pages_r96,
    "e2e/hint-mode": hint_mode,
}


class CliRunner:
    """subprocess.run for cli steps: `settings set|unset <key>` edits the fake app's settings facet."""

    def __init__(self, apps: List[ScriptedApp]):
        self.apps = apps

    def __call__(self, argv, **kwargs):
        words = list(argv)[3:]  # cmux --app-socket PATH ...
        if words[:2] == ["settings", "set"]:
            self.apps[-1].set_setting(words[2], json.loads(words[3]) is True)
        elif words[:2] == ["settings", "unset"]:
            self.apps[-1].set_setting(words[2], False)
        else:
            return subprocess.CompletedProcess(argv, 2, "", f"unknown cli {words}")
        return subprocess.CompletedProcess(argv, 0, "OK\n", "")


class ManifestTest(unittest.TestCase):
    def test_manifest_covers_its_range_with_a_case_or_a_reason(self) -> None:
        batch = manifest()
        first, last = batch["range"]
        self.assertEqual((first, last), (12, 22), "p15-oracle-093 converts MQ-e2e entries 12-22")
        self.assertEqual(sorted(batch["scripts"]), mq_e2e()[first - 1:last], "the scripts at positions 12-22")
        self.assertIn("p15-oracle-202", batch.get("red_on_parent", ""), "say how and when red on parent is run")
        for script, entry in batch["scripts"].items():
            if "excluded" in entry:
                self.assertNotIn("case", entry, script)
                self.assertGreaterEqual(len(entry["excluded"]), 40, f"{script}: say why it does not convert")
                continue
            for key in ("case", "fix", "parent", "cited", "catches"):
                self.assertIn(key, entry, f"{script}: {key}")
            self.assertRegex(entry["fix"], SHA, script)
            self.assertRegex(entry["parent"], SHA, script)
            suite, case_name = entry["case"].split("/")
            self.assertEqual(suite, "e2e", script)
            case = json.loads((SUITE / f"{case_name}.json").read_text(encoding="utf-8"))
            self.assertIn(script, case["steps"][0].get("note", ""), f"{entry['case']}: its first step names the script")
            self.assertIn(catches_step(entry), [s["id"] for s in case["steps"]], f"{entry['case']}: catches names a step")

    def test_cases_read_only_facets_the_base_provides(self) -> None:
        for case_id in converted():
            case = ConvertedCaseTest.load(case_id)
            for step in case["steps"]:
                with self.subTest(case=case_id, step=step["id"]):
                    for facet in (step.get("args") or {}).get("facets") or ():
                        self.assertIn(facet, SNAPSHOT_PROVIDED, "a snapshot of an unprovided facet is not-comparable")
                    if "waitFor" in step:
                        facet = driver_app.decode_pointer(step["waitFor"]["pointer"])[0]
                        self.assertIn(facet, WAITABLE, "wait_for refuses a facet with no provider or change signal")

    def test_every_converted_case_has_a_behavior(self) -> None:
        self.assertEqual(sorted(converted()), sorted(BEHAVIOR))


class ConvertedCaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    @staticmethod
    def load(case_id: str) -> Dict[str, Any]:
        return json.loads((SUITE / f"{case_id.split('/')[1]}.json").read_text(encoding="utf-8"))

    def run_as(self, case_id: str, parent: bool, case: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        apps: List[ScriptedApp] = []

        def make(app, out, env):
            fake = ScriptedApp(app, out, env)
            BEHAVIOR[case_id](fake, parent)
            apps.append(fake)
            return fake

        ctx = {"run_id": "r", "product": "app", "build": "bench", "binary": driver_app_test.APP,
               "out_dir": self.tmp.name}
        session = driver_app.AppSession(ctx, make_app=make, identity=driver_app_test.identity,
                                        canonicalizer=driver_app_test.identity_canonicalizer(), run=CliRunner(apps),
                                        host=lambda: {"os": "macOS 26.1", "arch": "arm64", "model": "Mac16,10"},
                                        root_base=Path(self.tmp.name) / "o")
        try:
            return session.run_case(case or self.load(case_id), {"case_id": case_id})
        finally:
            session.close()

    def test_each_case_passes_on_the_base_builds_facets(self) -> None:
        for case_id in BEHAVIOR:
            with self.subTest(case=case_id):
                head = self.run_as(case_id, parent=False)
                self.assertEqual(head["status"], "Pass", head.get("message"))

    def test_each_case_tells_the_described_parent_behavior_apart_at_catches(self) -> None:
        entries = converted()
        for case_id in BEHAVIOR:
            with self.subTest(case=case_id):
                parent = self.run_as(case_id, parent=True)
                self.assertEqual(parent["status"], "Failure", parent.get("message"))
                self.assertEqual(parent.get("step"), catches_step(entries[case_id]), parent.get("message"))

    def test_a_wait_on_a_facet_the_base_lacks_is_refused(self) -> None:
        """The guard the dock case once missed: /sidebar has no provider on the base, so its wait crashes the case."""
        case = self.load("e2e/dock-split-pane")
        step = next(s for s in case["steps"] if s["id"] == "select-workspace")
        step["waitFor"]["pointer"] = "/sidebar/selectedWorkspace"
        result = self.run_as("e2e/dock-split-pane", parent=False, case=case)
        self.assertEqual(result["status"], "Crash", result.get("message"))
        self.assertEqual(result.get("step"), "select-workspace")


if __name__ == "__main__":
    unittest.main()
