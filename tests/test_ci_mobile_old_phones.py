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


class RunsRequestTest(unittest.TestCase):
    # The first real run (46111150746) died at resolve with HTTP 403: urllib's default agent.
    def test_names_its_agent_and_api_version(self):
        req = mop.runs_request("manaflow-ai/cmux", "tok")
        self.assertTrue(req.get_header("User-agent", "").startswith("cmux-ci-mobile-old-phones"))
        self.assertEqual(req.get_header("X-github-api-version"), "2022-11-28")
        self.assertEqual(req.get_header("Authorization"), "Bearer tok")

    def test_no_token_sends_no_authorization(self):
        self.assertIsNone(mop.runs_request("manaflow-ai/cmux", "").get_header("Authorization"))

class FetchRunsRetryTest(unittest.TestCase):
    def _err(self, code, reset=None):
        import email.message, io, urllib.error
        h = email.message.Message(); h["x-ratelimit-remaining"] = "0"
        if reset is not None:
            h["x-ratelimit-reset"] = str(reset)
        return urllib.error.HTTPError("u", code, "Forbidden", h, io.BytesIO(b'{"message":"rate limit"}'))

    def test_403_then_ok_retries(self):
        import io
        calls = []
        def opener(req, timeout):
            calls.append(1)
            if len(calls) == 1:
                raise self._err(403)
            return io.BytesIO(b'{"workflow_runs":[{"id":1}]}')
        self.assertEqual(mop.fetch_runs("o/r", "t", opener=opener, sleep=lambda s: None), [{"id": 1}])
        self.assertEqual(len(calls), 2)

    def test_last_403_names_githubs_reason(self):
        def opener(req, timeout):
            raise self._err(403)
        with self.assertRaises(SystemExit) as cm:
            mop.fetch_runs("o/r", "t", opener=opener, sleep=lambda s: None)
        self.assertIn("403", str(cm.exception))
        self.assertIn("x-ratelimit-remaining=0", str(cm.exception))
        self.assertIn("rate limit", str(cm.exception))

    def test_spent_quota_without_a_cache_reads_again_after_the_reset(self):
        # Run 46141489174: no earlier list (evicted from the full repo cache), quota due back in minutes,
        # and the job died after 85 s of retries.
        import io
        calls, slept = [], []
        def opener(req, timeout):
            calls.append(1)
            if len(calls) <= 4:
                raise self._err(403, reset=1000 + 600)
            return io.BytesIO(b'{"workflow_runs":[{"id":2}]}')
        got = mop.fetch_runs("o/r", "t", opener=opener, sleep=slept.append, now=lambda: 1000,
                             reset_wait_max=mop.RESET_WAIT_MAX_S)
        self.assertEqual(got, [{"id": 2}])
        self.assertEqual(slept, [5, 20, 60, 605])

    def test_reset_further_than_the_bound_fails_without_waiting(self):
        slept = []
        def opener(req, timeout):
            raise self._err(403, reset=1000 + mop.RESET_WAIT_MAX_S + 1)
        with self.assertRaises(SystemExit):
            mop.fetch_runs("o/r", "t", opener=opener, sleep=slept.append, now=lambda: 1000,
                           reset_wait_max=mop.RESET_WAIT_MAX_S)
        self.assertEqual(slept, [5, 20, 60])

    def test_waits_for_the_reset_once(self):
        slept = []
        def opener(req, timeout):
            raise self._err(403, reset=1060)
        with self.assertRaises(SystemExit):
            mop.fetch_runs("o/r", "t", opener=opener, sleep=slept.append, now=lambda: 1000,
                           reset_wait_max=mop.RESET_WAIT_MAX_S)
        self.assertEqual(slept, [5, 20, 60, 65])

class ResolveCacheTest(unittest.TestCase):
    # Runs 46116606886 and 46125947911 died at resolve: "API rate limit exceeded for installation".
    RUNS = [{"id": 9, "conclusion": "success", "created_at": "2026-11-28T05:17:48Z",
             "display_title": "cmux-next-ios INTERNAL " + "a" * 40}]

    @staticmethod
    def refused(repo, token, **kw):
        raise SystemExit("::error::GitHub answered 403 for the ios-internal-nightly runs (x-ratelimit-remaining=0)")

    def test_fresh_read_fills_the_cache(self):
        with tempfile.TemporaryDirectory() as d:
            cache = Path(d) / "c" / "phones.txt"
            lines, fresh = mop.resolve("o/r", "t", 3, cache, fetch=lambda r, t, **kw: self.RUNS)
            self.assertTrue(fresh)
            self.assertEqual(lines, ["a" * 40 + " 9 2026-11-28T05:17:48Z"])
            self.assertEqual(cache.read_text(), lines[0] + "\n")

    def test_rate_limited_read_answers_from_the_cache(self):
        with tempfile.TemporaryDirectory() as d:
            cache = Path(d) / "phones.txt"
            cache.write_text("b" * 40 + " 8 2026-11-28T00:49:41Z\n")
            lines, fresh = mop.resolve("o/r", "t", 3, cache, fetch=self.refused)
            self.assertFalse(fresh)
            self.assertEqual(lines, ["b" * 40 + " 8 2026-11-28T00:49:41Z"])

    def test_waits_for_the_reset_only_without_a_cache(self):
        seen = []
        def fetch(repo, token, *, reset_wait_max=0):
            seen.append(reset_wait_max)
            return self.RUNS
        with tempfile.TemporaryDirectory() as d:
            cache = Path(d) / "phones.txt"
            mop.resolve("o/r", "t", 3, cache, fetch=fetch)
            mop.resolve("o/r", "t", 3, cache, fetch=fetch)
        self.assertEqual(seen, [mop.RESET_WAIT_MAX_S, 0])

    def test_rate_limited_read_without_a_cache_still_fails(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(SystemExit):
                mop.resolve("o/r", "t", 3, Path(d) / "none.txt", fetch=self.refused)


class CleanupTrapTest(unittest.TestCase):
    """The EXIT trap runs under set -e: a helper that returns nonzero there ends cleanup early,
    so registered phone devices are never deleted and an all-ok run exits 1."""

    def test_stop_host_with_no_host_running_lets_cleanup_finish(self):
        import subprocess
        script = (ROOT / "scripts/ci/mobile-old-phones.sh").read_text()
        stop = next(line for line in script.splitlines() if line.startswith("stop_host()"))
        probe = f"set -euo pipefail\n{stop}\nafter() {{ stop_host; echo cleanup-finished; }}\ntrap after EXIT\nexit 0\n"
        r = subprocess.run(["bash", "-c", probe], capture_output=True, text=True)
        self.assertEqual(r.stdout.strip(), "cleanup-finished", r.stderr)
        self.assertEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
