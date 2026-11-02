#!/usr/bin/env python3
"""run.py never reports an earlier run's result.json as this round's (resize P0, 2026-10-31).

A reused --out folder held the 11:22Z round's <id>/result.json; at 11:32Z the launch failed before the driver
wrote anything, and run.py's collect reported the old file as the new round's fail. Here a fake capture-host gives a
lease and then fails, as that launch did: the round must be "not run", and the old result must be kept aside, not
deleted. Standard library only: python3 scripts/journeys/test_run_stale_result.py"""
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run  # noqa: E402


class StaleResultTests(unittest.TestCase):
    def test_a_failed_round_never_reports_an_old_result(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            fake = tmp / "capture-host"
            # acquire gives a lease; slot-info fails (the lease cannot be used); release succeeds.
            fake.write_text("#!/bin/sh\ncase \"$1\" in\n  acquire) echo lease-test ;;\n  slot-info) exit 1 ;;\n"
                            "  release) exit 0 ;;\nesac\n")
            fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
            out = tmp / "round"
            (out / "j1").mkdir(parents=True)
            (out / "j1" / "result.json").write_text(json.dumps({"status": "fail", "reason": "the old round's"}))
            old_env = os.environ.get("CAPTURE_HOST")
            os.environ["CAPTURE_HOST"] = str(fake)
            try:
                results = run.run_lease([{"id": "j1"}], {"id": "job", "commit": "0" * 40, "tag": "t"}, out, 1.0)
            finally:
                if old_env is None:
                    os.environ.pop("CAPTURE_HOST", None)
                else:
                    os.environ["CAPTURE_HOST"] = old_env
            self.assertEqual(results["j1"]["status"], "not run", results["j1"])
            self.assertNotIn("the old round's", json.dumps(results["j1"]))
            kept = [p for p in out.iterdir() if p.name.startswith("j1.old-")]
            self.assertEqual(len(kept), 1, "the old result was not kept aside")
            self.assertTrue((kept[0] / "result.json").is_file())


if __name__ == "__main__":
    unittest.main()
