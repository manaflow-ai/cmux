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

import hashlib
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
RECIPE = "0123456789ab"


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
        self.runs: dict[int, dict] = {}
        self.requests: list[str] = []
        self.budgets: list[int] = []
        self.clock = 0.0
        self.download_takes = 0.0
        self.run_takes = 0.0

    def add(self, name: str, tar_path: Path, expired: bool = False, created: str = "2026-10-19T20:00:00Z",
            fork: bool = False, workflow: str = ".github/workflows/cmux-next-media.yml",
            digest: str | None = None) -> None:
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            zf.write(tar_path, tar_path.name)
        art_id = len(self.artifacts) + 1
        url = f"https://api.github.com/repos/o/r/actions/artifacts/{art_id}/zip"
        self.blobs[url] = buf.getvalue()
        run_id = 1000 + art_id
        self.runs[run_id] = {"id": run_id, "path": workflow, "event": "pull_request"}
        self.artifacts.append({
            "id": art_id, "name": name, "expired": expired, "created_at": created, "archive_download_url": url,
            "digest": digest or "sha256:" + hashlib.sha256(buf.getvalue()).hexdigest(),
            "workflow_run": {"id": run_id, "repository_id": 7, "head_repository_id": 8 if fork else 7},
        })

    def run(self, repo: str, run_id: int) -> dict:
        self.requests.append(f"run {repo} {run_id}")
        self.clock += self.run_takes
        return self.runs[run_id]

    def list_artifacts(self, repo: str, name: str) -> list[dict]:
        self.requests.append(f"list {repo} {name}")
        return [a for a in self.artifacts if a["name"] == name]

    def download(self, url: str, dest: Path, seconds: int) -> None:
        self.requests.append(f"download {url}")
        self.budgets.append(seconds)
        self.clock += self.download_takes
        dest.write_bytes(self.blobs[url])


class CacheCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.gh = FakeGitHub()

    def pack(self, tag: str = TAG, sha: str = SHA, xcode: str = XCODE, recipe: str = RECIPE) -> Path:
        src = self.tmp / f"src-{tag}-{sha[:4]}-{len(list(self.tmp.iterdir()))}"
        src.mkdir()
        app = make_app(src, tag)
        out = self.tmp / f"{src.name}.tar"
        media_app_cache.pack(app=app, tag=tag, sha=sha, xcode=xcode, recipe=recipe, out=out)
        return out

    def name(self) -> str:
        return media_app_cache.artifact_name(TAG, SHA, XCODE, RECIPE)

    def fetch(self, dest: Path, tag: str = TAG, sha: str = SHA, xcode: str = XCODE):
        return media_app_cache.fetch(
            repo="o/r", tag=tag, sha=sha, xcode=xcode, recipe=RECIPE, dest=dest, api=self.gh, verify=False,
            clock=lambda: self.gh.clock,
        )



class MediaAppCacheTest(CacheCase):
    def test_hit_lands_the_bundle_at_the_tag_product_path(self) -> None:
        self.gh.add(self.name(), self.pack())
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
        self.gh.add(self.name(), self.pack(), expired=True)
        self.assertIsNone(self.fetch(dest))
        self.assertFalse(any(dest.glob("*.app")) if dest.exists() else False)

    def test_the_name_separates_tag_commit_and_xcode(self) -> None:
        names = {
            self.name(),
            media_app_cache.artifact_name("ci-media-slot1-base", SHA, XCODE, RECIPE),
            media_app_cache.artifact_name(TAG, "b" * 40, XCODE, RECIPE),
            media_app_cache.artifact_name(TAG, SHA, "17F114", RECIPE),
            media_app_cache.artifact_name(TAG, SHA, XCODE, "ba9876543210"),
        }
        self.assertEqual(len(names), 5)
        for name in names:
            self.assertNotRegex(name, r'[":<>|*?\\/\r\n]')

    def test_an_archive_packed_for_another_commit_is_refused(self) -> None:
        # Uploaded under this commit's name, but the manifest inside says otherwise.
        self.gh.add(self.name(), self.pack(sha="b" * 40))
        self.assertIsNone(self.fetch(self.tmp / "products"))

    def test_an_archive_with_a_path_outside_the_app_is_refused(self) -> None:
        evil_root = self.tmp / "evil"
        (evil_root / "payload").mkdir(parents=True)
        (evil_root / "payload" / "x").write_text("x")
        tar = self.tmp / "evil.tar"
        manifest = evil_root / media_app_cache.MANIFEST
        manifest.write_text(json.dumps({"tag": TAG, "sha": SHA, "xcode": XCODE, "recipe": RECIPE,
                                        "app": f"cmux DEV {TAG}.app"}))
        subprocess.run(["tar", "-cf", str(tar), "-C", str(evil_root), media_app_cache.MANIFEST, "payload"], check=True)
        self.gh.add(self.name(), tar)
        dest = self.tmp / "products"
        self.assertIsNone(self.fetch(dest))
        self.assertFalse((dest / "payload").exists())

    def test_the_newest_live_artifact_wins(self) -> None:
        name = self.name()
        self.gh.add(name, self.pack(sha="b" * 40), created="2026-10-19T19:00:00Z")  # bad, older
        self.gh.add(name, self.pack(), created="2026-10-19T21:00:00Z")
        self.assertIsNotNone(self.fetch(self.tmp / "products"))


class ProvenanceTest(CacheCase):
    """Only an artifact the media tour itself uploaded from this repository counts."""

    def test_an_artifact_from_a_fork_run_is_refused(self) -> None:
        self.gh.add(self.name(), self.pack(), fork=True)
        self.assertIsNone(self.fetch(self.tmp / "products"))

    def test_an_artifact_from_another_workflow_is_refused(self) -> None:
        self.gh.add(self.name(), self.pack(), workflow=".github/workflows/ci-guards.yml")
        self.assertIsNone(self.fetch(self.tmp / "products"))

    def test_a_download_that_does_not_match_the_digest_is_refused(self) -> None:
        self.gh.add(self.name(), self.pack(), digest="sha256:" + "0" * 64)
        self.assertIsNone(self.fetch(self.tmp / "products"))


class DownloadBudgetTest(CacheCase):
    """Every download of one fetch shares one time budget, so a slow blob store
    costs at most DOWNLOAD_SECONDS in all, never tries x curl retries x the cap."""

    def test_a_slow_first_download_leaves_the_second_only_the_rest(self) -> None:
        name = self.name()
        self.gh.add(name, self.pack(), created="2026-10-19T19:00:00Z")
        self.gh.add(name, self.pack(), created="2026-10-19T21:00:00Z", digest="sha256:" + "0" * 64)
        self.gh.download_takes = 200
        self.assertIsNotNone(self.fetch(self.tmp / "products"))
        self.assertEqual(self.gh.budgets, [media_app_cache.DOWNLOAD_SECONDS, media_app_cache.DOWNLOAD_SECONDS - 200])

    def test_the_provenance_check_counts_against_the_budget(self) -> None:
        # The run lookup before a download can take up to its 30 s timeout;
        # curl gets only what is left after it.
        self.gh.add(self.name(), self.pack())
        self.gh.run_takes = 25
        self.assertIsNotNone(self.fetch(self.tmp / "products"))
        self.assertEqual(self.gh.budgets, [media_app_cache.DOWNLOAD_SECONDS - 25])

    def test_no_download_starts_once_the_budget_is_nearly_spent(self) -> None:
        name = self.name()
        self.gh.add(name, self.pack(), created="2026-10-19T19:00:00Z")
        self.gh.add(name, self.pack(), created="2026-10-19T21:00:00Z", digest="sha256:" + "0" * 64)
        self.gh.download_takes = media_app_cache.DOWNLOAD_SECONDS - 10
        self.assertIsNone(self.fetch(self.tmp / "products"))
        self.assertEqual(len(self.gh.budgets), 1, "a second download started with 10 s left")

    def test_curl_never_retries_and_stops_at_the_budget(self) -> None:
        seen: list[list[str]] = []
        real = media_app_cache.subprocess.run
        media_app_cache.subprocess.run = lambda argv, **kw: seen.append(argv)
        try:
            media_app_cache.GitHubApi("t").download("https://x/zip", self.tmp / "z", 37)
        finally:
            media_app_cache.subprocess.run = real
        argv = seen[0]
        self.assertEqual(argv[argv.index("--retry") + 1], "0")
        self.assertEqual(argv[argv.index("--max-time") + 1], "37")


class PackageFrameworksTest(CacheCase):
    """Debug Mach-Os search <DerivedData>/Build/Products/Debug/PackageFrameworks
    before the bundle's own Frameworks, so a reused app must not land beside
    package frameworks from another build, nor be packed from beside them."""

    def test_a_consumer_with_package_frameworks_builds_instead(self) -> None:
        self.gh.add(self.name(), self.pack())
        dest = self.tmp / "products"
        (dest / "PackageFrameworks" / "Pkg.framework").mkdir(parents=True)
        self.assertIsNone(self.fetch(dest))

    def test_an_app_beside_package_frameworks_is_not_packed(self) -> None:
        src = self.tmp / "producer"
        src.mkdir()
        app = make_app(src)
        (src / "PackageFrameworks" / "Pkg.framework").mkdir(parents=True)
        with self.assertRaises(ValueError):
            media_app_cache.pack(app=app, tag=TAG, sha=SHA, xcode=XCODE, recipe=RECIPE, out=self.tmp / "x.tar")

    def test_an_empty_package_frameworks_dir_is_fine(self) -> None:
        self.gh.add(self.name(), self.pack())
        dest = self.tmp / "products"
        (dest / "PackageFrameworks").mkdir(parents=True)
        self.assertIsNotNone(self.fetch(dest))


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
