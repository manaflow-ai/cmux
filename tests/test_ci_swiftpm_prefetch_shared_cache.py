#!/usr/bin/env python3
"""Runner slots sharing one SwiftPM artifact cache never download one artifact at once.

A mini's glaeda runner slots run as one user, so every `swift build` there shares
~/Library/Caches/org.swift.swiftpm. Two that miss the same new binary artifact both download it, and the
second fails with "failed downloading '<url>' ... already exists in file system" (cmux#43892's daemon test,
2026-11-15). scripts/ci/swiftpm_prefetch_binary_artifacts.py seeds the cache first, under one host lock,
with atomic renames. This checks the seed (macOS cache path, one download for jobs seeding together, a good
cache entry left in place) and that every owned-Mac step that keeps SwiftPM builds also seeds.
"""
from __future__ import annotations

import hashlib
import importlib.util
import os
import re
import sys
import tempfile
import threading
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/swiftpm_prefetch_binary_artifacts.py"
SPEC = importlib.util.spec_from_file_location("swiftpm_prefetch", SCRIPT)
PREFETCH = importlib.util.module_from_spec(SPEC)
sys.modules["swiftpm_prefetch"] = PREFETCH
SPEC.loader.exec_module(PREFETCH)

URL = "https://github.com/getsentry/sentry-cocoa/releases/download/9.28.0/Sentry.xcframework.zip"
BODY = b"zip bytes" * 1000
CHECKSUM = hashlib.sha256(BODY).hexdigest()
# Workflows whose owned-Mac (glaeda) jobs build Swift packages with binary targets.
SEEDING_WORKFLOWS = (".github/workflows/cmux-next.yml", ".github/workflows/test-ios.yml")
KEEP_STEP = re.compile(r"owned_spm_scratch\.py (link|lease) ")


class SeedsTheSharedCache(unittest.TestCase):
    def test_macos_cache_is_the_accounts_library_caches(self) -> None:
        cache = PREFETCH.swiftpm_artifact_cache({"HOME": "/elsewhere"}, None, platform="darwin")
        self.assertEqual(cache.parts[-4:], ("Library", "Caches", "org.swift.swiftpm", "artifacts"))
        self.assertFalse(str(cache).startswith("/elsewhere"))
        self.assertEqual(PREFETCH.swiftpm_artifact_cache({"HOME": "/h"}, "/c", platform="darwin"),
                         Path("/c/artifacts"))
        self.assertEqual(PREFETCH.swiftpm_artifact_cache({"HOME": "/h"}, None, platform="linux"),
                         Path("/h/.cache/org.swift.swiftpm/artifacts"))

    def test_jobs_seeding_together_download_once(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store, cache, package = Path(tmp, "store"), Path(tmp, "cache"), Path(tmp, "pkg")
            package.mkdir()
            (package / "Package.swift").write_text("// swift-tools-version:5.9\n")
            downloads = []
            waiting = []
            both_waiting = threading.Event()
            real_say = PREFETCH.say

            def say(message: str) -> None:
                real_say(message)
                if message.startswith("waiting for another job's seed"):
                    waiting.append(message)
                    if len(waiting) == 2:
                        both_waiting.set()

            def download(url: str, destination: Path) -> None:
                downloads.append(url)
                # Held mid-download until the other two jobs wait on the seed lock.
                self.assertTrue(both_waiting.wait(30), "the other jobs never waited on the seed lock")
                destination.write_bytes(BODY)

            def collect(*_args, **_kwargs):
                return [(URL, CHECKSUM)]

            missed = []
            jobs = [threading.Thread(target=lambda: missed.append(
                PREFETCH.seed([package], store, cache, download=download, collect=collect))) for _ in range(3)]
            with mock.patch.object(PREFETCH, "say", side_effect=say):
                for job in jobs:
                    job.start()
                for job in jobs:
                    job.join()
            self.assertTrue(both_waiting.is_set(), "the other jobs never waited on the seed lock")
            self.assertEqual(missed, [0, 0, 0])
            self.assertEqual(downloads, [URL], "each artifact downloads once for jobs seeding together")
            entry = cache / PREFETCH.swiftpm_cache_key(URL)
            self.assertEqual(entry.read_bytes(), BODY)
            self.assertEqual([p.name for p in cache.iterdir()], [entry.name], "no temporary file left")

    def test_a_good_cache_entry_is_left_in_place(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store, cache = Path(tmp, "store"), Path(tmp, "cache")
            blob = store / "sha256" / f"{CHECKSUM}.zip"
            blob.parent.mkdir(parents=True)
            blob.write_bytes(BODY)
            cache.mkdir()
            entry = cache / PREFETCH.swiftpm_cache_key(URL)
            entry.write_bytes(BODY)  # SwiftPM's own download of it
            inode = entry.stat().st_ino
            PREFETCH.link_into_cache(blob, cache, URL)
            self.assertEqual(entry.stat().st_ino, inode, "a reader's file is never swapped")
            entry.write_bytes(b"x" * len(BODY))  # same size, wrong bytes: replaced
            PREFETCH.link_into_cache(blob, cache, URL)
            self.assertEqual(entry.read_bytes(), BODY)

    def test_a_held_lock_is_waited_for_then_passed(self) -> None:
        # The wait runs on a fake clock: each 1 s retry sleep moves it, so the test counts the retries the
        # 3 s wait allows instead of timing them on a busy runner.
        class FakeTime:
            def __init__(self) -> None:
                self.now, self.sleeps = 0.0, []

            def monotonic(self) -> float:
                return self.now

            def sleep(self, seconds: float) -> None:
                self.sleeps.append(seconds)
                self.now += seconds

        with tempfile.TemporaryDirectory() as tmp:
            store = Path(tmp)
            import fcntl
            fake = FakeTime()
            with open(store / PREFETCH.SEED_LOCK, "a") as held, mock.patch.object(PREFETCH, "time", fake):
                fcntl.flock(held, fcntl.LOCK_EX)
                with PREFETCH.seed_lock(store, wait=3.0):
                    passed_at = list(fake.sleeps)
            self.assertEqual(passed_at, [1, 1, 1], "it retried each second for the whole wait, then went on without")


class EveryOwnedMacKeepStepSeeds(unittest.TestCase):
    def test_keep_steps_seed_the_artifact_cache(self) -> None:
        found = 0
        for name in SEEDING_WORKFLOWS:
            lines = (ROOT / name).read_text().splitlines()
            for i, line in enumerate(lines):
                if not KEEP_STEP.search(line):
                    continue
                found += 1
                step = "\n".join(lines[i:i + 3])
                self.assertIn("swiftpm_prefetch_binary_artifacts.py", step,
                              f"{name}:{i + 1}: an owned-Mac step that keeps SwiftPM builds must seed the shared "
                              "artifact cache too (python3 scripts/ci/swiftpm_prefetch_binary_artifacts.py "
                              "--package-path Packages/macOS/CmuxNext), or two runner slots fail with "
                              "\"already exists in file system\"")
        self.assertGreaterEqual(found, 6)


class DownloadsThroughTheControllerWhileGitHubRefuses(unittest.TestCase):
    """GitHub answered every release download from the office Macs 403 (cmux23, 2026-11-26), so SwiftPM ended
    "binary target 'CCmuxAppFFI' could not be mapped"; the worker then names the controller's release proxy."""

    PROXY = {"CMUX_CI_GITHUB_RELEASE_PROXY": "http://ctl:18765/v1/github-release/"}

    def test_a_release_url_maps_onto_the_proxy(self) -> None:
        self.assertEqual(PREFETCH.release_proxy_url(URL, self.PROXY),
                         "http://ctl:18765/v1/github-release/getsentry/sentry-cocoa/9.28.0/Sentry.xcframework.zip")
        self.assertIsNone(PREFETCH.release_proxy_url(URL, {}))
        self.assertIsNone(PREFETCH.release_proxy_url("https://example.com/a.zip", self.PROXY))

    def test_the_proxy_goes_first_and_github_is_the_fallback(self) -> None:
        seen = []

        def fetch(url, destination, retries="4"):
            seen.append(url)
            if "ctl" in url:
                raise PREFETCH.subprocess.CalledProcessError(22, ["curl"])

        PREFETCH.curl_download(URL, Path("/nonexistent"), fetch=fetch, environ=self.PROXY)
        self.assertEqual(seen, [PREFETCH.release_proxy_url(URL, self.PROXY), URL])
        seen.clear()
        PREFETCH.curl_download(URL, Path("/nonexistent"), fetch=fetch, environ={})
        self.assertEqual(seen, [URL])


if __name__ == "__main__":
    unittest.main()
