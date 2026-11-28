#!/usr/bin/env python3
"""Tests for reduce-motion-audit.py on a made-up tree: what counts as an ungated animation, and what does not."""
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("audit", Path(__file__).with_name("reduce-motion-audit.py"))
audit = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(audit)


class Audit(unittest.TestCase):
    def tree(self, files: dict[str, str]) -> Path:
        root = Path(tempfile.mkdtemp())
        for rel, text in files.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(text)
        return root

    def test_web_counts_script_motion_in_files_that_never_read_the_reduce_state(self):
        root = self.tree({
            "webviews/src/a.ts": "box.animate([{ height: 0 }], t);\nel.scrollTo({ behavior: \"smooth\" });\n",
            "webviews/src/b.ts": "if (isAgentMotionOff()) return;\nbox.animate([{ opacity: 0 }], t);\n",
            "webviews/src/c.ts": "// motion: allow a dwell ramp the pointer drives\nbox.animate({ opacity: [0, 1] }, t);\n",
            "webviews/src/d.test.ts": "box.animate([{ height: 0 }], t);\n",
            "webviews/src/e.css": "a { transition: transform 1s; }\n",
            "webviews/src/f.ts": "if (!foldMoves(doc)) return;\nbox.animate([{ height: 0 }], t);\n",
        })
        got = audit.ungated(root, audit.WEB_DIRS, audit.WEB_SUFFIXES, audit.WEB_SITE, audit.WEB_GATE)
        self.assertEqual((got["sites"], got["files"]), (2, 1))
        self.assertEqual([w["line"] for w in got["where"]], [1, 2])

    def test_ios_counts_animation_calls_in_files_that_never_read_reduce_motion(self):
        root = self.tree({
            "cmux-next-ios/Kit/Sources/Home.swift": "UIView.animate(withDuration: 0.2) { v.alpha = 0 }\n",
            # The classic app is frozen and not counted.
            "ios/App/Sources/Home.swift": "UIView.animate(withDuration: 0.2) { v.alpha = 0 }\n",
            "Packages/iOS/Kit/Sources/Row.swift": "guard !UIAccessibility.isReduceMotionEnabled else { return }\n"
                                                  "UIView.animate(withDuration: 0.2) {}\n",
            "Packages/iOS/Kit/Tests/RowTests.swift": "UIView.animate(withDuration: 0.2) {}\n",
            "Packages/iOS/Kit/Sources/Shape.swift": "let a = layer.animation(forKey: \"path\")\n",
            "cmux-next-ios/Kit/Sources/List.swift": "HomeMotion.animate { v.alpha = 0 }\n",
            "Packages/iOS/Tabs/Sources/Bar.swift": "withAnimation(theme.motion.resolve(theme.motion.collapse)) {}\n",
        })
        got = audit.ungated(root, audit.IOS_DIRS, (".swift",), audit.IOS_SITE, audit.IOS_GATE)
        self.assertEqual([w["file"] for w in got["where"]], ["cmux-next-ios/Kit/Sources/Home.swift"])

    def test_a_tree_without_the_macos_check_has_no_total(self):
        report = audit.audit(self.tree({"webviews/src/a.ts": ""}))
        self.assertIn("error", report["macos"])
        self.assertIsNone(report["total"])


if __name__ == "__main__":
    unittest.main()
