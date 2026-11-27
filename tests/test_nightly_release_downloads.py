#!/usr/bin/env python3
"""The NIGHTLY Macs' github.com release downloads carry the job's token, through the API.

The NIGHTLY signing Macs get 403 from GitHub on anonymous requests. Release downloads from github.com went out
with no token: our Zig package mirror (https://github.com/manaflow-ai/ghostty-next/releases/download/
zig-packages/..., "Seeded 0 of 40 Zig package archives from the mirror", then the mirror-only zig fetch failed,
run 45776501690), ensure-gh.sh's pinned gh, and the bundle size budget's previous DMG. github.com's download path
does not read a token; the API's asset path does: scripts/ci/github-release-download.sh URL OUT resolves the
asset (scripts/ci/github_release_asset.py, one API read per release per job) and downloads it with
Accept: application/octet-stream and the token, which curl keeps off the redirect to the asset host.

A local server plays api.github.com (GITHUB_API_URL) and the asset host (a second host name, as the real
redirect goes elsewhere). Then the workflow: every step that runs one of these downloads passes the token.

Run: python3 tests/test_nightly_release_downloads.py (a few seconds, curl and a local HTTP server, no network).
"""
from __future__ import annotations

import http.server
import json
import os
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
DOWNLOAD = ROOT / "scripts/ci/github-release-download.sh"
RESOLVE = ROOT / "scripts/ci/github_release_asset.py"
SEED = ROOT / "scripts/ci/seed-zig-package-archives.sh"
TOKEN = "ghs_testtokenvalue0123456789"
URL = "https://github.com/o/r/releases/download/zig-packages/pkg.tar.gz"
BODY = b"the asset bytes"


class FakeGitHub(http.server.BaseHTTPRequestHandler):
    seen: list[tuple[str, str, str | None, str | None]] = []
    port = 0

    def do_GET(self) -> None:  # noqa: N802
        self.seen.append((self.headers.get("Host", "").split(":")[0], self.path,
                          self.headers.get("Authorization"), self.headers.get("Accept")))
        api = f"http://127.0.0.1:{self.port}"
        authorized = self.headers.get("Authorization") == f"Bearer {TOKEN}"
        if self.path.startswith("/repos/") and not authorized:
            return self.answer(403, b'{"message": "rate limited"}')
        if self.path == "/repos/o/r/releases/tags/zig-packages":
            return self.answer(200, json.dumps({"id": 9, "assets": [
                {"name": "pkg.tar.gz", "url": f"{api}/repos/o/r/releases/assets/7", "size": len(BODY)}]}).encode())
        if self.path.startswith("/repos/o/r/releases/9/assets?"):
            page = [{"name": "more.tar.gz", "url": f"{api}/repos/o/r/releases/assets/8", "size": 1}]
            return self.answer(200, json.dumps(page if "page=1" in self.path else []).encode())
        if self.path == "/repos/o/r/releases/assets/7":
            if self.headers.get("Accept") != "application/octet-stream":
                return self.answer(200, b'{"json": "metadata, not the bytes"}')
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{self.port}/signed/pkg.tar.gz")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        if self.path == "/signed/pkg.tar.gz":
            # The signed link: a token sent here would be one sent to a host that is not GitHub's API.
            if self.headers.get("Authorization"):
                return self.answer(400, b"two credentials")
            return self.answer(200, BODY)
        return self.answer(404, b"no")

    def answer(self, status: int, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:
        pass


class DownloadTest(unittest.TestCase):
    def setUp(self) -> None:
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
        FakeGitHub.port = self.server.server_address[1]
        FakeGitHub.seen = []
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.tmp), "GH_DOWNLOAD_TOKEN": TOKEN,
                    "GITHUB_API_URL": f"http://127.0.0.1:{FakeGitHub.port}", "RUNNER_TEMP": str(self.tmp)}

    def download(self, url: str = URL, **env: str) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", str(DOWNLOAD), url, str(self.tmp / "out"), "--max-time", "10"],
                              capture_output=True, text=True, env={**self.env, **env}, timeout=60)

    def test_the_download_goes_through_the_api_with_the_token(self) -> None:
        result = self.download()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.tmp / "out").read_bytes(), BODY)
        asset = [s for s in FakeGitHub.seen if s[1] == "/repos/o/r/releases/assets/7"]
        self.assertEqual(asset, [("127.0.0.1", "/repos/o/r/releases/assets/7", f"Bearer {TOKEN}", "application/octet-stream")])
        signed = [s for s in FakeGitHub.seen if s[1].startswith("/signed/")]
        self.assertEqual([(host, auth) for host, _, auth, _ in signed], [("localhost", None)])

    def test_the_release_is_read_once_per_job(self) -> None:
        for _ in range(3):
            self.assertEqual(self.download().returncode, 0)
        reads = [s[1] for s in FakeGitHub.seen if "/assets/" not in s[1] and not s[1].startswith("/signed/")]
        self.assertEqual(reads.count("/repos/o/r/releases/tags/zig-packages"), 1, reads)

    def test_the_size_comes_from_the_api(self) -> None:
        result = subprocess.run(["python3", str(RESOLVE), "--size", URL], capture_output=True, text=True, env=self.env)
        self.assertEqual((result.returncode, result.stdout), (0, f"{len(BODY)}\n"), result.stderr)

    def test_no_api_route_without_a_token_or_for_another_url(self) -> None:
        for url, env in ((URL, {"GH_DOWNLOAD_TOKEN": ""}),
                         ("https://example.com/o/r/releases/download/zig-packages/pkg.tar.gz", {}),
                         ("https://github.com/o/r/archive/main.tar.gz", {})):
            result = subprocess.run(["python3", str(RESOLVE), url], capture_output=True, text=True,
                                    env={**self.env, **env})
            self.assertEqual((result.returncode, result.stdout), (1, ""), url)
        self.assertEqual(FakeGitHub.seen, [])


class WiringTest(unittest.TestCase):
    def test_the_seed_downloads_through_it(self) -> None:
        text = SEED.read_text()
        one = text[text.index('if [[ "${1:-}" == --one ]]'):text.index("\nfi\n", text.index('if [[ "${1:-}" == --one ]]'))]
        self.assertIn("github-release-download.sh", one)
        self.assertNotIn("\n    curl ", one)

    def test_the_other_downloads_go_through_it(self) -> None:
        for script in ("scripts/ci/nightly-steps/ensure-gh.sh",
                       "scripts/ci/nightly-steps/verify-final-dmg-bundle-size-budget.sh"):
            self.assertIn("github-release-download.sh", (ROOT / script).read_text(), script)

    def test_every_step_that_downloads_passes_the_token(self) -> None:
        wanted = {"helper-build.sh": "GH_DOWNLOAD_TOKEN", "helper-source-archive.sh": "GH_DOWNLOAD_TOKEN",
                  "ensure-gh.sh": "GH_PIN_TOKEN", "verify-final-dmg-bundle-size-budget.sh": "GH_DOWNLOAD_TOKEN"}
        seen = {name: 0 for name in wanted}
        for job in yaml.safe_load(WORKFLOW.read_text())["jobs"].values():
            for step in job.get("steps") or []:
                for name, env in wanted.items():
                    if f"nightly-steps/{name}" in str(step.get("run") or ""):
                        seen[name] += 1
                        self.assertEqual((step.get("env") or {}).get(env), "${{ github.token }}", step.get("name"))
        self.assertTrue(all(seen.values()), seen)


if __name__ == "__main__":
    unittest.main()
