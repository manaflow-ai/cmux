#!/usr/bin/env python3
"""Tests for scripts/ci/owned_warm_state.py (no network: the client is a fake)."""

from __future__ import annotations

import datetime as dt
import importlib.util
import io
import json
import sys
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


state = load("owned_warm_state", ROOT / "scripts/ci/owned_warm_state.py")

NOW = dt.datetime(2026, 9, 25, 20, 0, tzinfo=dt.timezone.utc)
A, B, C = "aaaaaaaaaaaa", "bbbbbbbbbbbb", "cccccccccccc"
ADMISSION = "macos / macOS compile admission"


def artifact(artifact_id: int, run_id: int, *, created="2026-09-25T19:00:00Z", fork=False, expired=False,
             name="owned-warm-keys"):
    return {"id": artifact_id, "name": name, "expired": expired, "created_at": created,
            "archive_download_url": f"https://api.github.com/artifacts/{artifact_id}/zip",
            "workflow_run": {"id": run_id, "repository_id": 1, "head_repository_id": 2 if fork else 1,
                             "head_branch": "main"}}


def admission(runner: str, workflow="CI"):
    return [{"name": "changes", "runner_name": "blacksmith-1", "workflow_name": workflow},
            {"name": ADMISSION, "runner_name": runner, "workflow_name": workflow}]


def zipped(name: str, document) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(name, json.dumps(document))
    return buffer.getvalue()


class FakeClient:
    """pr_runner_pool.GitHub's get() and download(), from canned answers; counts requests."""

    def __init__(self, *, snapshots=(), artifacts=(), jobs=None, blobs=None):
        self.snapshots, self.artifacts = list(snapshots), list(artifacts)
        self.jobs, self.blobs, self.calls = jobs or {}, blobs or {}, []

    def get(self, path: str):
        self.calls.append(path)
        if path.startswith("/actions/artifacts?name=macos-pool-load"):
            return {"artifacts": self.snapshots}
        if path.startswith("/actions/artifacts?name=owned-warm-keys"):
            return {"artifacts": self.artifacts}
        run_id = int(path.split("/")[3])
        return {"jobs": self.jobs.get(run_id, [])}

    def download(self, item):
        self.calls.append(item["archive_download_url"])
        blob = self.blobs[item["id"]]
        if isinstance(blob, Exception):
            raise blob
        return blob


def snapshot_artifact(warm, artifact_id=500):
    item = artifact(artifact_id, 99, name="macos-pool-load")
    return item, zipped("macos-pool-load.json", {"pools": {}, "warm": warm})


class Pure(unittest.TestCase):
    def test_keys_are_twelve_hex_digits_deduplicated_and_capped(self):
        self.assertEqual(state.keys({"keys": [A.upper(), A, "nope", B + "ff", C, "dddddddddddd", "eeeeeeeeeeee"]}),
                         [A, B, C, "dddddddddddd"])
        self.assertEqual(state.keys({"keys": "aaaaaaaaaaaa"}), [])
        self.assertEqual(state.keys([A]), [])

    def test_the_runner_comes_from_the_jobs_api(self):
        self.assertEqual(state.record({"runner": "cmux7-glaeda", "keys": [A]}, admission("cmux7-glaeda")),
                         ("cmux7-glaeda", [A]))
        lie = state.record({"runner": "cmux9-glaeda", "keys": [A]}, admission("cmux7-glaeda"))
        self.assertIsInstance(lie, str)
        self.assertIn("cmux9-glaeda", lie)
        self.assertIsInstance(state.record({"runner": "x", "keys": [A]}, [{"name": "changes", "runner_name": "x"}]),
                              str)
        self.assertIsInstance(state.record([A], admission("x")), str)
        # Admission of another workflow proves nothing.
        self.assertIsInstance(state.record({"runner": "x", "keys": [A]}, admission("x", workflow="Other")), str)

    def test_new_artifacts_are_newer_same_repository_and_capped(self):
        listed = [artifact(9, 1), artifact(10, 2, fork=True), artifact(11, 3, expired=True), artifact(12, 4),
                  artifact(13, 5, name="other"), "junk"]
        self.assertEqual([item["id"] for item in state.new_artifacts({"through": 9}, listed)], [12])
        self.assertEqual([item["id"] for item in state.new_artifacts({}, listed)], [9, 12])
        many = [artifact(index, index) for index in range(1, 40)]
        picked = state.new_artifacts({}, many)
        # The oldest first, so a backlog drains over later sweeps.
        self.assertEqual([item["id"] for item in picked], list(range(1, 1 + state.MAX_NEW)))
        self.assertEqual(state.new_artifacts({"through": "junk"}, [artifact(3, 3)])[0]["id"], 3)

    def test_fold_keeps_each_runners_newest_admission_and_drops_old_entries(self):
        previous = {"through": 5, "runners": {"r1": {"keys": [A], "at": "2026-09-25T10:00:00Z"},
                                              "old": {"keys": [B], "at": "2026-09-24T10:00:00Z"},
                                              "bad": {"keys": ["../x"], "at": "2026-09-25T10:00:00Z"}}}
        folded = [(artifact(6, 1, created="2026-09-25T19:00:00Z"), ("r1", [C])),
                  (artifact(7, 2, created="2026-09-25T19:05:00Z"), ("r2", [A, B])),
                  (artifact(8, 3), "no compile admission job ran on a runner")]
        result = state.fold(previous, folded, NOW)
        self.assertEqual(result["through"], 8)
        self.assertEqual(result["runners"], {"r1": {"keys": [C], "at": "2026-09-25T19:00:00Z"},
                                             "r2": {"keys": [A, B], "at": "2026-09-25T19:05:00Z"}})
        self.assertEqual(state.fold({}, [], NOW), {"through": 0, "runners": {}})


class Sweep(unittest.TestCase):
    def test_folds_new_artifacts_onto_the_previous_snapshot(self):
        previous, blob = snapshot_artifact({"through": 20, "runners": {"cmux1-glaeda": {
            "keys": [A], "at": "2026-09-25T18:00:00Z"}}})
        new = artifact(21, 301, created="2026-09-25T19:30:00Z")
        lie = artifact(22, 302, created="2026-09-25T19:31:00Z")
        client = FakeClient(
            snapshots=[previous], artifacts=[artifact(20, 300), new, lie],
            jobs={301: admission("cmux1-glaeda"), 302: admission("cmux2-glaeda")},
            blobs={500: blob, 21: zipped("warm-keys.json", {"runner": "cmux1-glaeda", "keys": [B]}),
                   22: zipped("warm-keys.json", {"runner": "cmux3-glaeda", "keys": [C]})})
        logged = []
        result = state.sweep(client, {}, NOW, log=logged.append)
        self.assertEqual(result, {"through": 22, "runners": {"cmux1-glaeda": {
            "keys": [B], "at": "2026-09-25T19:30:00Z"}}})
        # Artifact 20 was folded already: only 21 and 22 cost requests.
        self.assertFalse(any("/runs/300/" in call for call in client.calls))
        self.assertEqual(len(logged), 2)

    def test_reuses_the_janitors_job_listings(self):
        client = FakeClient(artifacts=[artifact(1, 301)],
                            blobs={1: zipped("warm-keys.json", {"runner": "cmux1-glaeda", "keys": [A]})})
        result = state.sweep(client, {301: admission("cmux1-glaeda")}, NOW, log=lambda _: None)
        self.assertEqual(result["runners"]["cmux1-glaeda"]["keys"], [A])
        self.assertFalse(any("/jobs" in call for call in client.calls))

    def test_an_unreadable_artifact_is_skipped_not_fatal(self):
        client = FakeClient(artifacts=[artifact(1, 301)], jobs={301: admission("cmux1-glaeda")},
                            blobs={1: b"not a zip"})
        result = state.sweep(client, {}, NOW, log=lambda _: None)
        self.assertEqual(result, {"through": 1, "runners": {}})

    def test_a_failed_request_stops_the_fold_for_a_retry(self):
        client = FakeClient(artifacts=[artifact(1, 301), artifact(2, 302), artifact(3, 303)],
                            jobs={301: admission("r1"), 302: admission("r2"), 303: admission("r3")},
                            blobs={1: zipped("warm-keys.json", {"runner": "r1", "keys": [A]}),
                                   2: OSError("timed out"),
                                   3: zipped("warm-keys.json", {"runner": "r3", "keys": [C]})})
        result = state.sweep(client, {}, NOW, log=lambda _: None)
        self.assertEqual((result["through"], list(result["runners"])), (1, ["r1"]))

    def test_a_failed_listing_keeps_the_previous_state(self):
        previous, blob = snapshot_artifact({"through": 20, "runners": {"r1": {"keys": [A], "at": "2026-09-25T18:00:00Z"}}})

        class Failing(FakeClient):
            def get(self, path):
                if "owned-warm-keys" in path:
                    raise OSError("500")
                return super().get(path)
        result = state.sweep(Failing(snapshots=[previous], blobs={500: blob}), {}, NOW, log=lambda _: None)
        self.assertEqual(result, {"through": 20, "runners": {"r1": {"keys": [A], "at": "2026-09-25T18:00:00Z"}}})

    def test_a_snapshot_without_warm_falls_back_to_the_one_before(self):
        newer, newer_blob = snapshot_artifact({}, artifact_id=501)
        newer_blob = zipped("macos-pool-load.json", {"pools": {}})
        newer["created_at"] = "2026-09-25T19:50:00Z"
        older, older_blob = snapshot_artifact({"through": 7, "runners": {}}, artifact_id=500)
        client = FakeClient(snapshots=[older, newer], blobs={500: older_blob, 501: newer_blob})
        self.assertEqual(state.previous_warm(client), {"through": 7, "runners": {}})

    def test_an_untrusted_or_unreadable_previous_snapshot_starts_fresh(self):
        fork, _ = snapshot_artifact({"through": 50, "runners": {}})
        fork["workflow_run"]["head_repository_id"] = 2
        self.assertEqual(state.previous_warm(FakeClient(snapshots=[fork])), {})
        item, _ = snapshot_artifact({})
        self.assertEqual(state.previous_warm(FakeClient(snapshots=[item], blobs={500: b"junk"})), {})


class Janitor(unittest.TestCase):
    def test_the_janitor_adds_warm_only_when_switched_on(self):
        text = (ROOT / "scripts/ci/queue_janitor.py").read_text()
        self.assertIn('os.environ.get("OWNED_WARM", "").strip() == "1"', text)
        self.assertIn('snapshot["warm"] = owned_warm_state.sweep(', text)


if __name__ == "__main__":
    unittest.main()
