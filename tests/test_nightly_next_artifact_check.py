#!/usr/bin/env python3
"""scripts/ci/nightly_next_artifact_check.py: a downloaded cmux NEXT DMG is checked against the
feed's sparkle:edSignature over its exact bytes, not only its byte length, and the canary checks
the app's CMUXCommit against the build's signed source record.

Run: python3 tests/test_nightly_next_artifact_check.py
"""
from __future__ import annotations

import base64
import contextlib
import importlib.util
import hashlib
import io
import json
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


# RFC 8032 Ed25519 signing, in Python, for signed release notes the tests make.
_ed = importlib.util.module_from_spec(importlib.util.spec_from_file_location(
    "verify_appcast_item", ROOT / "scripts" / "ci" / "release-signer" / "verify_appcast_item.py"))
_ed.__spec__.loader.exec_module(_ed)


def _encode(point) -> bytes:
    x, y, z, _ = point
    inverse = pow(z, _ed.P - 2, _ed.P)
    x, y = x * inverse % _ed.P, y * inverse % _ed.P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def ed25519_keypair(seed: bytes) -> tuple[int, bytes, bytes]:
    digest = hashlib.sha512(seed).digest()
    scalar = int.from_bytes(digest[:32], "little") & ((1 << 254) - 8) | (1 << 254)
    return scalar, digest[32:], _encode(_ed._mul(scalar, _ed.BASE))


def ed25519_sign(seed: bytes, message: bytes) -> bytes:
    scalar, prefix, public = ed25519_keypair(seed)
    r = int.from_bytes(hashlib.sha512(prefix + message).digest(), "little") % _ed.L
    big_r = _encode(_ed._mul(r, _ed.BASE))
    k = int.from_bytes(hashlib.sha512(big_r + public + message).digest(), "little") % _ed.L
    return big_r + ((r + k * scalar) % _ed.L).to_bytes(32, "little")


SEED = bytes(range(32))
CONTENT_KEY = base64.b64encode(ed25519_keypair(SEED)[2]).decode()
NOTES = "https://files-next.cmux.com/nightly-next/next/notes"
BUILD = "4097386595501"
RUN = f"repos/{REPO}/actions/runs/40973865955"


class ExpectedCommitTests(unittest.TestCase):
    """The commit a build was made from: its signed release notes' head (nightly.yml may build an
    earlier commit than its run's head); without those notes the source stays unknown."""

    def setUp(self) -> None:
        patcher = mock.patch.object(check, "CONTENT_PUBLIC_KEY", CONTENT_KEY)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.api_calls: list[str] = []

    def notes(self, head: str = OTHER, build: str = BUILD, seed: bytes = SEED) -> dict:
        body = json.dumps({"build": build, "head": head}).encode()
        return {f"{NOTES}/{BUILD}.json": body,
                f"{NOTES}/{BUILD}.json.sig": base64.b64encode(ed25519_sign(seed, body)) + b"\n"}

    def resolve(self, served: dict, run: dict | Exception | None = None):
        def fetch(url):
            return served.get(url.split("?", 1)[0])

        def api(path, *rest, **kwargs):
            self.api_calls.append(path)
            if isinstance(run, Exception):
                raise run
            return run

        return check.expected_commit(REPO, BUILD, NOTES, api, fetch)

    def test_the_signed_notes_head_wins_over_the_run_head(self) -> None:
        # The run's head is HEAD; the build was made from the earlier OTHER (resolve-newest-published).
        commit, source = self.resolve(self.notes(OTHER), run_record(status="completed"))
        self.assertEqual(commit, OTHER)
        self.assertIn("signed release notes", source)
        self.assertEqual(self.api_calls, [])

    def test_notes_signed_with_another_key_are_not_trusted(self) -> None:
        with self.assertRaisesRegex(check.Unknown, "does not verify"):
            self.resolve(self.notes(seed=bytes(32)), run_record(status="completed"))

    def test_notes_of_another_build_or_without_a_full_head_are_not_trusted(self) -> None:
        for served in (self.notes(build="1"), self.notes(head=OTHER[:7])):
            with self.assertRaises(check.Unknown):
                self.resolve(served, run_record(status="completed"))

    def test_signed_json_that_is_not_an_object_is_unknown(self) -> None:
        body = b"[]"
        served = {
            f"{NOTES}/{BUILD}.json": body,
            f"{NOTES}/{BUILD}.json.sig": base64.b64encode(ed25519_sign(SEED, body)) + b"\n",
        }
        with self.assertRaisesRegex(check.Unknown, "not a JSON object"):
            self.resolve(served, run_record(status="completed"))

    def test_unsigned_notes_are_not_trusted(self) -> None:
        served = self.notes()
        del served[f"{NOTES}/{BUILD}.json.sig"]
        with self.assertRaisesRegex(check.Unknown, "no signature"):
            self.resolve(served, run_record(status="completed"))

    def test_without_notes_a_completed_run_does_not_prove_the_artifact_source(self) -> None:
        # A recovered/resolver-behind build may stamp OTHER while the run reports HEAD.
        with self.assertRaisesRegex(check.Unknown, "source is not proven"):
            self.resolve({}, run_record(status="completed"))
        self.assertEqual(self.api_calls, [])

    def test_without_notes_a_run_still_going_is_unknown(self) -> None:
        with self.assertRaisesRegex(check.Unknown, "source is not proven"):
            self.resolve({}, run_record(status="in_progress"))

    def test_without_notes_a_run_that_is_not_a_nightly_next_publication_is_unknown(self) -> None:
        for run in (run_record(status="completed", head_branch="feat-cmux-next"),
                    run_record(status="completed", event="pull_request"),
                    run_record(status="completed", head_repository={"full_name": "someone/cmux"})):
            with self.assertRaisesRegex(check.Unknown, "source is not proven"):
                self.resolve({}, run)

    def test_read_errors_are_unknown(self) -> None:
        with self.assertRaisesRegex(check.Unknown, "source is not proven"):
            self.resolve({}, RuntimeError("HTTP 403"))

        def broken(url):
            raise OSError("connection reset")

        with self.assertRaisesRegex(check.Unknown, "connection reset"):
            check.expected_commit(REPO, BUILD, NOTES, lambda *a, **k: run_record(status="completed"), broken)

    def test_a_malformed_build_is_unknown(self) -> None:
        with self.assertRaises(check.Unknown):
            check.expected_commit(REPO, "7", NOTES, lambda *a, **k: run_record(), lambda url: None)

    def test_unknown_prints_an_empty_commit_and_exits_0(self) -> None:
        out = io.StringIO()
        with mock.patch.object(check, "expected_commit", side_effect=check.Unknown("run 1 is queued")), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = check.main(["expected-commit", "--repo", REPO, "--build", BUILD, "--notes-base", NOTES])
        self.assertEqual(code, 0)
        self.assertEqual(out.getvalue(), "commit=\ncommit_source=\n")

    def test_the_content_key_is_the_one_nightly_signs_notes_with(self) -> None:
        nightly = (ROOT / ".github" / "workflows" / "nightly.yml").read_text(encoding="utf-8")
        pinned = re.search(r"^\s+CONTENT_PUBLIC_KEY:\s*(\S+)\s*$", nightly, re.M)
        self.assertIsNotNone(pinned)
        source = (ROOT / "scripts" / "ci" / "nightly_next_artifact_check.py").read_text(encoding="utf-8")
        self.assertIn(f'CONTENT_PUBLIC_KEY = "{pinned.group(1)}"', source)


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
        self.assertIn("scripts/ci/release-signer/verify_appcast_item.py", sparse)
        self.assertIn("set -euo pipefail", source["run"])
        self.assertIn('--notes-base "${NIGHTLY_NEXT_FEED%/*}/notes"', source["run"])
        # No expected commit: no canary job, so no verdict and nothing cached.
        self.assertIn("needs.pick.outputs.source_commit != ''", self.jobs["canary"]["if"])
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
