from __future__ import annotations

import http.client
import importlib.util
import json
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
import re
import tempfile
import urllib.error
from unittest import TestCase, main
from unittest.mock import patch

import yaml


SCRIPT = Path(__file__).with_name("verify_published_manifest.py")
ROOT = SCRIPT.parents[2]
ARTIFACT_WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"
WINDOWS_INSTALLER = ROOT / "web" / "public" / "tui" / "install-static.ps1"
SPEC = importlib.util.spec_from_file_location("verify_published_manifest", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class FakeResponse:
    def __init__(self, body: dict[str, object]) -> None:
        self.body = json.dumps(body).encode("utf-8")

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def read(self) -> bytes:
        return self.body


class VerifyPublishedManifestTests(TestCase):
    COMMIT = "a" * 40
    WINDOWS = "cmux-tui-x86_64-pc-windows-gnu.exe"
    CURRENT_UNIX_ONLY_MANIFEST = {
        "commit": "2dc5237c59e06b8f1007533cd4d14b13e702e553",
        "builtAt": "2026-07-15T06:35:13.005735+00:00",
        "binaries": {
            "cmux-tui-aarch64-apple-darwin":
                "21311bd5af176f5196937240b4f38c4810f01ed2e219731e8ba122256512b58d",
            "cmux-tui-aarch64-unknown-linux-gnu":
                "cc50a9cf5040f3d3a7d02d5d9faae6a479967adf3c3f5abb4c4c34796dee3046",
            "cmux-tui-x86_64-apple-darwin":
                "66ac1ee6d31fbb8de1004668de6517f59c075899a359c3946fce92f9273d3741",
            "cmux-tui-x86_64-unknown-linux-gnu":
                "8455dcebdb91d47a3988d64679f1d1ac0919ab558286e3a016ec88c24dce463a",
        },
    }

    def manifest(self, *, windows: bool = True) -> dict[str, object]:
        binaries: dict[str, str] = {}
        if windows:
            binaries[self.WINDOWS] = "b" * 64
        return {"commit": self.COMMIT, "binaries": binaries}

    def verify(self, manifest: dict[str, object]) -> None:
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            VERIFY.verify_manifest(
                "https://files.example/cmux-tui/latest/manifest.json",
                expected_commit=self.COMMIT,
                required_artifacts=(self.WINDOWS,),
            )

    def test_accepts_required_windows_artifact_and_digest(self) -> None:
        self.verify(self.manifest())

    def test_rejects_manifest_without_windows_artifact(self) -> None:
        with self.assertRaisesRegex(VERIFY.ManifestError, "missing required artifact"):
            self.verify(self.manifest(windows=False))

    def test_rejects_current_unix_only_latest_manifest(self) -> None:
        manifest = self.CURRENT_UNIX_ONLY_MANIFEST
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            with self.assertRaisesRegex(
                VERIFY.ManifestError,
                "missing required artifact",
            ):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=manifest["commit"],
                    required_artifacts=(self.WINDOWS,),
                )

    def test_artifact_workflow_verifies_windows_before_rolling_latest(self) -> None:
        document = yaml.safe_load(ARTIFACT_WORKFLOW.read_text(encoding="utf-8"))
        build = document["jobs"]["build"]["with"]
        self.assertIs(build["include_windows"], True)
        self.assertIs(build["package_npm"], False)
        self.assertIs(build["package_pypi"], False)

        installer = WINDOWS_INSTALLER.read_text(encoding="utf-8")
        advertised = re.search(r'^\$Artifact = "([^"]+)"$', installer, re.MULTILINE)
        self.assertIsNotNone(advertised)
        self.assertEqual(advertised.group(1), self.WINDOWS)

        steps = document["jobs"]["publish"]["steps"]
        names = [step.get("name", "") for step in steps]
        before_upload = names.index("Verify cmux-tui manifest before upload")
        upload = names.index("Upload to R2")
        before_latest = names.index("Verify immutable cmux-tui manifest before latest publish")
        rolling = names.index("Publish rolling latest artifacts")
        after_publish = names.index("Verify published cmux-tui manifests")
        self.assertLess(before_upload, upload)
        self.assertLess(upload, before_latest)
        self.assertLess(before_latest, rolling)
        self.assertLess(rolling, after_publish)

        upload_run = steps[upload]["run"]
        self.assertNotIn("cmux-tui/latest", upload_run)
        publish_env = document["jobs"]["publish"]["env"]
        self.assertEqual(publish_env["EXPECTED_WINDOWS_ARTIFACT"], self.WINDOWS)
        before_upload_run = steps[before_upload]["run"]
        self.assertIn("$EXPECTED_WINDOWS_ARTIFACT", before_upload_run)
        before_latest_run = steps[before_latest]["run"]
        self.assertIn("$EXPECTED_WINDOWS_ARTIFACT", before_latest_run)
        after_publish_run = steps[after_publish]["run"]
        self.assertIn("cmux-tui/$GITHUB_SHA/manifest.json", after_publish_run)
        self.assertIn("cmux-tui/latest/manifest.json?verify=$GITHUB_SHA", after_publish_run)

    def test_rejects_manifest_with_invalid_digest(self) -> None:
        manifest = self.manifest()
        manifest["binaries"] = {self.WINDOWS: "not-a-sha256"}
        with self.assertRaisesRegex(VERIFY.ManifestError, "invalid SHA-256"):
            self.verify(manifest)

    def test_validates_local_manifest_before_upload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(self.manifest()), encoding="utf-8")
            VERIFY.verify_manifest_file(
                path,
                expected_commit=self.COMMIT,
                required_artifacts=(self.WINDOWS,),
            )

    def test_rejects_manifest_for_a_different_commit(self) -> None:
        manifest = self.manifest()
        manifest["commit"] = "c" * 40
        with self.assertRaisesRegex(VERIFY.ManifestError, "commit mismatch"):
            self.verify(manifest)

    def test_cli_does_not_echo_manifest_url_or_error_details(self) -> None:
        secret = "query-credential-should-stay-private"
        url = f"https://files.example/cmux-tui/latest/manifest.json?token={secret}"
        invalid = self.manifest()
        invalid["commit"] = "c" * 40

        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(invalid)):
            stdout = StringIO()
            stderr = StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                result = VERIFY.main(
                    [
                        "--manifest-url",
                        url,
                        "--expected-commit",
                        self.COMMIT,
                        "--require-artifact",
                        self.WINDOWS,
                    ]
                )
        self.assertEqual(result, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "cmux-tui manifest verification failed\n")
        self.assertNotIn(url, stdout.getvalue() + stderr.getvalue())
        self.assertNotIn(secret, stdout.getvalue() + stderr.getvalue())

    def test_rejects_non_https_manifest_url_before_fetching(self) -> None:
        with self.assertRaisesRegex(VERIFY.ManifestError, "HTTPS"):
            VERIFY.verify_manifest(
                "http://files.example/cmux-tui/latest/manifest.json?token=private",
                expected_commit=self.COMMIT,
                required_artifacts=(self.WINDOWS,),
            )

    def test_rejects_manifest_url_fragments_before_fetching(self) -> None:
        with patch.object(VERIFY, "urlopen") as fetch:
            with self.assertRaisesRegex(VERIFY.ManifestError, "HTTPS"):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json#private",
                    expected_commit=self.COMMIT,
                    required_artifacts=(self.WINDOWS,),
                )
        fetch.assert_not_called()

    def test_fetch_error_does_not_include_manifest_url_or_raw_error(self) -> None:
        secret = "query-credential-should-stay-private"
        url = f"https://files.example/cmux-tui/latest/manifest.json?token={secret}"
        error = urllib.error.HTTPError(url, 503, "upstream secret", {}, None)
        try:
            with patch.object(VERIFY, "urlopen", side_effect=error):
                with self.assertRaises(VERIFY.ManifestError) as context:
                    VERIFY.verify_manifest(
                        url,
                        expected_commit=self.COMMIT,
                        required_artifacts=(self.WINDOWS,),
                    )
        finally:
            error.close()
        message = str(context.exception)
        self.assertNotIn(url, message)
        self.assertNotIn(secret, message)
        self.assertNotIn("upstream secret", message)

        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(self.manifest())):
            stdout = StringIO()
            stderr = StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                result = VERIFY.main(
                    [
                        "--manifest-url",
                        url,
                        "--expected-commit",
                        self.COMMIT,
                        "--require-artifact",
                        self.WINDOWS,
                    ]
                )
        self.assertEqual(result, 0)
        self.assertEqual(stdout.getvalue(), "Verified cmux-tui manifest\n")
        self.assertEqual(stderr.getvalue(), "")
        self.assertNotIn(url, stdout.getvalue() + stderr.getvalue())
        self.assertNotIn(secret, stdout.getvalue() + stderr.getvalue())

    def test_http_protocol_errors_are_sanitized(self) -> None:
        with patch.object(
            VERIFY,
            "urlopen",
            side_effect=http.client.RemoteDisconnected("private endpoint detail"),
        ):
            with self.assertRaisesRegex(
                VERIFY.ManifestError,
                "could not fetch published manifest",
            ) as context:
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(self.WINDOWS,),
                )
        self.assertNotIn("private endpoint detail", str(context.exception))


if __name__ == "__main__":
    main()
