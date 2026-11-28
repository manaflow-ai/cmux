#!/usr/bin/env python3
"""cloud-mvp-nightly-readback.py's accessibility read on stand-in CuaDriver answers.

Run 46142896615 (NIGHTLY 4613363345501) failed "auto: no Runs On control on the New Tab page ... the control shows only
with an active Cloud plan" with 0 AX rows read at launch and at the failure: the read asked no walk budget, read no
tree_markdown, dropped CuaDriver's errors, and the copy ran without CMUX_NEXT_ACCESSIBILITY, so its CEF pages had no
tree. The checks: every get_window_state asks timeout_ms 8000 and the tree; a structuredContent answer and its
tree_markdown rows are read; an error is kept for the note; an empty tree or a page without its composer is the rig's
(RigFailure), and only a read page without Runs On is a product failure; the launch passes the accessibility switch.
Run: python3 -I scripts/measure/tests/cloud-mvp-nightly-readback.test.py
"""
import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
spec = importlib.util.spec_from_file_location("readback", HERE.parent / "cloud-mvp-nightly-readback.py")
rb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rb)

MARKDOWN = """- [0] AXWindow "cmux"
  - AXGroup "New Tab"
    - [3] AXTextArea "Type a question"
    - AXRadioGroup "Runs On"
      - AXStaticText "Hybrid"
"""


class FakeCua:
    def __init__(self, state):
        self.state, self.calls = state, []

    def __call__(self, tool, args, timeout=90):
        self.calls.append((tool, args))
        if tool == "list_windows":
            return {"windows": [{"window_id": 7}]}
        return self.state


class ReadTest(unittest.TestCase):
    def read(self, state):
        fake = FakeCua(state)
        old, rb.lkr.cua = rb.lkr.cua, fake
        try:
            return rb.nodes(1), fake.calls
        finally:
            rb.lkr.cua = old

    def test_every_tree_read_asks_for_the_walk_budget_and_the_tree(self):
        _, calls = self.read({"elements": []})
        args = [a for tool, a in calls if tool == "get_window_state"][0]
        self.assertEqual(args["timeout_ms"], 8000)
        self.assertTrue(args["include_accessibility_tree"])

    def test_structured_content_and_unindexed_markdown_rows_are_read(self):
        seen, _ = self.read({"structuredContent": {
            "elements": [{"role": "AXTextArea", "label": "Type a question", "element_index": 3}],
            "tree_markdown": MARKDOWN}})
        self.assertIsNotNone(rb.composer(seen))
        self.assertEqual(rb.has_text(seen, "Runs On"), "Runs On")
        self.assertEqual(sum(1 for e in seen if e.get("label") == "Type a question"), 1)  # indexed once, not twice
        self.assertGreater(rb.LAST_READ["markdown"], 0)

    def test_an_error_is_kept_and_an_empty_tree_is_the_rigs(self):
        seen, _ = self.read({"error": "exit 1: AX API disabled"})
        self.assertIn("AX API disabled", rb.read_note())
        with self.assertRaises(rb.RigFailure):
            rb.require_tree(seen, "launch")

    def test_a_page_without_its_composer_is_the_rigs_and_a_read_page_without_runs_on_the_products(self):
        def chat(state):
            fake = FakeCua(state)
            old = rb.lkr.cua, rb.new_tab_page, rb.dump
            rb.lkr.cua = fake
            rb.new_tab_page = lambda sock, pid, folder: {"seen": rb.nodes(pid)}
            rb.dump = lambda *a, **k: {}
            try:
                rb.step_chat("sock", 1, "/tmp/demo", Path("/tmp"), "auto", "Hybrid", None)
            finally:
                rb.lkr.cua, rb.new_tab_page, rb.dump = old
        with self.assertRaises(rb.RigFailure):
            chat({"elements": [{"role": "AXButton", "label": "This Mac", "element_index": 1}]})
        with self.assertRaises(rb.ProductFailure):
            chat({"elements": [{"role": "AXTextArea", "label": "Type a question", "element_index": 3},
                               {"role": "AXButton", "label": "This Mac", "element_index": 4}]})

    def test_the_copy_launches_with_the_accessibility_switch(self):
        script = (ROOT / "scripts/measure/cloud-mvp-nightly-readback.sh").read_text()
        self.assertIn('CMUX_NEXT_ACCESSIBILITY=1 "$side" launch', script)
        side = (ROOT / "scripts/cmux-next/side-instance.sh").read_text()
        self.assertIn("--env CMUX_NEXT_ACCESSIBILITY=1", side)


if __name__ == "__main__":
    unittest.main()
