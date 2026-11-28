"""Unit tests for screen-share-vs.py: the budget table, compare, the motion frame score and the
Apple (RFB) leg's focus click, click mode and stall handling, and the --app-viewer presented leg,
with fakes (no Mac, no network).

  python3 -m unittest cmux-tui/crates/cmux-rd-host/scripts/test_screen_share_vs.py
"""
import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shlex
import socket
import sys
import tempfile
import textwrap
import threading
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
                         ["Input", "Screen", "Capture", " Frame lead", " Gate wait", " Readback", "Encode", "Send", "Network", "Reassembly",
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

    def test_click_and_scroll_aim_at_the_marker_pad(self):
        # Without --at the bench clicks 960,600, off the marker, and every click/scroll trial is lost.
        at = vs.marker_click_at("marker-origin 0,50 click-at 704,66")
        self.assertEqual(at, [704, 66])
        self.assertIsNone(vs.marker_click_at("marker-origin 0,50"))
        self.assertIsNone(vs.marker_click_at("marker: stream width 1920 px"))
        for kind in ("click", "scroll"):
            self.assertEqual(vs.bench_input(kind, 30, at), f"--input {kind} --samples 30 --at 704,66")
        self.assertEqual(vs.bench_input("key", 30, at), "--input key --samples 30")
        self.assertEqual(vs.bench_input("click", 30, None), "--input click --samples 30")


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


class RfbViewerLeg(unittest.TestCase):
    """rfb-bench without cua-vnc: the in-repo rfb-viewer.py client against a fake Apple RFB server."""
    CELL, W = 32, 32 * 24

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        pw = os.path.join(self.dir.name, "pw")
        with open(pw, "w") as f:
            f.write("secret\n")
        os.chmod(pw, 0o600)
        self.env = {"VNC_USERNAME": "u", "VNC_PASSWORD_FILE": pw}
        os.environ.update(self.env)
        self.lsock = socket.socket()
        self.lsock.bind(("127.0.0.1", 0))
        self.lsock.listen(1)
        self.events = []
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def tearDown(self):
        for k in self.env:
            os.environ.pop(k, None)
        sys.modules.pop("rfb_viewer", None)
        self.lsock.close()
        self.dir.cleanup()

    def serve(self):
        import struct
        conn, _ = self.lsock.accept()
        f = conn.makefile("rb")
        counter, wanted, shown, focused, pressed = 7, None, None, False, False

        def frame(rect):
            x, y, w, h = rect
            bits = [(counter >> i) & 1 == 1 for i in range(16)] + [True, False, True, False]
            row = bytearray()
            for px in range(x, x + w):
                i = px // self.CELL
                row += b"\xff\xff\xff\x00" if i < len(bits) and bits[i] else b"\x00\x00\x00\x00"
            conn.sendall(struct.pack("!BxH", 0, 1) + struct.pack("!HHHHi", x, y, w, h, 0) + bytes(row) * h)

        try:
            conn.sendall(b"RFB 003.889\n")
            f.read(12)
            conn.sendall(b"\x01\x1e")
            self.events.append(("security", f.read(1)[0]))
            prime = (0xFFFFFFFFFFFFFFC5).to_bytes(8, "big")
            conn.sendall(struct.pack("!HH", 2, 8) + prime + (5).to_bytes(8, "big"))
            f.read(128 + 8)
            conn.sendall(b"\0\0\0\0")
            f.read(1)
            conn.sendall(struct.pack("!HH", self.W, self.CELL) + bytes(16) + struct.pack("!I", 0))
            f.read(20)
            n = struct.unpack("!xxH", f.read(4))[0]
            f.read(4 * n)
            while True:
                kind = f.read(1)
                if not kind:
                    return
                if kind[0] == 3:
                    inc, *rect = struct.unpack("!BHHHH", f.read(9))
                    wanted = tuple(rect)
                    if not inc:
                        shown = None
                elif kind[0] == 4:
                    down, sym = struct.unpack("!BxxI", f.read(7))
                    self.events.append(("key", down))
                    if down and focused:
                        counter = (counter + 1) & 0xFFFF
                elif kind[0] == 5:
                    mask, x, y = struct.unpack("!BHH", f.read(5))
                    self.events.append(("pointer", x, y, mask))
                    if mask and not pressed and x >= self.CELL * vs.CELLS:
                        focused = True
                        counter = (counter + 1) & 0xFFFF
                    pressed = bool(mask)
                if wanted and counter != shown:
                    frame(wanted)
                    wanted, shown = None, counter
        except OSError:
            pass
        finally:
            conn.close()

    def test_keys_are_timed_through_rfb_viewer_without_cua_vnc(self):
        args = argparse.Namespace(cua_vnc=None, rfb_viewer=vs.RFB_VIEWER, host="127.0.0.1",
                                  port=self.lsock.getsockname()[1], origin=[0, 0], cell=self.CELL,
                                  mode="key", input="key", samples=4, duration_s=0.3)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            vs.cmd_rfb_bench(args)
        rep = json.loads(out.getvalue().strip().splitlines()[-1])
        self.assertNotIn("error", rep)
        self.assertEqual(rep["security_type"], 30)
        self.assertTrue(rep["focus_click"])
        self.assertEqual((rep["lost"], len(rep["key_to_frame_ms"])), (0, 4))
        self.assertEqual(self.events[0], ("security", 30))
        self.assertEqual(self.events[1], ("pointer", 32 * 22, 16, 1))

    def test_a_missing_cua_vnc_falls_back_to_rfb_viewer(self):
        args = argparse.Namespace(cua_vnc=os.path.join(self.dir.name, "absent"), rfb_viewer=None,
                                  host="127.0.0.1", port=self.lsock.getsockname()[1], origin=[0, 0],
                                  cell=self.CELL, mode="key", input="click", samples=2, duration_s=0.3)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            vs.cmd_rfb_bench(args)
        rep = json.loads(out.getvalue().strip().splitlines()[-1])
        self.assertEqual((rep.get("error"), rep["lost"]), (None, 0))


class TailnetHostIpTests(unittest.TestCase):
    def test_only_cgnat_addresses_count_as_tailnet(self):
        self.assertTrue(vs.tailnet("100.64.0.1"))
        self.assertTrue(vs.tailnet("100.127.255.254"))
        self.assertFalse(vs.tailnet("100.128.0.1"))
        self.assertFalse(vs.tailnet("172.20.21.250"))
        self.assertFalse(vs.tailnet("cmux20"))

    def clock_failure(self, host_ip):
        import queue
        import types
        srv = types.SimpleNamespace(lines=queue.Queue(), terminate=lambda: None)
        srv.lines.put('{"listening": 4000}')

        def fail(cmd, timeout=120):
            raise RuntimeError("viewer: clock-probe: exit 1: no clock replies")
        me = types.SimpleNamespace(
            a=types.SimpleNamespace(host="mac-a", host_ip=host_ip, clock_count=5),
            py="python3", me="screen-share-vs.py",
            host=types.SimpleNamespace(popen=lambda cmd: srv),
            viewer=types.SimpleNamespace(run=fail), CLOCK_TRIES=2)
        me.clock_over_peer = lambda: False
        me.clock_once = lambda: vs.Orchestrator.clock_once(me)
        with self.assertRaises(RuntimeError) as cm, contextlib.redirect_stderr(io.StringIO()):
            vs.Orchestrator.clock(me)
        return str(cm.exception)

    def test_a_clock_failure_on_a_tailnet_host_ip_names_the_cause(self):
        msg = self.clock_failure("100.101.102.103")
        self.assertIn("no clock replies", msg)
        self.assertIn("LAN address", msg)

    def test_a_clock_failure_on_a_lan_host_ip_is_left_as_is(self):
        self.assertNotIn("LAN address", self.clock_failure("172.20.21.250"))


class BudgetInputTests(unittest.TestCase):
    def test_budget_names_the_input_kind_and_pair(self):
        b = vs.build_budget({"rows": [breakdown_row()]}, None, cmux_input="scroll", host="mac-a", viewer="mac-b")
        self.assertEqual((b["input"], b["host"], b["viewer"]), ("scroll", "mac-a", "mac-b"))

    def test_budget_input_defaults_to_key(self):
        self.assertEqual(vs.build_budget({"rows": [breakdown_row()]}, None)["input"], "key")

    def test_budget_names_the_encode_profile(self):
        b = vs.build_budget({"rows": [breakdown_row()]}, None, encode_profile="ultra")
        self.assertEqual(b["encode_profile"], "ultra")
        self.assertIsNone(vs.build_budget({"rows": [breakdown_row()]}, None)["encode_profile"])


class FakeRelay(vs.SpoolRemote):
    """A SpoolRemote whose relay is a local shell: each run is one `reach` call's command,
    refused with "nothing was run" for the first FAILS calls."""

    def __init__(self, fails=0):
        super().__init__("fake-mac")
        self.calls, self.fails = [], fails

    def argv(self, cmd):
        self.calls.append(cmd)
        if self.fails:
            self.fails -= 1
            return ["sh", "-c", "echo 'reach: refused: nothing was run' >&2; exit 4"]
        return ["sh", "-c", cmd]


class SpoolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.sleep = vs.time.sleep
        vs.time.sleep = lambda s: None

    def tearDown(self):
        vs.time.sleep = self.sleep

    def test_put_chunks_under_the_relay_command_limit(self):
        relay = FakeRelay()
        src = os.path.join(self.tmp, "blob")
        with open(src, "wb") as f:
            f.write(os.urandom(100_000))  # random: gzip cannot shrink it below several chunks
        dst = os.path.join(self.tmp, "out", "blob")
        relay.put(src, dst)
        with open(src, "rb") as a, open(dst, "rb") as b:
            self.assertEqual(a.read(), b.read())
        self.assertGreater(len(relay.calls), 4)
        self.assertTrue(all(len(c.encode()) <= 16384 for c in relay.calls), "a call over the relay's 16 KiB")

    def test_run_retries_a_refusal_that_ran_nothing(self):
        relay = FakeRelay(fails=2)
        self.assertEqual(relay.run("printf ok"), "ok")
        self.assertEqual(len(relay.calls), 3)

    def test_run_does_not_retry_a_command_that_failed(self):
        relay = FakeRelay()
        with self.assertRaises(RuntimeError):
            relay.run("exit 3")
        self.assertEqual(len(relay.calls), 1)

    def test_popen_feeds_stdin_and_reads_lines_to_exit(self):
        if not os.path.exists("/usr/bin/python3"):
            self.skipTest("the runner is started with /usr/bin/python3")
        relay = FakeRelay()
        p = relay.popen("read a; echo got:$a; echo second")
        p.stdin.write("hello\n")
        p.stdin.flush()
        p.stdin.close()
        self.assertEqual(p.wait(timeout=30), 0)
        lines = []
        while True:
            line = p.lines.get(timeout=5)
            if line is None:
                break
            lines.append(line)
        self.assertEqual(lines, ["got:hello\n", "second\n"])

APP = "/Users/u/ss-ultra/cmux DEV ssultra54ea.app"


def run_argv(*extra):
    return ["run", "--host", "cmux20", "--viewer", "cmux17", "--host-ip", "10.0.0.20", *extra]


class AppViewerArgs(unittest.TestCase):
    def test_flags_reach_the_run_namespace(self):
        a = vs.build_parser().parse_args(run_argv(
            "--app-viewer", APP, "--app-viewer-env", "CMUX_AUTH_CREDENTIALS_FILE=/tmp/c.json",
            "--app-host-app", "/Applications/cmux DEV host.app", "--presented-input", "click",
            "--encode-profile", "ultra", "--max-fps", "120"))
        self.assertEqual(a.app_viewer, APP)
        self.assertEqual(a.app_viewer_env, ["CMUX_AUTH_CREDENTIALS_FILE=/tmp/c.json"])
        self.assertEqual(a.app_host_app, "/Applications/cmux DEV host.app")
        self.assertEqual(a.presented_input, "click")
        self.assertEqual(a.app_viewer_frame, "0,0,1500,950")
        self.assertFalse(a.app_viewer_background)
        self.assertIs(a.fn, vs.cmd_run)

    def test_defaults_keep_the_old_presented_leg(self):
        a = vs.build_parser().parse_args(run_argv())
        self.assertIsNone(a.app_viewer)
        self.assertEqual(a.presented_input, "key")

    def test_env_takes_only_cmux_variables(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            vs.build_parser().parse_args(run_argv("--app-viewer", APP, "--app-viewer-env", "PATH=/x"))

    def test_app_subcommand_parses(self):
        a = vs.build_parser().parse_args(["app", "rpc", "debug.device_hub", '{"action": "state"}',
                                          "--app", APP])
        self.assertEqual((a.action, a.method, a.params, a.fn), ("rpc", "debug.device_hub",
                                                                '{"action": "state"}', vs.cmd_app))

    def test_app_viewer_needs_marker_locate_and_no_presented_pid(self):
        with tempfile.TemporaryDirectory() as tools:
            a = vs.build_parser().parse_args(run_argv("--app-viewer", APP, "--tools", tools))
            with self.assertRaises(SystemExit) as e:
                vs.Orchestrator(a)
            self.assertIn("screen-eval-marker-locate", str(e.exception))
            open(os.path.join(tools, "screen-eval-marker-locate"), "w").close()
            a = vs.build_parser().parse_args(run_argv("--app-viewer", APP, "--tools", tools,
                                                      "--presented-pid", "7"))
            with self.assertRaises(SystemExit):
                vs.Orchestrator(a)


class AppViewerHelpers(unittest.TestCase):
    def test_socket_paths_follow_control_socket_path(self):
        self.assertEqual(vs.app_socket_paths("com.cmuxterm.app.debug.ssultra54ea", "/Users/u"),
                         ["/Users/u/.local/state/cmux/cmux-debug-ssultra54ea.sock",
                          "/tmp/cmux-debug-ssultra54ea.sock"])
        self.assertEqual(vs.app_socket_paths("com.cmuxterm.app.nightly", "/Users/u"),
                         ["/Users/u/.local/state/cmux/cmux-nightly.sock", "/tmp/cmux-nightly.sock"])
        self.assertEqual(vs.app_socket_paths("com.cmuxterm.app.debug.SS Ultra_1", "/Users/u")[1],
                         "/tmp/cmux-debug-ss-ultra-1.sock")
        self.assertEqual(vs.app_socket_paths("com.cmuxterm.app", "/Users/u"),
                         ["/Users/u/.local/state/cmux/cmux.sock"])
        long_home = "/Users/" + "u" * 90
        self.assertEqual(vs.app_socket_paths("com.cmuxterm.app.debug.x", long_home),
                         ["/tmp/cmux-debug-x.sock"])

    def test_app_call_speaks_the_control_socket(self):
        import threading
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "s.sock")
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            srv.bind(path)
            srv.listen(1)
            got = []

            def serve():
                conn, _ = srv.accept()
                got.append(json.loads(conn.makefile().readline()))
                conn.sendall(b'{"id":1,"ok":true,"result":{"tabs":[]}}\n')
                conn.close()

            t = threading.Thread(target=serve)
            t.start()
            try:
                out = vs.app_call([os.path.join(d, "missing.sock"), path], "debug.mac_screen",
                                  {"action": "state"}, timeout=5)
            finally:
                t.join(5)
                srv.close()
        self.assertEqual(out, {"tabs": []})
        self.assertEqual(got, [{"id": 1, "method": "debug.mac_screen", "params": {"action": "state"}}])
        self.assertIn("error", vs.app_call(["/nonexistent.sock"], "x"))

    def launch_release(self, has_state):
        # A NIGHTLY answers system.ping but not debug.mac_screen.
        calls = []

        def fake_call(paths, method, params=None, timeout=60):
            calls.append(method)
            if method == "debug.mac_screen" or (method == "mac_screen.state" and not has_state):
                return {"error": {"code": "method_not_found", "message": method}}
            return {"pong": True} if method == "system.ping" else {"tabs": []}

        orig, vs.app_call = vs.app_call, fake_call
        orig_id, vs.app_bundle_id = vs.app_bundle_id, lambda app: "com.cmuxterm.app.nightly"
        try:
            with tempfile.TemporaryDirectory() as d:
                a = vs.build_parser().parse_args(["app", "launch", "--app", os.path.join(d, "cmux NIGHTLY.app")])
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    vs.cmd_app(a)
        finally:
            vs.app_call, vs.app_bundle_id = orig, orig_id
        return json.loads(out.getvalue().strip().splitlines()[-1]), calls

    def test_launch_takes_a_release_app_and_says_so(self):
        got, calls = self.launch_release(True)
        self.assertTrue(got["release"] and got["reused"])
        self.assertNotIn("error", got)
        self.assertEqual(calls, ["system.ping", "debug.mac_screen", "mac_screen.state"])

    def test_launch_refuses_a_release_app_without_the_state_read(self):
        got, _ = self.launch_release(False)
        self.assertIn("is a Release build without mac_screen.state", got["error"])

    def test_locate_output(self):
        self.assertEqual(vs.parse_locate("origin 812,402 cell 32 at 868,418\n"), ("812,402", 32, "868,418"))
        self.assertIsNone(vs.parse_locate("no marker\n"))

    def test_ledger_is_the_newest_logged_line(self):
        def line(msg):
            return json.dumps({"eventMessage": msg})
        led = {"schema": vs.LEDGER_SCHEMA, "stages": [{"stage": "Present", "n": 4, "p50_ms": 7, "p95_ms": 9}]}
        text = "\n".join([line("other"), line("stage ledger: " + json.dumps({"schema": "old"})),
                          "not json", line("stage ledger: " + json.dumps(led))])
        self.assertEqual(vs.app_ledger_from_log(text), (led, 2))
        self.assertEqual(vs.app_ledger_from_log(""), (None, 0))


class FakeMac:
    """A Remote whose `screen-share-vs.py app ...` and observe calls answer like the app would."""

    def __init__(self, name, answer):
        self.name, self.answer, self.calls = name, answer, []

    def run(self, cmd, timeout=120, stdin=None):
        self.calls.append(cmd)
        return json.dumps(self.answer(cmd)) + "\n" if not cmd.startswith("scutil") else "cmux20\n"


class AppViewerRun(unittest.TestCase):
    def orchestrator(self, tools, *extra):
        open(os.path.join(tools, "screen-eval-marker-locate"), "w").close()
        a = vs.build_parser().parse_args(run_argv(
            "--app-viewer", APP, "--tools", tools, "--encode-profile", "ultra", "--root", "/r", *extra))
        return vs.Orchestrator(a)

    def viewer_answer(self, opened, observe=None):
        led = {"schema": vs.LEDGER_SCHEMA, "stages": [{"stage": "Present", "n": 5, "p50_ms": 6.0, "p95_ms": 8.0}]}
        row = {"tab": "t1", "phase": "connected", "has_frame": True, "window_pid": 4242,
               "window_id": 99, "session_scope": "full", "hub_session": "s1", "transport": "rd_wg",
               "path": "direct", "window_on_primary_display": True,
               "decode_ms": {"count": 120, "p50": 2.1, "p95": 3.0, "max": 4.0},
               "glass_ms": {"count": 120, "p50": 9.4, "p95": 14.0, "max": 20.0},
               "decode_present_ms": {"count": 120, "p50": 11.5, "p95": 16.5, "max": 22.0},
               "frame_interval_ms": None}

        def answer(cmd):
            argv = shlex.split(cmd)
            if argv[1:3] == ["observe", "--pid"] or argv[0].endswith("cmux-rd"):
                return observe or {"complete": True, "samples_us": [40000, 50000, 60000], "p50_ms": 50.0}
            self.assertEqual(argv[2:4][0], "app")
            action, app = argv[3], argv[argv.index("--app") + 1]
            self.assertEqual(app, APP)
            vs.build_parser().parse_args(argv[2:])  # what the Mac's copy would parse
            if action == "launch":
                return {"socket": "/tmp/s", "reused": False, "encode_profile_applied": True}
            if action == "locate":
                return {"origin": "812,402", "cell": 32, "at": "868,418"}
            if action == "ledger":
                return {"ledger": led, "lines": 2}
            method, params = argv[4], json.loads(argv[5])
            if method == "debug.device_hub" and params["action"] == "state":
                return {"signed_in": True, "this_device": "V", "devices": [
                    {"id": "H", "name": "cmux20", "online": True, "shared": True}]}
            if method == "debug.device_hub" and params["action"] == "connect":
                opened.append(params)
                return {"ok": True}
            if method == "mac_screen.state":
                # Every build's read: the pane timings come from here, not debug.mac_screen.
                self.assertEqual(params, {"tab": "t1"})
                return {"tabs": [{k: row[k] for k in ("tab", "phase") + vs.APP_TIMING_FIELDS if k in row}]}
            if method == "debug.mac_screen":
                dev = {k: v for k, v in row.items() if k not in vs.APP_TIMING_FIELDS}
                if "tab" in params:
                    return {"tabs": [dev]}
                return {"tabs": [dev] if opened else []}
            return {}
        return answer

    def run_leg(self, o, opened, **kw):
        o.viewer = FakeMac("cmux17", self.viewer_answer(opened, **kw))
        o.host = FakeMac("cmux20", lambda cmd: {"pending_requests": [{"id": "s1"}], "this_device": "H"})
        rigs = []
        o.rig = lambda req, timeout=30: rigs.append(req["cmd"]) or {"ok": True}
        sleeps = []
        orig = vs.time.sleep
        vs.time.sleep = sleeps.append
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                return o.run_presented(), rigs
        finally:
            vs.time.sleep = orig

    def test_app_mode_fills_observe_and_labels_the_source(self):
        with tempfile.TemporaryDirectory() as tools:
            o = self.orchestrator(tools, "--presented-input", "click")
            opened = []
            ms, rigs = self.run_leg(o, opened)
        self.assertEqual(ms, [40.0, 50.0, 60.0])
        self.assertEqual(opened, [{"action": "connect", "device": "H", "scope": "full"}])
        self.assertEqual(rigs, ["marker", "stop"])
        observe = [c for c in o.viewer.calls if " observe " in c][0]
        argv = shlex.split(observe)
        for flag, want in (("--pid", "4242"), ("--window", "99"), ("--input", "click"),
                           ("--cell-size", "32"), ("--marker-origin", "812,402"), ("--at", "868,418")):
            self.assertEqual(argv[argv.index(flag) + 1], want, flag)
        launch = shlex.split([c for c in o.viewer.calls if " app launch " in c][0])
        self.assertEqual(launch[launch.index("--encode-profile") + 1], "ultra")
        self.assertNotIn("--background", launch)
        self.assertTrue(any('"quitEndSessions"' in c for c in o.viewer.calls))  # it launched it
        self.assertTrue(any('"end"' in c for c in o.viewer.calls))
        src = o.presented_source
        self.assertEqual((src["kind"], src["pid"], src["window"], src["transport"]), ("app-viewer", 4242, 99, "rd_wg"))
        self.assertTrue(src["encode_profile_applied"])
        b = vs.build_budget({"rows": [breakdown_row()] * 3, "presented": ms,
                             "presented_source": src, "app_ledger": o.app_ledger,
                             "app_timings": o.app_timings}, None)
        total = rows_named(b)["Total"]["cmux"]
        self.assertEqual((total["to"], total["via"], total["p50"]), ("presented", "app-viewer", 50.0))
        self.assertEqual(b["presented_source"]["kind"], "app-viewer")
        self.assertEqual(b["app_ledger"]["stages"]["Present"]["p50"], 6.0)
        text = "\n".join(vs.format_budget(b))
        self.assertIn("presented via app-viewer", text)
        self.assertIn("app viewer ledger: Present 6/8 (n 5)", text)
        self.assertEqual(b["app_timings"]["decode_present_ms"]["p50"], 11.5)
        self.assertNotIn("frame_interval_ms", b["app_timings"])  # null on the pane: left out
        self.assertNotIn("short_window", b["app_timings"])
        self.assertIn("app viewer timings p50/p95: decode 2.1/3 (n 120), glass 9.4/14 (n 120), "
                      "decode_present 11.5/16.5 (n 120)", text)

    def release_viewer(self, opened, window=True):
        """A NIGHTLY viewer: no debug.*; mac_screen.state carries the hub and the window fields."""
        dev = self.viewer_answer(opened)
        row = {"tab": "t1", "phase": "connected", "has_frame": True, "window_pid": 4242, "window_id": 99,
               "session_scope": "full", "hub_session": "s1", "transport": "rd_wg", "path": "direct",
               "window_on_primary_display": True,
               "decode_present_ms": {"count": 120, "p50": 11.5, "p95": 16.5, "max": 22.0}}
        if not window:
            del row["window_id"]

        def answer(cmd):
            argv = shlex.split(cmd)
            if argv[2:3] == ["app"] and argv[3] == "launch":
                return {"socket": "/tmp/s", "reused": False, "release": True}
            if argv[2:3] == ["app"] and argv[3] == "rpc":
                method, params = argv[4], json.loads(argv[5])
                if method.startswith("debug."):
                    return {"error": {"code": "method_not_found", "message": method}}
                if method == "action.run" and params.get("action") == "macScreen.open":
                    opened.append(params)
                    return {"status": "done"}
                if method == "mac_screen.state":
                    hub = {"running": True, "registered": True, "this_device": "V", "devices": [
                        {"id": "H", "name": "cmux20", "online": True, "shared": True, "this": False}]}
                    return {"tabs": [row] if opened else [], "hub": hub}
            return dev(cmd)
        return answer

    def test_a_release_viewer_opens_through_macscreen_open(self):
        with tempfile.TemporaryDirectory() as tools:
            o = self.orchestrator(tools)
            opened = []
            o.viewer = FakeMac("cmux17", self.release_viewer(opened))
            o.host = FakeMac("cmux20", lambda cmd: {})
            o.rig = lambda req, timeout=30: {"ok": True}
            orig, vs.time.sleep = vs.time.sleep, lambda s: None
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    ms = o.run_presented()
            finally:
                vs.time.sleep = orig
        self.assertEqual(ms, [40.0, 50.0, 60.0])
        self.assertEqual(opened, [{"action": "macScreen.open", "origin": "cli",
                                   "args": {"device": "H", "scope": "full", "autoconnect": True}}])
        self.assertFalse(any("debug.device_hub" in c and '"end"' in c for c in o.viewer.calls))
        self.assertEqual((o.presented_source["pid"], o.presented_source["window"]), (4242, 99))
        self.assertEqual(o.app_timings["decode_present_ms"]["p50"], 11.5)

    def test_a_release_viewer_without_window_fields_says_so(self):
        with tempfile.TemporaryDirectory() as tools:
            o = self.orchestrator(tools, "--timeout", "1")
            o.viewer = FakeMac("cmux17", self.release_viewer([], window=False))
            o.host = FakeMac("cmux20", lambda cmd: {})
            o.rig = lambda req, timeout=30: {"ok": True}
            orig, vs.time.sleep = vs.time.sleep, lambda s: None
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertIsNone(o.run_presented())
            finally:
                vs.time.sleep = orig
        self.assertIn("no window_id", o.presented_source["null"])

    def test_host_app_approves_and_names_the_device(self):
        with tempfile.TemporaryDirectory() as tools:
            o = self.orchestrator(tools, "--app-host-app", "/Applications/cmux DEV host.app")
            opened = []
            self.run_leg(o, opened)
        self.assertTrue(any('"always_full"' in c for c in o.host.calls))
        self.assertFalse(any(c.startswith("scutil") for c in o.host.calls))

    def test_an_incomplete_observe_leaves_total_at_decode(self):
        with tempfile.TemporaryDirectory() as tools:
            o = self.orchestrator(tools)
            ms, _ = self.run_leg(o, [], observe={"complete": False, "error": "pane obscured"})
        self.assertIsNone(ms)
        b = vs.build_budget({"rows": [breakdown_row()] * 3, "presented": ms,
                             "presented_source": o.presented_source}, None)
        self.assertEqual(rows_named(b)["Total"]["cmux"]["to"], "decoded")
        self.assertEqual(b["presented_source"]["kind"], "app-viewer")
        self.assertIn("null", b["presented_source"])


class PresentedSourceLabel(unittest.TestCase):
    def test_flags_source_and_no_source(self):
        src = vs.presented_source("presented-flags", pid=1, window=2)
        b = vs.build_budget({"rows": [breakdown_row()], "presented": [50.0], "presented_source": src}, None)
        self.assertEqual(rows_named(b)["Total"]["cmux"]["via"], "presented-flags")
        b = vs.build_budget({"rows": [breakdown_row()]}, None)
        self.assertIn("null", b["presented_source"])
        self.assertNotIn("via", rows_named(b)["Total"]["cmux"])
        self.assertIn("null", b["app_ledger"])
        self.assertIn("null", b["app_timings"])
        with self.assertRaises(ValueError):
            vs.presented_source("bogus")


class ClockRetryTest(unittest.TestCase):
    def runner(self, outcomes):
        o = vs.Orchestrator.__new__(vs.Orchestrator)
        calls = []

        def once():
            calls.append(1)
            r = outcomes[len(calls) - 1]
            if isinstance(r, Exception):
                raise r
            return r
        o.clock_once = once
        return o, calls

    def test_a_slow_start_is_retried(self):
        o, calls = self.runner([RuntimeError("clock-serve on cmux20 did not start: None"), {"offset_ns": 5}])
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(o.clock(), {"offset_ns": 5})
        self.assertEqual(len(calls), 2)

    def test_every_try_failing_names_each_error(self):
        o, calls = self.runner([RuntimeError("a"), TimeoutError("b"), ValueError("c")])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(RuntimeError) as e:
            o.clock()
        self.assertEqual(len(calls), vs.Orchestrator.CLOCK_TRIES)
        self.assertIn("RuntimeError: a | TimeoutError: b | ValueError: c", str(e.exception))


class HostTestLossTest(unittest.TestCase):
    def orchestrator(self, pct):
        o = vs.Orchestrator.__new__(vs.Orchestrator)
        o.host_test_loss = pct
        o.host_args, o.viewer_args, o.host_argv, o.out = [], [], [], None
        o.root = "/r"
        o.a = argparse.Namespace(synthetic_size=None, synthetic_scene=None, link_bind=None)
        return o

    def test_the_value_is_checked(self):
        self.assertEqual(vs.test_loss_pct(1.0), "1")
        self.assertEqual(vs.test_loss_pct("0.5"), "0.5")
        for bad in (0, -1, 100.5, "x"):
            with self.assertRaises(ValueError):
                vs.test_loss_pct(bad)

    def test_the_flag_parses(self):
        a = vs.build_parser().parse_args(run_argv("--host-test-loss", "1"))
        self.assertEqual(a.host_test_loss, 1.0)
        self.assertIsNone(vs.build_parser().parse_args(run_argv()).host_test_loss)

    def test_synthetic_serve_sets_the_env(self):
        self.assertIn("CMUX_RD_TEST_LOSS_PCT=1 ", self.orchestrator("1").synthetic_serve("fps"))
        self.assertNotIn("CMUX_RD_TEST_LOSS_PCT", self.orchestrator(None).synthetic_serve("fps"))

    def test_rows_record_it_only_when_set(self):
        for pct, want in (("1", {"host_test_loss_pct": 1.0}), (None, {})):
            o = self.orchestrator(pct)
            with contextlib.redirect_stdout(io.StringIO()) as out:
                o.log({"mode": "fps"})
            row = json.loads(out.getvalue())
            self.assertEqual({k: v for k, v in row.items() if k == "host_test_loss_pct"}, want)


class RemoteRunStdin(unittest.TestCase):
    """Remote.run with no input gives the remote command /dev/null, not the orchestrator's stdin."""

    def test_no_input_reads_dev_null(self):
        r = vs.Remote("here", "local")
        r_fd, w_fd = os.pipe()  # an open stdin that never ends: inherited, `cat` would block
        saved = os.dup(0)
        try:
            os.dup2(r_fd, 0)
            self.assertEqual(r.run("cat; echo done", timeout=10), "done\n")
        finally:
            os.dup2(saved, 0)
            for fd in (saved, r_fd, w_fd):
                os.close(fd)

    def test_input_is_still_passed(self):
        self.assertEqual(vs.Remote("here", "local").run("cat", timeout=10, stdin="hi"), "hi")


class PeerRoute(unittest.TestCase):
    """--via peer: the orchestrating Mac drives the other Mac of a pair job through its peer-serve."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.token = "ab" * 32
        self.token_file = os.path.join(self.tmp, "token")
        with open(self.token_file, "w") as f:
            f.write(self.token + "\n")
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        args = argparse.Namespace(bind="127.0.0.1", port=self.port, token_file=self.token_file, hold_s=60)
        self.server = vs.threading.Thread(target=vs.cmd_peer_serve, args=(args,), daemon=True)
        with contextlib.redirect_stdout(io.StringIO()):
            self.server.start()
            vs.time.sleep(0.3)
        self.url = f"http://127.0.0.1:{self.port}"

    def tearDown(self):
        vs.PeerRemote("mac", self.url, self.token).done()
        self.server.join(10)

    def test_run_returns_stdout_and_passes_stdin(self):
        r = vs.PeerRemote("mac", self.url, self.token)
        self.assertEqual(r.run("echo hi"), "hi\n")
        self.assertEqual(r.run("cat", stdin="in"), "in")

    def test_a_failed_command_raises_with_its_status(self):
        with self.assertRaisesRegex(RuntimeError, "exit 3"):
            vs.PeerRemote("mac", self.url, self.token).run("echo no >&2; exit 3")

    def test_a_wrong_token_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "HTTP 403"):
            vs.PeerRemote("mac", self.url, "cd" * 32).run("echo hi")

    def test_put_and_popen_go_through_it(self):
        r = vs.PeerRemote("mac", self.url, self.token)
        src = os.path.join(self.tmp, "blob")
        with open(src, "wb") as f:
            f.write(os.urandom(300_000))
        dst = os.path.join(self.tmp, "out", "blob")
        r.put(src, dst)
        with open(src, "rb") as a, open(dst, "rb") as b:
            self.assertEqual(a.read(), b.read())
        if not os.path.exists("/usr/bin/python3"):
            return
        p = r.popen("read a; echo got:$a")
        p.stdin.write("x\n")
        p.stdin.close()
        self.assertEqual(p.wait(timeout=30), 0)
        self.assertEqual(p.lines.get(timeout=5), "got:x\n")

    def test_clients_private_and_pinned(self):
        self.assertTrue(vs.peer_client_ok("172.20.21.5", None))
        self.assertTrue(vs.peer_client_ok("127.0.0.1", None))
        self.assertFalse(vs.peer_client_ok("8.8.8.8", None))
        self.assertFalse(vs.peer_client_ok("172.20.21.6", "172.20.21.5"))
        self.assertTrue(vs.peer_client_ok("172.20.21.5", "172.20.21.5"))

    def test_local_mac_runs_here_and_the_other_end_over_peer(self):
        args = vs.build_parser().parse_args(run_argv("--via", "peer", "--local-mac", "cmux17",
                                                     "--peer-url", self.url, "--peer-token-file", self.token_file))
        o = vs.Orchestrator(args)
        self.assertEqual((type(o.viewer), o.viewer.via), (vs.Remote, "local"))
        self.assertIsInstance(o.host, vs.PeerRemote)

    def test_peer_needs_its_url_and_token(self):
        args = vs.build_parser().parse_args(run_argv("--via", "peer"))
        with self.assertRaises(SystemExit):
            vs.Orchestrator(args)


class LocalMac(unittest.TestCase):
    """--local-mac NAME: that end runs here, the other end over --via (a job on one Mac of the pair)."""

    def orchestrator(self, *extra):
        a = vs.build_parser().parse_args(["run", "--host", "cmux20", "--viewer", "cmux17", "--host-ip", "10.0.0.2",
                                          "--via", "ssh", *extra])
        return vs.Orchestrator(a)

    def test_host_local_viewer_over_ssh(self):
        o = self.orchestrator("--local-mac", "cmux20")
        self.assertEqual(o.host.argv("true"), ["/bin/bash", "-c", "true"])
        self.assertEqual(o.viewer.argv("true"), ["ssh", "-o", "BatchMode=yes", "cmux17", "true"])

    def test_without_it_both_over_via(self):
        o = self.orchestrator()
        self.assertEqual(o.host.argv("true")[0], "ssh")
        self.assertEqual(o.viewer.argv("true")[0], "ssh")


class ClockProbeDeadline(unittest.TestCase):
    """A clock probe at a silent-but-for-one-reply peer stops at --max-seconds, not after count misses."""

    def test_probe_stops_at_its_deadline(self):
        import threading
        import time
        srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        srv.bind(("127.0.0.1", 0))
        port = srv.getsockname()[1]

        def answer_once():  # one reply, then a lossy link drops everything
            data, peer = srv.recvfrom(64)
            srv.sendto(data[:8] + (0).to_bytes(8, "big"), peer)
        t = threading.Thread(target=answer_once, daemon=True)
        t.start()
        args = argparse.Namespace(addr=f"127.0.0.1:{port}", count=200, gap_ms=0, max_seconds=1.5)
        out = io.StringIO()
        t0 = time.time()
        try:
            with contextlib.redirect_stdout(out):
                vs.cmd_clock_probe(args)
        finally:
            srv.close()
        self.assertLess(time.time() - t0, 3.0)
        self.assertEqual(json.loads(out.getvalue())["replies"], 1)



class ClockOverPeerTcp(unittest.TestCase):
    """A fleet pair job's clock: clock-serve --tcp on the viewer, the probe from the host, over the
    path the host's peer-serve calls use (2026-11-27: the UDP probe from the viewer got Errno 65 to
    the host's LAN address and no answer over the tailnet)."""

    def test_tcp_serve_and_probe_round_trip_on_loopback(self):
        import subprocess
        import time
        here = os.path.dirname(os.path.abspath(__file__))
        srv = subprocess.Popen([sys.executable, "-I", os.path.join(here, "screen-share-vs.py"), "clock-serve",
                                "--tcp", "--bind", "127.0.0.1", "--port", "0", "--seconds", "20"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            port = json.loads(srv.stdout.readline())["listening"]
            args = argparse.Namespace(addr=f"127.0.0.1:{port}", count=20, gap_ms=0, max_seconds=5, tcp=True)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                vs.cmd_clock_probe(args)
            r = json.loads(out.getvalue())
            self.assertEqual(r["replies"], 20)
            # One Mac, one monotonic clock: the offset is about zero.
            self.assertLess(abs(r["offset_ns"]), 50_000_000)
        finally:
            srv.stdin.close()
            srv.wait(10)

    def test_a_tcp_probe_with_nothing_listening_says_so(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        args = argparse.Namespace(addr=f"127.0.0.1:{port}", count=5, gap_ms=0, max_seconds=2, tcp=True)
        out = io.StringIO()
        with self.assertRaises(SystemExit), contextlib.redirect_stdout(out):
            vs.cmd_clock_probe(args)
        self.assertIn("clock connect", out.getvalue())

    def orchestrator(self, viewer, host):
        import types
        me = types.SimpleNamespace(a=types.SimpleNamespace(viewer="cmux20", host="mini", host_ip="172.20.21.199",
                                                           clock_count=5),
                                   py="python3", me="screen-share-vs.py", viewer=viewer, host=host)
        me.clock_over_peer = lambda: vs.Orchestrator.clock_over_peer(me)
        me.clock_once_tcp = lambda: vs.Orchestrator.clock_once_tcp(me)
        return me

    def test_a_pair_job_probes_the_viewer_over_tcp_and_flips_the_sign(self):
        import queue
        import types
        srv = types.SimpleNamespace(lines=queue.Queue(), terminate=lambda: None)
        srv.lines.put('{"listening": 4555, "tcp": true}')
        viewer = vs.PeerRemote.__new__(vs.PeerRemote)
        viewer.url, viewer.name = "http://172.20.21.250:4181", "cmux20"
        seen = {}
        viewer.popen = lambda cmd: seen.setdefault("serve", cmd) and srv

        def host_run(cmd, timeout=120):
            seen["probe"] = cmd
            return '{"offset_ns": 7000, "rtt_min_ms": 0.4, "replies": 5}\n'
        host = types.SimpleNamespace(via="local", run=host_run)
        me = self.orchestrator(viewer, host)
        self.assertTrue(me.clock_over_peer())
        r = vs.Orchestrator.clock_once(me)
        self.assertIn("clock-serve --tcp --bind 172.20.21.250", seen["serve"])
        self.assertIn("clock-probe --tcp --addr 172.20.21.250:4555", seen["probe"])
        self.assertEqual(r["offset_ns"], -7000)
        self.assertEqual(r["path"], "tcp host->viewer")

    def test_a_non_pair_run_keeps_the_udp_probe(self):
        import types
        me = self.orchestrator(types.SimpleNamespace(), types.SimpleNamespace(via="reach"))
        self.assertFalse(me.clock_over_peer())

if __name__ == "__main__":
    unittest.main()
