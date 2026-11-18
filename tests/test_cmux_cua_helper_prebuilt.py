#!/usr/bin/env python3
"""The prebuilt nightly Computer Use helper: its input key and the cmux-cua source bundle.

scripts/cmux-cua-helper-key.sh decides when the nightly may reuse a published unsigned helper
(scripts/ci/nightly-steps/app-assemble-computer-use-helper.sh), so every input that changes the
helper's bytes must change the key, and the recorded fields must hash to it (publish-cmux-cua-helper.sh
checks a run's key.txt that way). The source bundle publish-cmux-cua-helper.sh makes from a full
fetch must clone and check out the pinned commit, as build-cmux-cua.sh's CMUX_CUA_SOURCE_BUNDLE seed does.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KEY = ROOT / "scripts" / "cmux-cua-helper-key.sh"
STEP = ROOT / "scripts" / "ci" / "nightly-steps" / "app-assemble-computer-use-helper.sh"
BUILD = ROOT / "scripts" / "build-cmux-cua.sh"
PUBLISH = ROOT / "scripts" / "cmux-next" / "publish-cmux-cua-helper.sh"
FIXED = {"CMUX_CUA_KEY_XCODE": "Xcode 26.6 Build version 17Z1", "CMUX_CUA_KEY_SDK": "26.5 25F1"}


def copy_inputs(dest: Path) -> None:
    """The files the key script reads, in a scratch tree that a test may edit."""
    for rel in ("scripts/cmux-cua-helper-key.sh", "scripts/build-cmux-cua.sh", "scripts/apply-cmux-cua-patch.sh",
                "scripts/strip-cmux-cua-rpaths.sh", "cmux-tui/rust-toolchain.toml"):
        (dest / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, dest / rel)
    text = (ROOT / "scripts/build-cmux-cua.sh").read_text()
    block = text.split("CMUX_CUA_PATCH_RELATIVE_PATHS=(\n", 1)[1].split("\n)", 1)[0]
    for line in block.splitlines():
        line = line.strip()
        if line.startswith('"'):
            rel = line.strip('"')
            (dest / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, dest / rel)


def key(tree: Path, archs: str = "arm64", fields: bool = False, **env: str) -> str:
    args = [str(tree / "scripts/cmux-cua-helper-key.sh"), "--archs", archs] + (["--fields"] if fields else [])
    return subprocess.run(args, check=True, capture_output=True, text=True,
                          env={**os.environ, **FIXED, **env}).stdout


class KeyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        copy_inputs(self.tmp)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def test_fields_hash_to_the_key(self) -> None:
        out = key(self.tmp, fields=True).splitlines()
        body = "".join(line + "\n" for line in out[:-1])
        self.assertEqual(hashlib.sha256(body.encode()).hexdigest(), out[-1])
        self.assertIn("recipe=cmux-cua-helper-prebuilt-v1", out)

    def test_every_input_changes_the_key(self) -> None:
        base = key(self.tmp)
        self.assertEqual(base, key(self.tmp), "the key is stable")
        self.assertNotEqual(base, key(self.tmp, archs="arm64 x86_64"))
        self.assertNotEqual(base, key(self.tmp, CMUX_CUA_KEY_XCODE="Xcode 27.0 Build version 18A1"))
        self.assertNotEqual(base, key(self.tmp, CMUX_CUA_KEY_SDK="27.0 26A1"))
        self.assertNotEqual(base, key(self.tmp, CMUX_CUA_HELPER_DISPLAY_NAME="other"))
        toolchain = self.tmp / "cmux-tui/rust-toolchain.toml"
        toolchain.write_text(toolchain.read_text().replace('channel = "', 'channel = "9'))
        changed = key(self.tmp)
        self.assertNotEqual(base, changed)
        patch = next(p for p in (self.tmp / "scripts").glob("cmux-cua-*.patch"))
        patch.write_text(patch.read_text() + "\n")
        self.assertNotEqual(changed, key(self.tmp))

    def test_an_unknown_arch_is_refused(self) -> None:
        result = subprocess.run([str(KEY), "--archs", "riscv"], capture_output=True, text=True,
                                env={**os.environ, **FIXED})
        self.assertEqual(result.returncode, 2)


class SourceBundleTest(unittest.TestCase):
    def test_the_bundle_seeds_the_pinned_commit(self) -> None:
        tmp = Path(tempfile.mkdtemp())
        try:
            git = ["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "protocol.file.allow=always"]
            up = tmp / "up"
            subprocess.run(git + ["init", "-q", str(up)], check=True)
            for i in range(3):
                (up / "f").write_text(str(i))
                subprocess.run(git + ["-C", str(up), "add", "f"], check=True)
                subprocess.run(git + ["-C", str(up), "commit", "-qm", str(i)], check=True)
            sha = subprocess.run(["git", "-C", str(up), "rev-parse", "HEAD"], check=True,
                                 capture_output=True, text=True).stdout.strip()
            src = tmp / "src.git"
            # The same commands publish-cmux-cua-helper.sh runs.
            subprocess.run(git + ["init", "-q", "--bare", str(src)], check=True)
            subprocess.run(git + ["-C", str(src), "fetch", "-q", f"file://{up}", sha], check=True)
            subprocess.run(git + ["-C", str(src), "update-ref", "refs/heads/pinned", sha], check=True)
            subprocess.run(git + ["-C", str(src), "symbolic-ref", "HEAD", "refs/heads/pinned"], check=True)
            bundle = tmp / "b.bundle"
            subprocess.run(git + ["-C", str(src), "bundle", "create", "-q", str(bundle), "refs/heads/pinned", "HEAD"],
                           check=True)
            # The same commands build-cmux-cua.sh's seed runs, then its checkout.
            clone = tmp / "clone"
            clone.mkdir()
            subprocess.run(git + ["clone", "-q", "--no-checkout", str(bundle), str(clone)], check=True)
            subprocess.run(git + ["-C", str(clone), "cat-file", "-e", f"{sha}^{{commit}}"], check=True)
            subprocess.run(git + ["-C", str(clone), "remote", "set-url", "origin", "https://example.invalid/x.git"],
                           check=True)
            subprocess.run(git + ["-C", str(clone), "checkout", "-q", "--force", "--detach", sha], check=True)
            self.assertEqual((clone / "f").read_text(), "2")
        finally:
            shutil.rmtree(tmp)


class WiringTest(unittest.TestCase):
    def test_the_step_tries_the_pin_before_a_source_build(self) -> None:
        text = STEP.read_text()
        self.assertLess(text.index("ensure-cua-pinned-asset.sh \"$helper_pin\""), text.index("./scripts/build-cmux-cua.sh"))
        self.assertIn("CMUX_CUA_SOURCE_BUNDLE", text)
        self.assertIn("cmux-cua-helper-prebuilt", text)

    def test_the_build_seeds_from_the_bundle_before_cloning(self) -> None:
        text = BUILD.read_text()
        self.assertLess(text.index('git clone --quiet --no-checkout "$CMUX_CUA_SOURCE_BUNDLE"'),
                        text.index('fetch --quiet --depth 1 origin "$CMUX_CUA_PINNED_SHA"'))

    def test_the_publisher_refuses_a_signed_helper(self) -> None:
        self.assertIn("Signature=adhoc", PUBLISH.read_text())


if __name__ == "__main__":
    unittest.main()
