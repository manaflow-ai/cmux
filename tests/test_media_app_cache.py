#!/usr/bin/env python3
"""The cmux-next media tour reuses a tagged app built for the same commit.

A tour builds the merge base's app (about 6 min) even when another tour on
another Mac built the same commit under the same tag minutes earlier.
scripts/ci/media_app_cache.py packs a built app into a run artifact and a later
tour fetches it instead of building. These tests drive pack and fetch through a
fake GitHub API: a hit lands a runnable bundle (symlinks intact) at the tag's
product path, and a miss, an expired artifact, an artifact packed for another
commit or tag, or a hostile archive path never yields an app.
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import media_app_cache  # noqa: E402

TAG = "ci-media-slot0-base"
SHA = "a" * 40
XCODE = "17F113"


def make_app(root: Path, tag: str = TAG) -> Path:
    app = root / f"cmux DEV {tag}.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "MacOS" / "cmux DEV").write_text("#!/bin/sh\necho hi\n")
    os.chmod(app / "Contents" / "MacOS" / "cmux DEV", 0o755)
    fw = app / "Contents" / "Frameworks" / "X.framework"
    (fw / "Versions" / "A").mkdir(parents=True)
    (fw / "Versions" / "A" / "X").write_text("lib")
    os.symlink("A", fw / "Versions" / "Current")
    os.symlink("Versions/Current/X", fw / "X")
    return app


class FakeGitHub:
    """Serves the artifact list and the zip download the way GitHub does."""

    def __init__(self) -> None:
        self.artifacts: list[dict] = []
        self.blobs: dict[str, bytes] = {}
        self.requests: list[str] = []

    def add(self, name: str, tar_path: Path, expired: bool = False, created: str = "2026-10-19T20:00:00Z") -> None:
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            zf.write(tar_path, tar_path.name)
        art_id = len(self.artifacts) + 1
        url = f"https://api.github.com/repos/o/r/actions/artifacts/{art_id}/zip"
        self.blobs[url] = buf.getvalue()
        self.artifacts.append(
            {"id": art_id, "name": name, "expired": expired, "created_at": created, "archive_download_url": url}
        )

    def list_artifacts(self, repo: str, name: str) -> list[dict]:
        self.requests.append(f"list {repo} {name}")
        return [a for a in self.artifacts if a["name"] == name]

    def download(self, url: str, dest: Path) -> None:
        self.requests.append(f"download {url}")
        dest.write_bytes(self.blobs[url])


class MediaAppCacheTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.gh = FakeGitHub()

    def pack(self, tag: str = TAG, sha: str = SHA, xcode: str = XCODE) -> Path:
        src = self.tmp / f"src-{tag}-{sha[:4]}"
        src.mkdir()
        app = make_app(src, tag)
        out = self.tmp / f"{tag}-{sha[:4]}-{xcode}.tar"
        media_app_cache.pack(app=app, tag=tag, sha=sha, xcode=xcode, out=out)
        return out

    def fetch(self, dest: Path, tag: str = TAG, sha: str = SHA, xcode: str = XCODE):
        return media_app_cache.fetch(
            repo="o/r", tag=tag, sha=sha, xcode=xcode, dest=dest, api=self.gh, verify=False
        )

    def test_hit_lands_the_bundle_at_the_tag_product_path(self) -> None:
        self.gh.add(media_app_cache.artifact_name(TAG, SHA, XCODE), self.pack())
        dest = self.tmp / "DerivedData" / f"cmux-{TAG}" / "Build" / "Products" / "Debug"
        dest.mkdir(parents=True)
        stale = make_app(dest)  # an older build of the tag sits there
        (stale / "Contents" / "stale").write_text("old")
        app = self.fetch(dest)
        self.assertEqual(app, dest / f"cmux DEV {TAG}.app")
        self.assertFalse((app / "Contents" / "stale").exists(), "the old app was not replaced")
        fw = app / "Contents" / "Frameworks" / "X.framework"
        self.assertTrue((fw / "Versions" / "Current").is_symlink(), "framework symlinks were not kept")
        self.assertEqual((fw / "X").read_text(), "lib")
        self.assertTrue(os.access(app / "Contents" / "MacOS" / "cmux DEV", os.X_OK))
        self.assertEqual([p.name for p in dest.iterdir()], [app.name], "fetch left scratch files beside the app")

    def test_miss_and_expired_artifacts_yield_no_app(self) -> None:
        dest = self.tmp / "products"
        self.assertIsNone(self.fetch(dest))
        self.gh.add(media_app_cache.artifact_name(TAG, SHA, XCODE), self.pack(), expired=True)
        self.assertIsNone(self.fetch(dest))
        self.assertFalse(any(dest.glob("*.app")) if dest.exists() else False)

    def test_the_name_separates_tag_commit_and_xcode(self) -> None:
        names = {
            media_app_cache.artifact_name(TAG, SHA, XCODE),
            media_app_cache.artifact_name("ci-media-slot1-base", SHA, XCODE),
            media_app_cache.artifact_name(TAG, "b" * 40, XCODE),
            media_app_cache.artifact_name(TAG, SHA, "17F114"),
        }
        self.assertEqual(len(names), 4)
        for name in names:
            self.assertNotRegex(name, r'[":<>|*?\\/\r\n]')

    def test_an_archive_packed_for_another_commit_is_refused(self) -> None:
        # Uploaded under this commit's name, but the manifest inside says otherwise.
        self.gh.add(media_app_cache.artifact_name(TAG, SHA, XCODE), self.pack(sha="b" * 40))
        self.assertIsNone(self.fetch(self.tmp / "products"))

    def test_an_archive_with_a_path_outside_the_app_is_refused(self) -> None:
        evil_root = self.tmp / "evil"
        (evil_root / "payload").mkdir(parents=True)
        (evil_root / "payload" / "x").write_text("x")
        tar = self.tmp / "evil.tar"
        manifest = evil_root / media_app_cache.MANIFEST
        manifest.write_text(json.dumps({"tag": TAG, "sha": SHA, "xcode": XCODE, "app": f"cmux DEV {TAG}.app"}))
        subprocess.run(["tar", "-cf", str(tar), "-C", str(evil_root), media_app_cache.MANIFEST, "payload"], check=True)
        self.gh.add(media_app_cache.artifact_name(TAG, SHA, XCODE), tar)
        dest = self.tmp / "products"
        self.assertIsNone(self.fetch(dest))
        self.assertFalse((dest / "payload").exists())

    def test_the_newest_live_artifact_wins(self) -> None:
        name = media_app_cache.artifact_name(TAG, SHA, XCODE)
        self.gh.add(name, self.pack(sha="b" * 40), created="2026-10-19T19:00:00Z")  # bad, older
        self.gh.add(name, self.pack(), created="2026-10-19T21:00:00Z")
        self.assertIsNotNone(self.fetch(self.tmp / "products"))


class WorkflowWiringTest(unittest.TestCase):
    def setUp(self) -> None:
        import yaml

        workflow = yaml.safe_load((ROOT / ".github" / "workflows" / "cmux-next-media.yml").read_text())
        self.job = workflow["jobs"]["tour"]
        self.steps = {step.get("name"): step for step in self.job["steps"]}

    def test_a_fetched_base_app_is_used_without_building(self) -> None:
        tmp = Path(tempfile.mkdtemp())
        out = tmp / "output"
        env = dict(os.environ, BASE_APP=str(tmp / "app"), GITHUB_OUTPUT=str(out), RUNNER_TEMP=str(tmp),
                   GITHUB_WORKSPACE=str(tmp / "no-checkout"), TOUR_TAG="ci-media-slot0", RUNNER_NAME="r")
        result = subprocess.run(["bash", "-c", self.steps["Build the base app"]["run"]], env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(out.read_text(), f"base_app={tmp / 'app'}\n")
        self.assertNotIn("artifact=", out.read_text(), "a reused app was packed again")

    def test_the_fetch_runs_before_the_base_worktree_and_build_and_can_read_artifacts(self) -> None:
        names = [step.get("name") for step in self.job["steps"]]
        fetch = names.index("Reuse the base app another tour built")
        self.assertLess(fetch, names.index("Download pre-built GhosttyKit.xcframework for both revisions"))
        self.assertLess(names.index("Build the base app"), names.index("Share the base app with later tours"))
        self.assertLess(names.index("Share the base app with later tours"), names.index("Build the head app"))
        self.assertTrue(self.steps["Reuse the base app another tour built"].get("continue-on-error"))
        self.assertEqual(self.job["permissions"].get("actions"), "read")


if __name__ == "__main__":
    unittest.main()
