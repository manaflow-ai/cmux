#!/usr/bin/env python3
"""scripts/ci/nightly_next_artifact_check.py: a downloaded cmux NEXT DMG is checked against the
feed's sparkle:edSignature over its exact bytes, not only its byte length, and the canary checks
the app's CMUXCommit against the head of the build's nightly-next run.

Run: python3 tests/test_nightly_next_artifact_check.py
"""
from __future__ import annotations

import base64
import contextlib
import importlib.util
import io
import os
import plistlib
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("nightly_next_artifact_check",
                                              ROOT / "scripts" / "ci" / "nightly_next_artifact_check.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

# RFC 8032 section 7.1, TEST 2: a one-byte message (0x72), its key and signature.
PUBLIC = base64.b64encode(bytes.fromhex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")).decode()
SIGNATURE = base64.b64encode(bytes.fromhex(
    "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
    "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")).decode()
SIGNED = bytes.fromhex("72")


class DmgTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.summary = Path(self.dir.name) / "summary.md"
        patcher = mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(self.summary)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_check(self, body: bytes, length: str = "1", signature: str = SIGNATURE, key: str = PUBLIC):
        dmg = Path(self.dir.name) / "cmux-nightly-next-macos-arm64-200.dmg"
        dmg.write_bytes(body)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = check.main(["dmg", "--dmg", str(dmg), "--length", length, "--ed-signature", signature,
                               "--public-key", key])
        return code, out.getvalue(), err.getvalue()

    def test_the_signed_bytes_pass_and_print_their_sha256(self) -> None:
        code, out, _ = self.run_check(SIGNED)
        self.assertEqual(code, 0)
        self.assertRegex(out, r"^sha256=[0-9a-f]{64}$")
        self.assertIn("edSignature verified", self.summary.read_text())

    def test_other_bytes_of_the_feed_length_fail(self) -> None:
        code, out, err = self.run_check(b"\x73")
        self.assertEqual(code, 1)
        self.assertEqual(out, "")
        self.assertIn("does not verify", err)
        self.assertIn("mismatch", self.summary.read_text())

    def test_another_length_fails(self) -> None:
        self.assertEqual(self.run_check(SIGNED, length="2")[0], 1)

    def test_a_missing_or_malformed_signature_fails(self) -> None:
        self.assertEqual(self.run_check(SIGNED, signature="")[0], 1)
        self.assertEqual(self.run_check(SIGNED, signature="not base64!")[0], 1)

    def test_another_key_fails(self) -> None:
        self.assertEqual(self.run_check(SIGNED, key=base64.b64encode(bytes(32)).decode())[0], 1)

    def test_the_default_key_is_the_one_nightly_pins(self) -> None:
        nightly = (ROOT / ".github" / "workflows" / "nightly.yml").read_text(encoding="utf-8")
        pinned = re.search(r"^\s+NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY:\s*(\S+)\s*$", nightly, re.M)
        self.assertIsNotNone(pinned)
        self.assertEqual(check.NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY, pinned.group(1))


HEAD = "eb8105b074755287155f4142e5586f128a0bc4be"
OTHER = "e398df3e7402e008dd089179dbcda32bf72fac46"
REPO = "manaflow-ai/cmux"


def run_record(**overrides) -> dict:
    run = {"head_branch": "nightly-next", "event": "push", "head_sha": HEAD,
           "head_repository": {"full_name": REPO}}
    run.update(overrides)
    return run


class CommitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.summary = Path(self.dir.name) / "summary.md"
        patcher = mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(self.summary)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_commit(self, info: dict, expected: str = HEAD):
        plist = Path(self.dir.name) / "Info.plist"
        plist.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = check.main(["commit", "--plist", str(plist), "--expected", expected])
        return code, out.getvalue(), err.getvalue()

    def test_the_short_commit_nightly_stamps_passes(self) -> None:
        code, out, _ = self.run_commit({"CMUXCommit": HEAD[:7]})
        self.assertEqual(code, 0)
        self.assertEqual(out, f"commit={HEAD[:7]}\n")
        self.assertIn(HEAD, self.summary.read_text())

    def test_the_full_commit_passes(self) -> None:
        self.assertEqual(self.run_commit({"CMUXCommit": HEAD})[0], 0)

    def test_another_commit_fails(self) -> None:
        code, _, err = self.run_commit({"CMUXCommit": OTHER[:7]})
        self.assertEqual(code, 1)
        self.assertIn(OTHER[:7], err)
        self.assertIn("mismatch", self.summary.read_text())

    def test_a_missing_or_malformed_commit_fails(self) -> None:
        for info in ({}, {"CMUXCommit": ""}, {"CMUXCommit": "unknown"}, {"CMUXCommit": "$(CMUX_COMMIT)"},
                     {"CMUXCommit": HEAD[:6]}, {"CMUXCommit": HEAD[:7].upper()}):
            self.assertEqual(self.run_commit(info)[0], 1, info)

    def test_no_expected_commit_fails(self) -> None:
        self.assertEqual(self.run_commit({"CMUXCommit": HEAD[:7]}, expected="")[0], 1)
        self.assertEqual(self.run_commit({"CMUXCommit": HEAD[:7]}, expected=HEAD[:7])[0], 1)


class ExpectedCommitTests(unittest.TestCase):
    def test_the_head_of_the_builds_nightly_next_run(self) -> None:
        seen = []

        def api(path, *rest, **kwargs):
            seen.append(path)
            return run_record()

        self.assertEqual(check.expected_commit(REPO, "4097386595501", api), HEAD)
        self.assertEqual(seen, [f"repos/{REPO}/actions/runs/40973865955"])

    def test_a_run_that_is_not_a_nightly_next_publication_has_none(self) -> None:
        for run in (run_record(head_branch="feat-cmux-next"), run_record(event="pull_request"),
                    run_record(head_repository={"full_name": "someone/cmux"}), run_record(head_sha="abc")):
            with self.assertRaisesRegex(check.Mismatch, "not a nightly-next publishing run"):
                check.expected_commit(REPO, "4097386595501", lambda path, *a, **k: run)

    def test_an_unreadable_run_names_the_error(self) -> None:
        def api(path, *rest, **kwargs):
            raise RuntimeError("HTTP 403")

        with self.assertRaisesRegex(check.Mismatch, "HTTP 403"):
            check.expected_commit(REPO, "4097386595501", api)

    def test_a_malformed_build_has_none(self) -> None:
        with self.assertRaises(check.Mismatch):
            check.expected_commit(REPO, "7", lambda path, *a, **k: run_record())


class CanaryWiringTests(unittest.TestCase):
    """nightly-next-canary.yml: the artifact step (id: app), whose failure is the fail verdict,
    checks the DMG's bytes and the app's commit."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.jobs = yaml.safe_load((ROOT / ".github" / "workflows" / "nightly-next-canary.yml").read_text())["jobs"]

    def test_the_pick_resolves_the_source_commit_and_the_signature(self) -> None:
        pick = self.jobs["pick"]
        self.assertEqual(pick["outputs"]["source_commit"], "${{ steps.source.outputs.commit }}")
        self.assertEqual(pick["outputs"]["ed_signature"], "${{ steps.feed.outputs.ed_signature }}")
        source = next(step for step in pick["steps"] if step.get("id") == "source")
        self.assertIn("nightly_next_artifact_check.py expected-commit", source["run"])
        self.assertNotIn("continue-on-error", source)
        sparse = pick["steps"][0]["with"]["sparse-checkout"].split()
        self.assertIn("scripts/ci/nightly_next_artifact_check.py", sparse)
        self.assertIn("scripts/ci/nightly_next_fix_forward.py", sparse)
        feed = next(step for step in pick["steps"] if step.get("id") == "feed")["run"]
        self.assertIn("ed_signature=", feed)

    def test_the_artifact_step_checks_the_bytes_and_the_commit(self) -> None:
        canary = self.jobs["canary"]
        self.assertEqual(canary["env"]["SOURCE_COMMIT"], "${{ needs.pick.outputs.source_commit }}")
        self.assertEqual(canary["env"]["DMG_ED_SIGNATURE"], "${{ needs.pick.outputs.ed_signature }}")
        app = next(step for step in canary["steps"] if step.get("id") == "app")
        self.assertNotIn("continue-on-error", app)
        self.assertIn("nightly_next_artifact_check.py dmg", app["run"])
        self.assertIn('--ed-signature "$DMG_ED_SIGNATURE"', app["run"])
        self.assertIn("nightly_next_artifact_check.py commit", app["run"])
        self.assertIn('--expected "$SOURCE_COMMIT"', app["run"])
        self.assertIn("set -euo pipefail", app["run"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
