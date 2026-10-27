#!/usr/bin/env python3
"""Offline tests of p15-oracle-095's e2e batch: its manifest and its four converted cases.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 5 item 4, and task p15-oracle-095 (MQ-e2e entries 34-44).
Stdlib only, Python 3.9+, safe under `python3 -I`.

- `tests/oracle/corpus/e2e/_scripts-095.json` names 11 distinct scripts that exist, each converted (a case whose first
  step names the script, with the fix commit, its parent and the step `catches` names, or `catches: null` with a `gap`)
  or excluded with a reason. They are positions 34..44 of MQ-e2e (`ls scripts/cmux-next/*-e2e.py
  scripts/cmux-next/*-e2e.sh`, sorted) at the manifest's `queue_ref`, the base commit the batches were assigned from;
  the test lists that commit's tree (`ls-tree`), not the working tree, so a script added on the base later does not
  move the batch (skipped when a shallow clone lacks the commit). The checks read only this batch's file and cases.
- Each converted case runs through driver_app's real step runner against a fake app that offers only the facets the
  base build has providers for (AppServices+OracleHost.makeOracleFacets, plus the router's topology in a snapshot):
  a wait on another facet is refused, as OracleSettleControl refuses it (no provider, or no change signal), and a
  static check refuses a case whose own snapshot or wait names such a facet.
- The case passes against the fake head. Against a fake of the parent behavior the manifest describes, it fails (a
  Failure, or the Timeout of its wait) at the `catches` step: the case's assertion tells the two behaviors apart. That
  is not the task's acceptance (red on the real parent commit), which waits for p15-oracle-202's overlay
  (`red_on_parent` in the manifest).

Chrome reference (chromium/src): third_party/blink/web_tests/TestExpectations keeps a reason on every test that does
not run; the manifest does the same for scripts that do not convert.

    python3 -I scripts/cmux-next/oracle/e2e_095_cases_test.py
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
MANIFEST = SUITE / "_scripts-095.json"
RANGE = (34, 44)
SHA = re.compile(r"^[0-9a-f]{40}$")

# The facets the base build's makeOracleFacets list provides, plus topology, which `debug.oracle.snapshot` adds from
# the router (OracleControl) and `debug.oracle.wait_for` does not (AppControl+Barrier passes the list as is). No
# sidebar (p15-oracle-036) and no switches (p15-oracle-027) provider yet.
SNAPSHOT_PROVIDED = ("topology", "focus", "layout", "tabs", "overlays", "settings", "intents", "windows", "history",
                     "notifications", "agents", "terminals", "webviews", "ax", "crashes", "liveObjects", "invariants")
# The provided facets wait_for can wait on (OracleFacets.signalsChanges: read on the main actor, or with a change
# signal), the subset these cases may use.
WAITABLE = ("focus", "layout", "tabs", "overlays", "settings", "windows", "invariants")


def mq_e2e_at(ref: str) -> Optional[List[str]]:
    """MQ-e2e at commit `ref`: the e2e scripts in `ls` order, repo-relative; None when the clone lacks `ref`."""
    listed = subprocess.run(["git", "-C", str(REPO), "ls-tree", "--name-only", ref, "scripts/cmux-next/"],
                            capture_output=True, text=True, check=False)
    if listed.returncode != 0:
        return None
    return sorted(p for p in listed.stdout.splitlines() if p.endswith(("-e2e.py", "-e2e.sh")))


def manifest() -> Dict[str, Any]:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


def converted() -> Dict[str, Dict[str, Any]]:
    return {e["case"]: e for e in manifest()["scripts"].values() if "case" in e}


def catches_step(entry: Mapping[str, Any]) -> Optional[str]:
    return entry["catches"].split(":")[0] if entry.get("catches") else None


def load(case_id: str) -> Dict[str, Any]:
    return json.loads((SUITE / f"{case_id.split('/')[1]}.json").read_text(encoding="utf-8"))


class Model:
    """Workspaces in sidebar order, each one pane of tabs; the window shows one workspace."""

    def __init__(self) -> None:
        self.serial = 0
        self.workspaces: List[Dict[str, Any]] = []
        self.shown = self.new_workspace()["id"]
        self.non_default: List[str] = []

    def mint(self, kind: str) -> str:
        self.serial += 1
        return f"{kind}_{self.serial}"

    def new_workspace(self) -> Dict[str, Any]:
        tab = {"id": self.mint("tab"), "kind": "terminal", "pinned": False}
        workspace = {"id": self.mint("ws"), "pane": self.mint("pane"), "tabs": [tab], "selected": tab["id"]}
        self.workspaces.insert(0, workspace)  # workspaces.newPlacement top, the default
        return workspace

    def workspace(self, ws_id: Optional[str] = None) -> Dict[str, Any]:
        return next(w for w in self.workspaces if w["id"] == (ws_id or self.shown))

    def owner(self, tab_id: str) -> Dict[str, Any]:
        return next(w for w in self.workspaces if any(t["id"] == tab_id for t in w["tabs"]))

    def new_tab(self, kind: str = "terminal") -> str:
        workspace = self.workspace()
        tab = {"id": self.mint("tab"), "kind": kind, "pinned": False}
        workspace["tabs"].append(tab)
        workspace["selected"] = tab["id"]
        return tab["id"]

    def select(self, ws_id: str) -> Dict[str, Any]:
        self.shown = ws_id
        return {}

    def step_workspace(self, by: int) -> None:
        ids = [w["id"] for w in self.workspaces]
        self.shown = ids[(ids.index(self.shown) + by) % len(ids)]

    def step_tab(self, by: int) -> None:
        workspace = self.workspace()
        ids = [t["id"] for t in workspace["tabs"]]
        workspace["selected"] = ids[(ids.index(workspace["selected"]) + by) % len(ids)]

    def facets(self) -> Dict[str, Any]:
        workspace = self.workspace()
        selected = next(t for t in workspace["tabs"] if t["id"] == workspace["selected"])
        tabs = [{"id": t["id"], "kind": t["kind"], "pinned": t["pinned"]} for t in workspace["tabs"]]
        return {
            "topology": {"topology": {"workspaces": [
                {"id": w["id"], "screens": [{"panes": [{"id": w["pane"], "selected_tab": w["selected"],
                                                        "tabs": tabs if w is workspace else
                                                        [{"id": t["id"], "pinned": t["pinned"]} for t in w["tabs"]]}]}]}
                for w in self.workspaces], "focus": {"workspace": self.shown}, "loaded": True},
                "tab_count": sum(len(w["tabs"]) for w in self.workspaces)},
            "focus": {"windows": [{"responder": "content", "model": {
                "pane": workspace["pane"], "resolved": "agentPage" if selected["kind"] == "page" else "terminal",
                "resolvedTab": selected["id"]}}]},
            "layout": {"screens": [{"workspace": self.shown, "root": {"kind": "leaf", "pane": workspace["pane"]}}]},
            "tabs": {"panes": [{"pane": workspace["pane"], "selected": workspace["selected"],
                                "tabs": [t for t in tabs if t["kind"] == "page"]}]},
            "overlays": {"stack": [], "palette": {"open": False}},
            "settings": {"effectiveSha256": f"{len(self.non_default):064x}", "nonDefaultKeys": list(self.non_default)},
        }


Handler = Callable[["ScriptedApp", Dict[str, Any]], Dict[str, Any]]


class ScriptedApp(driver_app_test.FakeApp):
    """The base build's facets over a Model, and per-action and per-key answers a behavior sets."""

    def __init__(self, app: str, out: Path, env: Mapping[str, str]):
        super().__init__(app, out, env)
        self.model = Model()
        self.actions: Dict[str, Handler] = {}
        self.keys: Dict[str, Callable[["ScriptedApp"], Optional[str]]] = {}
        self.settings_refused = ("tabs.tabBar.",)

    def turned(self, label: str) -> None:
        self.sequence += 1
        if self.armed is not None:
            values = self.model.facets()
            self.checkpoint("turn", label, origin="cli", ran=True,
                            facets={f: values.get(f, {}) for f in self.armed})

    def m_debug_oracle_snapshot(self, params):
        if params.get("list"):
            return {"ok": True, "result": [{"facet": f, "provided": f in SNAPSHOT_PROVIDED, "task": "t"}
                                           for f in driver_app.FACETS if f != "daemon"]}
        values = self.model.facets()
        return {"ok": True, "result": {
            f: json.loads(json.dumps(values.get(f, {}))) if f in SNAPSHOT_PROVIDED
            else {"status": "not-comparable", "reason": f"no provider for {f} in this build", "task": "t"}
            for f in params["facets"]}}

    def m_debug_oracle_wait_for(self, params):
        facet = driver_app.decode_pointer(params["pointer"])[0]
        if facet not in WAITABLE:
            return {"ok": False, "error": {"code": "unavailable", "message": f"facet {facet} cannot be waited on"}}
        value = driver_app.resolve_pointer(self.model.facets(), params["pointer"])
        value = None if value is driver_app.MISSING else value
        if "equals" in params:
            ok = value == params["equals"]
        elif params.get("predicate") == "changed":
            ok = value != params["since"]
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
        created = handler(self, params)
        self.turned(params["action"])
        return {"ok": True, "result": {"action": params["action"], "ran": True, "waited": True, "args": {},
                                       "target": params.get("target"), "created": created.get("created", []),
                                       "sequence": self.sequence}}

    def m_debug_key(self, params):
        stroke = "+".join([*params["modifiers"], params["key"]])
        handler = self.keys.get(stroke)
        action = handler(self) if handler else None
        if action is None:
            return {"ok": True, "result": {"handled_by": "responder", "action": None, "window_kind": "shell"}}
        self.turned(action)
        return {"ok": True, "result": {"handled_by": "app", "action": action, "window_kind": "shell"}}

    def settings_set(self, key: str) -> subprocess.CompletedProcess:
        if any(key.startswith(prefix) for prefix in self.settings_refused):
            return subprocess.CompletedProcess([], 1, "", '{"code":"removed","message":"removed"}\n')
        self.model.non_default.append(key)
        return subprocess.CompletedProcess([], 0, "OK\n", "")


def target_tab(params: Mapping[str, Any]) -> str:
    kind, _, value = params["target"].partition(":")
    assert kind == "tab", params
    return value


# -- behaviors: the head, and the parent the manifest describes (parent=True)

def base_actions(app: ScriptedApp) -> None:
    model = app.model
    app.actions["newTab"] = lambda a, p: {"created": [model.new_workspace()["id"]]}
    app.actions["workspace.selectFirst"] = lambda a, p: model.select(model.workspaces[0]["id"])
    app.actions["newSurface"] = lambda a, p: {"created": [model.new_tab()]}
    app.actions["goToWorkspace"] = lambda a, p: model.select(p["args"]["workspace"])


def navigate(app: ScriptedApp, by: int) -> Dict[str, Any]:
    """Previous / Next: a pane with 2+ tabs steps its tabs, else the sidebar's workspaces (8a7689bb3c2)."""
    if len(app.model.workspace()["tabs"]) > 1:
        app.model.step_tab(by)
    else:
        app.model.step_workspace(by)
    return {}


def rapid_switch(app: ScriptedApp, parent: bool) -> None:
    base_actions(app)
    if not parent:  # 048230b3a89 has no navigate.next / navigate.previous
        app.actions["navigate.next"] = lambda a, p: navigate(a, 1)
        app.actions["navigate.previous"] = lambda a, p: navigate(a, -1)


def prev_next_webview(app: ScriptedApp, parent: bool) -> None:
    base_actions(app)

    def new_tab_page(a: ScriptedApp) -> str:
        a.model.new_tab("page")
        return "newTab.page"

    def sidebar(by: int, action: str) -> Callable[[ScriptedApp], str]:
        def press(a: ScriptedApp) -> str:
            a.model.step_workspace(by)
            return action
        return press

    def previous_next(by: int, action: str) -> Callable[[ScriptedApp], str]:
        # 75691a21cba: Ctrl-PageDown / Up off a terminal ran navigate.next / previous (the pane's tabs when 2+).
        def press(a: ScriptedApp) -> str:
            navigate(a, by)
            return action
        return press

    app.keys["cmd+t"] = new_tab_page
    if parent:
        app.keys["control+pagedown"] = previous_next(1, "navigate.next")
        app.keys["control+pageup"] = previous_next(-1, "navigate.previous")
    else:
        app.keys["control+pagedown"] = sidebar(1, "nextSidebarTab")
        app.keys["control+pageup"] = sidebar(-1, "prevSidebarTab")
    app.keys["control+cmd+]"] = sidebar(1, "nextSidebarTab")
    app.keys["control+cmd+["] = sidebar(-1, "prevSidebarTab")


def pane_tab_bar(app: ScriptedApp, parent: bool) -> None:
    base_actions(app)
    if parent:  # c8657678751: tabs.tabBar.<kind> is a schema key with auto / always / never
        app.settings_refused = ()
    app.actions["pane.toggleTabBar"] = lambda a, p: {}
    app.actions["newTab.horizontal"] = lambda a, p: {"created": [a.model.new_tab()]}


def pinned_items(app: ScriptedApp, parent: bool) -> None:
    base_actions(app)

    def pin(a: ScriptedApp, params: Dict[str, Any]) -> Dict[str, Any]:
        tab_id = target_tab(params)
        tabs = a.model.owner(tab_id)["tabs"]
        tab = next(t for t in tabs if t["id"] == tab_id)
        tab["pinned"] = not tab["pinned"]
        tabs.sort(key=lambda t: not t["pinned"])  # stable: pinned tabs lead, in their order
        return {}

    def close_others(a: ScriptedApp, params: Dict[str, Any]) -> Dict[str, Any]:
        tab_id = target_tab(params)
        workspace = a.model.owner(tab_id)
        workspace["tabs"] = [t for t in workspace["tabs"] if t["id"] == tab_id or t["pinned"]]
        if workspace["selected"] not in [t["id"] for t in workspace["tabs"]]:
            workspace["selected"] = tab_id
        return {}

    app.actions["palette.toggleTabPin"] = pin
    app.actions["closeOtherTabsInPane"] = close_others


BEHAVIOR: Dict[str, Callable[[ScriptedApp, bool], None]] = {
    "e2e/pane-tab-bar": pane_tab_bar,
    "e2e/pinned-items": pinned_items,
    "e2e/prev-next-webview": prev_next_webview,
    "e2e/rapid-switch": rapid_switch,
}


class CliRunner:
    """subprocess.run for cli steps: `settings set <key> <value>` on the last fake app."""

    def __init__(self, apps: List[ScriptedApp]):
        self.apps = apps

    def __call__(self, argv, **kwargs):
        words = list(argv)[3:]  # cmux --app-socket PATH ...
        if words[:2] == ["settings", "set"] and len(words) == 4:
            done = self.apps[-1].settings_set(words[2])
            return subprocess.CompletedProcess(argv, done.returncode, done.stdout, done.stderr)
        return subprocess.CompletedProcess(argv, 2, "", f"unknown cli {words}")


class ManifestTest(unittest.TestCase):
    def test_manifest_covers_its_range_with_a_case_or_a_reason(self) -> None:
        batch = manifest()
        first, last = batch["range"]
        self.assertEqual((first, last), RANGE, "p15-oracle-095 converts MQ-e2e entries 34-44")
        self.assertEqual(batch["task"], "p15-oracle-095")
        self.assertEqual(len(batch["scripts"]), last - first + 1, "one entry per queue position")
        self.assertRegex(batch["queue_ref"], SHA)
        self.assertIn("p15-oracle-202", batch.get("red_on_parent", ""), "say how and when red on parent is run")
        for script, entry in batch["scripts"].items():
            with self.subTest(script=script):
                self.assertTrue((REPO / script).is_file(), "the script stays")
                if "excluded" in entry:
                    self.assertNotIn("case", entry)
                    self.assertGreaterEqual(len(entry["excluded"]), 80, "say why it does not convert")
                    continue
                for key in ("case", "fix", "parent", "cited", "catches"):
                    self.assertIn(key, entry)
                self.assertRegex(entry["fix"], SHA)
                self.assertRegex(entry["parent"], SHA)
                self.assertNotEqual(entry["fix"], entry["parent"])
                suite, _ = entry["case"].split("/")
                self.assertEqual(suite, "e2e")
                case = load(entry["case"])
                self.assertEqual(case["id"], entry["case"].split("/")[1])
                self.assertIn(script, case["steps"][0].get("note", ""), "its first step names the script")
                if entry["catches"] is None:
                    self.assertGreaterEqual(len(entry.get("gap", "")), 80, "a case that catches nothing says why")
                else:
                    self.assertIn(catches_step(entry), [s["id"] for s in case["steps"]], "catches names a step")

    def test_manifest_is_positions_34_to_44_at_its_queue_ref(self) -> None:
        batch = manifest()
        queue = mq_e2e_at(batch["queue_ref"])
        if queue is None:
            self.skipTest(f"queue_ref {batch['queue_ref']} is not in this clone (a shallow checkout)")
        first, last = batch["range"]
        self.assertEqual(sorted(batch["scripts"]), queue[first - 1:last], "the scripts at positions 34-44")

    def test_cases_read_only_facets_the_base_provides(self) -> None:
        for case_id in converted():
            for step in load(case_id)["steps"]:
                with self.subTest(case=case_id, step=step["id"]):
                    for facet in (step.get("args") or {}).get("facets") or ():
                        self.assertIn(facet, SNAPSHOT_PROVIDED, "a snapshot of an unprovided facet is not-comparable")
                    if "waitFor" in step:
                        facet = driver_app.decode_pointer(step["waitFor"]["pointer"])[0]
                        self.assertIn(facet, WAITABLE, "wait_for refuses a facet with no provider or change signal")

    def test_cases_launch_and_send_keys_the_driver_accepts(self) -> None:
        for case_id in converted():
            with self.subTest(case=case_id):
                case = load(case_id)
                driver_app.launch_spec(case)
                for step in case["steps"]:
                    for stroke in (step.get("args") or {}).get("keys") or ():
                        driver_app.debug_key(stroke, step["id"])
                    self.assertNotIn("sleep", json.dumps(step).lower(), "waits are barriers, never sleeps")

    def test_every_converted_case_has_a_behavior(self) -> None:
        self.assertEqual(sorted(converted()), sorted(BEHAVIOR))


class ConvertedCaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

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
            return session.run_case(case or load(case_id), {"case_id": case_id})
        finally:
            session.close()

    @staticmethod
    def snapshot(result: Mapping[str, Any], step: str, facet: str, checkpoint: str = "settled") -> Any:
        return next(c["snapshot"]["facets"][facet] for c in result["checkpoints"]
                    if c["step"] == step and c["checkpoint"] == checkpoint)

    def test_each_case_passes_on_the_base_builds_facets(self) -> None:
        for case_id in BEHAVIOR:
            with self.subTest(case=case_id):
                head = self.run_as(case_id, parent=False)
                self.assertEqual(head["status"], "Pass", head.get("message"))

    def test_each_case_tells_the_described_parent_behavior_apart_at_catches(self) -> None:
        for case_id, entry in converted().items():
            step = catches_step(entry)
            if step is None:
                continue
            with self.subTest(case=case_id):
                parent = self.run_as(case_id, parent=True)
                self.assertIn(parent["status"], ("Failure", "Timeout"), parent.get("message"))
                self.assertEqual(parent.get("step"), step, parent.get("message"))

    def test_the_invariants_hold_on_the_fake_head(self) -> None:
        """The prose invariants the head run must meet, read from the fake's checkpoints."""
        switch = self.run_as("e2e/rapid-switch", parent=False)
        shown = {s: self.snapshot(switch, s, "layout")["screens"][0]["workspace"]
                 for s in ("first", "next", "previous", "two-tabs", "wrapped")}
        self.assertNotEqual(shown["next"], shown["first"])
        self.assertEqual(shown["previous"], shown["first"])
        self.assertEqual(shown["wrapped"], shown["two-tabs"])
        tab = {s: self.snapshot(switch, s, "focus")["windows"][0]["model"]["resolvedTab"]
               for s in ("two-tabs", "next-tab", "next-tab-wraps")}
        self.assertNotEqual(tab["next-tab"], tab["two-tabs"])
        self.assertEqual(tab["next-tab-wraps"], tab["two-tabs"])

        pins = self.run_as("e2e/pinned-items", parent=False)

        def pane(step: str) -> List[Any]:
            topology = self.snapshot(pins, step, "topology")["topology"]
            shown = next(w for w in topology["workspaces"] if w["id"] == topology["focus"]["workspace"])
            return [(t["id"], t["pinned"]) for t in shown["screens"][0]["panes"][0]["tabs"]]
        created = {step: pane(step)[-1][0] for step in ("t2", "t3")}
        self.assertEqual(len(pane("three-tabs")), 3)
        self.assertEqual(pane("pinned-first")[0], (created["t3"], True))
        self.assertEqual(sorted(pane("kept")), sorted([(created["t3"], True), (created["t2"], False)]))

        bar = self.run_as("e2e/pane-tab-bar", parent=False)
        self.assertEqual(self.snapshot(bar, "retired-setting", "settings"),
                         self.snapshot(bar, "retired-setting", "settings", checkpoint="before"))
        self.assertEqual(self.snapshot(bar, "retired-setting", "settings")["nonDefaultKeys"], [])

        keys = self.run_as("e2e/prev-next-webview", parent=False)
        launch = self.snapshot(keys, "launched", "layout")["screens"][0]["workspace"]
        # Each of the four presses starts from a New Tab field: the step just before it ends with one focused.
        steps = [s["id"] for s in load("e2e/prev-next-webview")["steps"]]
        for press in ("ctrl-pagedown", "ctrl-pageup", "ctrl-cmd-next", "ctrl-cmd-previous"):
            before = steps[steps.index(press) - 1]
            self.assertEqual(self.snapshot(keys, before, "focus")["windows"][0]["model"]["resolved"], "agentPage",
                             f"{press} starts from {before}")
            self.assertIn("waitFor", next(s for s in load("e2e/prev-next-webview")["steps"] if s["id"] == before),
                          f"{before} waits for the field before {press}")
        middle = self.snapshot(keys, "field", "layout")["screens"][0]["workspace"]
        self.assertNotEqual(middle, launch)
        for step, expected in (("ctrl-pagedown", launch), ("launch-new-tab-page", launch), ("ctrl-pageup", middle),
                               ("back-in-field", middle), ("ctrl-cmd-next", launch), ("launch-field", launch),
                               ("ctrl-cmd-previous", middle), ("ended", middle)):
            self.assertEqual(self.snapshot(keys, step, "layout")["screens"][0]["workspace"], expected, step)
        ended = self.snapshot(keys, "ended", "topology")["topology"]
        for workspace in (launch, middle):
            panes = next(w for w in ended["workspaces"] if w["id"] == workspace)["screens"][0]["panes"]
            self.assertEqual(len(panes[0]["tabs"]), 2, workspace)

    def test_a_wait_on_a_facet_the_base_lacks_is_refused(self) -> None:
        """/sidebar has no provider on the base, so a wait on it crashes the case instead of passing it."""
        case = load("e2e/rapid-switch")
        step = next(s for s in case["steps"] if s["id"] == "next")
        step["waitFor"]["pointer"] = "/sidebar/selection"
        result = self.run_as("e2e/rapid-switch", parent=False, case=case)
        self.assertEqual(result["status"], "Crash", result.get("message"))
        self.assertEqual(result.get("step"), "next")


if __name__ == "__main__":
    unittest.main()
