"""screen-share-vs.py stage ledger: Apple to the presented frame, the table of every leg (wired and
a shaped Wi-Fi profile), and the shaper's start and clear around each leg. Fakes only: no Mac.

    python3 -m unittest cmux-tui/crates/cmux-rd-host/scripts/test_screen_share_vs_legs.py
"""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("screen_share_vs", os.path.join(HERE, "screen-share-vs.py"))
vs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vs)


def breakdown_row(**over):
    row = {"up": 1.0, "inject": 0.5, "draw": 10.0, "sck": 6.0, "gate": 2.0, "encode": 5.0,
           "send": 3.0, "first_packet": 1.0, "down": 4.0, "decode": 2.0, "total": 34.0}
    row.update(over)
    return row


def rows_named(b):
    return {r["row"]: r for r in b["rows"]}


class ApplePresented(unittest.TestCase):
    def test_observe_on_screen_sharing_makes_apple_total_end_at_the_presented_frame(self):
        b = vs.build_budget(None, {"g2g": [20.0, 30.0], "presented": [40.0, 50.0, 60.0]})
        total = rows_named(b)["Total"]["apple"]
        self.assertEqual(total["to"], "presented")
        self.assertEqual(total["p50"], 50.0)
        self.assertIn("Screen Sharing.app", total["source"])
        # Its stages stay null: Apple exposes none, and the RFB client is another viewer.
        self.assertIn("null", rows_named(b)["Present"]["apple"])

    def test_without_a_window_apple_total_is_the_rfb_update(self):
        b = vs.build_budget(None, {"g2g": [20.0, 30.0], "presented": None})
        self.assertEqual(rows_named(b)["Total"]["apple"]["to"], "RFB update")


class Legs(unittest.TestCase):
    def test_a_leg_named_after_a_profile_is_shaped_and_wired_is_not(self):
        self.assertEqual(vs.parse_legs("wired, wifi-away"), [("wired", None), ("wifi-away", "wifi-away")])
        self.assertEqual(vs.parse_legs("radio=wifi-long"), [("radio", "wifi-long")])
        self.assertEqual(vs.parse_legs(None), [])
        with self.assertRaises(SystemExit):
            vs.parse_legs("wired=bogus")

    def budgets(self):
        wired = vs.build_budget({"rows": [breakdown_row()] * 3, "presented": [40.0, 41.0, 42.0]},
                                {"g2g": [28.0], "presented": [45.0]}, rev="0123456789abcdef",
                                link="wired", rtt=0.79)
        radio = vs.build_budget({"rows": [breakdown_row(down=60.0, total=90.0)] * 3},
                                {"skipped": "skipped: no --vnc-user / --vnc-password-file given"},
                                rev="0123456789abcdef", link="wifi-away", rtt=4.5)
        return wired, radio

    def test_one_table_has_every_leg_side_by_side_with_glass_to_glass(self):
        text = "\n".join(vs.format_legs(list(self.budgets())))
        lines = text.splitlines()
        self.assertIn("@ 0123456789ab", lines[0])
        self.assertIn("leg 1: wired, udp rtt min 0.79 ms", text)
        self.assertIn("leg 2: wifi-away", text)
        head = next(line for line in lines if line.split()[:2] == ["stage", "budget"])
        for h in ("cmux wired", "Apple wired", "cmux wifi-away", "Apple wifi-away"):
            self.assertIn(h, head)
        for stage in ("Capture", "Encode", "Send", "Network", "Reassembly", "Decode", "Present"):
            self.assertTrue(any(line.strip().startswith(stage) for line in lines), stage)
        g2g = next(line for line in lines if line.strip().startswith("Glass to glass"))
        self.assertIn("41 / 42", g2g)  # cmux wired, to the presented frame
        self.assertIn("45 / 45", g2g)  # Apple wired, Screen Sharing.app presented
        self.assertIn("90 / 90 (to decoded)", g2g)  # the radio leg had no viewer pane
        network = next(line for line in lines if line.strip().startswith("Network"))
        self.assertIn("60 / 60", network)
        # Each null names its reason once in a footnote.
        self.assertIn("null: skipped: no --vnc-user", text)

    def test_table_reads_every_budget_record_of_a_run_file(self):
        wired, radio = self.budgets()
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "legs.jsonl")
            with open(p, "w") as f:
                for rec in ({"clock": {}}, {"budget": wired}, {"summary": {}}, {"budget": radio}):
                    f.write(json.dumps(rec) + "\n")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                vs.cmd_table(argparse.Namespace(files=[p]))
            self.assertIn("cmux wifi-away", out.getvalue())
            empty = os.path.join(d, "none.jsonl")
            with open(empty, "w") as f:
                f.write("{}\n")
            with self.assertRaises(SystemExit):
                vs.load_budgets([empty])


class CaptureSplit(unittest.TestCase):
    """Capture's two parts: the gate wait (ss-encode-transport's stage) and the Linux readback
    (ss-capture's capture_start_us)."""

    def breakdown(self, frame):
        o = vs.Orchestrator(types.SimpleNamespace(
            source="synthetic", host="h", viewer="v", via="ssh", root="/r", python="p", out=None))
        timing = [{"recv_us": 1_000, "inject_us": 1_100}, dict(frame, release_us=10_000,
                                                              encoded_us=15_000, sent_us=16_000)]
        sample = {"capture_us": 10_000, "sent_ns": 900_000, "first_rx_ns": 17_000_000,
                  "complete_ns": 18_000_000, "decoded_ns": 20_000_000}
        return o.breakdown({"sample_times": [sample]}, timing, 0)[0]

    def test_linux_capture_start_splits_gate_wait_from_readback(self):
        row = self.breakdown({"damage_us": 6_000, "capture_start_us": 8_000})
        self.assertEqual((row["gate_wait"], row["readback"]), (2.0, 2.0))
        b = vs.build_budget({"rows": [row]}, None)
        self.assertEqual(rows_named(b)[" Readback"]["cmux"]["p50"], 2.0)
        self.assertEqual(rows_named(b)[" Gate wait"]["cmux"]["p50"], 2.0)

    def test_without_capture_start_the_gate_wait_runs_to_encode_start_and_readback_says_why(self):
        row = self.breakdown({"shown_us": 5_000, "arrived_us": 7_000})
        self.assertEqual((row["gate_wait"], row["readback"]), (3.0, None))
        b = vs.build_budget({"rows": [row]}, None)
        self.assertIn("capture_start_us", rows_named(b)[" Readback"]["cmux"]["null"])
        self.assertEqual(rows_named(b)["Capture"]["cmux"]["p50"], 5.0)  # sck 2 + gate 3, unchanged

    def test_a_record_from_before_the_split_still_tables_beside_a_new_one(self):
        old = vs.build_budget({"rows": [breakdown_row()]}, None, link="old")
        old["rows"] = [r for r in old["rows"] if r["row"] not in (" Gate wait", " Readback")]
        new = vs.build_budget({"rows": [breakdown_row(gate_wait=2.0)]}, None, link="new")
        lines = vs.format_legs([old, new])
        wait = next(line for line in lines if line.strip().startswith("Gate wait"))
        self.assertIn("-", wait.split()[2])
        self.assertIn("2 / 2", wait)


class FakeRemote:
    def __init__(self, fail_on=()):
        self.calls, self.fail_on = [], fail_on

    def run(self, cmd, timeout=120, stdin=None):
        self.calls.append(cmd)
        if any(f in cmd for f in self.fail_on):
            raise RuntimeError("refused")
        if cmd.endswith(" holds"):
            return json.dumps({"kind": "long", "hold_ms": 455}) + "\n"
        return ""

    def put(self, local, remote_path, mode="0755"):
        self.calls.append(f"put {os.path.basename(local)} {remote_path}")


def orchestrator(**kw):
    args = dict(source="synthetic", host="cmux20", viewer="cmux17", via="ssh", root="/Users/c/rd",
                python="/usr/bin/python3", out=None, shape="wifi-away", viewer_ip="10.0.0.7",
                shape_max_s=900, shape_sudo="sudo -n", host_ip="10.0.0.5")
    args.update(kw)
    o = vs.Orchestrator(types.SimpleNamespace(**args))
    o.host = FakeRemote()
    o.setup = lambda: None
    return o


class Shape(unittest.TestCase):
    def test_a_shaped_leg_starts_the_profile_toward_the_viewer_and_clears_it_after(self):
        o = orchestrator()
        o.measure = lambda: {"budget": "b"}
        logged = []
        o.log = logged.append
        self.assertEqual(o.main(), {"budget": "b"})
        self.assertTrue(os.path.exists(vs.MAC_HOLDS), vs.MAC_HOLDS)
        self.assertEqual(o.host.calls[0], "put mac-holds.sh /Users/c/rd/bin/mac-holds.sh")
        self.assertEqual(o.host.calls[1:], [
            "sudo -n /bin/bash /Users/c/rd/bin/mac-holds.sh start wifi-away 900 10.0.0.7",
            "sudo -n /bin/bash /Users/c/rd/bin/mac-holds.sh holds",
            "sudo -n /bin/bash /Users/c/rd/bin/mac-holds.sh clear"])
        self.assertEqual(logged[-1]["holds"], [{"kind": "long", "hold_ms": 455}])
        self.assertFalse(o.shaped)

    def test_a_leg_that_fails_still_clears_the_shaper(self):
        o = orchestrator()
        o.log = lambda rec: None

        def boom():
            raise RuntimeError("bench died")
        o.measure = boom
        with self.assertRaises(RuntimeError):
            o.main()
        self.assertTrue(o.host.calls[-1].endswith("mac-holds.sh clear"))

    def test_an_unshaped_leg_never_touches_the_shaper(self):
        o = orchestrator(shape=None)
        o.measure = lambda: None
        o.main()
        self.assertEqual(o.host.calls, [])

    def test_shape_needs_the_viewer_address(self):
        o = orchestrator(viewer_ip=None)
        o.measure = lambda: None
        with self.assertRaises(SystemExit):
            o.main()

    def test_local_sudo_runs_here_with_the_host_filled_in(self):
        o = orchestrator(shape_sudo="local:echo {host}")
        self.assertEqual(o.shape_run("show").strip(), "cmux20 /bin/bash /Users/c/rd/bin/mac-holds.sh show")
        o = orchestrator(shape_sudo="local:false")
        with self.assertRaises(RuntimeError):
            o.shape_run("show")


if __name__ == "__main__":
    unittest.main()
