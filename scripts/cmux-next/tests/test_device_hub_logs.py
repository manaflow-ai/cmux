"""device-hub-logs.py prints the hub's `relay entitlement` and `relay mint` lines, and nothing else."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/cmux-next/device-hub-logs.py"


def event(ts, message):
    return {"timestamp": ts, "$metadata": {"message": message, "url": "https://hub.example/v1/me", "coloCode": "SJC"}}


class DeviceHubLogs(unittest.TestCase):
    def run_on(self, events):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "events.json"
            path.write_text(json.dumps(events))
            out = subprocess.run([sys.executable, "-I", str(SCRIPT), "--events", str(path)], capture_output=True, text=True, check=True).stdout
        head, *rest = out.splitlines()
        return json.loads(head), "\n".join(rest)

    def test_paid_with_no_key_names_the_cause(self):
        head, body = self.run_on([
            event(1, "relay entitlement: paid"),
            event(2, "relay mint: platform failed (status 502 turn_mint_failed)"),
            event(3, "relay mint: none (no local key)"),
            event(4, "relay mint: local failed (turn 401)"),
        ])
        self.assertEqual((head["entitlement_lines"], head["mint_lines"]), (1, 3))
        for line in ("relay entitlement: paid", "relay mint: platform failed (status 502 turn_mint_failed)",
                     "relay mint: none (no local key)", "relay mint: local failed (turn 401)"):
            self.assertIn(f"| {line} | /v1/me | - | SJC |", body)

    def test_lines_off_the_shape_are_never_printed(self):
        head, body = self.run_on([
            event(1, "relay mint: local failed (token=abc/def?x)"),
            event(2, "relay mint: other (x)"),
            event(3, "relay entitlement: paid user 42"),
        ])
        self.assertEqual((head["entitlement_lines"], head["mint_lines"]), (0, 0))
        self.assertNotIn("abc", body)
        self.assertNotIn("user 42", body)


if __name__ == "__main__":
    unittest.main()
