#!/usr/bin/env python3
"""run_python_test_lane.py --shard K/N splits the lanes' tests into N parts by recorded seconds.

ci-macos.yml's cli-regressions job runs the CLI and shell regressions as N shards, each serial on its own
machine. Every test must run in exactly one shard, the split must not depend on the run, and the shards should
take about the same time.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts" / "ci" / "run_python_test_lane.py"
SECONDS = ROOT / "scripts" / "ci" / "python-test-lane-seconds.json"
CLI_LANES = ("macos-shell", "macos-cli-no-socket", "macos-shell-fish", "macos-cli-no-socket-post-fish")

sys.path.insert(0, str(RUNNER.parent))
spec = importlib.util.spec_from_file_location("run_python_test_lane", RUNNER)
runner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner
spec.loader.exec_module(runner)


def listed(*extra: str) -> list[str]:
    lanes = [argument for lane in CLI_LANES for argument in ("--lane", lane)]
    done = subprocess.run([sys.executable, str(RUNNER), *lanes, "--list", *extra],
                          capture_output=True, text=True, check=True)
    return done.stdout.split()


class ShardTests(unittest.TestCase):
    def test_every_test_runs_in_exactly_one_shard(self) -> None:
        everything = listed()
        shards = [listed("--shard", f"{index}/3") for index in (1, 2, 3)]
        self.assertTrue(all(shards), shards)
        combined = [path for shard in shards for path in shard]
        self.assertEqual(sorted(combined), sorted(everything))
        self.assertEqual(len(combined), len(set(combined)))

    def test_a_shard_keeps_registry_order(self) -> None:
        everything = listed()
        shard = listed("--shard", "2/3")
        self.assertEqual(shard, [path for path in everything if path in set(shard)])

    def test_the_split_balances_recorded_seconds(self) -> None:
        paths = [f"tests/test_{index}.py" for index in range(8)]
        seconds = {paths[0]: 70.0, paths[1]: 30.0, paths[2]: 25.0, paths[3]: 25.0,
                   paths[4]: 20.0, paths[5]: 20.0, paths[6]: 10.0}  # paths[7] has no record
        shards = [runner.shard(paths, seconds, index, 3) for index in (1, 2, 3)]
        loads = [sum(seconds.get(path, runner.UNKNOWN_SECONDS) for path in shard) for shard in shards]
        self.assertLessEqual(max(loads) - min(loads), 25.0, (shards, loads))
        self.assertEqual(shards, [runner.shard(paths, seconds, index, 3) for index in (1, 2, 3)])

    def test_the_cli_lanes_split_into_three_shards_of_similar_length(self) -> None:
        seconds = json.loads(SECONDS.read_text())
        loads = [sum(seconds.get(path, runner.UNKNOWN_SECONDS) for path in listed("--shard", f"{index}/3"))
                 for index in (1, 2, 3)]
        self.assertLess(max(loads), sum(loads) / 3 * 1.25, loads)

    def test_a_bad_shard_is_refused(self) -> None:
        for value in ("0/3", "4/3", "1/0", "x", "1-3"):
            done = subprocess.run([sys.executable, str(RUNNER), "--lane", "macos-shell", "--list", "--shard", value],
                                  capture_output=True, text=True)
            self.assertNotEqual(done.returncode, 0, value)


if __name__ == "__main__":
    unittest.main()
