#!/usr/bin/env python3
"""Tests for the packaged Linux behavior runner."""

from __future__ import annotations

import pathlib
import sys
import unittest
from unittest import mock


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import test_linux_packages  # noqa: E402


class LinuxReleaseBehaviorRunnerTests(unittest.TestCase):
    def test_runs_native_binary_on_glibc_and_musl(self) -> None:
        binary = pathlib.Path("/artifacts/cmux-tui")

        with mock.patch.object(test_linux_packages, "run") as run:
            test_linux_packages.test_release_behavior(
                binary,
                platform="linux/amd64",
                architecture="x64",
            )

        self.assertEqual(run.call_count, 2)
        calls = {call.args[0]: call.args[1] for call in run.call_args_list}
        self.assertEqual(
            set(calls),
            {
                "release behavior on glibc-bookworm (x64)",
                "release behavior on musl-alpine-3.22 (x64)",
            },
        )

        expected_images = {
            "release behavior on glibc-bookworm (x64)": "python:3.12-slim-bookworm",
            "release behavior on musl-alpine-3.22 (x64)": "python:3.12-alpine3.22",
        }
        for label, command in calls.items():
            self.assertEqual(
                command[:7],
                [
                    "docker",
                    "run",
                    "--rm",
                    "--platform",
                    "linux/amd64",
                    "--network",
                    "none",
                ],
            )
            self.assertIn(expected_images[label], command)
            self.assertIn("/artifacts/cmux-tui:/cmux-tui:ro", command)
            self.assertTrue(
                any(
                    mount.endswith(":/smoke-linux-release-binary.py:ro")
                    for mount in command
                )
            )
            self.assertIn("--architecture x64", command[-1])
            expected_family = "musl" if "musl-" in label else "glibc"
            self.assertIn(f"--runtime-family {expected_family}", command[-1])


if __name__ == "__main__":
    unittest.main()
