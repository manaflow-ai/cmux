#!/usr/bin/env python3
"""A web ABI read that fails is an infra error, never "no ABI".

PR 57082 at 6c31c0584c7d had web ABI 9, as did its app. The fleet worker's blob-less clone could not fetch the
web-abi.json blob ("RPC failed; HTTP 503"), hot-apply's abi_at returned None as it does for a tree with no
web-abi.json, and hot-verify planned a build ("the change's web needs ABI None, the app has 9"): a 40-minute look
lost. abi_at now retries the read and then raises AbiReadError (a RuntimeError, so the look fails as an infra
failure); None stays for a tree that has no web-abi.json.

    python3 tests/test_hot_apply_abi_read_error.py
"""
from __future__ import annotations

import importlib.util
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts/cmux-next" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ha = load("hot_apply_abi_read_error", "hot-apply.py")
hv = load("hot_verify_abi_read_error", "hot-verify.py")


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


class AbiReadError(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.origin = self.tmp / "origin"
        self.origin.mkdir()
        git(self.origin, "init", "-q")
        git(self.origin, "config", "user.email", "t@example.com")
        git(self.origin, "config", "user.name", "t")
        git(self.origin, "config", "uploadpack.allowFilter", "true")
        (self.origin / "README").write_text("no abi yet\n")
        git(self.origin, "add", "-A")
        git(self.origin, "commit", "-qm", "no abi")
        self.no_abi = git(self.origin, "rev-parse", "HEAD")
        (self.origin / "webviews/src").mkdir(parents=True)
        (self.origin / ha.WEB_ABI_PATH).write_text('{"abi": 9}\n')
        git(self.origin, "add", "-A")
        git(self.origin, "commit", "-qm", "abi 9")
        self.with_abi = git(self.origin, "rev-parse", "HEAD")
        # A blob-less clone, as the fleet workers keep: trees here, blobs fetched from origin when read.
        self.clone = self.tmp / "clone"
        subprocess.run(["git", "clone", "-q", "--no-checkout", "--filter=blob:none", self.origin.as_uri(),
                        str(self.clone)], check=True, capture_output=True)
        self.away = self.tmp / "origin-away"

    def origin_down(self) -> None:
        self.origin.rename(self.away)

    def origin_up(self) -> None:
        self.away.rename(self.origin)

    def test_reads_the_abi_through_the_blob_fetch(self) -> None:
        self.assertEqual(ha.abi_at(self.clone, self.with_abi), 9)

    def test_a_tree_with_no_abi_file_is_none_even_with_origin_down(self) -> None:
        self.origin_down()
        with mock.patch.object(ha.time, "sleep"):
            self.assertIsNone(ha.abi_at(self.clone, self.no_abi))

    def test_a_failed_blob_fetch_raises_not_none(self) -> None:
        self.origin_down()
        with mock.patch.object(ha.time, "sleep") as slept, self.assertRaises(ha.AbiReadError) as caught:
            ha.abi_at(self.clone, self.with_abi)
        self.assertIsInstance(caught.exception, RuntimeError)
        self.assertIn("infra", str(caught.exception))
        self.assertEqual(slept.call_count, len(ha.ABI_READ_RETRY_SECONDS))

    def test_a_retry_reads_it_once_origin_answers(self) -> None:
        self.origin_down()
        with mock.patch.object(ha.time, "sleep", side_effect=lambda _s: self.origin_up()) as slept:
            self.assertEqual(ha.abi_at(self.clone, self.with_abi), 9)
        self.assertEqual(slept.call_count, 1)

    def test_abi_needed_raises_on_a_failed_read(self) -> None:
        self.origin_down()
        with mock.patch.object(ha.time, "sleep"), self.assertRaises(ha.AbiReadError):
            ha.abi_needed(self.clone, self.with_abi)

    def test_hot_verify_plan_fails_rather_than_plans_a_build(self) -> None:
        """hot-verify's plan with a web change: the read error comes up out of plan (the look fails as infra), and
        no plan with `needs_build` and "needs ABI None" is made."""
        repo = self.tmp / "plan"
        repo.mkdir()
        git(repo, "init", "-q")
        git(repo, "config", "user.email", "t@example.com")
        git(repo, "config", "user.name", "t")
        (repo / "README").write_text("base\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "base")
        base = git(repo, "rev-parse", "HEAD")
        git(repo, "update-ref", f"refs/remotes/origin/{hv.BASE_BRANCH}", base)
        (repo / "webviews/src").mkdir(parents=True)
        (repo / "webviews/src/app.tsx").write_text("changed\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "head")
        head = git(repo, "rev-parse", "HEAD")

        def unreadable(_repo, commit):
            raise ha.AbiReadError(f"infra: could not read {commit}:{ha.WEB_ABI_PATH}")

        h = SimpleNamespace(
            _plan=lambda *a, **k: {"parts": [], "left": {hv.LEFT_WEB: ["webviews/src/app.tsx"]}, "notes": []},
            abi_at=unreadable, tree_key=lambda rules, commit: "k", published=lambda key: True)
        with mock.patch.object(hv, "hot", return_value=h), \
                mock.patch.object(hv, "rules_for", return_value=ROOT), \
                mock.patch.object(hv, "pins_differ", return_value=False), \
                self.assertRaises(RuntimeError) as caught:
            hv.plan(repo, f"sha:{head}", base=base)
        self.assertIn("infra", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
