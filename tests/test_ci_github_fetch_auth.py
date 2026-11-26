#!/usr/bin/env python3
"""github_fetch_auth.py and the prefetch's authenticated release download (GitHub 403s anonymous fetches
from the office Macs' shared address, 11-26)."""

from __future__ import annotations

import base64
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


AUTH = load("github_fetch_auth", ROOT / "scripts/ci/github_fetch_auth.py")
PREFETCH = load("swiftpm_prefetch", ROOT / "scripts/ci/swiftpm_prefetch_binary_artifacts.py")

RESOLVED = {"pins": [
    {"location": "https://github.com/apple/swift-crypto.git", "state": {"revision": "a"}},
    {"location": "https://github.com/getsentry/sentry-cocoa", "state": {"revision": "b"}},
    {"location": "https://github.com/manaflow-ai/cmux.git", "state": {"revision": "c"}},
    {"location": "https://gitlab.com/other/thing.git", "state": {"revision": "d"}},
]}
LEGACY = {"object": {"pins": [{"repositoryURL": "https://github.com/Apple/Swift-Crypto", "state": {}}]}}


class FetchAuthTests(unittest.TestCase):
    def repo(self, scratch: Path) -> Path:
        subprocess.run(["git", "init", "-q", str(scratch)], check=True)
        (scratch / "A").mkdir()
        (scratch / "A/Package.resolved").write_text(json.dumps(RESOLVED))
        (scratch / "B").mkdir()
        (scratch / "B/Package.resolved").write_text(json.dumps(LEGACY))
        subprocess.run(["git", "-C", str(scratch), "add", "."], check=True)
        return scratch

    def test_one_header_per_pinned_github_repo_never_the_checkout_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            repos = AUTH.pinned_repos(AUTH.resolved_files(self.repo(Path(tmp))))
        self.assertEqual(repos, [("apple", "swift-crypto"), ("getsentry", "sentry-cocoa")])
        entries = AUTH.config_entries(repos, "tok")
        keys = [key for key, _ in entries]
        self.assertIn("http.https://github.com/apple/swift-crypto.git/.extraheader", keys)
        self.assertIn("http.https://github.com/apple/swift-crypto/.extraheader", keys)
        self.assertFalse(any("manaflow-ai/cmux" in key for key in keys))
        expected = "AUTHORIZATION: basic " + base64.b64encode(b"x-access-token:tok").decode()
        self.assertTrue(all(value == expected for _, value in entries))

    def test_appends_after_existing_git_config_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.repo(Path(tmp) / "r")
            env_file = Path(tmp) / "env"
            env = {"GH_TOKEN": "tok", "GITHUB_ENV": str(env_file), "GIT_CONFIG_COUNT": "2"}
            self.assertEqual(AUTH.main(["--root", str(root)], env), 0)
            lines = env_file.read_text().splitlines()
        self.assertTrue(lines[0].startswith("GIT_CONFIG_KEY_2="))
        self.assertIn("GIT_CONFIG_COUNT=6", lines)
        self.assertIn("CMUX_GITHUB_FETCH_AUTH=2", lines)

    def test_no_token_or_already_set_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.repo(Path(tmp) / "r")
            env_file = Path(tmp) / "env"
            AUTH.main(["--root", str(root)], {"GITHUB_ENV": str(env_file)})
            AUTH.main(["--root", str(root)], {"GITHUB_ENV": str(env_file), "GH_TOKEN": "t",
                                               "CMUX_GITHUB_FETCH_AUTH": "2"})
            self.assertFalse(env_file.exists())


class Recorder:
    def __init__(self, api_ok=True, asset_ok=True):
        self.calls, self.api_ok, self.asset_ok = [], api_ok, asset_ok

    def __call__(self, argv, **kwargs):
        self.calls.append((argv, kwargs.get("input")))
        url = argv[-1]
        if url.startswith("https://api.github.com/repos/") and "/releases/tags/" in url:
            body = json.dumps({"assets": [{"name": "W.xcframework.zip", "url": "https://api.github.com/a/1"}]})
            return subprocess.CompletedProcess(argv, 0 if self.api_ok else 22, body, "")
        if url == "https://api.github.com/a/1":
            return subprocess.CompletedProcess(argv, 0 if self.asset_ok else 22)
        return subprocess.CompletedProcess(argv, 0)


URL = "https://github.com/stasel/WebRTC/releases/download/154.0.0/W.xcframework.zip"


class AuthenticatedDownloadTests(unittest.TestCase):
    def test_release_asset_goes_through_the_api_with_the_token_on_stdin(self):
        run = Recorder()
        PREFETCH.curl_download(URL, Path("/tmp/x"), {"GH_TOKEN": "secret"}, run)
        self.assertEqual([argv[-1] for argv, _ in run.calls],
                         ["https://api.github.com/repos/stasel/WebRTC/releases/tags/154.0.0",
                          "https://api.github.com/a/1"])
        self.assertFalse(any("secret" in arg for argv, _ in run.calls for arg in argv))
        self.assertIn("application/octet-stream", run.calls[1][1])
        self.assertIn("secret", run.calls[1][1])

    def test_falls_back_to_the_anonymous_download(self):
        run = Recorder(asset_ok=False)
        PREFETCH.curl_download(URL, Path("/tmp/x"), {"GH_TOKEN": "secret"}, run)
        self.assertEqual(run.calls[-1][0][-1], URL)
        self.assertIsNone(run.calls[-1][1])

    def test_no_token_is_the_old_anonymous_download(self):
        run = Recorder()
        PREFETCH.curl_download(URL, Path("/tmp/x"), {}, run)
        self.assertEqual(len(run.calls), 1)
        self.assertEqual(run.calls[0][0][-1], URL)


if __name__ == "__main__":
    unittest.main()
