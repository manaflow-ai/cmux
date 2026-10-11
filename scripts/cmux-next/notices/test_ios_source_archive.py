#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""IOS-SOURCE-ARCHIVE-PER-RELEASE: every iOS release workflow builds and checks the
corresponding-source archive of the exact commit it ships, before the upload,
with the cmux-next source-archive workflow, and publishes it (only while
vars.CMUX_NEXT_PUBLISH_SOURCE_ARCHIVE is 1) as cmux-ios-source-<build>.tar.gz,
the archive that the iOS z2d MPL-2.0 offer names. Stdlib only."""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
ARCHIVE_WORKFLOW = WORKFLOWS / "cmux-next-source-archive.yml"
PUBLISH = ROOT / "scripts/cmux-next/publish-ios-source-archive.sh"
# The workflows that upload the iOS app (TestFlight INTERNAL/DEMO, TestFlight cmux.app,
# App Store production) and the job that uploads in each.
RELEASES = {
    "ios-testflight.yml": "upload",
    "ios-appstore-upload.yml": "upload",
    "ios-app-store.yml": "upload-and-validate",
}
GATE = "vars.CMUX_NEXT_PUBLISH_SOURCE_ARCHIVE == '1'"

sys.path.insert(0, str(HERE))
import ios_notices  # noqa: E402


def jobs(text: str) -> dict[str, str]:
    body = text[text.index("\njobs:\n") :]
    starts = list(re.finditer(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", body))
    return {m.group(1): body[m.start() : starts[i + 1].start() if i + 1 < len(starts) else len(body)] for i, m in enumerate(starts)}


def needs(job: str) -> set[str]:
    match = re.search(r"(?m)^    needs: (.*)$", job)
    if not match:
        return set()
    return {name.strip() for name in match.group(1).strip("[] ").split(",") if name.strip()}


def field(job: str, key: str) -> str:
    match = re.search(rf"(?m)^    {key}: (.*)$", job)
    return match.group(1).strip() if match else ""


class ReleaseWorkflowTest(unittest.TestCase):
    def test_every_ios_release_builds_the_archive_before_its_upload(self) -> None:
        for name, upload_name in RELEASES.items():
            with self.subTest(workflow=name):
                all_jobs = jobs((WORKFLOWS / name).read_text(encoding="utf-8"))
                archive = all_jobs.get("source-archive", "")
                self.assertIn("uses: ./.github/workflows/cmux-next-source-archive.yml", archive)
                ref = re.search(r"(?m)^      ref: (.*)$", archive)
                self.assertIsNotNone(ref, "the archive job must name the exact commit the upload builds")
                self.assertIn("artifact: cmux-ios-source-archive", archive)
                upload = all_jobs[upload_name]
                self.assertIn("source-archive", needs(upload), "no iOS upload without a built and checked archive")
                self.assertNotIn("continue-on-error", archive)
                # The upload builds the same commit the archive holds.
                checkout = upload[upload.index("uses: actions/checkout@") :]
                checkout = checkout[: checkout.index("\n      - ")]
                app_ref = re.search(r"(?m)^          ref: (.*)$", checkout)
                self.assertEqual(ref.group(1).strip(), app_ref.group(1).strip() if app_ref else "${{ github.sha }}")

    def test_every_ios_release_publishes_only_behind_the_gate_and_after_the_upload(self) -> None:
        for name, upload_name in RELEASES.items():
            with self.subTest(workflow=name):
                all_jobs = jobs((WORKFLOWS / name).read_text(encoding="utf-8"))
                publish = all_jobs.get("publish-source-archive", "")
                self.assertIn(GATE, field(publish, "if"))
                self.assertIn(f"needs.{upload_name}.result == 'success'", field(publish, "if"))
                self.assertLessEqual({upload_name, "source-archive"}, needs(publish))
                self.assertIn("name: cmux-ios-source-archive", publish)
                self.assertIn("scripts/cmux-next/publish-ios-source-archive.sh", publish)
                self.assertIn(f"needs.{upload_name}.outputs.", publish, "the archive is named by the uploaded build number")
                self.assertIn("contents: write", publish)

    def test_the_archive_workflow_is_callable_with_an_exact_ref_and_never_cancels_a_release(self) -> None:
        text = ARCHIVE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("workflow_call:", text)
        for key in ("ref:", "build:", "artifact:"):
            self.assertIn(key, text[text.index("workflow_call:") : text.index("workflow_dispatch:")])
        self.assertEqual(text.count("ref: ${{ inputs.ref }}"), 2, "both jobs check out the caller's commit")
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'push' }}", text)

    def test_the_publish_script_checks_the_pin_and_the_archive(self) -> None:
        script = PUBLISH.read_text(encoding="utf-8")
        self.assertRegex(script, r'ghostty_source_archive\.py"? verify')
        self.assertIn("ghostty_kit_pin", script, "the archive's ghostty-next must be the GhosttyNextKit pin's revision")
        self.assertIn('cmux-ios-source-${build}.tar.gz', script)
        self.assertIn("--immutable", script)
        self.assertIn("ios-source", script)


class OfferTest(unittest.TestCase):
    def test_the_z2d_offer_names_the_ios_release_archive(self) -> None:
        offer = ios_notices.Z2D_OFFER.format(url="u", revision="r" * 40)
        self.assertIn("cmux-ios-source-<build>.tar.gz", offer)
        self.assertIn("https://github.com/manaflow-ai/cmux/releases/download/ios-source/", offer)
        self.assertIn("cmux-next-src-<commit, 11 characters>", offer)


if __name__ == "__main__":
    unittest.main()
