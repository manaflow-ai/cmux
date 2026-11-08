#!/usr/bin/env python3
"""cu_bench.py without a GUI: the stats, the answer parsers, and a whole run against fake engines
(one per catalog shape) that play Calculator over MCP stdio.

  python3 scripts/measure/cu-bench/test_cu_bench.py
"""

from __future__ import annotations

import json
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import cu_bench  # noqa: E402

# A fake engine: PROFILE is app (tree as indexed text) or tree (JSON tree, window ids).
FAKE = textwrap.dedent('''
    import json, sys
    PROFILE = sys.argv[1]
    BUTTONS = [("AllClear", "all clear", "c"), ("One", "1", "1"), ("Two", "2", "2"), ("Five", "5", "5"),
               ("Seven", "7", "7"), ("Multiply", "multiply", "*"), ("Equals", "equals", "=")]
    expr = ""
    def shown():
        return str(eval(expr[:-1])) if expr.endswith("=") else (expr.split("*")[-1] or "0")
    def press(ch):
        global expr
        if ch == "c":
            expr = ""
        elif ch == "=":
            expr += "="
        else:
            expr = (ch if expr.endswith("=") else expr + ch)
    def state_text():
        lines = ["0 standard window Calculator", "\\t1 scroll area", "\\t\\t2 static text Value: \\u200e" + shown()]
        for i, (ident, desc, _) in enumerate(BUTTONS):
            lines.append("\\t%d button Description: %s, ID: %s" % (i + 3, desc, ident))
        return "\\n".join(lines)
    def state_json():
        kids = [{"id": "e-display", "role": "AXStaticText", "value": shown()}]
        kids += [{"id": "e-%d" % i, "role": "AXButton", "description": d, "identifier": ident}
                 for i, (ident, d, _) in enumerate(BUTTONS)]
        return {"window_id": "w1", "root": {"id": "e-root", "role": "AXWindow", "children": kids}}
    if PROFILE == "app":
        TOOLS = ["list_apps", "get_app_state", "click", "type_text", "press_key"]
    else:
        TOOLS = ["list_apps", "list_windows", "screenshot", "get_ui_tree", "click", "type_text", "press_key"]
    def answer(name, a):
        if name == "list_apps":
            return {"content": [{"type": "text", "text": "Calculator (com.apple.calculator) pid 42"}]}
        if name == "list_windows":
            return {"content": [{"type": "text", "text": json.dumps({"windows": [
                {"window_id": "w0", "app_name": "Finder", "pid": 1},
                {"window_id": "w1", "app_name": "Calculator", "pid": 42, "on_screen": True}]})}]}
        if PROFILE == "tree" and a.get("window_id") != "w1":
            return {"isError": True, "content": [{"type": "text", "text": "no window"}]}
        if name in ("get_app_state", "get_ui_tree"):
            body = state_text() if PROFILE == "app" else json.dumps(state_json())
            parts = [{"type": "text", "text": body}]
            if a.get("screenshot", True) and PROFILE == "app":
                parts.append({"type": "image", "mimeType": "image/jpeg", "data": "AAAA"})
            return {"content": parts}
        if name == "screenshot":
            return {"content": [{"type": "image", "mimeType": "image/png", "data": "AAAA"}]}
        if name == "click":
            key = "element_index" if PROFILE == "app" else "element_id"
            i = int(str(a[key]).replace("e-", "")) - (3 if PROFILE == "app" else 0)
            press(BUTTONS[i][2])
            return {"content": [{"type": "text", "text": state_text() if PROFILE == "app" else "ok"}]}
        if name == "press_key":
            k = a.get("key", a.get("keys"))
            press({"Escape": "c", "asterisk": "*", "Return": "="}.get(k, k))
            return {"content": [{"type": "text", "text": "ok"}]}
        if name == "type_text":
            for ch in a["text"]:
                press(ch)
            return {"content": [{"type": "text", "text": "ok"}]}
        return {"isError": True, "content": [{"type": "text", "text": "unknown " + name}]}
    for raw in sys.stdin:
        msg = json.loads(raw)
        if "id" not in msg:
            continue
        m, p = msg["method"], msg.get("params", {})
        if m == "initialize":
            res = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake"}}
        elif m == "tools/list":
            sch = {"type": "object", "properties": {"app": {"type": "string"}, "element_index": {"type": "integer"},
                   "element_id": {"type": "string"}, "window_id": {"type": "string"}, "screenshot": {"type": "boolean"},
                   "key": {"type": "string"}, "keys": {"type": "string"}, "text": {"type": "string"}}}
            if PROFILE == "tree":
                for drop in ("key", "app", "element_index", "screenshot"):
                    sch["properties"].pop(drop)
            res = {"tools": [{"name": t, "inputSchema": sch} for t in TOOLS]}
        else:
            res = answer(p["name"], p.get("arguments", {}))
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": res}) + "\\n")
        sys.stdout.flush()
''')


class Stats(unittest.TestCase):
    def test_percentile(self):
        self.assertIsNone(cu_bench.percentile([], 0.5))
        self.assertEqual(cu_bench.percentile([3.0], 0.95), 3.0)
        self.assertEqual(cu_bench.percentile([1, 2, 3, 4], 0.5), 2.5)
        self.assertAlmostEqual(cu_bench.percentile(list(range(1, 101)), 0.95), 95.05)

    def test_summarize_counts_errors_apart(self):
        row = cu_bench.summarize([{"ok": True, "ms": 10, "bytes": 100}, {"ok": True, "ms": 30, "bytes": 300},
                                  {"ok": False, "ms": 5, "error": "boom"}])
        self.assertEqual((row["n"], row["ok"], row["errors"]), (3, 2, 1))
        self.assertEqual((row["median_ms"], row["min_ms"], row["max_ms"], row["bytes_median"]), (20.0, 10.0, 30.0, 200))
        self.assertEqual(row["first_error"], "boom")

    def test_summarize_nothing_measured_is_null(self):
        row = cu_bench.summarize([{"ok": False, "ms": 1, "error": "x"}])
        self.assertIsNone(row["median_ms"])
        self.assertIsNone(row["p95_ms"])


def text(body: str) -> dict:
    return {"content": [{"type": "text", "text": body}]}


class Parsing(unittest.TestCase):
    INDEXED = "0 standard window Calculator\n\t2 static text Value: ‎84\n\t3 button Description: 1, ID: One\n" \
              "\t4 button Description: multiply, ID: Multiply\n\t5 button Description: all clear, ID: AllClear"
    BRACKETED = '- [7] AXButton "7" (id=Seven)\n- [8] AXButton "=" (id=Equals)\n- [9] AXStaticText "12"'

    def test_indexed_text(self):
        r = text(self.INDEXED)
        self.assertEqual(cu_bench.find_element(r, "1"), "3")
        self.assertEqual(cu_bench.find_element(r, "multiply"), "4")
        self.assertEqual(cu_bench.find_element(r, "clear"), "5")
        self.assertIsNone(cu_bench.find_element(r, "7"))
        self.assertTrue(cu_bench.reads(r, "84"))

    def test_bracketed_text(self):
        r = text(self.BRACKETED)
        self.assertEqual(cu_bench.find_element(r, "7"), "7")
        self.assertEqual(cu_bench.find_element(r, "equals"), "8")
        self.assertFalse(cu_bench.reads(r, "84"))

    def test_json_tree(self):
        tree = {"root": {"id": "r", "role": "AXWindow", "children": [
            {"id": "d", "role": "AXStaticText", "value": "1,234"},
            {"id": "b2", "role": "AXButton", "description": "2", "identifier": "Two"}]}}
        r = {"content": [{"type": "text", "text": json.dumps(tree)}]}
        self.assertEqual(cu_bench.find_element(r, "2"), "b2")
        self.assertTrue(cu_bench.reads(r, "1234"))
        self.assertTrue(cu_bench.reads({"structuredContent": tree, "content": []}, "1234"))

    def test_index_is_not_a_label(self):
        # Element 1 is the scroll area, not the "1" button.
        self.assertIsNone(cu_bench.find_element(text("\t1 scroll area\n\t2 group"), "1"))

    def test_find_window_prefers_the_app(self):
        doc = {"windows": [{"window_id": 5, "app_name": "Finder", "pid": 1},
                           {"window_id": 9, "app_name": "Calculator", "pid": 42}]}
        self.assertEqual(cu_bench.find_window(doc, 42, "Calculator", "com.apple.calculator"), {"window_id": 9, "pid": 42})
        self.assertIsNone(cu_bench.find_window(doc, None, "Notes", "com.apple.Notes"))


class FakeRun(unittest.TestCase):
    def test_every_profile_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "fake_engine.py"
            fake.write_text(FAKE)
            out = Path(tmp) / "out"
            argv = ["run", "--out", str(out), "--app", "", "--rounds", "2", "--samples", "2", "--settle", "0",
                    "--timeout", "10",
                    "--server", f"text-engine={sys.executable} -I {fake} app",
                    "--server", f"json-engine={sys.executable} -I {fake} tree"]
            self.assertEqual(cu_bench.main(argv), 0)
            data = json.loads((out / "cu-bench.json").read_text())
            self.assertEqual(data["schema"], cu_bench.SCHEMA)
            for name, profile in (("text-engine", "app"), ("json-engine", "tree")):
                e = data["engines"][name]
                self.assertIsNone(e["unavailable"], name)
                self.assertEqual(e["profile"], profile)
                for op in cu_bench.OPS:
                    self.assertEqual(e["ops"][op]["ok"], 4, f"{name} {op}: {e['ops'][op]}")
                self.assertEqual((e["e2e"]["n"], e["e2e"]["reads_84"]), (2, 2), f"{name}: {e['e2e']}")
                self.assertEqual(e["e2e"]["modes"], ["clicks"])
            md = (out / "summary.md").read_text()
            self.assertIn("| e2e 12x7= |", md)
            self.assertIn("2/2 read 84", md)
            lines = (out / "samples.jsonl").read_text().splitlines()
            self.assertEqual(len(lines), 2 * 2 * (6 * 2 + 1))
            self.assertTrue((out / "first" / "text-engine-screenshot.txt").exists())

    def test_engine_that_fails_to_start_is_unavailable(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            argv = ["run", "--out", str(out), "--app", "", "--rounds", "1", "--settle", "0",
                    "--server", "broken=/usr/bin/false"]
            self.assertEqual(cu_bench.main(argv), 4)
            data = json.loads((out / "cu-bench.json").read_text())
            self.assertIn("start:", data["engines"]["broken"]["unavailable"])
            self.assertIsNone(data["engines"]["broken"]["ops"]["click"]["median_ms"])

    def test_engine_that_answers_nothing_fails_the_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "fake_engine.py"
            fake.write_text(FAKE)
            out = Path(tmp) / "out"
            # The tree engine shows no window of Notes, so every setup fails.
            argv = ["run", "--out", str(out), "--app", str(Path(tmp) / "Notes.app"), "--rounds", "1", "--settle", "0",
                    "--server", f"json-engine={sys.executable} -I {fake} tree"]
            self.assertEqual(cu_bench.main(argv), 4)
            self.assertTrue(json.loads((out / "cu-bench.json").read_text())["engines"]["json-engine"]["errors"])


if __name__ == "__main__":
    unittest.main()
