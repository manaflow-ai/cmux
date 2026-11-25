#!/usr/bin/env python3
"""scripts/ci/cmux_tui_channel_keeper.py: the feat-cmux-next channel follows the newest published,
daemon-tested tree, whichever run published or tested it.

Leo, 2026-11-23: "but why is it a job. we own/should own the in-between. like ci v2. we own the end to end."
Offline: git, the tree key and files.cmux.com are faked.
"""

from __future__ import annotations

import argparse
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import cmux_tui_channel_keeper as keeper  # noqa: E402

BASE = keeper.BASE
CHANNEL_COMMIT = "c" * 40


def key_of(commit: str) -> str:
    return commit[0] * 39 + "k"


class Fake:
    """A first-parent history (newest first) and which tree keys are published and tested."""

    def __init__(self, history: list[str], published: set[str], tested: set[str], channel: str = CHANNEL_COMMIT):
        self.history, self.published, self.tested, self.channel = history, published, tested, channel

    def git(self, *args: str) -> str:
        if args[0] == "rev-parse":
            return self.history[0]
        if args[:2] == ("rev-list", "--count"):
            return str(self.history.index(self.channel))
        if args[0] == "show":
            return "0"
        if args[:2] == ("rev-list", "--first-parent"):
            return "\n".join(self.history)
        raise AssertionError(args)

    def fetch(self, url: str) -> tuple[int, bytes]:
        if url.endswith(f"/channels/{keeper.CHANNEL}.json"):
            return 200, f'{{"commit": "{self.channel}", "key": "{key_of(self.channel)}"}}'.encode()
        key = url.split("/tree/", 1)[1].split("/", 1)[0]
        if url.endswith("/completion.json"):
            return (200, f'{{"key": "{key}"}}'.encode()) if key in self.published else (404, b"")
        if url.endswith("/daemon-tests.json"):
            return (200, b"{}") if key in self.tested else (404, b"")
        return 404, b""

    def patch(self):
        return mock.patch.multiple(keeper, git=self.git, fetch=self.fetch, tree_key=key_of)


def drive_args(**kw) -> argparse.Namespace:
    base = dict(limit=300, no_fetch=True, runner="true {commit}", dry_run=False, point_only=False)
    base.update(kw)
    return argparse.Namespace(**base)


class KeeperTests(unittest.TestCase):
    def test_current_when_the_head_is_the_channel(self) -> None:
        with Fake([CHANNEL_COMMIT], set(), set()).patch():
            report = keeper.measure(300, fetch_branch=False)
        self.assertEqual(report.state, "current")

    def test_a_tested_tree_the_channel_skipped_is_point_due(self) -> None:
        # 62687afe550b at 3cd71dcc6bb2 on 2026-11-23: published and tested, never pointed at.
        history = ["a" * 40, "b" * 40, "d" * 40, CHANNEL_COMMIT]
        with Fake(history, published={key_of("b" * 40)}, tested={key_of("b" * 40)}).patch():
            report = keeper.measure(300, fetch_branch=False)
        self.assertEqual(report.state, "point-due")
        self.assertEqual(report.newest_tested.commit, "b" * 40)

    def test_a_newer_untested_tree_is_named_and_the_tested_one_kept(self) -> None:
        history = ["a" * 40, "b" * 40, CHANNEL_COMMIT]
        with Fake(history, published={key_of("a" * 40), key_of("b" * 40)}, tested={key_of("b" * 40)}).patch():
            report = keeper.measure(300, fetch_branch=False)
        self.assertEqual(report.state, "untested")
        self.assertEqual(report.newest_published.commit, "a" * 40)
        self.assertEqual(report.newest_tested.commit, "b" * 40)

    def test_point_only_points_at_the_tested_tree_and_runs_no_tests(self) -> None:
        history = ["a" * 40, "b" * 40, CHANNEL_COMMIT]
        fake = Fake(history, published={key_of("a" * 40), key_of("b" * 40)}, tested={key_of("b" * 40)})
        env = {"R2_ENDPOINT": "x", "AWS_ACCESS_KEY_ID": "x", "AWS_SECRET_ACCESS_KEY": "x", "GH_TOKEN": "x"}
        with fake.patch(), mock.patch.dict(keeper.os.environ, env), \
                mock.patch.object(keeper.subprocess, "run") as run:
            code = keeper.drive(drive_args(point_only=True))
        self.assertEqual(code, keeper.EXIT_CURRENT)
        argvs = [call.args[0] for call in run.call_args_list]
        self.assertEqual(len(argvs), 1, argvs)  # no tests, no marker: only the point
        self.assertTrue(argvs[0][0].endswith("cmux-tui-point-channel.sh"))
        self.assertEqual(argvs[0][1:], [keeper.CHANNEL, key_of("b" * 40)])
        self.assertEqual(run.call_args.kwargs["env"]["GITHUB_SHA"], "b" * 40)

    def test_point_only_with_nothing_tested_does_nothing(self) -> None:
        history = ["a" * 40, CHANNEL_COMMIT]
        with Fake(history, published={key_of("a" * 40)}, tested=set()).patch(), \
                mock.patch.object(keeper.subprocess, "run") as run:
            self.assertEqual(keeper.drive(drive_args(point_only=True)), keeper.EXIT_CURRENT)
        run.assert_not_called()

    def test_point_only_is_never_red_while_newer_trees_build(self) -> None:
        history = ["a" * 40, CHANNEL_COMMIT]
        with Fake(history, published=set(), tested=set()).patch(), \
                mock.patch.object(keeper.subprocess, "run") as run:
            self.assertEqual(keeper.drive(drive_args(point_only=True)), keeper.EXIT_CURRENT)
            self.assertEqual(keeper.drive(drive_args()), keeper.EXIT_BEHIND)
        run.assert_not_called()

    def test_drive_tests_an_untested_tree_on_our_machines_then_marks_and_points(self) -> None:
        history = ["a" * 40, CHANNEL_COMMIT]
        env = {"R2_ENDPOINT": "x", "AWS_ACCESS_KEY_ID": "x", "AWS_SECRET_ACCESS_KEY": "x", "GH_TOKEN": "x"}
        with Fake(history, published={key_of("a" * 40)}, tested=set()).patch(), \
                mock.patch.dict(keeper.os.environ, env), \
                mock.patch.object(keeper.subprocess, "run",
                                  return_value=mock.Mock(returncode=0)) as run:
            self.assertEqual(keeper.drive(drive_args(runner="tests {commit}")), keeper.EXIT_CURRENT)
        calls = run.call_args_list
        self.assertEqual(calls[0].args[0], f"tests {'a' * 40}")
        self.assertTrue(calls[1].args[0][0].endswith("cmux-tui-mark-daemon-tested.sh"))
        self.assertTrue(calls[2].args[0][0].endswith("cmux-tui-point-channel.sh"))

    def test_a_red_run_points_at_nothing(self) -> None:
        history = ["a" * 40, CHANNEL_COMMIT]
        with Fake(history, published={key_of("a" * 40)}, tested=set()).patch(), \
                mock.patch.object(keeper.subprocess, "run", return_value=mock.Mock(returncode=101)) as run:
            self.assertEqual(keeper.drive(drive_args()), 101)
        self.assertEqual(len(run.call_args_list), 1)

    def test_a_pass_without_credentials_says_so(self) -> None:
        history = ["a" * 40, CHANNEL_COMMIT]
        env = {name: "" for name in ("R2_ENDPOINT", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "GH_TOKEN")}
        with Fake(history, published={key_of("a" * 40)}, tested=set()).patch(), \
                mock.patch.dict(keeper.os.environ, env), \
                mock.patch.object(keeper.subprocess, "run", return_value=mock.Mock(returncode=0)):
            self.assertEqual(keeper.drive(drive_args()), keeper.EXIT_NO_CREDENTIALS)


if __name__ == "__main__":
    unittest.main()
