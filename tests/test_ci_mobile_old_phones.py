#!/usr/bin/env python3
"""scripts/ci/mobile_old_phones.py: which phone builds are shipped, and when a leg is red.

The shipped-iPhones job (.github/workflows/mobile-old-phones.yml) is green only on what this
verdict accepts, so each leg has a case that must fail: a transport that never linked, a daemon
that never answered identify, an echo that moved too few bytes, and a held link that never came
back after the Mac host restarted (the 11-27 phone link break: "so between mac and ios
connections something broke", Leo).
"""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mobile_old_phones", ROOT / "scripts/ci/mobile_old_phones.py")
mop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mop)

RESTART = 1_000_000
META = {"api": "staging", "mac_sha": "a" * 40, "transports": ["webrtc", "wireguard"], "bytes": 1024,
        "restart_epoch_ms": RESTART}
IDENT = json.dumps({"id": 1, "ok": True, "result": {"name": "stub"}})


def pair(transport: str, **kw) -> dict:
    row = {"transport": transport, "path": "direct", "connect_ms": 120, "daemon": IDENT, "echo_bytes": 1024,
           "echo_mbit_per_s_each_way": 9.5, "error": None}
    row.update(kw)
    return row


GOOD_PAIR = [pair("webrtc"), pair("wireguard")]
GOOD_HOLD = [{"event": "probe", "epoch_ms": RESTART - 500},
             {"event": "dead", "epoch_ms": RESTART + 3000},
             {"event": "redial", "epoch_ms": RESTART + 3500},
             {"event": "probe", "epoch_ms": RESTART + 3700},
             {"event": "hold-done", "answered": 40, "redials": 1, "epoch_ms": RESTART + 30000}]


class Verdict(unittest.TestCase):
    def legs(self, pair_rows=GOOD_PAIR, hold_rows=GOOD_HOLD, meta=META):
        return mop.judge_leg_set(pair_rows, hold_rows, meta)

    def test_good_dial_passes_every_leg(self):
        v = self.legs()
        for leg in mop.LEGS:
            self.assertTrue(v[leg].startswith("ok"), (leg, v[leg]))
        self.assertIn("back in 3700 ms", v["reconnect"])

    def test_missing_or_failed_transport_fails_pair(self):
        self.assertTrue(self.legs(pair_rows=[pair("webrtc")])["pair"].startswith("FAIL"))
        v = self.legs(pair_rows=[pair("webrtc"), pair("wireguard", error="ice failed")])["pair"]
        self.assertTrue(v.startswith("FAIL") and "ice failed" in v, v)

    def test_no_identify_fails_attach(self):
        bad = json.dumps({"id": 1, "ok": False})
        self.assertTrue(self.legs(pair_rows=[pair("webrtc"), pair("wireguard", daemon=bad)])["attach"].startswith("FAIL"))
        self.assertTrue(self.legs(pair_rows=[pair("webrtc"), pair("wireguard", daemon="")])["attach"].startswith("FAIL"))

    def test_short_echo_fails_stream(self):
        self.assertTrue(self.legs(pair_rows=[pair("webrtc", echo_bytes=10), pair("wireguard")])["stream"].startswith("FAIL"))

    def test_reconnect_needs_restart_redial_and_probe_after(self):
        self.assertTrue(self.legs(meta={**META, "restart_epoch_ms": 0})["reconnect"].startswith("FAIL"))
        no_redial = [r for r in GOOD_HOLD if r["event"] != "redial"]
        self.assertIn("no redial", self.legs(hold_rows=no_redial)["reconnect"])
        no_probe_after = [r for r in GOOD_HOLD if not (r["event"] == "probe" and r["epoch_ms"] > RESTART)]
        self.assertIn("no probe", self.legs(hold_rows=no_probe_after)["reconnect"])
        stale_redial = [{"event": "redial", "epoch_ms": RESTART - 10}] + [r for r in GOOD_HOLD if r["event"] != "redial"]
        self.assertIn("no redial", self.legs(hold_rows=stale_redial)["reconnect"])

    def test_verdict_reads_the_tree_and_goes_red_on_one_bad_cell(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.assertEqual(mop.verdict(root), (["no legs ran"], True))
            for sha, rows in (("b" * 40, GOOD_PAIR), ("c" * 40, [pair("webrtc")])):
                cell = root / "head" / sha
                cell.mkdir(parents=True)
                (cell / "pair.out").write_text("noise\n" + "\n".join(json.dumps(r) for r in rows) + "\n")
                (cell / "hold.out").write_text("\n".join(json.dumps(r) for r in GOOD_HOLD) + "\n")
                (cell / "meta.json").write_text(json.dumps(META))
            lines, failed = mop.verdict(root)
            self.assertTrue(failed)
            self.assertEqual(len(lines), 4)
            self.assertNotIn("FAIL", lines[2])
            self.assertIn("FAIL", lines[3])
            (root / "head" / ("c" * 40) / "pair.out").write_text("\n".join(json.dumps(r) for r in GOOD_PAIR))
            self.assertFalse(mop.verdict(root)[1])


class Resolve(unittest.TestCase):
    def test_newest_distinct_successful_uploads(self):
        def run(i, sha, created, conclusion="success", title=None):
            return {"id": i, "conclusion": conclusion, "created_at": created,
                    "display_title": title or f"cmux-next-ios INTERNAL {sha}"}
        runs = [run(1, "1" * 40, "2026-11-27T18:11:00Z"),
                run(2, "2" * 40, "2026-11-27T19:17:00Z"),
                run(3, "2" * 40, "2026-11-27T19:40:00Z"),            # a rerun of the same commit
                run(4, "3" * 40, "2026-11-27T20:00:00Z", "failure"),  # never uploaded
                run(5, "4" * 40, "2026-11-27T21:00:00Z", title="cmux-next-ios PUBLIC " + "4" * 40),
                run(6, "5" * 40, "2026-11-27T22:55:00Z"),
                run(7, "6" * 40, "2026-11-26T22:55:00Z")]
        got = mop.shipped_commits(runs, 3)
        self.assertEqual([g["sha"] for g in got], ["5" * 40, "2" * 40, "1" * 40])
        self.assertEqual(got[1]["run"], 3)


if __name__ == "__main__":
    unittest.main()
