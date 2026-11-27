#!/usr/bin/env python3
"""A signed nightly is downloadable before Apple answers.

When Apple's notary queue is slow, nightly.yml waits up to 20m (nightly-next)
or 40m per run and the feed does not move. Teammates still need the build, so
build-sign-notarize-nightly uploads the Developer ID-signed app as a run
artifact. Since 2026-10-20 the zip is made during Apple's wait, on the copy of
the app taken right after signing (signed-app-checks.sh), and uploaded after
the notarization step, once the checks passed, even when that step failed or
handed the submission to a later run: the wait no longer holds about 2.5 min of checks. Diagnostic
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


CHECKS = ROOT / "scripts/ci/signed-app-checks.sh"


class SignedUnnotarizedArtifactTests(unittest.TestCase):
    START = "Start the signed-app checks (they run during notarization)"
    FINISH = "Finish the signed-app checks"
    UPLOAD = "Upload the signed unnotarized app"

    def test_zipped_during_the_wait_and_uploaded_after_it(self):
        self.assertLess(index("Codesign apps"), index(self.START))
        self.assertLess(index(self.START), index("Notarize app ticket through final DMG"))
        self.assertLess(index("Notarize app ticket through final DMG"), index(self.FINISH))
        self.assertLess(index(self.FINISH), index(self.UPLOAD))
        # A failed or pending notarization still uploads the zip, but only an
        # app that passed the checks: the repository is public.
        self.assertTrue(steps()[index(self.UPLOAD)]["if"].startswith(
            "!cancelled() && steps.signed-app-checks.outcome == 'success' && "))

    def test_artifact_name_retention_and_contents(self):
        upload = steps()[index(self.UPLOAD)]
        self.assertTrue(upload["uses"].startswith("actions/upload-artifact@"))
        self.assertEqual(upload["with"]["name"], "cmux-nightly-signed-unnotarized-${{ matrix.variant }}")
        self.assertEqual(upload["with"]["retention-days"], 7)
        self.assertEqual(upload["with"]["if-no-files-found"], "error")
        # ditto keeps the bundle's symlinks and signature intact; the copy is
        # the app as Codesign apps left it.
        self.assertIn('ditto -c -k --sequesterRsrc --keepParent "$app"', CHECKS.read_text())
        self.assertIn('ditto "$app" "$copy"', CHECKS.read_text())

    def test_never_for_fast_notary_test_or_paused_builds(self):
        conditions = (
            steps()[index(self.START)]["env"]["PACKAGE_UNNOTARIZED_ZIP"],
            steps()[index(self.UPLOAD)]["if"],
        )
        for condition in conditions:
            self.assertIn("needs.decide.outputs.fast_build != 'true'", condition)
            self.assertIn("needs.decide.outputs.notary_test != 'true'", condition)
            self.assertIn("needs.decide.outputs.import_paused != 'true'", condition)
            # A submissions pause (Apple's queue stuck) is exactly when teammates need it.
            self.assertNotIn("notary_paused", condition)
        self.assertTrue(steps()[index(self.UPLOAD)].get("continue-on-error"))

    def test_fast_dogfood_upload_does_not_depend_on_notarization(self):
        condition = steps()[index("Upload fast arm64 dogfood artifact")]["if"]
        self.assertNotIn("notarize", condition)
        self.assertNotIn("notary", condition)


if __name__ == "__main__":
    unittest.main(verbosity=2)
