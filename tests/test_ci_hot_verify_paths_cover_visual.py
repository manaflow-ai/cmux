"""Every root cmux/ui-proof calls visual starts cmux-next-hot-verify.yml, so a held head always gets a look.

2026-11-28T12:12Z: 17 ready rows waited on `land-judge: ui_proof`; 13 were Swift-only (Packages/macOS/, Native/),
and none of the 13 had a run of the hot verify workflow at any head. cmux#63712 taught the plan to look at a Swift
change with a fleet app build, but the workflow's `paths:` gate still named only the web and Rust layers, so the
pull request event never started it and nothing else requests the look. ui_proof_verdict.py posts `pending` for
these heads; the 6 h stale sweep then turns it into a failure no look can answer.
"""
import fnmatch, pathlib, sys, unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = ROOT / ".github/workflows/cmux-next-hot-verify.yml"
sys.path.insert(0, str(ROOT / "scripts/ci"))
import ui_proof_verdict  # noqa: E402


def started(path, patterns):
    """GitHub's paths filter: the last matching pattern wins, a `!` one excludes."""
    hit = False
    for p in patterns:
        neg = p.startswith("!")
        glob = p[1:] if neg else p
        # GitHub's `**` matches across `/`; fnmatch's `*` already does, so `**/x` must also match a top-level x.
        if fnmatch.fnmatchcase(path, glob) or (glob.startswith("**/") and fnmatch.fnmatchcase(path, glob[3:])):
            hit = not neg
    return hit


class PathsCoverVisual(unittest.TestCase):
    def setUp(self):
        doc = yaml.safe_load(WF.read_text())
        on = doc.get("on", doc.get(True))
        self.paths = on["pull_request"]["paths"]

    def test_every_visual_root_starts_the_look(self):
        for root in ui_proof_verdict.APP_VISUAL + ui_proof_verdict.WEB_VISUAL:
            sample = root + "Sources/X/View.swift" if root.endswith("/") else root.replace("*", "x")
            self.assertEqual(ui_proof_verdict.kind(sample) != "", True, sample)
            self.assertTrue(started(sample, self.paths), f"{sample} is visual but does not start the look")

    def test_the_held_rows_files_start_it(self):
        for path in ("Packages/macOS/CmuxNext/Sources/CmuxNextBrowserAutomation/FrameTree.swift",
                     "Native/OptChat/Sources/Chat.swift", "webviews/src/app.tsx"):
            self.assertTrue(started(path, self.paths), path)

    def test_prose_still_skips(self):
        self.assertFalse(started("Packages/macOS/CmuxNext/README.md", self.paths))


if __name__ == "__main__":
    unittest.main()
