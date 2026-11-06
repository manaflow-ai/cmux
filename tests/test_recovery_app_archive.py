#!/usr/bin/env python3
"""A recovery app archive made on a Mac extracts through the strict recovery resolver.

macOS bsdtar writes an AppleDouble member ("._<name>") next to every file or folder that has an
extended attribute, unless COPYFILE_DISABLE=1 is set. A recent macOS gives new files and folders
such attributes (com.apple.provenance), so `tar -czf ... "cmux NIGHTLY.app"` on a Mac produced
"._cmux NIGHTLY.app", and resolve-notarization-recovery.py --extract-app refused the archive
("unsafe recovery archive member"). Its guard stays strict: the archive must hold only the app.

The fixture app gets an extended attribute where the platform has one (`xattr` on macOS), so this
reproduces on any Mac; on Linux, GNU tar writes no AppleDouble member and the case passes either way.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
STAGE = ROOT / "scripts/ci/stage-outer-notarization-recovery.py"
RESOLVE = ROOT / "scripts/ci/resolve-notarization-recovery.py"
# nightly.yml's "Prepare pending notarization recovery artifact" and the outer stage both archive through it.
ARCHIVE = ROOT / "scripts/ci/archive-recovery-app.sh"
HEAD_SHA = "0123456789abcdef0123456789abcdef01234567"


def make_app(parent: Path) -> Path:
    app = parent / "cmux NIGHTLY.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    binary = app / "Contents/MacOS/cmux"
    binary.write_text("signed-app-fixture\n", encoding="utf-8")
    xattr = shutil.which("xattr")
    if xattr and sys.platform == "darwin":
        for path in (app, app / "Contents", binary):
            subprocess.run([xattr, "-w", "com.cmux.test", "1", str(path)], check=True)
    return app


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class RecoveryAppArchiveTests(unittest.TestCase):
    def test_nightly_archive_holds_only_the_app_and_extracts(self) -> None:
        spec = importlib.util.spec_from_file_location("resolve_recovery", RESOLVE)
        resolver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(resolver)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = make_app(root / "build/Build/Products/Release")
            archive = root / "cmux-nightly-notarization-recovery-app.tar.gz"
            archive.write_text("stale", encoding="utf-8")
            subprocess.run(["bash", str(ARCHIVE), str(app), str(archive)], check=True, capture_output=True, text=True)
            with tarfile.open(archive, "r:gz") as tar:
                names = sorted(tar.getnames())
            self.assertEqual(names, ["cmux NIGHTLY.app", "cmux NIGHTLY.app/Contents", "cmux NIGHTLY.app/Contents/MacOS",
                                     "cmux NIGHTLY.app/Contents/MacOS/cmux"])
            out = root / "out"
            resolver.extract_app_archive(out, archive, "cmux-nightly-notarization-recovery-app/cmux NIGHTLY.app")
            self.assertEqual((out / "cmux-nightly-notarization-recovery-app/cmux NIGHTLY.app/Contents/MacOS/cmux")
                             .read_text(encoding="utf-8"), "signed-app-fixture\n")
            not_app = root / "plain"
            not_app.mkdir()
            refused = subprocess.run(["bash", str(ARCHIVE), str(not_app), str(archive)], capture_output=True, text=True)
            self.assertNotEqual(refused.returncode, 0)

    def test_staged_outer_archive_extracts_strictly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            app = make_app(run / "cmux-nightly-notarization-recovery-app")
            dmg = run / "cmux-nightly-macos-arm64.dmg"
            dmg.write_text("outer\n", encoding="utf-8")
            state = run / "outer.state"
            state.write_text(
                "submission_id=fixture-poll-id\n"
                f"dmg_path={dmg}\n"
                f"dmg_sha256={sha256(dmg)}\n"
                "submit_exit=0\n"
                f"immutable_path={run / 'cmux-nightly-macos-arm64-4242.dmg'}\n"
                "channel=nightly\n", encoding="utf-8")
            (run / "outer.state.log").write_text("evidence\n", encoding="utf-8")
            source = root / "source.json"
            source.write_text(json.dumps({
                "build": "4242", "app_path": "cmux-nightly-notarization-recovery-app/cmux NIGHTLY.app",
                "app_archive_path": "cmux-nightly-notarization-recovery-app.tar.gz"}), encoding="utf-8")
            staged = root / "staged"
            subprocess.run(
                [sys.executable, str(STAGE), str(source), str(state), str(dmg), str(app), str(staged),
                 "--source-run-id", "123", "--head-sha", HEAD_SHA, "--run-attempt", "1", "--channel", "nightly",
                 "--variant", "arm64", "--release-tag", "nightly", "--dmg-prefix", "cmux-nightly-macos",
                 "--short-sha", HEAD_SHA[:7]],
                check=True, capture_output=True, text=True)
            archive = staged / "cmux-nightly-notarization-recovery-app.tar.gz"
            with tarfile.open(archive, "r:gz") as tar:
                names = tar.getnames()
            self.assertEqual({Path(name).parts[0] for name in names}, {"cmux NIGHTLY.app"}, names)
            self.assertFalse([name for name in names if Path(name).name.startswith("._")], names)
            resolved = subprocess.run(
                [sys.executable, str(RESOLVE), str(staged / "cmux-nightly-notarization-recovery.json"), "123",
                 HEAD_SHA, "nightly", "arm64", "--run-attempt", "1", "--strict", "--extract-app"],
                capture_output=True, text=True, env={**os.environ})
            self.assertEqual(resolved.returncode, 0, resolved.stderr)
            extracted = staged / "cmux-nightly-notarization-recovery-app/cmux NIGHTLY.app/Contents/MacOS/cmux"
            self.assertEqual(extracted.read_text(encoding="utf-8"), "signed-app-fixture\n")


if __name__ == "__main__":
    unittest.main()
