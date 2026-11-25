#!/usr/bin/env python3
"""scripts/ci/desktop_visual_diff.py: this nightly's desktop visual-gate stills against the previous nightly's.

Tiny generated PNGs stand in for the stills, laid out the way capture_states.py writes them
(<state>/light.png, <state>/dark.png). Commit messages are injected; nothing reaches the network.
Run: python3 tests/test_desktop_visual_diff.py
"""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "desktop_visual_diff.py"
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_ios_gate_screen_diff import png  # noqa: E402


def load():
    spec = importlib.util.spec_from_file_location("desktop_visual_diff", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


MOD = load()
WHITE = (255, 255, 255, 255)
BLACK = (0, 0, 0, 255)


def still(color=WHITE, mark: int = 0) -> bytes:
    """A 10x10 still; MARK pixels of the first rows turn black (each is 1% of the still)."""
    pixels = [[color] * 10 for _ in range(10)]
    for i in range(mark):
        pixels[i // 10][i % 10] = BLACK
    return png(pixels)


def tree(root: Path, states: dict[str, bytes]) -> Path:
    for key, data in states.items():
        path = root / f"{key}.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return root


class DesktopVisualDiffTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.base = tree(self.root / "base", {
            "home/light": still(), "home/dark": still(),
            "settings/light": still(), "settings/dark": still(),
            "chat/light": still(), "chat/dark": still(),
            "gone/light": still(), "gone/dark": still(),
        })
        self.head = tree(self.root / "head" / "visual-gate", {
            "home/light": still(), "home/dark": still(),
            "settings/light": still(mark=30), "settings/dark": still(),
            "chat/light": still(mark=40), "chat/dark": still(mark=40),
            "brand-new/light": still(), "brand-new/dark": still(),
        })

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, messages: list[str] | None, baseline: Path | None = None) -> tuple[str, str]:
        out = self.root / "summary.md"
        out.write_text("earlier step\n")
        argv = ["--head-root", str(self.root / "head"), "--head-sha", "abcdef0123456789",
                "--baseline-root", str(baseline or self.base), "--baseline-sha", "01234567", "--out", str(out)]
        if messages is not None:
            path = self.root / "messages.json"
            path.write_text(json.dumps(messages))
            argv += ["--messages", str(path)]
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            self.assertEqual(MOD.main(argv), 0)
        text = out.read_text()
        self.assertTrue(text.startswith("earlier step\n"), "the summary is appended to, not replaced")
        return text, stdout.getvalue()

    def rows(self, messages: list[str]) -> dict[str, object]:
        rows, unchanged, _ = MOD.compare(self.root / "head", self.base, MOD.all_justifications(messages))
        self.assertEqual(unchanged, 3)  # home/light, home/dark, settings/dark
        return {row.key: row for row in rows}

    def test_unchanged_states_are_not_rows(self):
        rows = self.rows([])
        self.assertNotIn("home/light", rows)
        self.assertNotIn("settings/dark", rows)

    def test_changed_unjustified(self):
        rows = self.rows(["Fix a thing (#1)\n\nnothing visual here"])
        self.assertEqual(rows["settings/light"].kind, "changed")
        self.assertAlmostEqual(rows["settings/light"].ratio, 0.30)
        self.assertEqual(rows["settings/light"].box, (0, 0, 10, 3))
        self.assertIsNone(rows["settings/light"].why)

    def test_changed_justified_by_state_mode_and_glob(self):
        rows = self.rows([
            "Sidebar (#2)\n\nVisual-change: settings/light: the sidebar is wider",
            "PR body\n\nVisual-change: ch*: new chat header",
        ])
        self.assertEqual(rows["settings/light"].why, "the sidebar is wider")
        self.assertEqual(rows["chat/light"].why, "new chat header")
        self.assertEqual(rows["chat/dark"].why, "new chat header")

    def test_star_justifies_everything(self):
        rows = self.rows(["Visual-change: *: theme refresh"])
        self.assertTrue(all(row.why == "theme refresh" for row in rows.values()))

    def test_new_and_removed_states(self):
        rows = self.rows([])
        self.assertEqual(rows["brand-new/light"].kind, "new")
        self.assertEqual(rows["brand-new/dark"].kind, "new")
        self.assertEqual(rows["gone/light"].kind, "removed")
        self.assertEqual(rows["gone/dark"].kind, "removed")

    def test_fenced_example_justifies_nothing(self):
        rows = self.rows(["Docs (#3)\n\n```\nVisual-change: *: an example\n```\n"])
        self.assertTrue(all(row.why is None for row in rows.values()))

    def test_report_and_one_warning_when_unjustified(self):
        text, stdout = self.run_main(["Visual-change: chat: new chat header"])
        self.assertIn("### Desktop states vs the previous nightly", text)
        self.assertIn("| `chat/light` | changed | 40.00% |", text)
        self.assertIn("justified: new chat header", text)
        self.assertIn("| `settings/light` | changed | 30.00% |", text)
        self.assertIn("with no Visual-change line", text)
        warnings = [line for line in stdout.splitlines() if line.startswith("::warning")]
        self.assertEqual(len(warnings), 1)
        self.assertIn("settings/light", warnings[0])
        self.assertNotIn("chat/light", warnings[0])
        self.assertNotIn("@", text + stdout, "nobody is mentioned")

    def test_no_warning_when_all_justified(self):
        text, stdout = self.run_main(["Visual-change: *: theme refresh"])
        self.assertIn("each with a Visual-change line", text)
        self.assertNotIn("::warning", stdout)

    def test_no_baseline(self):
        empty = self.root / "empty"
        empty.mkdir()
        text, stdout = self.run_main([], baseline=empty)
        self.assertIn("No baseline", text)
        self.assertNotIn("::warning", stdout)

    def test_no_head_capture(self):
        out = self.root / "summary.md"
        with redirect_stdout(io.StringIO()):
            self.assertEqual(MOD.main(["--head-root", str(self.root / "missing"), "--baseline-root",
                                       str(self.base), "--messages", "/nonexistent", "--out", str(out)]), 0)
        self.assertIn("captured no states", out.read_text())

    def test_fetch_without_token_reports_and_exits_zero(self):
        out = self.root / "summary.md"
        env = {k: MOD.os.environ.pop(k) for k in ("GH_TOKEN", "GITHUB_TOKEN") if k in MOD.os.environ}
        try:
            with redirect_stdout(io.StringIO()):
                self.assertEqual(MOD.main(["--head-root", str(self.root / "head"), "--fetch-baseline",
                                           "--repo", "o/r", "--out", str(out)]), 0)
        finally:
            MOD.os.environ.update(env)
        self.assertIn("no GitHub token", out.read_text())

    def test_extract_keeps_only_stills(self):
        archive = self.root / "a.zip"
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("home/light.png", still())
            z.writestr("home/result.json", "{}")
            z.writestr("../evil/dark.png", still())
            z.writestr("report.md", "x")
        dest = MOD._extract_stills(archive, self.root / "x")
        self.assertEqual(sorted(MOD.load_states(dest)), ["evil/dark", "home/light"])
        self.assertFalse((self.root / "evil").exists())


if __name__ == "__main__":
    unittest.main()
