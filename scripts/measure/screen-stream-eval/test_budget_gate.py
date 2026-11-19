"""budget_gate.py: a stage over its budget fails and is named; nothing measured never passes.

  python3 -m unittest scripts/measure/screen-stream-eval/test_budget_gate.py
"""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("screen_eval_budget_gate", HERE / "budget_gate.py")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)
VS_PATH = HERE.parents[2] / "cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py"


def results(render=9.0, sck=3.0, pickup=1.0, gate_ms=1.0, encode=5.0, transport=6.0, decode=2.0, total=40.0):
    def part(p50):
        return None if p50 is None else {"n": 50, "p50": p50, "p95": p50 * 2}
    return {"schema": gate.RESULTS_SCHEMA, "run": {"link": "lan", "rev": "0123456789abcdef"}, "targets": {
        "rd": {"latency": {"key": {"p50_ms": total}},
               "split": {"key": {"encode_ms": encode, "transport_ms": transport, "decode_ms": decode,
                                 "input_to_capture_parts": {"render_ms": part(render), "sck_ms": part(sck),
                                                            "pickup_ms": part(pickup), "gate_ms": part(gate_ms),
                                                            "encode_ms": part(encode)}}}},
        "webrtc": {"latency": {"key": {"p50_ms": 900.0}}}}}


class GateTests(unittest.TestCase):
    def run_gate(self, source, *extra):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        path = Path(folder.name) / "in.json"
        path.write_text(source if isinstance(source, str) else json.dumps(source))
        out, summary = Path(folder.name) / "gate.json", Path(folder.name) / "summary.md"
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            code = gate.main(["check", str(path), "--out", str(out), "--summary", str(summary), *extra])
        record = json.loads(out.read_text()) if out.exists() else None
        return code, record, printed.getvalue(), summary.read_text() if summary.exists() else ""

    def test_within_budget_passes(self):
        code, record, printed, summary = self.run_gate(results())
        self.assertEqual(code, 0, printed)
        self.assertEqual(record["over"], [])
        self.assertIn("Every measured stage is within budget", summary)
        self.assertNotIn("::error", printed)

    def test_stage_over_budget_fails_and_is_named(self):
        code, record, printed, summary = self.run_gate(results(render=20.7))
        self.assertEqual(code, 1)
        self.assertEqual(record["over"], ["Screen"])
        self.assertIn("::error title=screen share budget: Screen::Screen p50 20.7 ms is over its 12 ms budget", printed)
        self.assertIn("**Over budget: Screen**", summary)

    def test_every_stage_over_is_named(self):
        code, record, printed, _ = self.run_gate(results(encode=9.5, decode=6.0, total=80.0))
        self.assertEqual(code, 1)
        self.assertEqual(record["over"], ["Encode", "Decode", "Total"])

    def test_capture_sums_its_parts(self):
        code, record, _, _ = self.run_gate(results(sck=4.0, pickup=2.0, gate_ms=2.5))
        self.assertEqual(code, 1)
        capture = next(r for r in record["rows"] if r["stage"] == "Capture")
        self.assertEqual((capture["p50"], capture["verdict"]), (8.5, "over"))

    def test_transport_judged_against_the_three_budgets(self):
        code, record, _, _ = self.run_gate(results(transport=10.9))
        row = next(r for r in record["rows"] if r["stage"] == "Send + Network + Reassembly")
        self.assertEqual((code, row["budget_ms"], row["verdict"]), (0, 11, "ok"))
        code, record, _, _ = self.run_gate(results(transport=240.0))
        self.assertEqual((code, record["over"]), (1, ["Send + Network + Reassembly"]))

    def test_null_stage_is_not_measured_not_failed(self):
        code, record, _, _ = self.run_gate(results(render=None))
        self.assertEqual(code, 0)
        screen = next(r for r in record["rows"] if r["stage"] == "Screen")
        self.assertEqual(screen["verdict"], "not measured")
        present = next(r for r in record["rows"] if r["stage"] == "Present")
        self.assertEqual(present["verdict"], "not measured")

    def test_nothing_measured_never_passes(self):
        code, _, printed, _ = self.run_gate(results(render=None, sck=None, encode=None, transport=None,
                                                    decode=None, total=None))
        self.assertEqual(code, 2)
        self.assertIn("no stage was measured", printed)

    def test_missing_rd_target_never_passes(self):
        source = results()
        del source["targets"]["rd"]
        code, _, printed, _ = self.run_gate(source)
        self.assertEqual(code, 2)
        self.assertIn("no 'rd' target", printed)

    def test_override_tightens_one_stage(self):
        code, record, printed, summary = self.run_gate(results(), "--budget", "encode=0.1")
        self.assertEqual((code, record["over"]), (1, ["Encode"]))
        self.assertEqual(record["overrides"], {"Encode": 0.1})
        self.assertIn("Budgets replaced for this run: Encode 0.1 ms", summary)
        self.assertIn("screen share budget: Encode", printed)

    def test_unknown_override_is_refused(self):
        for pair in ("Warp=3", "Screen=nan", "Screen=inf", "Screen=-1", "Screen=fast"):
            with self.assertRaises(SystemExit, msg=pair):
                gate.parse_overrides([pair])

    def test_budget_record_lines_from_screen_share_vs(self):
        rows = [{"row": name, "budget_ms": ms, "cmux": {"null": "no ledger"}} for name, ms in gate.BUDGETS.items()]
        rows[list(gate.BUDGETS).index("Send")]["cmux"] = {"p50": 240.0, "p95": 400.0, "source": "send"}
        rows[list(gate.BUDGETS).index("Encode")]["cmux"] = {"p50": 6.0, "p95": 9.0, "source": "ledger"}
        record = {"schema": gate.BUDGET_SCHEMA, "label": "after", "rev": "abc", "rows": rows}
        lines = json.dumps({"other": 1}) + "\n" + json.dumps({"budget": record}) + "\n"
        code, judged, printed, _ = self.run_gate(lines)
        self.assertEqual((code, judged["over"]), (1, ["Send"]), printed)

    def test_embedded_budget_record_wins_over_the_split(self):
        source = results(render=50.0)
        rows = [{"row": "Encode", "budget_ms": 8, "cmux": {"p50": 3.0, "source": "ledger"}}]
        source["targets"]["rd"]["budget"] = {"schema": gate.BUDGET_SCHEMA, "rows": rows}
        code, record, _, _ = self.run_gate(source)
        self.assertEqual((code, [r["stage"] for r in record["rows"]]), (0, ["Encode"]))

    def test_budgets_match_screen_share_vs(self):
        if not VS_PATH.exists():
            self.skipTest("screen-share-vs.py is not in this checkout")
        spec = importlib.util.spec_from_file_location("screen_share_vs", VS_PATH)
        vs = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(vs)
        self.assertEqual({row: ms for row, ms, _, _ in vs.BUDGET_ROWS}, gate.BUDGETS)


if __name__ == "__main__":
    unittest.main()
