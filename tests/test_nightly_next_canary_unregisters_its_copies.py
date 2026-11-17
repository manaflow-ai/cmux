"""The nightly-next canary takes its app copies back from LaunchServices before they go.

LaunchServices keeps a record of every app bundle a job copies or runs after RUNNER_TEMP is
emptied. A later `open -a "cmux NIGHTLY"` or bundle-id lookup on the same Mac then picked a
dead copy (_temp/canary-app, _temp/canary-mount): eleven "The application "cmux NIGHTLY"
can't be opened." alerts on capture mini cmux12s, 2026-11-16.
"""

import pathlib
import re
import unittest

WORKFLOW = pathlib.Path(__file__).resolve().parents[1] / ".github/workflows/nightly-next-canary.yml"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def step(text: str, name: str) -> tuple[str, str]:
    match = re.search(rf"^      - name: {re.escape(name)}\n(.*?)(?=^      - name: |^  \S|\Z)", text, re.M | re.S)
    if not match:
        raise AssertionError(f"no step {name!r}")
    return match.group(0), match.group(1)


class CanaryUnregistersItsCopies(unittest.TestCase):
    def setUp(self) -> None:
        self.text = WORKFLOW.read_text(encoding="utf-8")
        self.whole, self.body = step(self.text, "Detach the DMG and unregister the app copies")

    def test_cleanup_runs_whenever_the_copy_step_ran(self) -> None:
        self.assertIn("if: always() && steps.app.outcome != 'skipped'", self.body)

    def test_every_app_under_both_copies_is_unregistered_by_path(self) -> None:
        self.assertIn(f"lsregister={LSREGISTER}", self.body)
        self.assertIn('for root in "$RUNNER_TEMP/canary-app" "$RUNNER_TEMP/canary-mount"; do', self.body)
        self.assertIn("find \"$root\" -type d -name '*.app'", self.body)
        self.assertIn('"$lsregister" -u "$bundle"', self.body)

    def test_unregister_comes_before_the_copy_is_removed_and_the_dmg_detached(self) -> None:
        unregister = self.body.index('"$lsregister" -u')
        self.assertLess(unregister, self.body.index('rm -rf "$RUNNER_TEMP/canary-app"'))
        self.assertLess(unregister, self.body.index('hdiutil detach "$RUNNER_TEMP/canary-mount"'))

    def test_no_step_opens_the_app_by_name(self) -> None:
        self.assertNotRegex(self.text, r"open\s+(-[a-zA-Z]+\s+)*-[ab]\s")


if __name__ == "__main__":
    unittest.main()
