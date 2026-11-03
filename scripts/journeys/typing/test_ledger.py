#!/usr/bin/env python3
"""ledger.py on a synthetic 2-part typing run: planned keys from each part's own result, the hog window in
CLOCK_UPTIME_RAW, keys_check on the echo log. No fleet, no app, no movie (source in-app).

    python3 scripts/journeys/typing/test_ledger.py
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import typist  # noqa: E402


def make_run(tmp, hog_gb=14.2, drop=None):
    run = Path(tmp) / "run"
    j = run / "typing-load-l6-nf"
    j.mkdir(parents=True)
    plan = typist.plan(7, 120, columns=80)
    steps, reads, t0 = [], [], 1000.0
    for part, (lo, hi) in enumerate(((0, 60), (60, 120)), 1):
        evs = [dict(e, t_post=t0 + e["t"], t_back=t0 + e["t"] + 0.011) for e in plan if lo <= e["t"] < hi]
        steps.append({"do": "typist_play", "ok": True, "result": {
            "label": f"typing-load-l6-nf-part{part}", "events": evs, "planned": len(evs), "columns": 80, "seed": 7,
            "seconds": 120.0, "from": lo, "to": hi}})
        for e in evs:
            if drop is not None and e["i"] == drop:
                continue
            import keys_check
            reads.append({"t": e["t_post"] + 0.004, "bytes": keys_check.event_bytes(e).hex()})
    steps += [{"do": "env_windows", "ok": True, "result": {"smoke_env": False}},
              {"do": "load_stop", "ok": True, "result": {"profile": "L6", "alive_at_stop": True, "focus_changed": False}}]
    (j / "result.json").write_text(json.dumps({"steps": steps}))
    (j / "echo.jsonl").write_text("".join(json.dumps(r) + "\n" for r in reads))
    (run / "results.jsonl").write_text(json.dumps({"id": "typing-load-l6-nf", "status": "pass", "build_job": "J",
                                                   "commit": "c", "kit": "k", "kit_dirty": False}) + "\n")
    (run / "hog-cmux20.jsonl").write_text("".join(
        json.dumps({"t": 5e9 + k, "t_mono": t0 - 10 + k, "held_mb": hog_gb * 1024}) + "\n" for k in range(0, 200)))
    return run


class LedgerTests(unittest.TestCase):
    def ledger(self, run, tmp):
        done = subprocess.run([sys.executable, str(HERE / "ledger.py"), "--run", str(run), "--journey",
                               "typing-load-l6-nf", "--ledger", str(Path(tmp) / "led")], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads((Path(tmp) / "led" / "J.jsonl").read_text().splitlines()[-1])

    def test_two_parts_count_their_planned_keys_and_the_hog_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            row = self.ledger(make_run(tmp), tmp)
            self.assertEqual(row["parts"], 2)
            self.assertEqual(row["keys"], row["planned_keys"])
            self.assertTrue(row["order_ok"])
            self.assertEqual(row["hog_held_gb"], 14.2)
            self.assertTrue(row["load_ok"])
            self.assertEqual(row["source"], "in-app")  # no movie: never counts for the gate

    def test_a_lost_key_and_a_hog_outside_the_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = make_run(tmp, drop=100)
            (run / "hog-cmux20.jsonl").write_text(json.dumps({"t": 1, "t_mono": 1.0, "held_mb": 14000}) + "\n")
            row = self.ledger(run, tmp)
            self.assertFalse(row["order_ok"])
            self.assertEqual(row["lost"][0], 100)
            self.assertEqual(row["hog_held_gb"], 0.0)


if __name__ == "__main__":
    unittest.main()
