#!/usr/bin/env python3
"""Exercise the recovery manifest across the artifact upload/download boundary."""

import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def manifest_program():
    workflow = (ROOT / ".github/workflows/nightly.yml").read_text()
    step = workflow.split("- name: Prepare pending notarization recovery artifact\n", 1)[1]
    step = step.split("\n      - name:", 1)[0]
    match = re.search(r"<<'PY'\n(.*?)^          PY$", step, re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError("recovery manifest generator is missing")
    return "\n".join(line.removeprefix("          ") for line in match.group(1).splitlines())


class RecoveryManifestTests(unittest.TestCase):
    def test_manifest_paths_survive_relocation(self):
        for absolute in (False, True):
            with self.subTest(absolute_source_paths=absolute), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / "source"
                source.mkdir()
                dmg = source / "cmux-nightly-macos-arm64.dmg"
                dmg.write_bytes(b"signed-dmg-fixture")
                digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
                state = source / (dmg.name + ".notarization.state")
                evidence = source / (dmg.name + ".notarization.log")
                evidence.write_text("submission is still processing\n")
                app = source / "build" / "cmux NIGHTLY.app"
                (app / "Contents").mkdir(parents=True)
                app_archive = source / "cmux-nightly-notarization-recovery-app.tar.gz"
                with tarfile.open(app_archive, "w:gz") as archive:
                    archive.add(app, arcname=app.name)
                state.write_text(
                    f"submission_id=fixture-id\n"
                    f"dmg_path={dmg}\n"
                    f"dmg_sha256={digest}\n"
                    "immutable_path=cmux-nightly-macos-arm64-123.dmg\n"
                    "release_tag=nightly\n"
                    "dmg_prefix=cmux-nightly-macos\n"
                    "variant=arm64\n"
                    "channel=nightly\n"
                )
                source_path = lambda path: str(path if absolute else path.relative_to(source))
                subprocess.run(
                    [sys.executable, "-c", manifest_program().replace(
                        "${{ needs.decide.outputs.should_publish == 'true' }}", "True"
                    ).replace(
                        "${{ github.run_attempt }}", "1"
                    ), source_path(state), digest,
                     source_path(dmg), source_path(app), "nightly", "arm64", "nightly", "123",
                     "a" * 40, "a" * 7],
                    cwd=source, check=True, capture_output=True, text=True,
                )
                manifest = json.loads((source / "cmux-nightly-notarization-recovery.json").read_text())
                downloaded = root / "downloaded"
                downloaded.mkdir()
                for path in (state, dmg, evidence):
                    shutil.copy2(path, downloaded / path.name)
                shutil.copy2(app_archive, downloaded / app_archive.name)
                shutil.copytree(app, downloaded / "cmux-nightly-notarization-recovery-app" / app.name)
                manifest["source_run_id"] = "123"
                manifest["source_run_attempt"] = "1"
                (downloaded / "cmux-nightly-notarization-recovery.json").write_text(
                    json.dumps(manifest), encoding="utf-8"
                )
                for key in ("state_path", "dmg_path", "app_path", "log_path", "app_archive_path"):
                    relative = Path(manifest[key])
                    self.assertFalse(relative.is_absolute(), key)
                    self.assertNotIn("..", relative.parts, key)
                    self.assertTrue((downloaded / relative).exists(), key)
                self.assertEqual(manifest["dmg_sha256"], digest)
                self.assertEqual(manifest["submission_id"], "fixture-id")
                resolver = ROOT / "scripts/ci/resolve-notarization-recovery.py"
                resolved = subprocess.run(
                    [sys.executable, str(resolver), str(downloaded / "cmux-nightly-notarization-recovery.json"),
                     "123", "a" * 40, "nightly", "arm64"],
                    check=True, capture_output=True, text=True,
                ).stdout
                self.assertIn(f"DMG_RELEASE={(downloaded / dmg.name).resolve()}", resolved)
                self.assertIn("IMMUTABLE_NAME=cmux-nightly-macos-arm64-123.dmg", resolved)

                strict = subprocess.run(
                    [sys.executable, str(resolver), str(downloaded / "cmux-nightly-notarization-recovery.json"),
                     "123", "a" * 40, "nightly", "arm64", "--source-run-attempt", "1", "--published"],
                    check=True, capture_output=True, text=True,
                ).stdout
                self.assertIn("IMMUTABLE_NAME=cmux-nightly-macos-arm64-123.dmg", strict)
                missing_attempt = subprocess.run(
                    [sys.executable, str(resolver), str(downloaded / "cmux-nightly-notarization-recovery.json"),
                     "123", "a" * 40, "nightly", "arm64", "--strict"],
                    check=False, capture_output=True, text=True,
                )
                self.assertNotEqual(missing_attempt.returncode, 0)
                self.assertIn("requires source run attempt", missing_attempt.stderr)

                shutil.rmtree(downloaded / "cmux-nightly-notarization-recovery-app")
                extracted = subprocess.run(
                    [sys.executable, str(resolver), str(downloaded / "cmux-nightly-notarization-recovery.json"),
                     "123", "a" * 40, "nightly", "arm64", "--source-run-attempt", "1", "--extract-app"],
                    check=True, capture_output=True, text=True,
                ).stdout
                self.assertIn("APP_PATH=", extracted)
                self.assertTrue((downloaded / "cmux-nightly-notarization-recovery-app" / app.name / "Contents").is_dir())

                unpublished = dict(manifest)
                unpublished["should_publish"] = False
                unpublished_path = downloaded / "unpublished-recovery.json"
                unpublished_path.write_text(json.dumps(unpublished), encoding="utf-8")
                rejected = subprocess.run(
                    [sys.executable, str(resolver), str(unpublished_path),
                     "123", "a" * 40, "nightly", "arm64", "--source-run-attempt", "1", "--published"],
                    check=False, capture_output=True, text=True,
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("requires should_publish=true", rejected.stderr)

                historical = dict(manifest)
                for key in ("schema", "source_run_attempt", "should_publish"):
                    historical.pop(key)
                historical_path = downloaded / "historical-recovery.json"
                historical_path.write_text(json.dumps(historical), encoding="utf-8")
                subprocess.run(
                    [sys.executable, str(resolver), str(historical_path),
                     "123", "a" * 40, "nightly", "arm64", "--metadata-only"],
                    check=True, capture_output=True, text=True,
                )
                rejected = subprocess.run(
                    [sys.executable, str(resolver), str(historical_path),
                     "123", "a" * 40, "nightly", "arm64", "--source-run-attempt", "1", "--strict"],
                    check=False, capture_output=True, text=True,
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("requires manifest schema 1", rejected.stderr)


if __name__ == "__main__":
    unittest.main()
