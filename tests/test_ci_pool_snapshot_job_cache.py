#!/usr/bin/env python3
"""A job reads the janitor's pool snapshot from the API once, not once per placement step.

While the runner census (CI_RUNNER_STATE) is stale, GitHub.snapshot() lists the macos-pool-load artifacts and
downloads the newest: two calls from the job's GITHUB_TOKEN, the repository's REST hour every workflow shares
(the production promote gates 403'd on it; their failed read and these artifact reads had the same reset,
backend.yml run 44878749398). On 2026-11-21, four steps of one tree-preflight job each fetched the same snapshot,
spending eight calls per push.

snapshot() now keeps what it read in the job's RUNNER_TEMP (the runner empties it for each job), and a later
step of the same job reuses it while it is fresh enough to use (snapshot_problem); a stale or unreadable file is
read again from the API.
"""

from __future__ import annotations

import datetime as dt
import importlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import unittest.mock
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
pool = importlib.import_module("pr_runner_pool")

NOW = dt.datetime(2026, 11, 21, 7, 30, tzinfo=dt.timezone.utc)


def snapshot(generated: dt.datetime) -> dict:
    return {"generated_at": generated.isoformat().replace("+00:00", "Z"), "pools": {"glaeda-std-xcode-27.2": {"queued": 0}}}


class JobSnapshotCache(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="pool-snapshot-job-"))
        self.addCleanup(shutil.rmtree, self.temp, ignore_errors=True)
        self.calls: list[str] = []
        self.generated = NOW - dt.timedelta(minutes=3)

    def artifact(self) -> dict:
        return {"id": 9, "name": pool.ARTIFACT_NAME, "expired": False,
                "created_at": self.generated.isoformat().replace("+00:00", "Z"),
                "archive_download_url": "https://api.github.com/repos/manaflow-ai/cmux/actions/artifacts/9/zip",
                "workflow_run": {"id": 5, "head_branch": pool.SNAPSHOT_BRANCH, "repository_id": 1, "head_repository_id": 1}}

    def read(self, now: dt.datetime = NOW):
        """One placement step: a fresh process (a new GitHub client) reading the snapshot."""
        client = pool.GitHub("job-token", "manaflow-ai/cmux")

        def get(path):
            self.calls.append(path)
            return {"artifacts": [self.artifact()]}

        def download(artifact):
            self.calls.append("download")
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as archive:
                archive.writestr(pool.SNAPSHOT_FILE, json.dumps(snapshot(self.generated)))
            return buffer.getvalue()
        client.get = get
        client.download = download
        with unittest.mock.patch.dict(os.environ, {"CI_RUNNER_STATE": "", "RUNNER_TEMP": str(self.temp)}):
            return client.snapshot(now=now)

    def test_four_steps_of_one_job_read_the_api_once(self):
        results = [self.read() for _ in range(4)]
        self.assertEqual(len(self.calls), 2, self.calls)
        self.assertTrue(all(result == results[0] for result in results))
        self.assertEqual(results[0]["generated_at"], snapshot(self.generated)["generated_at"])

    def test_a_kept_snapshot_older_than_the_share_window_is_read_again(self):
        """A kept copy is reused only while the janitor (every few minutes) would not have a newer one: the
        artifact read takes the newest snapshot up to 45 minutes old, a shared copy at most 5."""
        self.read()
        later = NOW + dt.timedelta(minutes=pool.KEPT_SNAPSHOT_MAX_MINUTES)
        self.generated = later - dt.timedelta(minutes=1)
        self.read(now=later)
        self.assertEqual(len(self.calls), 4, self.calls)

    def test_another_job_of_the_run_reuses_the_shared_copy_and_marks_no_fetch(self):
        """actions/cache carries the kept directory to the run's (and the base branch's) next jobs: such a job
        reads no API and leaves no fetched marker, so it saves no new cache entry."""
        self.read()
        self.assertTrue((self.temp / pool.SNAPSHOT_FETCHED_MARKER).exists())
        shared = self.temp / pool.KEPT_SNAPSHOT_DIR
        other = Path(tempfile.mkdtemp(prefix="pool-snapshot-other-job-"))
        self.addCleanup(shutil.rmtree, other, ignore_errors=True)
        shutil.copytree(shared, other / pool.KEPT_SNAPSHOT_DIR)
        self.temp = other
        self.read(now=NOW + dt.timedelta(minutes=1))
        self.assertEqual(len(self.calls), 2, self.calls)
        self.assertFalse((other / pool.SNAPSHOT_FETCHED_MARKER).exists())

    def test_an_unreadable_kept_file_is_read_again(self):
        self.read()
        for path in (self.temp / pool.KEPT_SNAPSHOT_DIR).iterdir():
            path.write_text("{not json")
        self.read()
        self.assertEqual(len(self.calls), 4, self.calls)


if __name__ == "__main__":
    unittest.main()
