# SPDX-License-Identifier: MIT
"""Tests for the truth matrix's scorer: the claim mapping (cmux `outcome` first, then `evidence`, then the text of
tools without either), the confusion cells (UNC for `uncertain`), the rates, the report's re-derivation of stored
rows, and the tab matcher (cmux's `tab_button`). Stdlib only; no display, no MCP server.

  python3 -m unittest -v test_truthscore          (from evals/computer-use/macos)
"""

import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(1, os.path.dirname(HERE))  # evals/computer-use, for bgmatrix's `cueval` imports

import truthmatrix_claims as tc  # noqa: E402
import truthreport as tr  # noqa: E402


def cmux_result(**top):
    """A cmux tool result as the engine sends it: sorted top-level keys, the window tree under "state"."""
    body = dict(top)
    body["state"] = {"root": {"children": [{"id": f"1.{i}", "role": "text", "value": "x" * 40} for i in range(80)]}}
    return json.dumps(body, sort_keys=True)


def rec(text, is_error=False, fields=None):
    r = {"tool": "click", "result": text[:1500], "is_error": is_error}
    if fields is not None:
        r["claim_fields"] = fields
    return r


class ClaimOf(unittest.TestCase):
    def test_outcome_is_the_claim_when_present(self):
        for out in ("confirmed", "no_effect", "uncertain"):
            text = cmux_result(outcome=out, evidence="delivered", route="ax_press")
            self.assertEqual(tc.claim_of("cmux-cu", rec(text)), out)

    def test_outcome_wins_over_evidence(self):
        # the engine keeps the older evidence marker next to outcome (no_effect keeps no_visible_change)
        text = cmux_result(outcome="no_effect", evidence="no_visible_change")
        self.assertEqual(tc.claim_of("cmux-cu", rec(text)), "no_effect")
        text = cmux_result(outcome="uncertain", evidence="delivered")
        self.assertEqual(tc.claim_of("cmux-cu", rec(text)), "uncertain")

    def test_outcome_survives_truncation_through_claim_fields(self):
        full = cmux_result(outcome="uncertain", evidence="delivered")
        self.assertGreater(len(full), 1500)
        r = rec(full, fields=tc.top_fields(full))
        self.assertEqual(r["claim_fields"]["outcome"], "uncertain")
        self.assertEqual(tc.claim_of("cmux-cu", r), "uncertain")

    def test_truncated_record_without_fields_reads_the_top_level_only(self):
        full = cmux_result(outcome="no_effect", evidence="no_visible_change")
        self.assertEqual(tc.claim_of("cmux-cu", rec(full)), "no_effect")  # top-level keys precede "state"
        # an "outcome" inside the nested state is not the call's claim
        nested = json.dumps({"evidence": "delivered", "state": {"outcome": "confirmed"}}, sort_keys=True)
        self.assertEqual(tc.claim_of("cmux-cu", rec(nested + " " * 2000)), "delivered")

    def test_evidence_when_the_engine_sends_no_outcome(self):
        for ev in ("confirmed", "delivered", "no_visible_change"):
            self.assertEqual(tc.claim_of("cmux-cu", rec(cmux_result(evidence=ev))), ev)

    def test_unknown_outcome_value_falls_back_to_evidence(self):
        text = cmux_result(outcome="something_new", evidence="delivered")
        self.assertEqual(tc.claim_of("cmux-cu", rec(text)), "delivered")

    def test_errors_and_refusals(self):
        self.assertEqual(tc.claim_of("cmux-cu", rec('{"code":"unsupported","error":"menu item stays disabled"}', True)), "error")
        self.assertEqual(tc.claim_of("cmux-cu", rec('{"code":"target_not_allowed","error":"app denied"}', True)), "refused")

    def test_tools_without_outcome_or_evidence(self):
        self.assertEqual(tc.claim_of("cua-driver-0.38.0", rec("✅ Performed AXPress on [3] AXCheckBox.")), "ok")
        self.assertEqual(tc.claim_of("cua-driver-0.38.0", rec("📨 Sent (unverified) AXValue on [8] AXSlider.")), "delivered")
        self.assertEqual(tc.claim_of("cua-driver-0.38.0", rec("Value confirmed by read-back.")), "confirmed")
        self.assertEqual(tc.claim_of("cua-driver-0.38.0", rec("Value could not be confirmed.")), "ok")
        self.assertEqual(tc.claim_of("aside", rec("clicked")), "ok")
        self.assertEqual(tc.claim_of("aside", rec("Error: no element 12")), "error")
        self.assertIsNone(tc.claim_of("aside", None))


class ConfusionCell(unittest.TestCase):
    def test_uncertain_is_its_own_cell(self):
        for truth in ("correct", "none", "wrong"):
            self.assertEqual(tc.confusion_cell("uncertain", truth), "UNC")
        self.assertEqual(tc.confusion_cell("uncertain", "none", expect_none=True), "UNC")

    def test_no_effect_is_negative_and_confirmed_positive(self):
        self.assertEqual(tc.confusion_cell("no_effect", "correct"), "FN")
        self.assertEqual(tc.confusion_cell("no_effect", "none"), "TN")
        self.assertEqual(tc.confusion_cell("no_effect", "wrong"), "TN")
        self.assertEqual(tc.confusion_cell("confirmed", "correct"), "TP")
        self.assertEqual(tc.confusion_cell("confirmed", "none"), "FP")
        self.assertEqual(tc.confusion_cell("confirmed", "wrong"), "FP")

    def test_side_effect_wins_whatever_the_claim(self):
        for claim in ("confirmed", "no_effect", "uncertain", "delivered"):
            self.assertEqual(tc.confusion_cell(claim, "extra"), "SIDE")

    def test_expect_none(self):
        self.assertEqual(tc.confusion_cell("confirmed", "none", expect_none=True), "FP")
        self.assertEqual(tc.confusion_cell("no_effect", "none", expect_none=True), "TN")

    def test_not_scored(self):
        self.assertEqual(tc.confusion_cell(None, "correct"), "no_action")
        self.assertEqual(tc.confusion_cell("confirmed", None), "not_scored")


class Rates(unittest.TestCase):
    def rows(self, spec):
        return [{"outcome": o, "truth": t} for o, t, n in spec for _ in range(n)]

    def test_uncertain_is_out_of_both_rates(self):
        c = tr.conf(self.rows([("TP", "correct", 6), ("FP", "none", 2), ("FN", "correct", 1), ("TN", "none", 3),
                               ("UNC", "correct", 4), ("UNC", "none", 4), ("no_action", None, 5)]))
        self.assertEqual(c["scored"], 20)
        self.assertEqual(c["UNC"], 8)
        self.assertAlmostEqual(c["fp_rate"], 2 / 8)
        self.assertAlmostEqual(c["fn_rate"], 1 / 4)
        self.assertAlmostEqual(c["unc_rate"], 8 / 20)
        self.assertAlmostEqual(c["effect_rate"], (6 + 1 + 4) / 20)  # every intended effect, whatever the claim
        self.assertEqual(c["no_action"], 5)

    def test_table_has_a_unc_column(self):
        c = tr.conf(self.rows([("UNC", "none", 2)]))
        row = tr.conf_row("arm", c)
        self.assertEqual(len(row), len(tr.CONF_HEAD))
        self.assertEqual(row[tr.CONF_HEAD.index("UNC")], 2)


class ReportRederives(unittest.TestCase):
    def row(self, result, truth, outcome="TP"):
        return {"arm": "cmux-cu", "app": "lab", "action": "menu_submenu", "scene": "bg", "rep": 1, "truth": truth,
                "outcome": outcome, "claim": "delivered", "detail": "", "scored_call": {"tool": "click", "args": {},
                "result": result, "is_error": False}}

    def test_a_stored_row_is_rescored_from_its_outcome(self):
        rows = tr.fixup([self.row(cmux_result(outcome="uncertain", evidence="delivered"), "correct")])
        self.assertEqual((rows[0]["claim"], rows[0]["outcome"]), ("uncertain", "UNC"))
        rows = tr.fixup([self.row(cmux_result(outcome="no_effect", evidence="no_visible_change"), "correct")])
        self.assertEqual((rows[0]["claim"], rows[0]["outcome"]), ("no_effect", "FN"))

    def test_rows_without_outcome_keep_their_evidence_score(self):
        rows = tr.fixup([self.row(cmux_result(evidence="delivered"), "none", outcome="FP")])
        self.assertEqual((rows[0]["claim"], rows[0]["outcome"]), ("delivered", "FP"))


class TabMatcher(unittest.TestCase):
    """cmux CU names an NSTabView's tabs `tab_button "General"` / `tab_button "Advanced"`."""

    @classmethod
    def setUpClass(cls):
        import truthmatrix as tm
        cls.tm = tm
        cls.bm = tm.bm

    def cmux_tree(self, children):
        bm = self.bm

        class Result:
            is_error = False
            data = {"root": {"role": "window", "children": children}}

            def text(self):
                return json.dumps(self.data)

        arm = object.__new__(bm.Cmux)
        arm.calls = []
        arm.call = lambda name, args, timeout=90: Result()
        return arm.tree({"wid": "1"})

    def test_tab_button_is_found_by_name(self):
        nodes = self.cmux_tree([{"id": "9.1", "role": "tab_button", "name": "General"},
                                {"id": "9.2", "role": "tab_button", "name": "Advanced"}])
        n = self.tm.find(nodes, "Advanced", self.tm.TAB_ROLES)
        self.assertEqual(n["key"], "9.2")

    def test_older_shapes_still_match(self):
        for role in ("radio", "radio_button", "tab"):
            nodes = self.cmux_tree([{"id": "9.2", "role": role, "name": "Advanced"}])
            self.assertEqual(self.tm.find(nodes, "Advanced", self.tm.TAB_ROLES)["key"], "9.2")

    def test_unnamed_tabs_are_not_matched(self):
        nodes = self.cmux_tree([{"id": "9.1", "role": "button"}, {"id": "9.2", "role": "button"}])
        with self.assertRaises(self.bm.ToolError):
            self.tm.find(nodes, "Advanced", self.tm.TAB_ROLES)


if __name__ == "__main__":
    unittest.main()
