#!/usr/bin/env python3
"""scripts/ci/nightly_ghostty_helper_reuse.py's token chain: its own goblin token, then github.token."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest
import urllib.error
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("helper_reuse_tokens", ROOT / "scripts/ci/nightly_ghostty_helper_reuse.py")
reuse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reuse)


class LookupTokensTest(unittest.TestCase):
    def test_the_own_token_comes_first_then_the_spares_each_once(self):
        self.assertEqual(reuse.lookup_tokens({"GH_TOKEN": "goblin", "GH_TOKEN_SPARES": " job  goblin "}), ["goblin", "job"])

    def test_no_secret_falls_back_to_the_job_token(self):
        self.assertEqual(reuse.lookup_tokens({"GH_TOKEN": "job", "GH_TOKEN_SPARES": "job"}), ["job"])

    def test_no_token_at_all_is_an_error(self):
        with self.assertRaises(SystemExit):
            reuse.lookup_tokens({"GH_TOKEN": "", "GH_TOKEN_SPARES": ""})

    def test_a_refusal_waits_until_the_reset(self):
        error = urllib.error.HTTPError("u", 403, "rate limited",
                                       {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1100"}, None)
        self.assertEqual(reuse.download.retry_wait(error, 1, now=1000.0), 101.0)


class MainTest(unittest.TestCase):
    def run_main(self, tmp: Path, find):
        out = tmp / "out.txt"
        env = {"GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "goblin", "GH_TOKEN_SPARES": "job", "GITHUB_OUTPUT": str(out)}
        argv = ["x", "--build-sha", "a" * 40, "--archs", "arm64", "--out", str(tmp / "h")]
        with mock.patch.dict(reuse.os.environ, env, clear=False), mock.patch.object(reuse.sys, "argv", argv), \
                mock.patch.object(reuse, "find", side_effect=find):
            reuse.main()
        return dict(line.split("=", 1) for line in out.read_text().splitlines())

    def test_a_403_on_the_goblin_token_moves_to_the_job_token(self):
        import tempfile
        seen = []

        def find(repo, sha, token, accept):
            seen.append(token)
            if token == "goblin":
                raise urllib.error.HTTPError("u", 403, "forbidden", {}, None)
            return "k", None, ""

        with tempfile.TemporaryDirectory() as tmp:
            outputs = self.run_main(Path(tmp), find)
        self.assertEqual(seen, ["goblin", "job"])
        self.assertEqual(outputs["key"], "k")

    def test_another_failure_is_a_miss_with_no_second_token(self):
        import tempfile
        seen = []

        def find(repo, sha, token, accept):
            seen.append(token)
            raise ValueError("unexpected answer")

        with tempfile.TemporaryDirectory() as tmp:
            outputs = self.run_main(Path(tmp), find)
        self.assertEqual(seen, ["goblin"])
        self.assertEqual(outputs["hit"], "false")


if __name__ == "__main__":
    unittest.main()
