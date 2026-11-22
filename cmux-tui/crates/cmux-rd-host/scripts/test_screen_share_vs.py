"""Unit tests for screen-share-vs.py: the budget table, compare, the motion frame score and the
Apple (RFB) leg's focus click, click mode and stall handling, with fakes (no Mac, no network).

  python3 -m unittest cmux-tui/crates/cmux-rd-host/scripts/test_screen_share_vs.py
"""
import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import socket
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def load_vs():
    loader = importlib.machinery.SourceFileLoader("screen_share_vs", os.path.join(HERE, "screen-share-vs.py"))
    spec = importlib.util.spec_from_loader("screen_share_vs", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


vs = load_vs()


def breakdown_row(**over):
    row = {"up": 1.0, "inject": 0.5, "draw": 10.0, "sck": 6.0, "gate": 2.0, "encode": 5.0,
           "send": 3.0, "first_packet": 1.0, "down": 4.0, "decode": 2.0, "total": 34.0}
    row.update(over)
    return row


def rows_named(b):
    return {r["row"]: r for r in b["rows"]}


class BudgetTable(unittest.TestCase):
    def test_maps_breakdown_onto_design_rows_and_nulls_the_rest(self):
        b = vs.build_budget({"rows": [breakdown_row(), breakdown_row(up=3.0, total=40.0)]},
                            {"g2g": [20.0, 30.0, 40.0]}, label="after", rev="abc")
        rows = rows_named(b)
        self.assertEqual([r["row"] for r in b["rows"]],
                         ["Input", "Screen", "Capture", "Encode", "Send", "Network", "Reassembly",
                          "Decode", "Present", "Total"])
        self.assertEqual(rows["Input"]["cmux"]["source"], "up + inject")
        self.assertEqual(sorted([rows["Input"]["cmux"]["p50"], rows["Input"]["cmux"]["p95"]]), [1.5, 3.5])
        self.assertEqual(rows["Capture"]["cmux"]["p50"], 8.0)
        self.assertEqual(rows["Network"]["cmux"]["source"], "down")
        self.assertIn("ledger", rows["Reassembly"]["cmux"]["null"])
        self.assertIn("no window", rows["Present"]["cmux"]["null"])
        self.assertEqual(rows["Total"]["cmux"]["to"], "decoded")
        self.assertEqual(rows["Total"]["apple"]["p50"], 30.0)
        for name in ("Input", "Encode", "Decode", "Present"):
            self.assertIn("null", rows[name]["apple"])
        self.assertIn("headless", rows["Present"]["apple"]["null"])
        self.assertEqual(b["schema"], "cmux.screen-share-budget/1")
        self.assertEqual((b["label"], b["rev"]), ("after", "abc"))

    def test_sample_with_unknown_part_is_left_out_not_zeroed(self):
        b = vs.build_budget({"rows": [breakdown_row(draw=None), breakdown_row(draw=None)]}, None)
        self.assertIn("null", rows_named(b)["Screen"]["cmux"])
        self.assertEqual(rows_named(b)["Input"]["cmux"]["n"], 2)

    def test_presented_total_and_derived_present(self):
        b = vs.build_budget({"rows": [breakdown_row()] * 3, "presented": [50.0, 50.0, 50.0]}, None)
        rows = rows_named(b)
        self.assertEqual(rows["Total"]["cmux"]["to"], "presented")
        self.assertEqual(rows["Total"]["cmux"]["p50"], 50.0)
        self.assertEqual(rows["Present"]["cmux"]["p50"], 16.0)
        self.assertTrue(rows["Present"]["cmux"]["derived"])

    def test_ledger_fields_fill_rows_and_missing_fields_stay_null(self):
        ledger = {"schema": vs.LEDGER_SCHEMA, "input_sent_us": 0, "inject_us": 2000,
                  "display_us": 12000, "encode_start_us": 15000, "bitstream_ready_us": 20000,
                  "last_datagram_sent_us": 22000, "last_shard_us": 23000, "released_us": 23500,
                  "decoded_us": 26000}
        stages = vs.ledger_stages(ledger)
        self.assertEqual(stages["Reassembly"], 0.5)
        self.assertNotIn("Present", stages)
        self.assertEqual(vs.ledger_stages({"inject_us": 1}), {})
        b = vs.build_budget({"rows": [breakdown_row()], "ledgers": [stages]}, None)
        rows = rows_named(b)
        self.assertEqual(rows["Reassembly"]["cmux"]["source"], "ledger")
        self.assertEqual(rows["Input"]["cmux"]["p50"], 2.0)
        self.assertIn("null", rows["Present"]["cmux"])
        self.assertEqual(rows["Total"]["cmux"]["to"], "decoded")  # no presented_us: not the ledger

    def test_run_stage_ledger_fills_rows_no_sample_ledger_does(self):
        def summary(frames, reassembly_p95):
            return {"schema": vs.LEDGER_SCHEMA, "clock": "host monotonic", "frames": frames,
                    "stages": [
                        {"stage": "Reassembly", "n": frames, "p50_ms": 1.234, "p95_ms": reassembly_p95},
                        {"stage": "Input", "n": 0, "p50_ms": None, "p95_ms": None},
                        {"stage": "Total", "n": frames, "p50_ms": 30.0, "p95_ms": 40.0}]}
        b = vs.build_budget({"rows": [breakdown_row()],
                             "summaries": [summary(50, 9.0), summary(400, 5.5), {"schema": "other"}]},
                            None)
        rows = rows_named(b)
        cell = rows["Reassembly"]["cmux"]
        self.assertEqual((cell["source"], cell["n"], cell["p50"], cell["p95"], cell["trials"]),
                         ("ledger", 400, 1.23, 5.5, 2))
        # A stage the summary did not measure keeps the breakdown; Total is never the summary's.
        self.assertEqual(rows["Input"]["cmux"]["source"], "up + inject")
        self.assertEqual(rows["Total"]["cmux"]["source"], "total")
        # A per-sample ledger, when there is one, still wins.
        b = vs.build_budget({"rows": [breakdown_row()], "ledgers": [{"Reassembly": 0.5}],
                             "summaries": [summary(400, 5.5)]}, None)
        self.assertEqual(rows_named(b)["Reassembly"]["cmux"]["p50"], 0.5)
        self.assertNotIn("trials", rows_named(b)["Reassembly"]["cmux"])

    def test_skipped_stacks_say_why(self):
        b = vs.build_budget(None, {"skipped": "skipped: no --vnc-user"})
        rows = rows_named(b)
        self.assertEqual(rows["Total"]["apple"]["null"], "skipped: no --vnc-user")
        self.assertEqual(rows["Total"]["cmux"]["null"], "not run (--stacks)")
        self.assertEqual(b["mbps"]["apple"]["null"], "skipped: no --vnc-user")

    def test_mbps_and_quality(self):
        motion = [{"mbit_per_s": 10.0, "mbit_per_s_peak": 18.0}, {"mbit_per_s": 12.0, "mbit_per_s_peak": 20.0}]
        scores = [{"frame_score": 0.9, "text_cer": 0.1}, {"frame_score": 0.8, "text_null": "x"}]
        b = vs.build_budget({"rows": [], "motion_rows": motion, "scores": scores}, None)
        self.assertEqual(b["mbps"]["cmux"], {"avg": 11.0, "peak": 20.0, "n": 2})
        self.assertEqual(b["quality"]["cmux"]["frame_score"]["min"], 0.8)
        self.assertEqual(b["quality"]["cmux"]["text_cer"]["n"], 1)
        b = vs.build_budget({"rows": [], "quality_null": "old marker"}, None)
        self.assertEqual(b["quality"]["cmux"]["frame_score"]["null"], "old marker")

    def test_format_names_every_row_and_footnotes_each_null(self):
        b = vs.build_budget({"rows": [breakdown_row()]}, {"g2g": [25.0]}, label="before", rev="0123456789abcdef")
        text = "\n".join(vs.format_budget(b))
        for name in ("Input", "Screen", "Capture", "Encode", "Send", "Network", "Reassembly", "Decode",
                     "Present", "Total", "Mbps", "frame score", "text error"):
            self.assertIn(name, text)
        self.assertIn("before @ 0123456789ab", text)
        self.assertIn("34 / 34 (to decoded)", text)
        notes = [line for line in text.splitlines() if "] null: " in line]
        self.assertTrue(notes)
        for line in notes:
            n = line.split("]")[0].split("[")[1]
            self.assertIn(f"null [{n}]", text)


class Compare(unittest.TestCase):
    def write(self, d, name, budget, extra=()):
        path = os.path.join(d, name)
        with open(path, "w") as f:
            for rec in extra:
                f.write(json.dumps(rec) + "\n")
            f.write(json.dumps({"budget": budget}) + "\n")
        return path

    def test_side_by_side_with_change(self):
        with tempfile.TemporaryDirectory() as d:
            before = vs.build_budget({"rows": [breakdown_row(send=240.0, total=270.0)]},
                                     {"g2g": [150.0]}, label="before")
            after = vs.build_budget({"rows": [breakdown_row(send=6.0, total=36.0)]},
                                    {"g2g": [150.0]}, label="after")
            pb = self.write(d, "b.jsonl", before, [{"clock": {}}, {"summary": {}, "rtt": {}}])
            pa = self.write(d, "a.jsonl", after)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                vs.cmd_compare(argparse.Namespace(before=pb, after=pa, json=False))
            text = out.getvalue()
            self.assertIn("before -> after", text)
            send = next(line for line in text.splitlines() if line.strip().startswith("Send"))
            self.assertIn("240 / 240", send)
            self.assertIn("-234", send)
            reasm = next(line for line in text.splitlines() if line.strip().startswith("Reassembly"))
            self.assertIn("null", reasm)

    def test_file_without_budget_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "x.jsonl")
            with open(p, "w") as f:
                f.write(json.dumps({"summary": {}, "rtt": {}}) + "\n")
            with self.assertRaises(SystemExit):
                vs.load_budget(p)


GEO = {"display_pt": [400, 300], "stream_width_px": 800, "bar_pt": 48, "step_pt": 8,
       "bars_top_pt": 64, "panel_pt": [100, 110, 200, 80], "lines": 2, "line_pt": 36,
       "pad_pt": 4, "font_pt": 28, "tick_driven": True}
ORIGIN, CELL = (0, 0), 32


def render(counter, geo=GEO, marker=None):
    """A frame of the marker's motion scene for COUNTER, in stream pixels (2 px a point)."""
    scale = geo["stream_width_px"] / geo["display_pt"][0]
    w, h = int(geo["display_pt"][0] * scale), int(geo["display_pt"][1] * scale)
    rgb = bytearray([31, 31, 31] * (w * h))
    bar, period = geo["bar_pt"], geo["bar_pt"] * 2
    start = -bar + (counter * geo["step_pt"]) % period
    for y in range(int(geo["bars_top_pt"] * scale), h):
        for x in range(w):
            if ((x + 0.5) / scale - start) % period < bar:
                rgb[(y * w + x) * 3:(y * w + x) * 3 + 3] = bytes([200, 120, 90])
    value = counter if marker is None else marker
    bits = [(value >> i) & 1 == 1 for i in range(16)] + list(vs.GUARD)
    for i, on in enumerate(bits):
        for y in range(CELL):
            for x in range(i * CELL, (i + 1) * CELL):
                rgb[(y * w + x) * 3:(y * w + x) * 3 + 3] = bytes([255] * 3 if on else [0] * 3)
    return w, h, bytes(rgb)


def write_ppm(path, w, h, rgb):
    with open(path, "wb") as f:
        f.write(f"P6\n{w} {h}\n255\n".encode() + rgb)


class FrameScore(unittest.TestCase):
    def test_motion_line_matches_the_marker(self):
        self.assertEqual(vs.motion_line(12), "row 00012 the quick brown fox 084")
        self.assertEqual(vs.motion_truth(99999, 2).splitlines()[1], "row 00000 the quick brown fox 000")

    def test_matching_frame_scores_one_and_a_stale_one_less(self):
        w, h, rgb = render(5)
        self.assertEqual(vs.frame_score(rgb, w, h, GEO, 5), 1.0)
        self.assertLess(vs.frame_score(rgb, w, h, GEO, 7), 0.9)

    def test_score_frame_reads_counter_and_runs_ocr_on_the_panel(self):
        with tempfile.TemporaryDirectory() as d:
            ppm = os.path.join(d, "f.ppm")
            write_ppm(ppm, *render(9))
            out = vs.score_frame(ppm, GEO, ORIGIN, CELL)
            self.assertEqual(out["counter"], 9)
            self.assertEqual(out["frame_score"], 1.0)
            self.assertIn("screen-eval-ocr", out["text_null"])
            # A fake OCR: CER 0 when the truth file is the source's lines for counter 9.
            ocr = os.path.join(d, "ocr")
            with open(ocr, "w") as f:
                f.write(textwrap.dedent(f"""\
                    #!{sys.executable}
                    import json, sys
                    truth = open(sys.argv[3]).read()
                    open(sys.argv[1], "rb").read(2) == b"P6" or sys.exit(2)
                    print(json.dumps({{"viewer_cer_vs_truth": 0.0 if truth.startswith("row 00009") else 0.5}}))
                    """))
            os.chmod(ocr, 0o755)
            out = vs.score_frame(ppm, GEO, ORIGIN, CELL, ocr)
            self.assertEqual((out["text_cer"], out["text_cer_prev"]), (0.0, 0.5))
            self.assertEqual(sorted(os.listdir(d)), ["f.ppm", "ocr"])  # crop and truth removed

    def test_frame_without_marker_or_tick_is_null(self):
        with tempfile.TemporaryDirectory() as d:
            ppm = os.path.join(d, "f.ppm")
            w, h, rgb = render(3)
            write_ppm(ppm, w, h, bytes([128]) * len(rgb))
            self.assertIn("marker", vs.score_frame(ppm, GEO, ORIGIN, CELL)["frame_null"])
            write_ppm(ppm, w, h, rgb)
            self.assertIn("--tick", vs.score_frame(ppm, dict(GEO, tick_driven=False), ORIGIN, CELL)["frame_null"])

    def test_motion_geometry_line(self):
        log = "marker: x\nmotion-geometry " + json.dumps(GEO) + "\nmarker-origin 0,50 click-at 704,66\n"
        self.assertEqual(vs.motion_geometry(log), GEO)
        self.assertIsNone(vs.motion_geometry("marker-origin 0,50\n"))


FAKE_VNC = '''
import socket, struct

CELLS, CELL, OX, OY = 20, 32, 0, 0
W, H = CELL * 24, CELL
STATE = {"events": [], "reads": 0, "stall_after": None, "needs_focus": True}


class Desktop:
    def __init__(self):
        self.width, self.height = W, H
        self.rgb = bytearray(W * H * 3)


class TcpTransport:
    def __init__(self, host, port, timeout):
        self.sock, self.peer = socket.socketpair()

    def set_timeout(self, t):
        self.sock.settimeout(t)

    def close(self):
        self.sock.close()
        self.peer.close()


class RfbClient:
    def __init__(self, transport, password, username, auth, encodings):
        self.t = transport
        self.security_type = 30
        self.desktop = None
        self.counter = 7
        self.focused = not STATE["needs_focus"]
        self.wanted = False
        self.shown = None
        self.pressed = False

    def connect(self):
        self.desktop = Desktop()

    def _draw(self):
        bits = [(self.counter >> i) & 1 == 1 for i in range(16)] + [True, False, True, False]
        for i, on in enumerate(bits):
            for x in range(i * CELL, (i + 1) * CELL):
                o = ((OY + CELL // 2) * W + x) * 3
                self.desktop.rgb[o:o + 3] = bytes([255] * 3 if on else [0] * 3)

    def _maybe_update(self):
        if self.wanted and self.counter != self.shown:
            self.wanted = False
            self.t.peer.send(b"u")

    def send(self, data):
        if data[0] == 3:
            self.wanted = True
            if data[1] == 0:
                self.shown = None
            self._maybe_update()

    def key(self, keysym, down):
        STATE["events"].append(("key", down))
        if down and self.focused:
            self.counter = (self.counter + 1) & 0xFFFF
            self._maybe_update()

    def pointer(self, x, y, mask):
        STATE["events"].append(("pointer", x, y, mask))
        if mask and not self.pressed and x >= CELL * CELLS:
            self.focused = True
            self.counter = (self.counter + 1) & 0xFFFF
            self._maybe_update()
        self.pressed = bool(mask)

    def read_message(self):
        STATE["reads"] += 1
        if STATE["stall_after"] is not None and STATE["reads"] > STATE["stall_after"]:
            raise socket.timeout("timed out mid-message")
        self.t.sock.recv(1)
        self._draw()
        self.shown = self.counter
        return 0

    def close(self):
        self.t.close()
'''


class RfbLeg(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.vnc = os.path.join(self.dir.name, "cua-vnc")
        with open(self.vnc, "w") as f:
            f.write(FAKE_VNC)
        pw = os.path.join(self.dir.name, "pw")
        with open(pw, "w") as f:
            f.write("secret\n")
        os.chmod(pw, 0o600)
        self.env = {"VNC_USERNAME": "u", "VNC_PASSWORD_FILE": pw}
        os.environ.update(self.env)

    def tearDown(self):
        for k in self.env:
            os.environ.pop(k, None)
        sys.modules.pop("cua_vnc", None)
        self.dir.cleanup()

    def bench(self, mode="key", inp="key", samples=4, stall_after=None):
        vs.load_cua_vnc(self.vnc)  # the module rfb-bench will load: reset its state first
        args = argparse.Namespace(cua_vnc=self.vnc, host="h", port=5900, origin=[0, 0], cell=32,
                                  mode=mode, input=inp, samples=samples, duration_s=0.3)
        real_load = vs.load_cua_vnc

        def load(path):
            mod = real_load(path)
            mod.STATE["stall_after"] = stall_after
            self.state = mod.STATE
            return mod

        vs.load_cua_vnc = load
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out):
                vs.cmd_rfb_bench(args)
        finally:
            vs.load_cua_vnc = real_load
        return json.loads(out.getvalue().strip().splitlines()[-1])

    def test_keys_are_timed_only_after_a_focus_click_on_the_pad(self):
        rep = self.bench()
        self.assertTrue(rep["focus_click"])
        self.assertEqual(rep["lost"], 0)
        self.assertEqual(len(rep["key_to_frame_ms"]), 4)
        first = self.state["events"][0]
        self.assertEqual(first, ("pointer", 32 * 22, 16, 1))
        keys = [i for i, e in enumerate(self.state["events"]) if e[0] == "key"]
        self.assertGreater(keys[0], 1)

    def test_click_mode_times_pad_clicks(self):
        rep = self.bench(inp="click")
        self.assertEqual(rep["input"], "click")
        self.assertNotIn("focus_click", rep)
        self.assertEqual((rep["lost"], len(rep["key_to_frame_ms"])), (0, 4))
        self.assertFalse(any(e[0] == "key" for e in self.state["events"]))

    def test_a_stall_mid_message_ends_the_trial(self):
        rep = self.bench(samples=10, stall_after=4)
        self.assertIn("stalled", rep)
        self.assertEqual(self.state["reads"], 5)  # no read after the stalled one
        self.assertLess(len(rep["key_to_frame_ms"]), 10)
        self.assertGreaterEqual(rep["lost"], 1)

    def test_rfb_next_waits_outside_the_read(self):
        a, b = socket.socketpair()
        try:
            calls = []

            class T:
                sock = a

                def set_timeout(self, t):
                    calls.append(t)

            class C:
                t = T()

                def read_message(self):
                    calls.append("read")
                    return a.recv(1)[0]

            self.assertIsNone(vs.rfb_next(C(), 0.05))
            self.assertEqual(calls, [])
            b.send(b"\x00")
            self.assertEqual(vs.rfb_next(C(), 0.05), 0)
            self.assertEqual(calls, [vs.RFB_MESSAGE_S, "read"])
        finally:
            a.close()
            b.close()


if __name__ == "__main__":
    unittest.main()
