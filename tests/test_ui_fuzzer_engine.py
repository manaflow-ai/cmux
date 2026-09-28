#!/usr/bin/env python3
"""The UI fuzzer's pure parts (dogfood/fuzz/cmuxfuzz): generation, oracles, minimization, signatures and the
public issue text. Driving an app needs a Mac with a console session; these need nothing."""

from __future__ import annotations

import json
import random
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "dogfood" / "fuzz"))

from cmuxfuzz import actions, oracles, triage  # noqa: E402
from cmuxfuzz.minimize import ddmin  # noqa: E402
from cmuxfuzz.signature import Signature, hang_signature, normalize  # noqa: E402

PANE_A = "999149DB-B3D6-48F7-817D-06CF744052C2"
PANE_B = "4FDBE39E-10F4-48BF-82A2-DDCB725A07E3"


def tree(*, focused=(True, False), surfaces=((["s1"], "s1"), (["s2"], "s2"))) -> dict:
    panes = [{"id": pid, "ref": f"pane:{n}", "focused": f, "surface_ids": ids, "selected_surface_id": sel}
             for n, (pid, f, (ids, sel)) in enumerate(zip((PANE_A, PANE_B), focused, surfaces))]
    return {"windows": [{"key": True, "workspaces": [{"selected": True, "ref": "workspace:1", "panes": panes}]}]}


def layout(*, container_w=1200.0, b_w=598.0, view_b_w=598.0) -> dict:
    """debug.layout's reply as the socket sends it: the payload nested under "layout"."""
    frame = lambda x, w: {"x": x, "y": 28, "width": w, "height": 800}
    return {"layout": {
        "layout": {"containerFrame": frame(240, container_w), "focusedPaneId": PANE_A,
                   "panes": [{"paneId": PANE_A, "tabIds": ["t1"], "frame": frame(240, 600)},
                             {"paneId": PANE_B, "tabIds": ["t2"], "frame": frame(842, b_w)}]},
        "selectedPanels": [
            {"paneId": PANE_A, "panelType": "terminal", "inWindow": True, "hidden": False,
             "viewFrame": {"x": 0, "y": 0, "width": 600, "height": 772}},
            {"paneId": PANE_B, "panelType": "terminal", "inWindow": True, "hidden": False,
             "viewFrame": {"x": 602, "y": 0, "width": view_b_w, "height": 772}},
        ]}}


class FakeSocket:
    def __init__(self, replies: dict):
        self.replies = replies

    def call(self, method, params=None, timeout=None):
        return self.replies[method]


class LayoutOracleTest(unittest.TestCase):
    def problems(self, t: dict, lay: dict) -> set[str]:
        return {name for name, _ in oracles.check_layout(FakeSocket({"system.tree": t, "debug.layout": lay}))}

    def test_a_healthy_split_passes(self) -> None:
        self.assertEqual(self.problems(tree(), layout()), set())

    def test_nested_debug_layout_payload_is_read(self) -> None:
        # The first cut read selectedPanels at the top level, so every pointer action skipped.
        self.assertEqual(len(oracles.debug_layout(FakeSocket({"debug.layout": layout()}))["selectedPanels"]), 2)

    def test_breakage_is_named(self) -> None:
        self.assertIn("focused-pane-count", self.problems(tree(focused=(True, True)), layout()))
        self.assertIn("container-degenerate", self.problems(tree(), layout(container_w=0)))
        self.assertIn("view-does-not-follow-model", self.problems(tree(), layout(view_b_w=200)))
        self.assertIn("selected-tab-not-in-pane",
                      self.problems(tree(surfaces=((["s1"], "s1"), (["s2"], "gone"))), layout()))

    def test_a_browser_view_under_its_toolbar_is_not_a_mismatch(self) -> None:
        lay = layout(view_b_w=598)
        lay["layout"]["selectedPanels"][1].update(panelType="browser")
        lay["layout"]["selectedPanels"][1]["viewFrame"]["height"] = 690
        self.assertEqual(self.problems(tree(), lay), set())


class GenerationTest(unittest.TestCase):
    def test_a_seed_gives_the_same_sequence(self) -> None:
        run = lambda seed: [actions.generate(random.Random(seed), {}, pointer=True) for _ in range(50)]
        self.assertEqual(run(3), run(3))
        self.assertNotEqual(run(3), run(4))

    def test_socket_only_runs_never_plan_pointer_actions(self) -> None:
        rng = random.Random(1)
        kinds = {actions.generate(rng, {}, pointer=False)["do"] for _ in range(2000)}
        self.assertFalse(kinds & {k.name for k in actions.KINDS if k.needs_pointer})

    def test_every_action_reads_as_words(self) -> None:
        rng = random.Random(0)
        for kind in actions.KINDS:
            step = {"do": kind.name, **kind.gen(rng)}
            text = actions.describe(step)
            self.assertFalse(text.startswith(kind.name + " `"), f"{kind.name} has no description")
            self.assertTrue(text.endswith("`"))


class MinimizeTest(unittest.TestCase):
    def test_ddmin_finds_the_two_steps_that_matter(self) -> None:
        steps = list(range(40))
        result = ddmin(steps, lambda c: 7 in c and 31 in c, max_replays=200)
        self.assertEqual(result.steps, [7, 31])
        self.assertFalse(result.exhausted)

    def test_budget_keeps_the_best_so_far(self) -> None:
        result = ddmin(list(range(40)), lambda c: 7 in c and 31 in c, max_replays=3)
        self.assertTrue(result.exhausted)
        self.assertIn(7, result.steps)
        self.assertIn(31, result.steps)


class SignatureTest(unittest.TestCase):
    def test_ids_and_numbers_do_not_split_one_bug(self) -> None:
        a = normalize(f"pane {PANE_A} at 0x1234abcd width 312.5")
        b = normalize(f"pane {PANE_B} at 0xdeadbeef width 17")
        self.assertEqual(a, b)
        self.assertEqual(Signature("hang", a, "t").digest, Signature("hang", b, "t").digest)

    def test_hang_signature_names_our_frame(self) -> None:
        sample = "\n".join([
            "Call graph:",
            "    2500 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)",
            "    + 2500 start  (in dyld) + 6992  [0x1]",
            "    +   2500 main  (in cmux DEV.debug.dylib) + 12  [0x2]",
            "    +     2500 Workspace.layoutPanes()  (in cmux DEV.debug.dylib) + 40  [0x3]",
            "    +       2500 __psynch_mutexwait  (in libsystem_kernel.dylib) + 8  [0x4]",
        ])
        sig = hang_signature(sample)
        self.assertIn("Workspace.layoutPanes()", sig.title)


class IssueTextTest(unittest.TestCase):
    def finding(self) -> dict:
        return {"signature": Signature("invariant", "container-degenerate",
                                       "Layout invariant broken: container-degenerate").to_json(),
                "detail": "container {'width': 0} on cmux12s-mac-mini.local in /Users/cmux/x and "
                          "/Users/Shared/cmux-build-fleet/fuzz/runs/r/session-000",
                "repro_steps": [{"do": "window_resize", "w": 480, "h": 800}], "seed": 5, "session_seed": 6,
                "sha": "a" * 40, "repro_replayed": True, "minimize_exhausted": False}

    def test_issue_text_carries_no_machine_detail(self) -> None:
        body = triage.issue_body(self.finding(), ["https://example.test/step-00000.png"], [])
        for leak in ("cmux12s", "mac-mini", "/Users/cmux", "cmux-build-fleet", ".local"):
            self.assertNotIn(leak, body)
        self.assertIn("Resize the window to 480x800 points", body)
        self.assertIn("cmux-fuzz-signature: " + self.finding()["signature"]["digest"], body)
        repro = json.loads(body.split("```json\n", 1)[1].split("\n```", 1)[0])
        self.assertEqual(repro["steps"], self.finding()["repro_steps"])


if __name__ == "__main__":
    unittest.main()
