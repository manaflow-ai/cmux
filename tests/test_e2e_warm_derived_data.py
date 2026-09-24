#!/usr/bin/env python3
"""Adopting main's DerivedData must rebuild exactly the inputs that changed."""
import io
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
import e2e_warm_derived_data as warm

BUILD_TIME_NS = 1_700_000_000_000_000_000
PRODUCER = "a" * 40
TESTED = "b" * 40


class ReplayTimes(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.producer = self.root / "producer"
        self.consumer = self.root / "consumer"
        for workspace in (self.producer, self.consumer):
            (workspace / "Sources").mkdir(parents=True)
            (workspace / "cmuxTests").mkdir()
            (workspace / "Sources/App.swift").write_text("let app = 1\n")
            (workspace / "cmuxTests/AppTests.swift").write_text("let test = 1\n")
        for path in self.producer.rglob("*.swift"):
            os.utime(path, ns=(BUILD_TIME_NS, BUILD_TIME_NS))
        (self.producer / "DerivedData").mkdir()
        (self.producer / "DerivedData/output.o").write_text("object")
        (self.producer / ".git").mkdir()
        (self.producer / ".git/index").write_text("git")

    def mtime(self, relative):
        return (self.consumer / relative).stat().st_mtime_ns

    def test_unchanged_inputs_take_the_producer_time_and_changed_inputs_do_not(self):
        recorded = warm.record(self.producer)
        (self.consumer / "cmuxTests/AppTests.swift").write_text("let test = 2\n")
        (self.consumer / "cmuxTests/NewTests.swift").write_text("let added = 1\n")

        restored, changed = warm.replay(self.consumer, recorded)

        self.assertEqual((restored, changed), (1, 2))
        self.assertEqual(self.mtime("Sources/App.swift"), BUILD_TIME_NS)
        self.assertGreater(self.mtime("cmuxTests/AppTests.swift"), BUILD_TIME_NS)
        self.assertGreater(self.mtime("cmuxTests/NewTests.swift"), BUILD_TIME_NS)

    def test_a_changed_input_unpacked_with_an_old_time_is_still_rebuilt(self):
        recorded = warm.record(self.producer)
        # An archive-extracted file (GhosttyKit, SwiftPM binaries) keeps the
        # archive's time, which can predate the producer's build.
        header = self.consumer / "Sources/App.swift"
        header.write_text("let app = 2\n")
        os.utime(header, ns=(BUILD_TIME_NS - 10**12, BUILD_TIME_NS - 10**12))

        warm.replay(self.consumer, recorded)

        self.assertGreater(self.mtime("Sources/App.swift"), BUILD_TIME_NS)

    def test_build_outputs_and_git_metadata_are_not_inputs(self):
        recorded = warm.record(self.producer)
        self.assertEqual(
            sorted(recorded),
            ["./", "Sources/", "Sources/App.swift", "cmuxTests/", "cmuxTests/AppTests.swift"],
        )

    def test_a_directory_takes_the_producer_time_only_while_its_entries_match(self):
        # Xcode signs a folder input (Assets.xcassets) by its directories'
        # times too, so a checkout-time directory reruns the asset catalog.
        for relative in ("Sources", "cmuxTests"):
            os.utime(self.producer / relative, ns=(BUILD_TIME_NS, BUILD_TIME_NS))
        recorded = warm.record(self.producer)
        (self.consumer / "cmuxTests/NewTests.swift").write_text("let added = 1\n")

        warm.replay(self.consumer, recorded)

        self.assertEqual(self.mtime("Sources"), BUILD_TIME_NS)
        self.assertGreater(self.mtime("cmuxTests"), BUILD_TIME_NS)

    def test_a_manifest_without_directories_leaves_them_at_checkout_time(self):
        os.utime(self.producer / "Sources", ns=(BUILD_TIME_NS, BUILD_TIME_NS))
        recorded = {key: entry for key, entry in warm.record(self.producer).items() if not key.endswith("/")}
        before = self.mtime("Sources")

        self.assertEqual(warm.replay(self.consumer, recorded), (2, 0))

        self.assertEqual(self.mtime("Sources"), before)

    def test_a_linked_directory_is_neither_recorded_nor_touched(self):
        outside = self.root / "outside"
        outside.mkdir()
        os.utime(outside, ns=(BUILD_TIME_NS, BUILD_TIME_NS))
        (self.consumer / "Linked").symlink_to(outside)
        (self.producer / "Linked").symlink_to(outside)
        recorded = warm.record(self.producer)
        recorded["Linked/"] = [warm.listing(outside), 1]

        warm.replay(self.consumer, recorded)

        self.assertNotIn("Linked/", warm.record(self.producer))
        self.assertEqual(outside.stat().st_mtime_ns, BUILD_TIME_NS)


class TrustedProducers(unittest.TestCase):
    def artifact(self, branch="main", expired=False):
        return {"expired": expired, "workflow_run": {"id": 7, "head_branch": branch, "repository_id": 1, "head_repository_id": 1}}

    def test_only_main_dispatches_of_this_workflow_are_adopted(self):
        run = {"path": warm.WORKFLOW_PATH, "event": "workflow_dispatch"}
        with mock.patch.object(warm, "api", return_value=run):
            self.assertTrue(warm.trusted(self.artifact(), "o/r"))
            self.assertFalse(warm.trusted(self.artifact(branch="feature"), "o/r"))
            self.assertFalse(warm.trusted(self.artifact(expired=True), "o/r"))
        with mock.patch.object(warm, "api", return_value={**run, "path": ".github/workflows/other.yml"}):
            self.assertFalse(warm.trusted(self.artifact(), "o/r"))


class ProviderDigest(unittest.TestCase):
    def test_an_archive_that_does_not_match_its_digest_is_never_unpacked(self):
        derived = Path(tempfile.mkdtemp())
        artifact = {"id": 3, "size_in_bytes": 4, "digest": "sha256:" + "0" * 64, "workflow_run": {"id": 7}}

        def download(repository, artifact_id, target, size):
            Path(target).write_bytes(b"zip!")

        with mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "o/r"}), \
                mock.patch.object(warm, "candidates", return_value=iter([artifact])), \
                mock.patch.object(warm, "api", return_value={"display_title": "t on r @ " + PRODUCER}), \
                mock.patch.object(warm, "tested_revision", return_value=PRODUCER), \
                mock.patch.object(warm.transport, "download_zip", side_effect=download), \
                mock.patch.object(warm, "extract") as extract:
            with self.assertRaises(ValueError):
                warm.restore(derived, derived, "key")
        extract.assert_not_called()


class ProducerDistance(unittest.TestCase):
    """A producer whose app sources differ recompiles the whole app anyway."""

    def restore_with(self, title, files, older=None):
        """`older` is (title, files) for a second, older candidate."""
        runs = {7: (title, files)}
        artifacts = [{"id": 3, "size_in_bytes": 4, "digest": "sha256:" + "0" * 64, "workflow_run": {"id": 7}}]
        if older is not None:
            runs[8] = older
            artifacts.append({"id": 4, "size_in_bytes": 4, "digest": "sha256:" + "0" * 64, "workflow_run": {"id": 8}})
        producers = {7: PRODUCER, 8: "c" * 40}

        def api(path):
            if "/compare/" in path:
                run_id = next(r for r, sha in producers.items() if sha in path)
                return {"files": [{"filename": name} for name in runs[run_id][1]]}
            run_id = int(path.rsplit("/", 1)[1])
            return {"display_title": runs[run_id][0].replace("PRODUCER", producers[run_id]), "head_sha": producers[run_id]}

        derived = Path(tempfile.mkdtemp())
        with mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "o/r"}), \
                mock.patch.object(warm, "candidates", return_value=iter(artifacts)), \
                mock.patch.object(warm, "api", side_effect=api), \
                mock.patch.object(warm, "tested_revision", return_value=TESTED), \
                mock.patch.object(warm.transport, "download_zip") as download:
            try:
                result = warm.restore(derived, derived, "key")
            except Exception:  # the download mock leaves nothing to verify
                result = {"hit": "attempted"}
        self.downloaded_ids = [call.args[1] for call in download.call_args_list]
        return result, download.called

    def test_an_app_source_change_since_the_producer_skips_the_download(self):
        result, downloaded = self.restore_with(
            "t on r @ PRODUCER", ["cmuxTests/AppTests.swift", "Packages/macOS/CmuxFoundation/Sources/A.swift"],
        )
        self.assertFalse(downloaded)
        self.assertEqual(result["hit"], "false")
        self.assertIn("app-build-changed-since-producer", result["reason"])

    def test_a_test_only_difference_adopts(self):
        _, downloaded = self.restore_with("t on r @ PRODUCER", ["cmuxTests/AppTests.swift", "docs/x.md"])
        self.assertTrue(downloaded)

    def test_a_producer_built_from_main_uses_the_run_head(self):
        _, downloaded = self.restore_with("t on r @ main [seed]", ["cmuxTests/AppTests.swift"])
        self.assertTrue(downloaded)

    def test_an_older_matching_seed_is_adopted_past_a_newer_distant_one(self):
        _, downloaded = self.restore_with(
            "t on r @ PRODUCER", ["Sources/App.swift"], older=("t on r @ PRODUCER", ["cmuxTests/A.swift"]),
        )
        self.assertTrue(downloaded)
        self.assertEqual(self.downloaded_ids, [4])

    def test_a_truncated_title_starts_cold(self):
        result, downloaded = self.restore_with("t on r @ 8994e2989013a19c5bb1614ddcfc...", [])
        self.assertEqual((result["reason"], downloaded), ("producer-revision-unknown", False))

    def test_an_unknown_producer_revision_or_huge_diff_starts_cold(self):
        result, downloaded = self.restore_with("t on r @ some-branch", [])
        self.assertEqual((result["reason"], downloaded), ("producer-revision-unknown", False))
        result, downloaded = self.restore_with("t on r @ PRODUCER", [f"cmuxTests/T{i}.swift" for i in range(300)])
        self.assertEqual((result["reason"], downloaded), ("producer-too-far", False))


class ArchiveBounds(unittest.TestCase):
    def archive(self, name, link=None):
        path = Path(tempfile.mkdtemp(), "derived-data.tar.gz")
        with tarfile.open(path, "w:gz") as bundle:
            member = tarfile.TarInfo(name)
            if link is not None:
                member.type, member.linkname = tarfile.SYMTYPE, link
                bundle.addfile(member)
            else:
                member.size = 1
                bundle.addfile(member, io.BytesIO(b"x"))
        return path

    def test_members_outside_derived_data_are_rejected(self):
        destination = Path(tempfile.mkdtemp())
        for archive in (self.archive("../escape"), self.archive("link", link="/etc/passwd")):
            with self.assertRaises(ValueError):
                warm.extract(archive, destination)
        self.assertEqual(list(destination.iterdir()), [])

    def test_an_absolute_link_inside_derived_data_is_accepted(self):
        destination = Path(tempfile.mkdtemp())
        target = str(destination / "Build/Products/Debug/PackageFrameworks")
        warm.extract(self.archive("Build/Products/link", link=target), destination)
        self.assertTrue((destination / "Build/Products/link").is_symlink())

    def test_a_contained_archive_extracts(self):
        destination = Path(tempfile.mkdtemp())
        warm.extract(self.archive("Build/Intermediates.noindex/a.o"), destination)
        self.assertTrue((destination / "Build/Intermediates.noindex/a.o").is_file())


class InterruptedAdoption(unittest.TestCase):
    """A timed-out adoption must never reach the build.

    The script's own cleanup runs only when it raises. A step timeout kills
    it first, so the workflow has to discard what it left behind.
    """

    def test_an_unfinished_adoption_is_discarded_before_the_build(self):
        import yaml

        workflow = Path(__file__).resolve().parents[1] / ".github/workflows/test-e2e.yml"
        steps = yaml.safe_load(workflow.read_text())["jobs"]["build"]["steps"]
        names = [step.get("name") for step in steps]
        warm = names.index("Adopt main's DerivedData")
        build = names.index("Build the app-host and UI test product")
        discard = [
            index for index, step in enumerate(steps)
            if warm < index < build
            and "steps.warm.outcome != 'success'" in str(step.get("if", ""))
            and 'rm -rf -- "$CMUX_DERIVED_DATA_PATH"' in str(step.get("run", ""))
        ]
        self.assertEqual(len(discard), 1, "no step discards an adoption that did not finish")
        self.assertNotIn("continue-on-error", steps[discard[0]])


if __name__ == "__main__":
    unittest.main()
