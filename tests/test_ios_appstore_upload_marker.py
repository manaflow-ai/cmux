#!/usr/bin/env python3
"""The cmux.app upload marker must follow Apple's receipt, not the step's exit.

ios-appstore-upload.yml skips a scheduled poll when a completed run for the
same main SHA left a `cmux-app-testflight-upload` artifact: the marker says
"Apple already has this revision", and the next poll only retries group
assignment. The two steps that write and retain that marker ran only on
success, so a failure after App Store Connect had accepted the IPA (issue
#13690: an unbound array in the notes step, after "uploaded": true) left no
marker. Every hourly poll then archived and uploaded the same revision again.

These tests run the marker step's own script against a fake runner directory,
with and without an upload receipt, and check that both steps are allowed to
run after the upload step fails.
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ios-appstore-upload.yml"
RECORD = "Record completed upload before group assignment"
RETAIN = "Retain completed upload for assignment retries"
APP_ID = "6783338052"
RECEIPT = {"uploadId": "41b619d5", "fileName": "cmux-resigned.ipa", "uploaded": True}


def upload_steps():
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return workflow["jobs"]["upload"]["steps"]


def step(name):
    for candidate in upload_steps():
        if candidate.get("name") == name:
            return candidate
    raise AssertionError(f"missing step {name!r}")


def runs_after_a_failed_step(condition):
    # GitHub skips a step after a failure unless its condition carries a
    # status function that allows it.
    return any(fn in str(condition or "") for fn in ("always()", "failure()", "!cancelled()"))


class UploadMarkerTests(unittest.TestCase):
    def record(self, outcome, receipt=None, build_number_file="20260922133206", output_build=""):
        """Run the marker step's script; return (GITHUB_OUTPUT dict, marker or None)."""
        record = step(RECORD)
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            upload_dir = temp / "cmux-ios-upload"
            upload_dir.mkdir()
            if receipt is not None:
                (upload_dir / "upload.log").write_text(receipt, encoding="utf-8")
            if build_number_file is not None:
                (temp / "cmux-final-build-number.txt").write_text(
                    build_number_file + "\n", encoding="utf-8"
                )
            output = temp / "github_output"
            output.touch()
            env = {
                **os.environ,
                "RUNNER_TEMP": str(temp),
                "GITHUB_OUTPUT": str(output),
                "GITHUB_SHA": "head-sha",
            }
            for key, value in (record.get("env") or {}).items():
                value = str(value)
                value = value.replace("${{ runner.temp }}", str(temp))
                value = value.replace("${{ steps.upload.outcome }}", outcome)
                value = value.replace("${{ steps.upload.outputs.final_build_number }}", output_build)
                env[key] = value
            result = subprocess.run(
                ["bash", "-e", "-c", record["run"]], env=env, capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            outputs = dict(
                line.split("=", 1) for line in output.read_text().splitlines() if "=" in line
            )
            marker_path = temp / "cmux-app-upload-marker" / "upload.json"
            marker = json.loads(marker_path.read_text()) if marker_path.exists() else None
            return outputs, marker

    def test_marker_steps_run_after_a_failed_upload_step(self):
        self.assertTrue(runs_after_a_failed_step(step(RECORD).get("if")), step(RECORD).get("if"))
        retain = str(step(RETAIN).get("if") or "")
        self.assertTrue(runs_after_a_failed_step(retain), retain)
        # Retention follows what the record step decided, so a failure before
        # Apple accepted anything never publishes a marker.
        self.assertIn("steps.record_upload.outputs.recorded == 'true'", retain)
        self.assertEqual(step(RECORD).get("id"), "record_upload")

    def test_failure_after_the_receipt_records_the_upload(self):
        outputs, marker = self.record("failure", receipt=json.dumps(RECEIPT) + "\n")
        self.assertEqual(outputs.get("recorded"), "true")
        self.assertEqual(
            marker, {"sha": "head-sha", "app_id": APP_ID, "build_number": "20260922133206"}
        )

    def test_receipt_among_other_log_lines_is_found(self):
        log = "Uploading cmux-resigned.ipa (53037920 bytes)\n" + json.dumps(RECEIPT, indent=2) + "\n"
        outputs, marker = self.record("failure", receipt=log)
        self.assertEqual(outputs.get("recorded"), "true")
        self.assertEqual(marker["build_number"], "20260922133206")

    def test_failure_before_the_receipt_records_nothing(self):
        # upload-testflight.sh writes the build number file before archiving,
        # so the file alone must never produce a marker.
        for receipt in (None, "", "error: export failed\n", json.dumps({**RECEIPT, "uploaded": False})):
            with self.subTest(receipt=receipt):
                outputs, marker = self.record("failure", receipt=receipt)
                self.assertNotEqual(outputs.get("recorded"), "true")
                self.assertIsNone(marker)

    def test_receipt_without_a_numeric_build_number_records_nothing(self):
        for build_number in (None, "", "unknown"):
            with self.subTest(build_number=build_number):
                outputs, marker = self.record(
                    "failure", receipt=json.dumps(RECEIPT), build_number_file=build_number
                )
                self.assertNotEqual(outputs.get("recorded"), "true")
                self.assertIsNone(marker)

    def test_successful_upload_still_records(self):
        outputs, marker = self.record(
            "success", receipt=json.dumps(RECEIPT), output_build="20260922133206"
        )
        self.assertEqual(outputs.get("recorded"), "true")
        self.assertEqual(marker["build_number"], "20260922133206")


if __name__ == "__main__":
    unittest.main()
