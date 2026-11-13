#!/usr/bin/env python3
"""scripts/ci/download-run-artifact.py reads another run's artifacts, a glob of them, or one by id.

The signing Mac's download-artifact steps read one stream: 7m06s for the prepared app, 8m20s for
publish-nightly's variants (a pattern with merge-multiple) and 5m57s for the deltas job's DMG from the
run that published (run-id), while the job held the whole Mac (runs 43300596948, 43318988406). Those
steps can use the ranged download only if it takes the same run-id, pattern and artifact-ids inputs.
"""
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("artifact_download_modes", ROOT / "scripts/ci/download-run-artifact.py")
download = importlib.util.module_from_spec(spec)
spec.loader.exec_module(download)


def artifact(id_: int, name: str, created: str, *, run: int = 77, expired: bool = False) -> dict:
    return {"id": id_, "name": name, "created_at": created, "expired": expired, "size_in_bytes": 1,
            "archive_download_url": f"https://api.github.invalid/zip/{id_}", "workflow_run": {"id": run}}


class ModeTests(unittest.TestCase):
    def test_a_pattern_takes_the_newest_unexpired_artifact_of_each_matching_name(self) -> None:
        listed = [
            artifact(200, "cmux-nightly-variant-arm64", "2026-11-12T01:00:00Z"),
            artifact(201, "cmux-nightly-variant-arm64", "2026-11-12T02:00:00Z"),
            artifact(202, "cmux-nightly-variant-x86_64", "2026-11-12T03:00:00Z", expired=True),
            artifact(300, "cmux-nightly-variant-universal", "2026-11-12T01:00:00Z"),
            artifact(301, "cmux-nightly-tested-arm64", "2026-11-12T01:00:00Z"),
        ]
        paths = []

        def api_json(path: str, token: str) -> dict:
            paths.append(path)
            return {"total_count": len(listed), "artifacts": listed}

        with mock.patch.object(download, "api_json", api_json):
            found = download.find_artifacts("o/r", "77", "cmux-nightly-variant-*", "t")
        self.assertEqual([(a["name"], a["id"]) for a in found],
                         [("cmux-nightly-variant-arm64", 201), ("cmux-nightly-variant-universal", 300)])
        self.assertEqual(paths, ["/repos/o/r/actions/runs/77/artifacts?per_page=100"])

    def test_a_run_with_more_artifacts_than_one_listing_fails_so_download_artifact_takes_over(self) -> None:
        listed = [artifact(i, f"cmux-nightly-variant-{i}", "1") for i in range(100)]
        with mock.patch.object(download, "api_json", lambda path, token: {"total_count": 101, "artifacts": listed}):
            with self.assertRaisesRegex(SystemExit, "101 artifacts"):
                download.find_artifacts("o/r", "77", "cmux-nightly-variant-*", "t")

    def test_a_pattern_that_matches_nothing_fails_so_download_artifact_takes_over(self) -> None:
        with mock.patch.object(download, "api_json", lambda path, token: {"artifacts": []}):
            with self.assertRaises(SystemExit):
                download.find_artifacts("o/r", "77", "cmux-nightly-variant-*", "t")

    def test_an_artifact_id_must_belong_to_the_named_run(self) -> None:
        with mock.patch.object(download, "api_json", lambda path, token: artifact(5, "dsyms", "x", run=78)):
            with self.assertRaisesRegex(SystemExit, "belongs to run 78, not 77"):
                download.find_artifact_by_id("o/r", "77", "5", "t")
        with mock.patch.object(download, "api_json", lambda path, token: artifact(5, "dsyms", "x", run=77)):
            self.assertEqual(download.find_artifact_by_id("o/r", "77", "5", "t")["id"], 5)

    def test_run_id_reads_that_run_and_a_pattern_merges_every_match_into_one_out(self) -> None:
        listings, archives = [], {}
        for name, member in (("cmux-nightly-variant-arm64", "a.dmg"), ("cmux-nightly-variant-universal", "u.dmg")):
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as bundle:
                bundle.writestr(member, name)
            archives[name] = buffer.getvalue()

        def api_json(path: str, token: str) -> dict:
            listings.append(path)
            return {"artifacts": [artifact(1, "cmux-nightly-variant-arm64", "1"),
                                  artifact(2, "cmux-nightly-variant-universal", "1")]}

        def fake_download(found: dict, token: str, dest: str, connections: int) -> None:
            Path(dest).write_bytes(archives[found["name"]])

        with tempfile.TemporaryDirectory() as out, \
                mock.patch.dict(os.environ, {"GH_TOKEN": "t", "GITHUB_REPOSITORY": "o/r", "GITHUB_RUN_ID": "1"}), \
                mock.patch.object(download, "api_json", api_json), \
                mock.patch.object(download, "download", fake_download), \
                mock.patch.object(download, "verify", lambda path, found: None), \
                mock.patch.object(sys, "argv", ["x", "--pattern", "cmux-nightly-variant-*", "--out", out,
                                                "--run-id", "43300596948"]):
            download.main()
            self.assertEqual(sorted(p.name for p in Path(out).iterdir()), ["a.dmg", "u.dmg"])
        self.assertTrue(all("/runs/43300596948/" in path for path in listings), listings)

    def test_an_artifact_id_lands_in_a_folder_named_after_the_artifact_as_download_artifact_puts_it(self) -> None:
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as bundle:
            bundle.writestr("cmux.app.dSYM/Contents/Info.plist", "x")
        with tempfile.TemporaryDirectory() as out, \
                mock.patch.dict(os.environ, {"GH_TOKEN": "t", "GITHUB_REPOSITORY": "o/r", "GITHUB_RUN_ID": "1"}), \
                mock.patch.object(download, "api_json", lambda path, token: artifact(5, "nightly-next-dsyms-abc", "1")), \
                mock.patch.object(download, "download",
                                  lambda found, token, dest, connections: Path(dest).write_bytes(buffer.getvalue())), \
                mock.patch.object(download, "verify", lambda path, found: None), \
                mock.patch.object(sys, "argv", ["x", "--artifact-id", "5", "--run-id", "77", "--out", out]):
            download.main()
            self.assertTrue((Path(out) / "nightly-next-dsyms-abc/cmux.app.dSYM/Contents/Info.plist").is_file())

    def test_every_ranged_download_with_a_fallback_has_its_own_step_timeout(self) -> None:
        # A range that trickles under the stall bound could hold the step past the job's timeout; the job is then
        # cancelled and the download-artifact fallback (no always()) never runs (Codex review of #42332).
        import yaml
        jobs = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())["jobs"]
        unbounded = [f"{job}: {step.get('name')}" for job, spec in jobs.items() for step in spec.get("steps") or []
                     if str(step.get("name", "")).startswith("Download") and "(parallel" in str(step.get("name", ""))
                     and step.get("continue-on-error") and not step.get("timeout-minutes")]
        self.assertEqual(unbounded, [])


if __name__ == "__main__":
    unittest.main()
