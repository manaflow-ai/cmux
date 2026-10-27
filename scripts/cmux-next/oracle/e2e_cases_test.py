#!/usr/bin/env python3
"""Offline tests of the e2e suite (p15-oracle-092..097): the batch manifests and the converted cases.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 5 item 4 and tasks 092-097 (MQ-e2e). Stdlib only,
Python 3.9+, safe under `python3 -I`.

- `coverage.json` is what gen_e2e.py writes from the batches. Every `tests/oracle/corpus/e2e/_batch-<a>-<b>.json` names exactly the scripts at positions a..b of MQ-e2e
  (`ls scripts/cmux-next/*-e2e.py scripts/cmux-next/*-e2e.sh`, sorted), each converted (a case of the suite whose
  first step names the script, the bug commit and its parent) or excluded with a reason. No two batches overlap.
- Each converted case of a batch listed in BEHAVIOR runs through driver_app's real step runner against a fake app
  twice: as the head behaves (the case passes) and as the bug's parent behaves (the case fails at the step the
  manifest's `fails_at` names). That is the task's acceptance, checked offline; the fleet run is the proof.

Chrome reference (chromium/src): third_party/blink/web_tests/TestExpectations keeps a reason on every test that does
not run; the batch manifests do the same for scripts that do not convert.

    python3 -I scripts/cmux-next/oracle/e2e_cases_test.py
"""

from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import driver_app  # noqa: E402
import driver_app_test  # noqa: E402

REPO = HERE.parents[2]
SUITE = REPO / "tests" / "oracle" / "corpus" / "e2e"
BATCH = re.compile(r"^_batch-([0-9]+)-([0-9]+)\.json$")
SHA = re.compile(r"^[0-9a-f]{40}$")


def mq_e2e() -> List[str]:
    """MQ-e2e: the e2e scripts in `ls` order, repo-relative."""
    scripts = REPO / "scripts" / "cmux-next"
    return sorted(f"scripts/cmux-next/{p.name}" for pattern in ("*-e2e.py", "*-e2e.sh") for p in scripts.glob(pattern))


def batches() -> Dict[str, Dict[str, Any]]:
    return {p.name: json.loads(p.read_text(encoding="utf-8")) for p in sorted(SUITE.glob("_batch-*.json"))}


class ScriptedApp(driver_app_test.FakeApp):
    """The facets a case reads, as a small model, and per-method answers a behavior sets."""

    def __init__(self, app: str, out: Path, env: Mapping[str, str]):
        super().__init__(app, out, env)
        self.model: Dict[str, Any] = {
            "topology": {"topology": {"workspaces": [{"id": "ws_1", "panes": 1}], "focus": {"workspace": "ws_1"},
                                      "loaded": True}, "tab_count": 1},
            "focus": {"windows": [{"model": {"pane": "pane_1"}}], "paletteOpen": False},
            "layout": {"screens": [{"workspace": "ws_1", "columns": 1}]},
            "sidebar": {"selectedWorkspace": "ws_1"},
            "tabs": {"panes": []},
            "overlays": {"stack": [], "palette": {"open": False}},
            "settings": {"effectiveSha256": "0" * 64, "nonDefaultKeys": []},
        }
        self.actions: Dict[str, Callable[["ScriptedApp", Dict[str, Any]], Dict[str, Any]]] = {}
        self.keys: Dict[str, Callable[["ScriptedApp"], Dict[str, Any]]] = {}

    def facets(self, names) -> Dict[str, Any]:
        out = super().facets(names)
        for name in names:
            if name in self.model:
                out[name] = json.loads(json.dumps(self.model[name]))
        return out

    def m_debug_oracle_wait_for(self, params):
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

    def split(self) -> Dict[str, Any]:
        self.model["focus"]["windows"][0]["model"]["pane"] = f"pane_{self.sequence}"
        self.model["topology"]["topology"]["workspaces"][-1]["panes"] += 1
        return {"action": "splitRight"}

    def dock(self, action: str) -> Dict[str, Any]:
        self.model["topology"]["topology"]["workspaces"][-1]["docked"] = action
        self.model["layout"]["screens"][-1]["columns"] += 1
        return self.ran(action)

    def new_workspace(self, action: str) -> Dict[str, Any]:
        new = f"ws_{self.sequence}"
        self.model["topology"]["topology"]["workspaces"].append({"id": new, "panes": 1})
        return self.ran(action, created=[new])

    def select_second(self) -> Dict[str, Any]:
        self.model["sidebar"]["selectedWorkspace"] = self.model["topology"]["topology"]["workspaces"][1]["id"]
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
    def picker(a: ScriptedApp, params: Dict[str, Any]) -> Dict[str, Any]:
        if parent or params.get("origin") not in ("cli", "mcp", "script", "remote") or params.get("focus"):
            a.model["overlays"]["palette"]["open"] = True
            a.model["focus"]["paletteOpen"] = True
            return a.ran(params["action"])
        return a.refused()

    app.actions["palette.openDirectoryDiffViewer"] = picker
    app.actions["openDiffViewer"] = picker


def hint_mode(app: ScriptedApp, parent: bool) -> None:
    if parent:
        return  # 9b0caf7793d has no hints.show and no Cmd-J F binding for it
    preview = "labs.previewFeatures"
    app.actions["hints.show"] = lambda a, p: a.ran("hints.show") \
        if preview in a.model["settings"]["nonDefaultKeys"] else a.refused()
    app.keys["cmd+j"] = lambda a: {"action": None}
    app.keys["f"] = lambda a: {"action": "hints.show"} if preview in a.model["settings"]["nonDefaultKeys"] \
        else {"action": None, "refused_action": "hints.show"}


# The converted cases this module dry-runs, by case id. A later batch adds its cases here.
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
        import subprocess
        words = list(argv)[3:]  # cmux --app-socket PATH ...
        if words[:2] == ["settings", "set"]:
            self.apps[-1].set_setting(words[2], json.loads(words[3]) is True)
        elif words[:2] == ["settings", "unset"]:
            self.apps[-1].set_setting(words[2], False)
        else:
            return subprocess.CompletedProcess(argv, 2, "", f"unknown cli {words}")
        return subprocess.CompletedProcess(argv, 0, "OK\n", "")


class BatchManifestTest(unittest.TestCase):
    def test_batches_cover_their_ranges_with_a_case_or_a_reason(self) -> None:
        scripts = mq_e2e()
        self.assertEqual(len(scripts), 66, "MQ-e2e has 66 scripts (p15-oracle.md section 2, item 4)")
        seen: Dict[str, str] = {}
        for name, batch in batches().items():
            match = BATCH.match(name)
            self.assertIsNotNone(match, f"{name}: name it _batch-<first>-<last>.json")
            first, last = int(match.group(1)), int(match.group(2))
            self.assertEqual(batch.get("range"), [first, last], name)
            self.assertEqual(sorted(batch["scripts"]), scripts[first - 1:last], f"{name}: scripts {first}-{last}")
            for script, entry in batch["scripts"].items():
                self.assertNotIn(script, seen, f"{script} is in {seen.get(script)} and {name}")
                seen[script] = name
                if "excluded" in entry:
                    self.assertNotIn("case", entry, script)
                    self.assertGreaterEqual(len(entry["excluded"]), 40, f"{script}: say why it does not convert")
                    continue
                for key in ("case", "bug", "parent", "fails_at"):
                    self.assertIn(key, entry, f"{script}: {key}")
                self.assertRegex(entry["bug"], SHA, script)
                self.assertRegex(entry["parent"], SHA, script)
                suite, case_name = entry["case"].split("/")
                self.assertEqual(suite, "e2e", script)
                case = json.loads((SUITE / f"{case_name}.json").read_text(encoding="utf-8"))
                self.assertIn(script, case["steps"][0].get("note", ""), f"{entry['case']}: its first step names the script")
                step_ids = [s["id"] for s in case["steps"]]
                self.assertIn(entry["fails_at"].split(":")[0], step_ids, f"{entry['case']}: fails_at names a step")
                self.assertIn(entry["case"], BEHAVIOR, f"{entry['case']}: add its head and parent behavior to BEHAVIOR")

    def test_coverage_json_is_current(self) -> None:
        import gen_e2e
        self.assertEqual(gen_e2e.main(["--check"]), 0, "run python3 -I scripts/cmux-next/oracle/gen_e2e.py")
        self.assertEqual(gen_e2e.coverage()["unknown"], [], "a batch names a script that is not in MQ-e2e")

    def test_every_case_of_the_suite_is_named_by_a_batch(self) -> None:
        named = {e["case"] for b in batches().values() for e in b["scripts"].values() if "case" in e}
        cases = {f"e2e/{p.stem}" for p in SUITE.glob("*.json") if not p.name.startswith("_") and p.name != "coverage.json"}
        self.assertEqual(cases, named)


class ConvertedCaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def run_as(self, case_id: str, parent: bool) -> Dict[str, Any]:
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
        case = json.loads((SUITE / f"{case_id.split('/')[1]}.json").read_text(encoding="utf-8"))
        try:
            return session.run_case(case, {"case_id": case_id})
        finally:
            session.close()

    def test_each_case_passes_on_head_and_fails_on_the_bugs_parent(self) -> None:
        entries = {e["case"]: e for b in batches().values() for e in b["scripts"].values() if "case" in e}
        for case_id in BEHAVIOR:
            with self.subTest(case=case_id):
                head = self.run_as(case_id, parent=False)
                self.assertEqual(head["status"], "Pass", head.get("message"))
                parent = self.run_as(case_id, parent=True)
                self.assertEqual(parent["status"], "Failure", parent.get("message"))
                self.assertEqual(parent.get("step"), entries[case_id]["fails_at"].split(":")[0], parent.get("message"))


if __name__ == "__main__":
    unittest.main()
