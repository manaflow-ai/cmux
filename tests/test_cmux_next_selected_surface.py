#!/usr/bin/env python3
"""check-selected-surface.py (design/selected-is-foreground.md): the tree passes, and the check
fails a selected style off the content surface, passes the token and an allow reason, and fails a
pending entry that is fixed."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts/cmux-next/check-selected-surface.py"


def run(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, "-I", str(CHECK), str(root)], capture_output=True, text=True)


class SelectedSurfaceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "webviews/src/ui").mkdir(parents=True)
        (self.root / "Packages/macOS/CmuxNext/Sources/CmuxNextDemo").mkdir(parents=True)
        (self.root / "schemas/selected-surface").mkdir(parents=True)
        self.pending({}, {})

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def pending(self, web: dict, native: dict) -> None:
        (self.root / "schemas/selected-surface/pending.json").write_text(json.dumps({"web": web, "native": native}))

    def css(self, text: str) -> None:
        (self.root / "webviews/src/ui/tabs.css").write_text(text)

    def swift(self, text: str) -> None:
        (self.root / "Packages/macOS/CmuxNext/Sources/CmuxNextDemo/Row.swift").write_text(text)

    def test_the_tree_passes(self) -> None:
        result = run(ROOT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_gray_selected_tab_fails(self) -> None:
        self.css('.tab[aria-selected="true"] { background: var(--ds-color-selection); }\n')
        result = run(self.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn("[web-selected]", result.stdout)

    def test_the_content_surface_token_passes(self) -> None:
        self.css('.tab[aria-selected="true"] { background: var(--ds-color-selected); }\n'
                 '.seg[data-active] { background-color: var(--cmux-selected-surface); }\n'
                 '.row:not([data-active]):hover { background: gray; }\n'
                 '.chip[data-checked] { background: transparent; }\n')
        self.assertEqual(run(self.root).returncode, 0)

    def test_an_allow_reason_passes(self) -> None:
        self.css('/* selected-surface-allow: a list cursor inside content */\n'
                 '.row.is-selected { background: var(--page-selection); }\n')
        self.assertEqual(run(self.root).returncode, 0)

    def test_a_pending_entry_passes_and_a_fixed_one_fails(self) -> None:
        self.css('.row.is-selected { background: var(--page-selection); }\n')
        self.pending({"webviews/src/ui/tabs.css": [".row.is-selected"]}, {})
        self.assertEqual(run(self.root).returncode, 0)
        self.css('.row.is-selected { background: var(--ds-color-selected); }\n')
        result = run(self.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn("[stale-pending]", result.stdout)

    def test_a_native_gray_selection_fails_and_the_token_passes(self) -> None:
        self.swift("paintFill(isSelected ? Palette.selectionFill : nil)\n")
        result = run(self.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn("[native-selected]", result.stdout)
        self.swift("paintFill(isSelected ? Palette.selectedSurface : nil)\n")
        self.assertEqual(run(self.root).returncode, 0)
        self.swift("// selected-surface-allow: a floating overlay's cursor\npaintFill(isSelected ? Palette.selectionFill : nil)\n")
        self.assertEqual(run(self.root).returncode, 0)


if __name__ == "__main__":
    unittest.main()
