#!/usr/bin/env python3
"""Every macOS job names its job class in .github/runners.json.

The live check runs scripts/ci/runner_routing_table.py against this tree. The
fixture tests pin what that check refuses: a new macOS job with no class, a
macOS job whose class runs on Linux, and an entry for a job that is gone.
"""

from __future__ import annotations

import json
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import runner_routing_table as table  # noqa: E402

CLASSES = {
    "apple-app-build": {"needs": "macos", "description": "Builds the app with Xcode."},
    "web-and-tooling": {"needs": "linux", "description": "Linters and web tests."},
}


class Fixture:
    def __init__(self, workflows: dict[str, str], macos_jobs: dict[str, object]) -> None:
        self._dir = tempfile.TemporaryDirectory()
        root = Path(self._dir.name)
        self.workflows = root / "workflows"
        self.workflows.mkdir()
        for name, text in workflows.items():
            (self.workflows / name).write_text(textwrap.dedent(text), encoding="utf-8")
        self.map = root / "runners.json"
        self.map.write_text(
            json.dumps({"job_classes": CLASSES, "macos_jobs": macos_jobs}), encoding="utf-8"
        )

    def check(self) -> list[str]:
        return table.check(self.map, self.workflows)

    def close(self) -> None:
        self._dir.cleanup()


MAC_JOB = """
    on: push
    jobs:
      build:
        runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || 'blacksmith-6vcpu-macos-26' }}
        steps:
          - run: xcodebuild build
      lint:
        runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }}
        steps:
          - run: bun run lint
"""


class RoutingTableTests(unittest.TestCase):
    def run_fixture(self, workflows: dict[str, str], macos_jobs: dict[str, object]) -> list[str]:
        fixture = Fixture(workflows, macos_jobs)
        self.addCleanup(fixture.close)
        return fixture.check()

    def test_the_tree_classifies_every_macos_job(self) -> None:
        self.assertEqual(table.check(), [])

    def test_a_classified_macos_job_passes(self) -> None:
        self.assertEqual(self.run_fixture({"w.yml": MAC_JOB}, {"w.yml#build": "apple-app-build"}), [])

    def test_a_new_macos_job_without_a_class_fails(self) -> None:
        problems = self.run_fixture({"w.yml": MAC_JOB}, {})
        self.assertEqual(len(problems), 1)
        self.assertIn("w.yml#build runs on macOS but has no entry", problems[0])

    def test_a_macos_job_whose_class_runs_on_linux_fails(self) -> None:
        problems = self.run_fixture({"w.yml": MAC_JOB}, {"w.yml#build": "web-and-tooling"})
        self.assertEqual(len(problems), 1)
        self.assertIn("which runs on Linux runners", problems[0])

    def test_an_existing_job_marked_to_move_passes_until_it_moves(self) -> None:
        entry = {"class": "web-and-tooling", "linux_followup": "move the lint to Linux"}
        self.assertEqual(self.run_fixture({"w.yml": MAC_JOB}, {"w.yml#build": entry}), [])

    def test_an_unknown_class_fails(self) -> None:
        problems = self.run_fixture({"w.yml": MAC_JOB}, {"w.yml#build": "no-such-class"})
        self.assertIn("unknown job class 'no-such-class'", problems[0])

    def test_entries_for_gone_or_linux_jobs_fail(self) -> None:
        problems = self.run_fixture(
            {"w.yml": MAC_JOB},
            {"w.yml#build": "apple-app-build", "w.yml#lint": "apple-app-build", "w.yml#gone": "apple-app-build"},
        )
        self.assertEqual(len(problems), 2)
        self.assertTrue(any("w.yml#gone" in p and "does not exist" in p for p in problems))
        self.assertTrue(any("w.yml#lint" in p and "no longer runs on macOS" in p for p in problems))

    def test_an_unreadable_runner_expression_counts_as_macos(self) -> None:
        workflow = """
            on: push
            jobs:
              build:
                runs-on: ${{ inputs.runner }}
                steps:
                  - run: make
        """
        problems = self.run_fixture({"w.yml": workflow}, {})
        self.assertIn("w.yml#build runs on macOS", problems[0])

    def test_an_owned_mac_pool_counts_as_macos(self) -> None:
        workflow = """
            on: push
            jobs:
              build:
                runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_SIDE_LANE_RUNNER }}
                steps:
                  - run: make
        """
        problems = self.run_fixture({"w.yml": workflow}, {})
        self.assertIn("w.yml#build runs on macOS", problems[0])

    def test_a_reusable_workflow_call_is_checked_in_its_callee(self) -> None:
        workflow = """
            on: push
            jobs:
              call:
                uses: ./.github/workflows/other.yml
        """
        self.assertEqual(self.run_fixture({"w.yml": workflow}, {}), [])

    def test_a_matrix_runner_is_read_from_the_strategy(self) -> None:
        workflow = """
            on: push
            jobs:
              test:
                strategy:
                  matrix:
                    runner: [blacksmith-4vcpu-ubuntu-2404, blacksmith-6vcpu-macos-15]
                runs-on: ${{ matrix.runner }}
                steps:
                  - run: cargo test
        """
        problems = self.run_fixture({"w.yml": workflow}, {})
        self.assertIn("w.yml#test runs on macOS", problems[0])

    def test_a_job_on_the_capability_map_routes_by_its_key(self) -> None:
        workflow = """
            on: push
            jobs:
              runners:
                uses: ./.github/workflows/resolve-runners.yml
              lint:
                needs: runners
                runs-on: ${{ fromJSON(needs.runners.outputs.map).linux_16 }}
                steps:
                  - run: bun run lint
              build:
                needs: runners
                runs-on: ${{ fromJSON(needs.runners.outputs.map).macos_26 }}
                steps:
                  - run: xcodebuild build
        """
        problems = self.run_fixture({"w.yml": workflow}, {})
        self.assertEqual(len(problems), 1)
        self.assertIn("w.yml#build runs on macOS", problems[0])

    SIDE_JOB = """
        on: push
        jobs:
          test:
            runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_SIDE_LANE_RUNNER || 'blacksmith-6vcpu-macos-15' }}
            steps:
              - run: xcodebuild test
    """

    def test_a_macos_job_that_bypasses_placement_fails(self) -> None:
        problems = self.run_fixture({"w.yml": self.SIDE_JOB}, {"w.yml#test": "apple-app-build"})
        self.assertEqual(len(problems), 1)
        self.assertIn("bypasses placement", problems[0])

    def test_an_existing_bypass_passes_until_it_takes_placement(self) -> None:
        entry = {"class": "apple-app-build", "placement_followup": "route through placement"}
        self.assertEqual(self.run_fixture({"w.yml": self.SIDE_JOB}, {"w.yml#test": entry}), [])
        problems = self.run_fixture({"w.yml": MAC_JOB}, {"w.yml#build": entry})
        self.assertIn("no longer bypasses placement", problems[0])

    def test_a_placement_output_with_a_variable_fallback_is_placed(self) -> None:
        workflow = """
            on: push
            jobs:
              test:
                runs-on: ${{ github.run_attempt == 1 && needs.placement.outputs.runner || vars.CI_SIDE_LANE_RUNNER }}
                steps:
                  - run: xcodebuild test
        """
        self.assertEqual(self.run_fixture({"w.yml": workflow}, {"w.yml#test": "apple-app-build"}), [])

    def test_a_linux_followup_on_a_macos_class_fails(self) -> None:
        entry = {"class": "apple-app-build", "linux_followup": "stale"}
        problems = self.run_fixture({"w.yml": MAC_JOB}, {"w.yml#build": entry})
        self.assertIn("remove its linux_followup", problems[0])

    def test_linux_size_capabilities_resolve_on_every_fleet(self) -> None:
        document = json.loads((ROOT / ".github" / "runners.json").read_text(encoding="utf-8"))
        for fleet in document["fleets"].values():
            for key in ("linux", "linux_16", "linux_32"):
                self.assertIn("ubuntu", fleet[key])


if __name__ == "__main__":
    unittest.main()
