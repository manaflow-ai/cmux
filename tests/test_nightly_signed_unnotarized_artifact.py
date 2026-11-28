#!/usr/bin/env python3
"""A signed nightly is downloadable before Apple answers.

When Apple's notary queue is slow, nightly.yml waits up to 20m (nightly-next)
or 40m per run and the feed does not move. Teammates still need the build, so
build-sign-notarize-nightly uploads the Developer ID-signed app as a run
artifact right after signing and before the notarization wait. Diagnostic
notary builds and builds held by NIGHTLY_NEXT_NOTARY_PAUSED (the browser-data import)
never upload an app: the repository is public. A failed upload never blocks
notarization.
"""

from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"


def steps() -> list[dict]:
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]["build-sign-notarize-nightly"]["steps"]


def index(name: str) -> int:
    return next(i for i, s in enumerate(steps()) if s.get("name") == name)


class SignedUnnotarizedArtifactTests(unittest.TestCase):
    ZIP = "Zip the signed app before notarization"
    UPLOAD = "Upload the signed app before notarization"

    def test_uploads_after_signing_and_before_the_notarization_wait(self):
        self.assertLess(index("Codesign apps"), index(self.ZIP))
        # The launch smokes run in verify-signed-nightly, a job without secrets
        # (#21024), so the zip no longer waits for them; it follows the signed
        # app's handoff to that job.
        self.assertLess(index("Upload signed app for the verify job"), index(self.ZIP))
        self.assertLess(index(self.ZIP), index(self.UPLOAD))
        self.assertLess(index(self.UPLOAD), index("Notarize app ticket through final DMG"))

    def test_artifact_name_retention_and_contents(self):
        upload = steps()[index(self.UPLOAD)]
        self.assertTrue(upload["uses"].startswith("actions/upload-artifact@"))
        self.assertEqual(upload["with"]["name"], "cmux-nightly-signed-unnotarized-${{ matrix.variant }}")
        self.assertEqual(upload["with"]["retention-days"], 7)
        self.assertEqual(upload["with"]["if-no-files-found"], "error")
        zip_run = steps()[index(self.ZIP)]["run"]
        # ditto keeps the bundle's symlinks and signature intact.
        self.assertIn('ditto -c -k --sequesterRsrc --keepParent "$CHANNEL_APP_PATH"', zip_run)

    def test_never_for_fast_notary_test_or_paused_builds(self):
        for name in (self.ZIP, self.UPLOAD):
            condition = steps()[index(name)]["if"]
            self.assertIn("needs.decide.outputs.fast_build != 'true'", condition)
            self.assertIn("needs.decide.outputs.notary_test != 'true'", condition)
            self.assertIn("needs.decide.outputs.import_paused != 'true'", condition)
            # A submissions pause (Apple's queue stuck) is exactly when teammates need it.
            self.assertNotIn("notary_paused", condition)
            self.assertTrue(steps()[index(name)].get("continue-on-error"), name)

    def test_fast_dogfood_upload_does_not_depend_on_notarization(self):
        condition = steps()[index("Upload fast arm64 dogfood artifact")]["if"]
        self.assertNotIn("notarize", condition)
        self.assertNotIn("notary", condition)


if __name__ == "__main__":
    unittest.main(verbosity=2)
