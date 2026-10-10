#!/usr/bin/env python3
"""Keep nightly notarization polling from repeating artifact verification."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/auto-resume-nightly-notarization.yml"


class NightlyNotarizationPollLoopTests(unittest.TestCase):
    def test_recovery_is_resolved_once_before_status_polling(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        poll_steps = workflow["jobs"]["poll"]["steps"]
        poll_run = next(step["run"] for step in poll_steps if step.get("id") == "poll")

        resolver = "scripts/ci/resolve-notarization-recovery.py"
        self.assertEqual(poll_run.count(resolver), 1)
        resolve_at = poll_run.index(resolver)
        loop_at = poll_run.index("while :; do")
        self.assertLess(resolve_at, loop_at)
        self.assertIn('--strict "${resolve_args[@]}"', poll_run)
        self.assertIn("recovery-$variant.state-file", poll_run)
        self.assertLess(poll_run.index("state-file", resolve_at), loop_at)
        self.assertGreater(poll_run.index("cat \"$RUNNER_TEMP/recovery-$variant.state-file\"", loop_at), loop_at)

        # Polling remains fail-closed: only an explicit Accepted result admits
        # stapling, while query failures and terminal statuses stop the job.
        self.assertIn("0) ;;", poll_run)
        self.assertIn("2) pending=true ;;", poll_run)
        self.assertIn("*) terminal_failure=true ;;", poll_run)
        self.assertIn('if [ "$terminal_failure" = true ]; then', poll_run)
        self.assertIn('if [ "$pending" = false ]; then', poll_run)

    def test_preflight_uses_metadata_only_when_all_variants_exist(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        check = workflow["jobs"]["preflight"]["steps"][0]["run"]
        program = re.search(r'<<\'PY\' > "\$RUNNER_TEMP/artifact-check"\n(.*?)\nPY', check, re.S).group(1)
        variants = ("arm64", "x86_64", "universal")
        recovery = [f"cmux-nightly-notarization-recovery-{v}-aaaaaaa" for v in variants]
        metadata = [f"cmux-nightly-notarization-metadata-{v}-aaaaaaa" for v in variants]
        for names, expired, ready, metadata_only in (
            (recovery, (), True, False),
            (recovery + metadata[:2], (), True, False),
            (recovery + metadata, (), True, True),
            (recovery + metadata, (metadata[0],), True, False),
            (metadata, (), False, False),
        ):
            with self.subTest(names=names, expired=expired), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "artifacts.json"
                path.write_text(json.dumps({"artifacts": [{"name": name, "expired": name in expired} for name in names]}))
                result = subprocess.run([sys.executable, "-c", program, str(path), "nightly", "aaaaaaa"],
                                        capture_output=True, text=True, check=True)
                outputs = dict(line.split("=", 1) for line in result.stdout.splitlines())
                self.assertEqual(outputs["ready"], str(ready).lower())
                if ready:
                    self.assertEqual(outputs["metadata_only"], str(metadata_only).lower())

    def test_metadata_and_retained_full_artifacts_reach_polling(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        steps = workflow["jobs"]["poll"]["steps"]
        download_run = next(step["run"] for step in steps if step.get("name") == "Download exact polling inputs")
        poll_run = next(step["run"] for step in steps if step.get("id") == "poll")
        for metadata_only in (True, False):
            with self.subTest(metadata_only=metadata_only), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "scripts/ci").mkdir(parents=True)
                shutil.copy2(ROOT / "scripts/ci/resolve-notarization-recovery.py", root / "scripts/ci")
                (root / "scripts/ci/poll-notary-submission.py").write_text("print('status=Accepted')\n")
                binaries = root / "bin"
                binaries.mkdir()
                gh = binaries / "gh"
                gh.write_text(f"#!{sys.executable}\n" + """import os, pathlib, shutil, sys
args = sys.argv[1:]
assert args[:3] == ['run', 'download', '123']
name = args[args.index('--name') + 1]
destination = args[args.index('--dir') + 1]
shutil.copytree(pathlib.Path(os.environ['ARTIFACTS']) / name, destination)
""")
                gh.chmod(0o755)
                artifacts = root / "artifacts"
                kind = "metadata" if metadata_only else "recovery"
                for variant in ("arm64", "x86_64", "universal"):
                    artifact = artifacts / f"cmux-nightly-notarization-{kind}-{variant}-aaaaaaa"
                    artifact.mkdir(parents=True)
                    dmg = f"cmux-nightly-macos-{variant}.dmg"
                    digest = hashlib.sha256(b"signed-dmg").hexdigest()
                    manifest = {
                        "schema": 1, "source_run_id": "123", "source_run_attempt": "1",
                        "head_sha": "a" * 40, "short_sha": "aaaaaaa", "should_publish": True,
                        "channel": "nightly", "variant": variant, "release_tag": "nightly",
                        "dmg_prefix": "cmux-nightly-macos", "build": "123", "dmg_path": dmg,
                        "immutable_path": f"cmux-nightly-macos-{variant}-123.dmg",
                        "app_path": "cmux-nightly-notarization-recovery-app/cmux NIGHTLY.app",
                        "app_archive_path": "cmux-nightly-notarization-recovery-app.tar.gz",
                        "state_path": f"{dmg}.notarization.state", "log_path": f"{dmg}.notarization.log",
                        "dmg_sha256": digest, "submission_id": f"submission-{variant}",
                    }
                    (artifact / "cmux-nightly-notarization-recovery.json").write_text(json.dumps(manifest))
                    (artifact / manifest["state_path"]).write_text(f"submission_id=submission-{variant}\ndmg_sha256={digest}\nsubmit_exit=0\n")
                    if not metadata_only:
                        (artifact / dmg).write_bytes(b"signed-dmg")
                        (artifact / manifest["log_path"]).write_text("In Progress\n")
                        with tarfile.open(artifact / manifest["app_archive_path"], "w:gz") as archive:
                            contents = tarfile.TarInfo("cmux NIGHTLY.app/Contents")
                            contents.type = tarfile.DIRTYPE
                            archive.addfile(contents)
                env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}", ARTIFACTS=str(artifacts),
                           SOURCE_RUN_ID="123", SOURCE_RUN_ATTEMPT="1", SOURCE_HEAD_SHA="a" * 40,
                           CHANNEL="nightly", SHORT_SHA="aaaaaaa", GITHUB_REPOSITORY="owner/repo",
                           RECOVERY_METADATA_ONLY=str(metadata_only).lower(), RUNNER_TEMP=str(root),
                           GITHUB_OUTPUT=str(root / "output"))
                for script in (download_run, poll_run):
                    result = subprocess.run(["bash", "-c", script], cwd=root, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("all_accepted=true", (root / "output").read_text())
                for variant in ("arm64", "x86_64", "universal"):
                    recovered = root / "recovery" / variant
                    self.assertEqual((recovered / "cmux-nightly-notarization-recovery-app").exists(), not metadata_only)
                    self.assertEqual(len(list(recovered.glob("*.dmg"))), 0 if metadata_only else 1)

    def test_staple_job_keeps_final_exact_artifact_resolution(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        staple_steps = workflow["jobs"]["wait-and-staple"]["steps"]
        resolve_run = next(
            step["run"] for step in staple_steps if step.get("name") == "Resolve manifest and verify exact DMG"
        )
        self.assertIn("scripts/ci/resolve-notarization-recovery.py", resolve_run)
        self.assertIn("--strict --extract-app", resolve_run)
        self.assertIn('> "$RUNNER_TEMP/recovery.env"', resolve_run)
        staple_run = next(
            step["run"] for step in staple_steps if step.get("name") == "Wait, staple, and validate exact submitted DMG"
        )
        self.assertIn('"$DMG_RELEASE"', staple_run)
        self.assertIn('"verified/$IMMUTABLE_NAME"', staple_run)
        upload = next(step for step in staple_steps if step.get("name") == "Upload accepted variant")
        self.assertEqual(upload["with"]["compression-level"], 0)


if __name__ == "__main__":
    unittest.main()
