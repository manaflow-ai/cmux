"""The advisory UI-review section check for webview changes."""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ui_review_advisory.py"
spec = importlib.util.spec_from_file_location("ui_review_advisory", SCRIPT)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


class UiReviewAdvisoryTests(unittest.TestCase):
    def test_only_webview_css_and_tsx_paths_are_ui_changes(self):
        files = [
            {"filename": "webviews/src/ui/Button.tsx"},
            {"filename": "webviews/src/ui/button.css"},
            {"filename": "webviews/src/ui/Button.test.ts"},
            {"filename": "webviews/README.md"},
            {"filename": "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home.swift"},
        ]
        self.assertEqual(module.ui_files(files), ["webviews/src/ui/Button.tsx", "webviews/src/ui/button.css"])

    def test_heading_and_verdict_are_required_only_when_ui_paths_change(self):
        files = [{"filename": "webviews/src/ui/Button.tsx"}]
        self.assertEqual(module.inspect("## Summary", files)["missing"], ["the `## UI review` heading", "a `Verdict:` line"])
        self.assertEqual(module.inspect("## UI review\nVerdict: ship it", files)["missing"], [])
        self.assertEqual(module.inspect("", [{"filename": "docs/ui.md"}])["missing"], [])

    def test_cli_is_advisory_and_never_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            body = root / "body.md"
            files = root / "files.json"
            body.write_text("", encoding="utf-8")
            files.write_text(json.dumps([{"filename": "webviews/src/pages/Home.tsx"}]), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--body-file", str(body), "--files-json", str(files)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("::warning", result.stdout)


if __name__ == "__main__":
    unittest.main()
