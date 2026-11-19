#!/usr/bin/env python3
"""Behavioral coverage for the manual workflow runner-literal lint."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import runner_literal_lint as lint  # noqa: E402


class RunnerLiteralLintTests(unittest.TestCase):
    def test_provider_and_owned_linux_and_macos_labels(self) -> None:
        for label in (
            "blacksmith-4vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404-arm",
            "blacksmith-6vcpu-macos-26", "warp-macos-15-arm64-6x", "tart-macos-15",
            "cmux-gcp-lane-build-x64", "cmux-fleet-linux-x64", "glaeda-trusted-next-signing",
            "glaeda-side-light-xcode-26.6", "self-hosted", "macfleet", "mac-mini-3",
        ):
            with self.subTest(label=label):
                self.assertEqual(lint.literal_labels(label), {label})

    def test_hosted_forks_pool_reads_and_windows_pass(self) -> None:
        for value in (
            "ubuntu-24.04", "macos-26", "windows-2025", "blacksmith-4vcpu-windows-2025",
            "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux_4 }}",
            "${{ fromJSON(vars.RUNNER_POOLS).macos_26 }}",
            "${{ fromJSON(vars.RUNNER_POOLS)['macos_26'] }}",
            "${{ needs.placement.outputs.runner || vars.LINUX_RUNNER }}",
            "${{ !startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || fromJSON(vars.RUNNER_POOLS).linux }}",
            "${{ github.ref == 'refs/heads/cmux-tui-pin-1' && needs.cmux-next.outputs.runner }}",
        ):
            with self.subTest(value=value):
                self.assertEqual(lint.literal_labels(value), set())

    def test_fork_branches_and_json_allowlists_do_not_hide_literals(self) -> None:
        label = "blacksmith-4vcpu-ubuntu-2404"
        for value in (
            "${{ github.event_name == 'pull_request' && '" + label + "' || fromJSON(vars.RUNNER_POOLS).linux }}",
            "${{ contains(fromJSON('[\"" + label + "\"]'), inputs.runner) && inputs.runner || fromJSON(vars.RUNNER_POOLS).linux }}",
            "${{ format('}} it''s {0}', '" + label + "') }}",
        ):
            with self.subTest(value=value):
                self.assertEqual(lint.literal_labels(value), {label})

    def test_lists_mapping_and_referenced_static_matrix_rows(self) -> None:
        label = "blacksmith-6vcpu-macos-26"
        for route in (["self-hosted", label], {"labels": ["self-hosted", label]},
                      {"group": "macfleet", "labels": label}):
            with self.subTest(route=route):
                self.assertIn(label, lint.job_labels({"runs-on": route}))
        job = {"runs-on": "${{ matrix.runner }}", "strategy": {"matrix": {"runner": [label, "macos-26"]}}}
        self.assertEqual(lint.job_labels(job), {label})
        job["runs-on"] = "${{ vars.MACOS_RUNNER || matrix['runner'] }}"
        self.assertEqual(lint.job_labels(job), {label})
        job["strategy"] = {"matrix": {"include": [{"runner": label}, {"runner": "macos-26"}]}}
        self.assertEqual(lint.job_labels(job), {label})
        job["runs-on"] = "${{ fromJSON(vars.RUNNER_POOLS).linux }}"
        self.assertEqual(lint.job_labels(job), set(), "unreferenced matrix data is not routing")

    def test_multiline_yaml_comments_and_step_text(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "example.yaml").write_text("""jobs:
  check:
    runs-on: >-
      ${{ vars.LINUX_RUNNER ||
          'blacksmith-4vcpu-ubuntu-2404' }}
    steps:
      - run: echo glaeda-nightly-only-m4pro
  good: # runs-on: blacksmith-6vcpu-macos-26
    runs-on: ${{ fromJSON(vars.RUNNER_POOLS).linux_4 }}
""")
            self.assertEqual(lint.inventory(path), [
                {"workflow": "example.yaml", "job": "check", "label": "blacksmith-4vcpu-ubuntu-2404"}])
            with contextlib.redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(lint.main(["--workflows", directory]), 1)
            self.assertIn("fromJSON(vars.RUNNER_POOLS)", errors.getvalue())
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(lint.main(["--workflows", directory, "--inventory"]), 0)
            self.assertEqual(json.loads(output.getvalue()), lint.inventory(path))

    def test_invalid_expression_duplicate_yaml_keys_and_empty_directory_fail_closed(self) -> None:
        with self.assertRaises(ValueError):
            lint.literal_labels("${{ 'blacksmith-4vcpu-ubuntu-2404' ")
        with tempfile.TemporaryDirectory() as directory:
            args = ["--workflows", directory]
            for text in (None, "jobs:\n  a: {runs-on: ubuntu-24.04}\n  a: {runs-on: macos-26}\n",
                         "jobs: [", "jobs: [a]", "jobs: {a: null}"):
                with self.subTest(text=text), contextlib.redirect_stderr(io.StringIO()):
                    if text is not None:
                        (Path(directory) / "bad.yml").write_text(text)
                    self.assertEqual(lint.main(args), 2)


if __name__ == "__main__":
    unittest.main()
