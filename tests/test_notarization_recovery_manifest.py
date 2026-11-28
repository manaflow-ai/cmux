#!/usr/bin/env python3
"""Exercise the recovery manifest across the artifact upload/download boundary."""

import fnmatch
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
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]


def manifest_program():
    workflow = (ROOT / ".github/workflows/nightly.yml").read_text()
    step = workflow.split("- name: Prepare pending notarization recovery artifact\n", 1)[1]
    step = step.split("\n      - name:", 1)[0]
    matches = re.findall(r"<<'PY'\n(.*?)^          PY$", step, re.MULTILINE | re.DOTALL)
    for body in matches:
        if "state_path, actual_sha, dmg_path" in body:
            return "\n".join(line.removeprefix("          ") for line in body.splitlines())
    raise AssertionError("DMG recovery manifest generator is missing")


class AcceptedPublicationTests(unittest.TestCase):
    """Run assembly with the layout produced by the pinned download action."""

    def assemble(self, root, channel="nightly", extra_variant=False, invalid=None):
        workflow = (ROOT / ".github/workflows/auto-resume-nightly-notarization.yml").read_text()

        def step(name):
            return workflow.split(f"- name: {name}\n", 1)[1].split("\n      - name:", 1)[0]

        download = step("Download all accepted variants").split("        with:\n", 1)[1]
        inputs = dict(re.findall(r"^          ([\w-]+): (.+)$", download, re.MULTILINE))
        for key, value in inputs.items():
            inputs[key] = value.replace("${{ needs.preflight.outputs.channel }}", channel).replace(
                "${{ needs.preflight.outputs.short_sha }}", "aaaaaaa"
            )
        artifact = f"cmux-{channel}-notarization-verified-arm64-aaaaaaa"
        available = [artifact]
        if extra_variant:
            available.append(f"cmux-{channel}-notarization-verified-universal-aaaaaaa")
        selected = [name for name in available if (
            name == inputs["name"] if "name" in inputs
            else fnmatch.fnmatchcase(name, inputs.get("pattern", "*"))
        )]
        self.assertIn(artifact, selected, "download must select the accepted arm64 artifact")
        dmg = b"accepted and launch-tested arm64 DMG"
        digest = hashlib.sha256(dmg).hexdigest()
        immutable = f"cmux-{channel}-macos-arm64-123.dmg"
        feed = "<rss>accepted arm64 feed</rss>"
        for name in selected:
            # download-artifact v7 flattens a single match even with merge-multiple=false.
            destination = root / inputs["path"]
            if "name" not in inputs and inputs.get("merge-multiple") != "true" and len(selected) > 1:
                destination /= name
            destination.mkdir(parents=True, exist_ok=True)
            if name != artifact:
                continue
            (destination / immutable).write_bytes(dmg)
            (destination / "appcast-arm64.xml").write_text(feed)
            (destination / "cmux-nightly-notarization-recovery.json").write_text(json.dumps({
                "build": "123", "immutable_path": immutable,
                "final_dmg_sha256": "0" * 64 if invalid == "manifest" else digest,
            }))
        (root / "tested").mkdir()
        tested_digest = "0" * 64 if invalid == "tested" else digest
        (root / "tested/tested-arm64.sha256").write_text(f"{tested_digest}  {immutable}\n")
        assembly = textwrap.dedent(step("Assemble and verify all accepted publication inputs").split(
            "        run: |\n", 1
        )[1])
        result = subprocess.run(
            ["bash", "-c", assembly], cwd=root, capture_output=True, text=True, timeout=10,
            env={**os.environ, "SHORT_SHA": "aaaaaaa", "DMG_PREFIX": f"cmux-{channel}-macos",
                 "GITHUB_ENV": str(root / "github-env")},
        )
        return result, immutable, dmg, feed

    def test_accepted_artifact_download_assembles_publication(self):
        for channel in ("nightly", "rc"):
            for extra_variant in (False, True):
                with self.subTest(channel=channel, extra_variant=extra_variant), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    result, immutable, dmg, feed = self.assemble(root, channel, extra_variant)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((root / "nightly-out" / immutable).read_bytes(), dmg)
                    self.assertEqual((root / "nightly-out" / f"cmux-{channel}-macos-arm64.dmg").read_bytes(), dmg)
                    self.assertEqual((root / "nightly-out/appcast-arm64.xml").read_text(), feed)
                    self.assertEqual((root / "github-env").read_text(), "NIGHTLY_BUILD=123\n")

    def test_publication_rejects_changed_or_untested_dmg(self):
        for invalid, message in (("manifest", "SHA-256 mismatch"), ("tested", "not the one verify-stapled launched")):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                result, immutable, _, _ = self.assemble(root, extra_variant=True, invalid=invalid)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse((root / "nightly-out" / immutable).exists())
                self.assertFalse((root / "github-env").exists())


class RecoveryManifestTests(unittest.TestCase):
    def metadata_fixture(self, root):
        manifest = {
            "schema": 1, "source_run_id": "123", "source_run_attempt": "1",
            "head_sha": "a" * 40, "short_sha": "a" * 7, "should_publish": True,
            "channel": "nightly", "variant": "arm64", "release_tag": "nightly",
            "dmg_prefix": "cmux-nightly-macos", "build": "123",
            "dmg_path": "cmux-nightly-macos-arm64.dmg",
            "immutable_path": "cmux-nightly-macos-arm64-123.dmg",
            "app_path": "cmux-nightly-notarization-recovery-app/cmux NIGHTLY.app",
            "app_archive_path": "cmux-nightly-notarization-recovery-app.tar.gz",
            "state_path": "cmux-nightly-macos-arm64.dmg.notarization.state",
            "log_path": "cmux-nightly-macos-arm64.dmg.notarization.log",
            "dmg_sha256": "b" * 64, "submission_id": "fixture-id",
        }
        path = root / "cmux-nightly-notarization-recovery.json"
        path.write_text(json.dumps(manifest), encoding="utf-8")
        state = root / manifest["state_path"]
        state.write_text("submission_id=fixture-id\ndmg_sha256=" + "b" * 64 + "\nsubmit_exit=0\n")
        return manifest, path, state

    def resolve_metadata(self, path):
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts/ci/resolve-notarization-recovery.py"),
             str(path), "123", "a" * 40, "nightly", "arm64", "--run-attempt", "1",
             "--strict", "--metadata-only"],
            capture_output=True, text=True,
        )

    def test_metadata_only_needs_no_dmg_app_or_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, path, state = self.metadata_fixture(root)
            resolved = self.resolve_metadata(path)
            self.assertEqual(resolved.returncode, 0, resolved.stderr)
            self.assertIn(f"STATE_FILE={state.resolve()}\n", resolved.stdout)
            self.assertEqual({p.name for p in root.iterdir()}, {path.name, state.name})

    def test_metadata_only_rejects_unbound_or_failed_state(self):
        for invalid, expected in (
            ("submission_id=other\ndmg_sha256=" + "b" * 64, "does not match"),
            ("submission_id=fixture-id\ndmg_sha256=" + "c" * 64, "does not match"),
            ("submission_id=fixture-id\nsubmission_id=fixture-id", "duplicate"),
            ("malformed-state-line", "invalid"),
            ("submission_id=fixture-id\ndmg_sha256=" + "b" * 64 + "\nsubmit_exit=1", "nonzero"),
        ):
            with self.subTest(state=invalid), tempfile.TemporaryDirectory() as directory:
                _, path, state = self.metadata_fixture(Path(directory))
                state.write_text(invalid, encoding="utf-8")
                resolved = self.resolve_metadata(path)
                self.assertNotEqual(resolved.returncode, 0)
                self.assertIn(expected, resolved.stderr)
                self.assertNotIn("STATE_FILE=", resolved.stdout)

    def test_metadata_only_rejects_wrong_source_and_unsafe_state(self):
        for key, value in (
            ("source_run_id", "456"), ("source_run_attempt", "2"), ("head_sha", "c" * 40),
            ("channel", "rc"), ("variant", "universal"), ("should_publish", False),
            ("state_path", "../cmux-nightly-macos-arm64.dmg.notarization.state"),
        ):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                manifest, path, _ = self.metadata_fixture(Path(directory))
                manifest[key] = value
                path.write_text(json.dumps(manifest), encoding="utf-8")
                resolved = self.resolve_metadata(path)
                self.assertNotEqual(resolved.returncode, 0)
                self.assertNotIn("STATE_FILE=", resolved.stdout)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "artifact"
            artifact.mkdir()
            _, path, state = self.metadata_fixture(artifact)
            outside = root / "outside.state"
            state.rename(outside)
            state.symlink_to(outside)
            resolved = self.resolve_metadata(path)
            self.assertNotEqual(resolved.returncode, 0)
            self.assertIn("escapes artifact", resolved.stderr)

    def test_helper_pending_manifest_binds_signed_app_and_submission(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hashes = "arm64=" + "a" * 40
            state = root / "cmux-computer-use-notarization.state"
            state.write_text(
                f"submission_id=helper-id\ncdhashes={hashes}\nstatus=In Progress\nwait_exit=124\npending=true\n",
                encoding="utf-8",
            )
            (root / "cmux-computer-use-notarization.state.log").write_text("timeout\n", encoding="utf-8")
            manifest = {
                "schema": 2, "recovery_kind": "computer-use-helper",
                "source_run_id": "123", "source_run_attempt": "1",
                "head_sha": "a" * 40, "short_sha": "a" * 7, "should_publish": True,
                "channel": "nightly", "variant": "arm64", "release_tag": "nightly",
                "dmg_prefix": "cmux-nightly-macos", "build": "123",
                "dmg_path": "cmux-nightly-macos-arm64.dmg",
                "immutable_path": "cmux-nightly-macos-arm64-123.dmg",
                "app_path": "cmux-nightly-notarization-recovery-app/cmux NIGHTLY.app",
                "app_archive_path": "cmux-nightly-notarization-recovery-app.tar.gz",
                "helper_state_path": state.name,
                "helper_log_path": "cmux-computer-use-notarization.state.log",
                "submission_id": "helper-id", "helper_cdhashes": hashes,
            }
            path = root / "cmux-nightly-notarization-recovery.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            resolved = self.resolve_metadata(path)
            self.assertEqual(resolved.returncode, 0, resolved.stderr)
            self.assertIn("RECOVERY_KIND=computer-use-helper", resolved.stdout)
            self.assertIn(f"STATE_FILE={state.resolve()}", resolved.stdout)
            manifest["helper_cdhashes"] = "c" * 40
            path.write_text(json.dumps(manifest), encoding="utf-8")
            rejected = self.resolve_metadata(path)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("CDHash evidence", rejected.stderr)

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
                        "${{ needs.decide.outputs.should_publish }}", "true"
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
