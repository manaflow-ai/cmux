#!/usr/bin/env python3
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
import base_red_skip as m  # noqa: E402

LOG = ("2026-11-23T22:00:00.1Z /Users/runner/work/cmux/cmux/Packages/macOS/CmuxNext/Tests/CmuxNextTests/"
       "TunableReadCadenceTests.swift:12:3: error: no such module 'CmuxNextBrowser'\n"
       "2026-11-23T22:00:01Z warning: /x/Other.swift:3: unrelated warning\n")
NAMED = {"Users/runner/work/cmux/cmux/Packages/macOS/CmuxNext/Tests/CmuxNextTests/TunableReadCadenceTests.swift"}


class BaseRedSkip(unittest.TestCase):
    def test_paths_from_error_lines_only(self):
        self.assertEqual(m.swift_paths(LOG), NAMED)

    def test_unrelated_change_does_not_touch(self):
        self.assertIsNone(m.touches(["docs/a.md", "web/x.ts", "Packages/macOS/CmuxNext/Sources/Other/A.swift"], NAMED))

    def test_fix_touches(self):
        f = "Packages/macOS/CmuxNext/Tests/CmuxNextTests/TunableReadCadenceTests.swift"
        self.assertEqual(m.touches([f], NAMED), f)

    def test_same_target_folder_and_manifest_and_plumbing_touch(self):
        for f in ("Packages/macOS/CmuxNext/Tests/CmuxNextTests/New.swift",
                  "Packages/macOS/CmuxNext/Tests/CmuxNextTests/sub/New.swift",
                  "Packages/macOS/CmuxNext/Package.swift", "scripts/ci/x.py", ".github/workflows/cmux-next.yml"):
            self.assertEqual(m.touches([f], NAMED), f)

    def test_full_ci_label_and_kill_switch_fail_open(self):
        self.assertEqual(m.decide([], "a" * 40, "feat-cmux-next", "full-ci")[0], [])


if __name__ == "__main__":
    unittest.main()
