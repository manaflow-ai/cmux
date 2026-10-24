"""The scheduled nightly-next canary runs the app a person runs: copied out of the DMG.

Launched straight from the read-only, compressed DMG mount, a cold start pages the whole bundle
through hdiutil: on hosted runners the control socket took over 45 s to appear and the first
calls then missed the app's 2 s deadline, so every scheduled canary failed on good builds
(#22648) while the same build passed from local disk in nightly.yml's pre-publication canary.
"""

import pathlib
import re
import unittest

WORKFLOW = pathlib.Path(__file__).resolve().parents[1] / ".github/workflows/nightly-next-canary.yml"


def step(text: str, name: str) -> str:
    match = re.search(rf"^      - name: {re.escape(name)}\n(.*?)(?=^      - name: |\Z)", text, re.M | re.S)
    if not match:
        raise AssertionError(f"no step {name!r}")
    return match.group(1)


class CanaryRunsTheInstalledApp(unittest.TestCase):
    def setUp(self) -> None:
        self.text = WORKFLOW.read_text(encoding="utf-8")
        self.check = step(self.text, "Check Gatekeeper and the notary tickets")

    def test_the_app_output_is_a_copy_on_local_disk_not_the_mount(self) -> None:
        outputs = re.findall(r'echo "app=([^"]*)" >> "\$GITHUB_OUTPUT"', self.check)
        self.assertEqual(outputs, ["$installed"])
        self.assertRegex(self.check, r'installed="\$RUNNER_TEMP/canary-app/')
        self.assertNotIn("canary-mount", self.check.split('installed="', 1)[1].split("\n", 1)[0])

    def test_the_copy_is_made_with_ditto_and_passes_gatekeeper_itself(self) -> None:
        copy = self.check.index('ditto "$app" "$installed"')
        self.assertLess(self.check.index('spctl -a -vv --type execute "$app"'), copy)
        self.assertGreater(self.check.index('spctl -a -vv --type execute "$installed"'), copy)
        self.assertGreater(self.check.index('codesign --verify --deep --strict "$installed"'), copy)

    def test_the_canary_launches_the_app_output_and_never_the_mount(self) -> None:
        run = step(self.text, "Run the canary")
        self.assertIn("APP: ${{ steps.app.outputs.app }}", run)
        self.assertNotIn("canary-mount", run)


if __name__ == "__main__":
    unittest.main()
