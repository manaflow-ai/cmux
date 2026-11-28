"""nightly.yml's cargo calls ride out a crates.io blip.

Why: docs/ci/nightly-workflow-notes/2026-11-28-cargo-net-retry.md (job 140875083765: cargo's default 3
retries all timed out on index.crates.io and failed the NEXT nightly).
"""
from pathlib import Path
import re
import unittest

NIGHTLY = Path(__file__).resolve().parents[1] / ".github/workflows/nightly.yml"


class NightlyCargoNetRetry(unittest.TestCase):
    def test_workflow_env_sets_cargo_network_resilience(self) -> None:
        m = re.search(r"^env:\n((?:[ #].*\n|\n)*)", NIGHTLY.read_text(), re.M)
        self.assertIsNotNone(m, "nightly.yml has no workflow-level env")
        env = m.group(1)
        for line in ('CARGO_NET_RETRY: "10"', 'CARGO_HTTP_TIMEOUT: "120"', 'CARGO_HTTP_MULTIPLEXING: "false"'):
            self.assertIn(line, env)

    def test_no_step_turns_retries_back_down(self) -> None:
        for m in re.finditer(r"CARGO_NET_RETRY:\s*\"?(\d+)", NIGHTLY.read_text()):
            self.assertGreaterEqual(int(m.group(1)), 10, f"a step lowers CARGO_NET_RETRY to {m.group(1)}")


if __name__ == "__main__":
    unittest.main()
