#!/usr/bin/env python3
"""nightly.yml reuses the Ghostty CLI helper and keeps the helper's own cache.

A Linux job (resolve-nightly-ghostty-cli-helper) first looks for an earlier
nightly's helper built from the same inputs; on a hit the helper job runs on
Linux and never compiles. Only a miss builds on a Mac, and then:

scripts/build-ghostty-cli-helper.sh reuses a helper only when the manifest it
wrote equals the current build's inputs and the binary's sha256 equals the
manifest's. A Blacksmith runner starts with an empty cache directory, so
the job restores that directory with actions/cache. The cache key must name
every input the script's manifest names, so a key never hides a changed input,
and it must be exact (no restore-keys), so an entry for other inputs is never
restored and then rebuilt into the same key.
"""
from __future__ import annotations

import importlib.util
import re
import struct
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
SCRIPT = ROOT / "scripts" / "build-ghostty-cli-helper.sh"


def cache_key_failures() -> list[str]:
    failures: list[str] = []
    job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["build-nightly-ghostty-cli-helper"]
    steps = job["steps"]
    names = [step.get("name", "") for step in steps]
    try:
        key_at = names.index("Key the Ghostty CLI helper cache")
        cache_at = names.index("Cache the Ghostty CLI helper")
        build_at = names.index("Build Ghostty CLI helper")
    except ValueError as error:
        return [str(error)]
    if not key_at < cache_at < build_at:
        failures.append("the key, then the cache, must come before the helper build")
    script = SCRIPT.read_text(encoding="utf-8")
    default_root = re.search(r'CACHE_ROOT="\$HOME/([^"]+)"', script)
    cache = steps[cache_at]
    if not default_root or cache["with"]["path"] != "~/" + default_root.group(1):
        failures.append("the cache path must be the script's default CACHE_ROOT")
    if "restore-keys" in cache["with"]:
        failures.append("the helper cache must restore an exact key only")
    if cache["with"]["key"] != "${{ steps.helper-cache-key.outputs.key }}":
        failures.append("the helper cache must use the key step's key")
    key_run = steps[key_at]["run"]
    # Each manifest field of ghostty_cache_metadata, and what the key reads for it.
    for field, needle in (
        ("ghostty", "git -C ghostty rev-parse HEAD"),
        ("script", "scripts/build-ghostty-cli-helper.sh"),
        ("zig_version and zig_sha256", 'shasum -a 256 "$zig"'),
        ("the PATH Zig the script may pick", "command -v zig"),
        ("sdk", "xcrun --sdk macosx --show-sdk-version"),
        ("macos", "sw_vers -productVersion"),
        ("host_arch", "uname -m"),
        ("requested_target", "NIGHTLY_COMPILE_ARCHS"),
    ):
        if needle not in key_run:
            failures.append(f"the key does not read {field} ({needle})")
    for field in ("ghostty=", "script=", "zig_version=", "zig_sha256=", "sdk=", "macos=", "host_arch=", "requested_target="):
        if field not in script:
            failures.append(f"the script's manifest no longer names {field}; update this guard and the key")
    if 'echo "key=ghostty-cli-helper-v1-' not in key_run:
        failures.append("the key step must write a versioned key")
    return failures


spec = importlib.util.spec_from_file_location("helper_reuse", ROOT / "scripts/ci/nightly_ghostty_helper_reuse.py")
reuse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reuse)


class CacheKeyTests(unittest.TestCase):
    def test_the_miss_path_cache_is_keyed_on_every_manifest_input(self):
        self.assertEqual(cache_key_failures(), [])


REPO = "manaflow-ai/cmux"
A, B = "a" * 40, "b" * 40


def run(**overrides):
    base = {"path": ".github/workflows/nightly.yml", "event": "push", "head_branch": "nightly-next",
            "repository": {"full_name": REPO}, "head_repository": {"full_name": REPO}}
    return base | overrides


def job(name, started="2026-10-27T04:00:00Z", completed="2026-10-27T05:00:00Z", job_id=7, stripped=True):
    steps = [{"name": reuse.STRIP_STEP, "conclusion": "success" if stripped else "skipped"}]
    return {"name": name, "id": job_id, "started_at": started, "completed_at": completed, "steps": steps}


class MachOTests(unittest.TestCase):
    def archs(self, data):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ghostty"
            path.write_bytes(data)
            return reuse.macho_archs(path)

    def test_thin_and_fat(self):
        self.assertEqual(self.archs(b"\xcf\xfa\xed\xfe" + struct.pack("<I", 0x0100000C) + b"\0" * 32), {"arm64"})
        fat = b"\xca\xfe\xba\xbe" + struct.pack(">I", 2)
        fat += struct.pack(">IIIII", 0x01000007, 3, 0, 0, 0) + struct.pack(">IIIII", 0x0100000C, 0, 0, 0, 0)
        self.assertEqual(self.archs(fat), {"arm64", "x86_64"})

    def test_rejects_non_macho(self):
        self.assertEqual(self.archs(b"#!/bin/sh\necho hi\n"), set())


class ProvenanceTests(unittest.TestCase):
    def test_only_protected_nightly_runs(self):
        self.assertTrue(reuse.trusted_run(run(), REPO))
        self.assertTrue(reuse.trusted_run(run(event="workflow_dispatch", head_branch="main"), REPO))
        self.assertFalse(reuse.trusted_run(run(head_branch="lane/x"), REPO))
        self.assertFalse(reuse.trusted_run(run(event="pull_request"), REPO))
        self.assertFalse(reuse.trusted_run(run(path=".github/workflows/other.yml"), REPO))
        self.assertFalse(reuse.trusted_run(run(head_repository={"full_name": "fork/cmux"}), REPO))

    def test_only_a_stripped_helper_is_reused(self):
        artifact = {"created_at": "2026-10-27T04:30:00Z"}
        marker = lambda _: f"ghostty-cli-helper-build={A}\n"
        self.assertEqual(reuse.producer_build_sha(artifact, [job("build-nightly-ghostty-cli-helper")], marker), A)
        self.assertIsNone(reuse.producer_build_sha(
            artifact, [job("build-nightly-ghostty-cli-helper", stripped=False)], marker))
        # A resolver from before the strip moved (#25885) re-uploaded an unstripped helper.
        self.assertIsNone(reuse.producer_build_sha(artifact, [job("resolve-nightly-ghostty-cli-helper")], marker))
        self.assertEqual(reuse.producer_build_sha(
            artifact, [job("resolve-nightly-ghostty-cli-helper")],
            lambda _: f"ghostty-cli-helper-stripped-build={B}\n"), B)

    def test_marker_then_checkout_fallback(self):
        artifact = {"created_at": "2026-10-27T04:30:00Z"}
        self.assertEqual(reuse.producer_build_sha(
            artifact, [job("resolve-nightly-ghostty-cli-helper")], lambda _: f"ghostty-cli-helper-stripped-build={A}\n"), A)
        self.assertEqual(reuse.producer_build_sha(
            artifact, [job("build-nightly-ghostty-cli-helper")],
            lambda _: f"[command]/usr/bin/git checkout --progress --force {B}\n"), B)

    def test_refuses_ambiguous_or_outside_window(self):
        artifact = {"created_at": "2026-10-27T04:30:00Z"}
        both = f"ghostty-cli-helper-build={A}\nghostty-cli-helper-build={B}\n"
        self.assertIsNone(reuse.producer_build_sha(artifact, [job("build-nightly-ghostty-cli-helper")], lambda _: both))
        late = job("build-nightly-ghostty-cli-helper", started="2026-10-27T04:40:00Z")
        self.assertIsNone(reuse.producer_build_sha(artifact, [late], lambda _: f"ghostty-cli-helper-build={A}"))
        self.assertIsNone(reuse.producer_build_sha(artifact, [job("build-nightly-app")],
                                                   lambda _: f"ghostty-cli-helper-build={A}"))


class FindTests(unittest.TestCase):
    def test_hit_needs_equal_input_key(self):
        artifact = {"name": reuse.ARTIFACT, "expired": False, "digest": "sha256:" + "0" * 64,
                    "created_at": "2026-10-27T04:30:00Z", "workflow_run": {"id": 9}}
        responses = {
            f"/repos/{REPO}/actions/artifacts?name={reuse.ARTIFACT}&per_page=50": {"artifacts": [artifact]},
            f"/repos/{REPO}/actions/runs/9": run(),
            f"/repos/{REPO}/actions/runs/9/jobs?per_page=100&page=1": {
                "total_count": 1, "jobs": [job("build-nightly-ghostty-cli-helper")]},
        }
        for key_of_a in ("same", "other"):
            with self.subTest(key_of_a=key_of_a), \
                    mock.patch.object(reuse.download, "api_json", side_effect=lambda path, token: responses[path]), \
                    mock.patch.object(reuse, "job_log", return_value=f"ghostty-cli-helper-build={A}"), \
                    mock.patch.object(reuse, "input_key", side_effect=lambda repo, sha, token:
                                      "same" if sha == B else key_of_a):
                key, found, sha = reuse.find(REPO, B, "token", lambda artifact: True)
                self.assertEqual(key, "same")
                self.assertEqual(sha, A if key_of_a == "same" else "")
                self.assertEqual(found is not None, key_of_a == "same")


class WorkflowTests(unittest.TestCase):
    def test_helper_never_takes_a_hosted_mac_and_skips_compile_on_hit(self):
        jobs = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())["jobs"]
        helper = jobs["build-nightly-ghostty-cli-helper"]
        self.assertIn("resolve-nightly-ghostty-cli-helper", helper["needs"])
        runs_on = helper["runs-on"].split("!= 'manaflow-ai' && 'macos-26' ||", 1)[1]
        self.assertNotIn("macos-15", helper["runs-on"])
        self.assertNotIn("'macos-26'", runs_on)
        for name in ("Key the Ghostty CLI helper cache", "Cache the Ghostty CLI helper",
                     "Build Ghostty CLI helper", "Strip the Ghostty CLI helper", "Upload Ghostty CLI helper"):
            step = next(s for s in helper["steps"] if s.get("name") == name)
            self.assertIn("needs.resolve-nightly-ghostty-cli-helper.outputs.hit != 'true'", step["if"])
        lookup = jobs["resolve-nightly-ghostty-cli-helper"]
        self.assertEqual(lookup["if"], helper["if"])
        # Every step that can fail is a miss, and a hit needs this run's own artifact.
        for step in lookup["steps"]:
            if "Record" not in step["name"]:
                self.assertTrue(step.get("continue-on-error"), step["name"])
                self.assertIn("timeout-minutes", step, step["name"])
        self.assertEqual(lookup["outputs"]["hit"], "${{ steps.upload.outcome == 'success' && 'true' || 'false' }}")


if __name__ == "__main__":
    unittest.main()
