#!/usr/bin/env python3
"""Adopting main's DerivedData must rebuild exactly the inputs that changed."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
import e2e_warm_derived_data as warm

BUILD_TIME_NS = 1_700_000_000_000_000_000


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

    def test_a_rename_that_keeps_the_entry_count_keeps_the_directory_new(self):
        os.utime(self.producer / "cmuxTests", ns=(BUILD_TIME_NS, BUILD_TIME_NS))
        recorded = warm.record(self.producer)
        (self.consumer / "cmuxTests/AppTests.swift").rename(self.consumer / "cmuxTests/RenamedTests.swift")

        warm.replay(self.consumer, recorded)

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


class TrackedWorkspace(unittest.TestCase):
    """In a git checkout only tracked files are inputs, and build trees are never walked."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.repo = self.root / "repo"
        (self.repo / "Sources").mkdir(parents=True)
        (self.repo / "Sources/App.swift").write_text("let app = 1\n")
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "add", "."], check=True)
        # A restored build tree: untracked, and large on a real runner.
        (self.repo / "Package/.build/debug").mkdir(parents=True)
        (self.repo / "Package/.build/debug/App.o").write_text("object")

    def test_untracked_build_trees_are_not_walked(self):
        visited = []
        real_walk = os.walk

        def walk(top, *args, **kwargs):
            for entry in real_walk(top, *args, **kwargs):
                visited.append(Path(entry[0]).relative_to(self.repo).as_posix())
                yield entry

        warm.os.walk = walk
        try:
            recorded = warm.record(self.repo)
            warm.replay(self.repo, recorded)
        finally:
            warm.os.walk = real_walk
        self.assertIn("Sources/App.swift", recorded)
        self.assertFalse([path for path in visited if path.startswith("Package")], visited)

    def test_replay_refuses_a_workspace_it_cannot_list(self):
        """Outside a git checkout every file would be an input, build products included:
        the command line refuses rather than stamping old times onto them."""
        plain = self.root / "plain"
        (plain / ".build").mkdir(parents=True)
        product = plain / ".build/App.o"
        product.write_text("object")
        os.utime(product, ns=(BUILD_TIME_NS, BUILD_TIME_NS))
        manifest = self.root / "manifest.json"
        manifest.write_text('{".build/App.o": ["%s", 1]}' % warm.digest(product))
        script = Path(__file__).resolve().parents[1] / "scripts/ci/e2e_warm_derived_data.py"
        result = subprocess.run([sys.executable, "-I", str(script), "replay", str(plain), str(manifest)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(product.stat().st_mtime_ns, BUILD_TIME_NS)


if __name__ == "__main__":
    unittest.main()
