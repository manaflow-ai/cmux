#!/usr/bin/env python3
"""Offline tests of p15-oracle-097's e2e batch: its manifest and its three converted cases.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 5 item 4, and task p15-oracle-097 (MQ-e2e entries 56-66).
Stdlib only, Python 3.9+, safe under `python3 -I`.

- `tests/oracle/corpus/e2e/_scripts-097.json` names exactly the scripts at positions 56..66 of MQ-e2e
  (`ls scripts/cmux-next/*-e2e.py scripts/cmux-next/*-e2e.sh`, sorted), each converted (a case whose first step names
  the script, with the fix commit, its parent and the step `catches` names) or excluded with a reason and a gap. The
  checks read only this batch's file and cases: the sibling batches (092-096) keep their own manifests. An excluded
  script's gap names its owner task (section 4 rule 6).
- Each converted case runs through driver_app's real step runner against a fake app that offers only the facets the
  base build has providers for (AppServices+OracleHost.makeOracleFacets, plus the router's topology for a snapshot):
  a wait on a facet with no provider, or on topology (OracleSettleControl gets the list without it), is refused as
  the app refuses it, and a static check refuses a case step that names such a facet.
- The case passes against the fake head. Against a fake of the parent behavior the manifest describes, it fails at
  the `catches` step. That shows the case's assertion tells the two behaviors apart. It is NOT the task's acceptance
  (red on the real parent commit): the parents predate debug.oracle.*, so that run waits for the overlay of
  p15-oracle-202 (the manifest's `red_on_parent`).
- The fake's terminals print a command's output in parts while the driver works, so a case whose checkpoint depends
  on when output arrives gives different checkpoints for different splits; terminal-keys must give the same ones.

Chrome reference (chromium/src): third_party/blink/web_tests/TestExpectations keeps a reason on every test that does
not run; the manifest does the same for scripts that do not convert.

    python3 -I scripts/cmux-next/oracle/e2e_097_cases_test.py
"""

from __future__ import annotations

import hashlib
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
MANIFEST = SUITE / "_scripts-097.json"
SHA = re.compile(r"^[0-9a-f]{40}$")

# The facets debug.oracle.snapshot answers with a provider in the base build: makeOracleFacets' list and the router's
# topology (OracleControl). No sidebar and no switches provider yet.
SNAPSHOT_PROVIDED = ("topology", "focus", "layout", "tabs", "overlays", "settings", "intents", "windows", "history",
                     "notifications", "agents", "terminals", "webviews", "ax", "crashes", "liveObjects", "invariants")
# What debug.oracle.wait_for can wait on (OracleFacets.signalsChanges): a main-actor provider, or one with a change
# signal (terminals, webviews, overlays). Topology is not in OracleSettleControl's list.
WAITABLE = ("focus", "layout", "tabs", "overlays", "settings", "windows", "invariants", "agents", "terminals",
            "webviews")


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


def digest(text: str) -> str:
    return "sha256:" + hashlib.sha256(text.encode()).hexdigest()


# A task id a gap names as its owner.
TASK_ID = re.compile(r"\bp\d{2}-[a-z][a-z-]*-\d{3}[a-z]?\b")
PROMPT = "$ "
CLEAR = object()  # the shell's `clear` in a terminal's pending output
VIEWPORT_ROWS = 40  # the fake's screen height: 400 lines scroll


def screen_hash(viewport: str) -> str:
    """The terminals facet's last24Sha256: the hash of the screen's last 24 rows (OracleTerminalsFacet.lastRows)."""
    return digest("\n".join(viewport.split("\n")[-24:]))


class ScriptedApp(driver_app_test.FakeApp):
    """A small model of the base build's facets, and per-action and per-keystroke answers a behavior sets.

    Terminals model a shell on a PTY: a typed key echoes at once, and a command's output reaches the daemon screen
    in `parts` chunks, one per control request the driver makes, the prompt last. So a wait that the first change
    meets (`changed` after the echo) snapshots a screen that is still filling, as on a real Mac. The bundle's CLI
    (`terminal current write`, `terminal current screen wait`) is answered from the same screens."""

    def __init__(self, app: str, out: Path, env: Mapping[str, str], parts: int = 4):
        super().__init__(app, out, env)
        self.model: Dict[str, Any] = {
            "topology": {"topology": {"workspaces": [{"id": "ws_1"}], "workspace_groups": []}},
            "focus": {"windows": [{"model": {"pane": "pane_1"}}]},
            "layout": {"screens": [{"workspace": "ws_1", "root": {"kind": "leaf", "pane": "pane_1"}}]},
            "windows": {"count": 1, "order": ["win_1"], "key": None, "main": None, "list": [{"id": "win_1"}]},
            "terminals": {"list": []},
            "intents": {"pending": []},
        }
        self.actions: Dict[str, Callable[["ScriptedApp", Dict[str, Any]], Dict[str, Any]]] = {}
        self.keys: Dict[str, Callable[["ScriptedApp"], Dict[str, Any]]] = {}
        self.parts = parts
        # Per terminal: its daemon screen's text (the terminals facet hashes its last rows), the output its shell
        # wrote that has not reached the screen yet, and the line typed at its prompt.
        self.screens: Dict[str, str] = {"term_1": PROMPT}
        self.output: Dict[str, List[Any]] = {"term_1": []}
        self.typed: Dict[str, str] = {}
        self.pane_terminal: Dict[str, str] = {"pane_1": "term_1"}
        self.publish_terminals()

    def request(self, method: str, params: Mapping[str, Any], timeout: float) -> Dict[str, Any]:
        self.deliver_output()
        return super().request(method, params, timeout)

    def m_debug_oracle_snapshot(self, params):
        if params.get("list"):
            return {"ok": True, "result": [{"facet": f, "provided": f in SNAPSHOT_PROVIDED, "task": "t"}
                                           for f in driver_app.FACETS if f != "daemon"]}
        return {"ok": True, "result": {
            f: json.loads(json.dumps(self.model.get(f, {}))) if f in SNAPSHOT_PROVIDED
            else {"status": "not-comparable", "reason": f"no provider for {f} in this build", "task": "t"}
            for f in params["facets"]}}

    def m_debug_oracle_wait_for(self, params):
        facet = driver_app.decode_pointer(params["pointer"])[0]
        if facet not in WAITABLE:
            return {"ok": False, "error": {"code": "unavailable", "message": f"no provider for facet {facet}"}}
        value = driver_app.resolve_pointer(self.model, params["pointer"])
        value = None if value is driver_app.MISSING else value
        if "equals" in params:
            ok = value == params["equals"]
        elif params.get("predicate") == "changed":
            ok = value != params["since"]
        else:
            ok = value is not None
        return {"ok": True, "result": {"satisfied": ok, "value": value, "evaluations": 1, "elapsed_ms": 1}}

    def m_action_run(self, params):
        handler = self.actions.get(params["action"])
        if handler is None:
            return {"ok": False, "error": {"code": "not_found", "message": params["action"]}}
        self.sequence += 1
        return handler(self, params)

    def m_debug_key(self, params):
        stroke = "+".join([*params["modifiers"], params["key"]])
        handler = self.keys.get(stroke)
        if handler is not None:
            self.sequence += 1
            return {"ok": True, "result": {"handled_by": "app", "window_kind": "shell", **handler(self)}}
        if not params["modifiers"]:
            self.type_key(params["key"])
        return {"ok": True, "result": {"handled_by": "responder", "action": None, "window_kind": "shell"}}

    def cli(self, argv: List[str], **kwargs: Any) -> subprocess.CompletedProcess:
        """The bundle's cmux on the app's socket, for the two terminal verbs the cases use. `write --text` types
        into the focused terminal's PTY and returns at once. `screen wait --pattern` returns when the daemon's
        screen matches (Rust regex syntax; its `\\z` is Python's `\\Z`), and exits 1 when the output ends first."""
        self.deliver_output()
        words = list(argv[3:])  # cmux --app-socket SOCKET
        if words[:1] == ["--json"]:
            words = words[1:]
        terminal = self.pane_terminal[self.focused_pane()]

        def answer(code: int, value: Dict[str, Any]) -> subprocess.CompletedProcess:
            return subprocess.CompletedProcess(argv, code, json.dumps(value), "")

        if words[:4] == ["terminal", "current", "write", "--text"] and len(words) == 5:
            text = words[4]
            self.show(terminal, text.rstrip("\r"))
            if text.endswith("\r"):
                self.run_line(terminal, text[:-1])
            self.publish_terminals()
            return answer(0, {"ok": True})
        if words[:5] == ["terminal", "current", "screen", "wait", "--pattern"] and len(words) == 8:
            pattern = re.compile(words[5].replace(r"\z", r"\Z"))
            while not pattern.search(self.viewport(terminal)):
                if not self.output[terminal]:
                    return answer(1, {"error": {"code": "timeout", "message": "timeout waiting for pattern"}})
                self.show(terminal, self.output[terminal].pop(0))
            self.publish_terminals()
            return answer(0, {"matched": True, "text": self.viewport(terminal)})
        return answer(2, {"error": {"code": "usage.invalid", "message": " ".join(words)}})

    # -- model edits a behavior composes

    def ran(self, action: str, created=()) -> Dict[str, Any]:
        return {"ok": True, "result": {"action": action, "ran": True, "waited": True, "args": {},
                                       "created": list(created), "sequence": self.sequence}}

    @staticmethod
    def refused(code: str) -> Dict[str, Any]:
        return {"ok": False, "error": {"code": code, "message": "refused"}}

    def focused_pane(self) -> str:
        return self.model["focus"]["windows"][0]["model"]["pane"]

    def open_terminal(self, pane: str, terminal: str) -> None:
        """A new terminal: a blank screen, its shell's first prompt still on the way."""
        self.pane_terminal[pane], self.screens[terminal], self.output[terminal] = terminal, "", [PROMPT]
        self.publish_terminals()

    def viewport(self, terminal: str) -> str:
        return "\n".join(self.screens[terminal].split("\n")[-VIEWPORT_ROWS:])

    def publish_terminals(self) -> None:
        self.model["terminals"]["list"] = [{"terminal": t, "tab": f"tab_{t[5:]}",
                                            "last24Sha256": screen_hash(self.viewport(t))} for t in self.screens]

    def show(self, terminal: str, chunk: Any) -> None:
        self.screens[terminal] = "" if chunk is CLEAR else self.screens[terminal] + chunk

    def deliver_output(self) -> None:
        """Output keeps arriving while the driver works: one chunk per terminal per request."""
        for terminal, chunks in self.output.items():
            if chunks:
                self.show(terminal, chunks.pop(0))
        self.publish_terminals()

    def run_line(self, terminal: str, line: str) -> None:
        """The shell runs `clear` and `seq A B`; their output reaches the screen in `parts` chunks, then the prompt."""
        chunks: List[Any] = ["\n"]
        for command in line.split(";"):
            words = command.split()
            if words == ["clear"]:
                chunks.append(CLEAR)
            elif words[:1] == ["seq"]:
                lines = [f"{n}\n" for n in range(int(words[1]), int(words[2]) + 1)]
                size = -(-len(lines) // self.parts)
                chunks.extend("".join(lines[i:i + size]) for i in range(0, len(lines), size))
        self.output[terminal].extend([*chunks, PROMPT])

    def type_key(self, key: str) -> None:
        """A plain key reaches the focused terminal's shell, which echoes it; Return runs the typed line."""
        terminal = self.pane_terminal[self.focused_pane()]
        if key == "return":
            self.run_line(terminal, self.typed.pop(terminal, ""))
        else:
            character = " " if key == "space" else key
            self.typed[terminal] = self.typed.get(terminal, "") + character
            self.show(terminal, character)
        self.publish_terminals()


def terminal_keys(app: ScriptedApp, parent: bool) -> None:
    history: List[str] = []

    def clear(a: ScriptedApp) -> Dict[str, Any]:
        # 4b5d8e0886f: terminal.clear sends the daemon's clear-history, which erases the rows above the prompt
        # (the cursor's row) in the emulator at once; its parent cleared the app's mirror only.
        if not parent:
            terminal = a.pane_terminal[a.focused_pane()]
            a.screens[terminal] = a.screens[terminal].split("\n")[-1]
            a.publish_terminals()
        return {"action": "terminal.clear"}

    def split(a: ScriptedApp) -> Dict[str, Any]:
        new, terminal = f"pane_{a.sequence}", f"term_{a.sequence}"
        history.append(a.focused_pane())
        a.open_terminal(new, terminal)
        a.model["focus"]["windows"][0]["model"]["pane"] = new
        screen = a.model["layout"]["screens"][0]
        screen["root"] = {"kind": "split", "children": [screen["root"], {"kind": "leaf", "pane": new}]}
        a.publish_terminals()
        return {"action": "splitRight"}

    def move(a: ScriptedApp, action: str, to: Callable[[], Optional[str]]) -> Dict[str, Any]:
        pane = to()
        if pane is None:
            return {"action": None, "refused_action": action}
        a.model["focus"]["windows"][0]["model"]["pane"] = pane
        return {"action": action}

    app.keys["cmd+k"] = clear
    app.keys["cmd+d"] = split
    app.keys["cmd+["] = lambda a: move(a, "focusHistoryBack", lambda: history[-1] if history else None)
    app.keys["cmd+]"] = lambda a: move(a, "focusHistoryForward",
                                       lambda: next(p for p in a.pane_terminal if p != a.focused_pane()))
    app.keys["cmd+c"] = lambda a: {"action": "terminalCopy"}


def window_order(app: ScriptedApp, parent: bool) -> None:
    windows = app.model["windows"]

    def new_window(a: ScriptedApp, params: Dict[str, Any]) -> Dict[str, Any]:
        new = f"win_{a.sequence}"
        windows["list"].append({"id": new})
        windows["count"] = len(windows["list"])
        windows["order"].append(new)  # WindowActivation .present under no-activate: behind the others
        return a.ran("newWindow", created=[new])

    def cycle(offset: int) -> Callable[[ScriptedApp, Dict[str, Any]], Dict[str, Any]]:
        def run(a: ScriptedApp, params: Dict[str, Any]) -> Dict[str, Any]:
            order = windows["order"]
            raised = order[offset % len(order)]
            # bc106793c4a: WindowManager.windowDidOrder moves a window ordered front to the front of the recency;
            # its parent moved it only on a key change, which no-activate never makes.
            if not parent:
                order.remove(raised)
                order.insert(0, raised)
            return a.ran(params["action"])
        return run

    app.actions["newWindow"] = new_window
    app.actions["selectPreviousWindow"] = cycle(-1)
    app.actions["selectNextWindow"] = cycle(1)


def workspace_group_section(app: ScriptedApp, parent: bool) -> None:
    topology = app.model["topology"]["topology"]
    sections: Dict[str, List[str]] = {}

    def group_of(workspace: str) -> Optional[Dict[str, Any]]:
        return next((g for g in topology["workspace_groups"] if workspace in g["workspaces"]), None)

    def new_workspace(a: ScriptedApp, params: Dict[str, Any]) -> Dict[str, Any]:
        new = f"ws_{a.sequence}"
        topology["workspaces"].append({"id": new})
        anchor = (params.get("target") or "").partition(":")[2]
        group = group_of(anchor)
        if group:
            group["workspaces"].append(new)
        return a.ran(params["action"], created=[new])

    def move_to_new_group(a: ScriptedApp, params: Dict[str, Any]) -> Dict[str, Any]:
        workspace = params["target"].partition(":")[2]
        topology["workspace_groups"].append({"id": f"grp_{a.sequence}", "workspaces": [workspace]})
        return a.ran(params["action"])

    def add_section(a: ScriptedApp, params: Dict[str, Any]) -> Dict[str, Any]:
        sections[params["args"]["title"]] = []
        return a.ran(params["action"])

    def add_to_section(a: ScriptedApp, params: Dict[str, Any]) -> Dict[str, Any]:
        group = group_of(params["target"].partition(":")[2])
        if group is None:
            return a.refused("unavailable")
        items = sections.get(params["args"]["section"])
        if items is None:
            return a.refused("unavailable")  # SidebarSectionStrings.noSuchSection
        fresh = [w for w in group["workspaces"] if w not in items]
        if not fresh:
            return a.refused("unavailable")  # RefusalStrings.groupAlreadyInSection
        items.extend(fresh)
        return a.ran(params["action"])

    app.actions["workspace.newAtBottom"] = new_workspace
    app.actions["workspace.newBelow"] = new_workspace
    app.actions["workspace.moveToNewGroup"] = move_to_new_group
    app.actions["sidebar.section.add"] = add_section
    if not parent:  # 32c2b6a7e76, the parent of 52d2b46c5df, has no workspaceGroup.addToSection
        app.actions["workspaceGroup.addToSection"] = add_to_section


# This batch's converted cases, by case id: the head behavior and the parent behavior the manifest describes.
BEHAVIOR: Dict[str, Callable[[ScriptedApp, bool], None]] = {
    "e2e/terminal-keys": terminal_keys,
    "e2e/window-order": window_order,
    "e2e/workspace-group-section": workspace_group_section,
}


class ManifestTest(unittest.TestCase):
    def test_manifest_covers_its_range_with_a_case_or_a_reason(self) -> None:
        batch = manifest()
        first, last = batch["range"]
        self.assertEqual((first, last), (56, 66), "p15-oracle-097 converts MQ-e2e entries 56-66")
        self.assertEqual(len(mq_e2e()), 66, "MQ-e2e has 66 scripts (p15-oracle.md section 1)")
        self.assertEqual(sorted(batch["scripts"]), mq_e2e()[first - 1:last], "the scripts at positions 56-66")
        self.assertIn("p15-oracle-202", batch.get("red_on_parent", ""), "say how and when red on parent is run")
        shells = [s for s in batch["scripts"] if s.endswith(".sh")]
        self.assertEqual(shells, [], "the two .sh scripts sort into earlier batches (cloud-dev, free-tier-attest)")
        for script, entry in batch["scripts"].items():
            with self.subTest(script=script):
                self.assertTrue((REPO / script).is_file(), "the script stays")
                if "excluded" in entry:
                    self.assertNotIn("case", entry)
                    self.assertGreaterEqual(len(entry["excluded"]), 80, "say why it does not convert")
                    # p15-oracle.md section 4 rule 6: every excluded script has a written reason and a task id.
                    self.assertRegex(entry.get("gap", ""), TASK_ID, "an excluded script's gap names its owner task")
                    continue
                for key in ("case", "fix", "parent", "cited", "catches"):
                    self.assertIn(key, entry)
                self.assertRegex(entry["fix"], SHA)
                self.assertRegex(entry["parent"], SHA)
                suite, _ = entry["case"].split("/")
                self.assertEqual(suite, "e2e")
                case = load(entry["case"])
                self.assertIn(script, case["steps"][0].get("note", ""), "its first step names the script")
                self.assertIn(catches_step(entry), [s["id"] for s in case["steps"]], "catches names a step")

    def test_cases_read_only_facets_the_base_provides(self) -> None:
        for case_id in converted():
            for step in load(case_id)["steps"]:
                with self.subTest(case=case_id, step=step["id"]):
                    for facet in (step.get("args") or {}).get("facets") or ():
                        self.assertIn(facet, SNAPSHOT_PROVIDED, "a snapshot of an unprovided facet is not-comparable")
                    if "waitFor" in step:
                        facet = driver_app.decode_pointer(step["waitFor"]["pointer"])[0]
                        self.assertIn(facet, WAITABLE, "wait_for refuses a facet with no provider or change signal")

    def test_cases_pass_the_app_drivers_launch_rules(self) -> None:
        for case_id in converted():
            with self.subTest(case=case_id):
                driver_app.launch_spec(load(case_id))
                for step in load(case_id)["steps"]:
                    for stroke in (step.get("args") or {}).get("keys") or () if step["op"] == "key" else ():
                        driver_app.debug_key(stroke, step["id"])

    def test_every_converted_case_has_a_behavior(self) -> None:
        self.assertEqual(sorted(converted()), sorted(BEHAVIOR))


class ConvertedCaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def run_as(self, case_id: str, parent: bool, case: Optional[Dict[str, Any]] = None,
               parts: int = 4) -> Dict[str, Any]:
        apps: List[ScriptedApp] = []

        def make(app, out, env):
            fake = ScriptedApp(app, out, env, parts=parts)
            BEHAVIOR[case_id](fake, parent)
            apps.append(fake)
            return fake

        def run(argv, **kwargs):
            """A cli step's bundle CLI, answered by the app that session launched."""
            return apps[-1].cli(list(argv), **kwargs)

        ctx = {"run_id": "r", "product": "app", "build": "bench", "binary": driver_app_test.APP,
               "out_dir": self.tmp.name}
        session = driver_app.AppSession(ctx, make_app=make, identity=driver_app_test.identity,
                                        canonicalizer=driver_app_test.identity_canonicalizer(), run=run,
                                        host=lambda: {"os": "macOS 26.1", "arch": "arm64", "model": "Mac16,10"},
                                        root_base=Path(self.tmp.name) / "o")
        try:
            return session.run_case(case or load(case_id), {"case_id": case_id})
        finally:
            session.close()

    def test_each_case_passes_on_the_base_builds_facets(self) -> None:
        for case_id in BEHAVIOR:
            with self.subTest(case=case_id):
                head = self.run_as(case_id, parent=False)
                self.assertEqual(head["status"], "Pass", head.get("message"))
                self.assertTrue(head["checkpoints"], "the case records checkpoints")

    def test_each_case_tells_the_described_parent_behavior_apart_at_catches(self) -> None:
        entries = converted()
        for case_id in BEHAVIOR:
            with self.subTest(case=case_id):
                parent = self.run_as(case_id, parent=True)
                self.assertIn(parent["status"], ("Failure", "Timeout"), parent.get("message"))
                self.assertEqual(parent.get("step"), catches_step(entries[case_id]), parent.get("message"))

    @staticmethod
    def states(result: Dict[str, Any]) -> List[Any]:
        """Each checkpoint's step, kind and facets: what two runs must agree on (meta holds the capture time)."""
        return [(c["step"], c["checkpoint"], c["snapshot"]["facets"]) for c in result["checkpoints"]]

    def test_terminal_keys_checkpoints_do_not_depend_on_when_output_arrives(self) -> None:
        """The fill waits are on the command's end state, so the checkpoints are the same however the shell's
        output is split, and filled holds line 400 and the prompt after it."""
        runs = {parts: self.run_as("e2e/terminal-keys", parent=False, parts=parts) for parts in (1, 4, 10)}
        for parts, result in runs.items():
            self.assertEqual(result["status"], "Pass", f"{parts} parts: {result.get('message')}")
        self.assertEqual(self.states(runs[1]), self.states(runs[4]))
        self.assertEqual(self.states(runs[1]), self.states(runs[10]))
        filled = next(c for c in runs[4]["checkpoints"] if c["step"] == "filled")
        end = "\n".join([*(str(n) for n in range(378, 401)), PROMPT])
        self.assertEqual(filled["snapshot"]["facets"]["terminals"]["list"][0]["last24Sha256"], digest(end))

    def test_typed_fill_with_a_changed_wait_is_timing_dependent(self) -> None:
        """The fake exercises the race the fill steps avoid: typed keys with a `changed` wait (the case before
        this fix) snapshot a screen that is still filling, the snapshot differs with the output's split, and on
        the parent the late output meets cmd-k's `changed` wait, so cmd-k (the `catches` step) passes there."""
        case = load("e2e/terminal-keys")
        typed = {"id": "fill", "op": "key", "target": {"window": "current"},
                 "args": {"keys": ["s", "e", "q", "space", "1", "space", "4", "0", "0", "return"]},
                 "expect": {"outcome": "ok", "noReceiptReason": "plain keys go to the terminal's program"},
                 "waitFor": {"pointer": "/terminals/list", "predicate": "changed", "maxMs": 10000}}
        snapshot = {"id": "filled", "op": "snapshot", "args": {"facets": ["focus", "terminals"]}}
        steps = case["steps"]
        at = next(i for i, s in enumerate(steps) if s["id"] == "fill")
        steps[at:at + 2] = [typed, snapshot]
        early = self.run_as("e2e/terminal-keys", parent=False, case=json.loads(json.dumps(case)), parts=4)
        late = self.run_as("e2e/terminal-keys", parent=False, case=json.loads(json.dumps(case)), parts=10)

        def filled(result: Dict[str, Any]) -> Any:
            return next(c for c in result["checkpoints"] if c["step"] == "filled")["snapshot"]["facets"]["terminals"]

        self.assertNotEqual(filled(early), filled(late))
        parent = self.run_as("e2e/terminal-keys", parent=True, case=json.loads(json.dumps(case)), parts=10)
        self.assertNotEqual(parent.get("step"), "cmd-k", parent.get("message"))

    def test_a_wait_on_topology_is_refused(self) -> None:
        """OracleSettleControl's facet list has no topology, so a case that waited on it would crash on head."""
        case = load("e2e/window-order")
        step = next(s for s in case["steps"] if s["id"] == "second-window")
        step["waitFor"] = {"pointer": "/topology/topology/workspaces", "predicate": "changed", "maxMs": 1000}
        result = self.run_as("e2e/window-order", parent=False, case=case)
        self.assertEqual(result["status"], "Crash", result.get("message"))
        self.assertEqual(result.get("step"), "second-window")


if __name__ == "__main__":
    unittest.main()
