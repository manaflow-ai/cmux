#!/usr/bin/env python3
"""The iPhone INTERNAL archive takes the dedicated mini only while it can take the job, else Blacksmith.

Before, runs-on read vars.CI_IOS_INTERNAL_RUNNER (one mini's own runner label)
directly, and a set variable never falls through: every archive waited on that
mini (Leo, 2026-10-24: no job waits on one reserved machine).
"""

from __future__ import annotations

import base64
import contextlib
import datetime as dt
import gzip
import io
import json
import sys
import unittest
from unittest import mock
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import ios_internal_runner as picker  # noqa: E402

LABEL = "glaeda-runner-mini-ios-internal"
WORKFLOW = ROOT / ".github" / "workflows" / "ios-internal-nightly.yml"


def runner(status: str = "online", busy: bool = False, label: str = LABEL) -> dict:
    return {"status": status, "busy": busy, "labels": [{"name": label}, {"name": "glaeda-ios-internal-next"}]}


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


class Pick(unittest.TestCase):
    def pick(self, reads: list, label: str = LABEL) -> tuple[str, str, int]:
        clock, calls = Clock(), []

        def read():
            calls.append(1)
            return reads[min(len(calls), len(reads)) - 1]

        dedicated, why = picker.pick(label, read, sleep=clock.sleep, clock=clock)
        return dedicated, why, len(calls)

    def test_idle_mini_is_taken(self) -> None:
        self.assertEqual(self.pick([[runner()]])[0], LABEL)

    def test_offline_unread_or_unset_takes_blacksmith_at_once(self) -> None:
        self.assertEqual(self.pick([[runner("offline")]])[:1], ("",))
        self.assertEqual(self.pick([[]])[:1], ("",))
        self.assertEqual(self.pick([None])[:1], ("",))
        self.assertEqual(self.pick([[runner()]], label="")[:1], ("",))
        # Another runner's label does not count.
        self.assertEqual(self.pick([[runner(label="glaeda-runner-other")]])[:1], ("",))

    def test_busy_mini_is_waited_on_for_at_most_five_minutes(self) -> None:
        dedicated, why, calls = self.pick([[runner(busy=True)]])
        self.assertEqual(dedicated, "")
        self.assertIn("stayed busy", why)
        self.assertLessEqual(calls, picker.WAIT_SECONDS // picker.LOOK_SECONDS + 1)
        dedicated, _, calls = self.pick([[runner(busy=True)], [runner(busy=True)], [runner()]])
        self.assertEqual((dedicated, calls), (LABEL, 3))

    def test_main_never_fails_and_writes_the_attempt(self) -> None:
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out")

            def broken(token, repo):
                raise RuntimeError("body with a token-like value")

            env = {"GITHUB_REPOSITORY": "o/r", "ROUTE_TOKEN": "t", "DEDICATED_LABEL": LABEL,
                   "GITHUB_RUN_ATTEMPT": "2", "GITHUB_OUTPUT": out}
            import contextlib
            import io
            printed = io.StringIO()
            with contextlib.redirect_stdout(printed):
                self.assertEqual(picker.main(env, read_runners=broken), 0)
            self.assertNotIn("token-like", printed.getvalue())
            self.assertEqual(Path(out).read_text(), "dedicated=\nattempt=2\n")
            Path(out).write_text("")
            self.assertEqual(picker.main(env, read_runners=lambda token, repo: [runner()]), 0)
            self.assertEqual(Path(out).read_text(), f"dedicated={LABEL}\nattempt=2\n")


class SharedFirstLook(unittest.TestCase):
    def document(self, *, busy=False, repository=True):
        row = dict(runner(busy=busy), id=1, name="synthetic-archive", os="macOS")
        doc = dict(schema="runner-state/v1", repository="manaflow-ai/cmux", complete=True,
                   generated_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                   repository_runners=[row] if repository else [],
                   runner_groups={"glaeda-minis": [] if repository else [row]}, scale_sets={})
        return base64.b64encode(gzip.compress(json.dumps(doc).encode())).decode()

    def run_main(self, raw):
        env = dict(GITHUB_REPOSITORY="manaflow-ai/cmux", ROUTE_TOKEN="synthetic-token",
                   DEDICATED_LABEL=LABEL, CI_RUNNER_STATE=raw)
        clock, output = Clock(), io.StringIO()
        with mock.patch.object(picker.pool.GitHub, "_runner_pages", return_value=[runner()]) as pages, \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(picker.main(env, sleep=clock.sleep, clock=clock), 0)
        return output.getvalue(), clock.now, pages

    def test_idle_document_is_first_look_without_a_repository_read(self):
        output, waited, pages = self.run_main(self.document())
        self.assertIn(f"archive runner: {LABEL}", output)
        self.assertEqual(waited, 0)
        pages.assert_not_called()

    def test_busy_document_is_rechecked_live_and_can_become_idle(self):
        output, waited, pages = self.run_main(self.document(busy=True))
        self.assertIn(f"archive runner: {LABEL}", output)
        self.assertEqual(waited, picker.LOOK_SECONDS)
        pages.assert_called_once_with("/repos/manaflow-ai/cmux/actions/runners")

    def test_document_preserves_repository_only_scope_and_invalid_state_falls_back(self):
        output, _, pages = self.run_main(self.document(repository=False))
        self.assertIn("archive runner: Blacksmith", output)
        pages.assert_not_called()
        for raw in ("", "invalid-base64"):
            with self.subTest(raw=raw):
                output, _, pages = self.run_main(raw)
                self.assertIn(f"archive runner: {LABEL}", output)
                pages.assert_called_once_with("/repos/manaflow-ai/cmux/actions/runners")


class Workflow(unittest.TestCase):
    def test_runs_on_never_reads_the_variable_directly(self) -> None:
        jobs = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]
        archive = jobs["archive"]
        self.assertNotIn("CI_IOS_INTERNAL_RUNNER", archive["runs-on"])
        self.assertIn("needs.pick-archive-runner.outputs.attempt == format('{0}', github.run_attempt) && "
                      "needs.pick-archive-runner.outputs.dedicated != '' && "
                      "needs.pick-archive-runner.outputs.dedicated || ", archive["runs-on"])
        self.assertTrue(archive["runs-on"].rstrip("} ").endswith("|| fromJSON(vars.RUNNER_POOLS).macos_26"))
        self.assertEqual(archive["needs"], "pick-archive-runner")
        self.assertIn("!cancelled()", archive["if"])
        self.assertIn("vars.CI_IOS_INTERNAL_RUNNER", jobs["pick-archive-runner"]["steps"][-1]["env"]["DEDICATED_LABEL"])


if __name__ == "__main__":
    unittest.main()
