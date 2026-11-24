"""The advisory UI-review section check for webview changes."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ui_review_advisory.py"
spec = importlib.util.spec_from_file_location("ui_review_advisory", SCRIPT)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


class UiReviewAdvisoryTests(unittest.TestCase):
    def test_workflow_warns_when_base_script_is_missing_or_crashes(self):
        # The ui-review step of the step table (ci/steps.toml), which pr-checks.yml's advisory job runs from the
        # base checkout (CI v2 step 6). The changed paths come from git, or the files API when git cannot list them.
        import tomllib

        command = tomllib.loads((ROOT / "ci/steps.toml").read_text())["step"]["ui-review"]["run"]
        workflow = yaml.safe_load((ROOT / ".github/workflows/pr-checks.yml").read_text())
        steps = workflow["jobs"]["advisory"]["steps"]
        self.assertTrue(next(step for step in steps if step.get("id") == "checkout")["continue-on-error"])
        self.assertIn("scripts/ci/ui_review_advisory.py",
                      next(step for step in steps if step.get("id") == "checkout")["with"]["sparse-checkout"])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            # No git history and a files API that lists one webview file.
            (bin_dir / "gh").write_text("#!/bin/sh\necho webviews/src/a.tsx\n")
            (bin_dir / "gh").chmod(0o755)
            env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "RUNNER_TEMP": str(root),
                   "BODY": "", "MERGE_SHA": "0" * 40, "HEAD_SHA": "1" * 40, "REPOSITORY": "o/r", "PR": "1",
                   "GIT_DIR": str(root / "no-repo")}
            cases = (("missing", None, "the advisory script is not present"),
                     ("crashes", "raise RuntimeError('script failure')\n", "could not run"),
                     ("warns", SCRIPT.read_text(), "UI review"))
            for name, text, expected in cases:
                with self.subTest(script=name):
                    if text is not None:
                        script = root / "scripts/ci/ui_review_advisory.py"
                        script.parent.mkdir(parents=True, exist_ok=True)
                        script.write_text(text)
                    result = subprocess.run(
                        ["bash", "-euo", "pipefail", "-c", command], cwd=root, capture_output=True, text=True, env=env,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("::warning", result.stdout)
                    self.assertIn(expected, result.stdout)
            # Neither git nor the API can list the files: a warning, and the step passes.
            (bin_dir / "gh").write_text("#!/bin/sh\nexit 1\n")
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", command], cwd=root, capture_output=True,
                                    text=True, env=env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("::warning title=UI review::could not check out the advisory or read changed files",
                          result.stdout)

    def test_webview_and_native_cmuxnext_paths_are_ui_changes(self):
        files = [
            {"filename": "webviews/src/ui/Button.tsx"},
            {"filename": "webviews/src/ui/button.css"},
            {"filename": "webviews/src/ui/Button.test.ts"},
            {"filename": "webviews/README.md"},
            {"filename": "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home.swift"},
        ]
        self.assertEqual(module.ui_files(files), [
            "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home.swift",
            "webviews/src/ui/Button.tsx",
            "webviews/src/ui/button.css",
        ])

    def test_heading_and_verdict_are_required_only_when_ui_paths_change(self):
        files = [{"filename": "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home.swift"}]
        self.assertEqual(module.inspect("## Summary", files)["missing"],
                         ["the `## UI review` heading", "a `Verdict:` line", "a `Try:` line"])
        self.assertEqual(module.inspect("## UI review\nVerdict: ship it", files)["missing"], ["a `Try:` line"])
        self.assertEqual(module.inspect("## UI review\nVerdict: ship it\nTry: `scripts/cmux-next/try-pr.sh 12`",
                                        files)["missing"], [])
        self.assertEqual(module.inspect("## UI review\nVerdict: ship it\nTry: none, iOS only", files)["missing"], [])
        self.assertEqual(module.inspect("## UI review\nVerdict: ship it\nTry:", files)["missing"], ["a `Try:` line"])
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
            # The warning names this pull request's own try command.
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--body-file", str(body), "--files-json", str(files), "--pr", "4321"],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("Try: `cmux app try 4321`", result.stdout)

    def test_with_try_line_adds_only_to_a_ui_change_without_one(self):
        ui = [{"filename": "webviews/src/chat/Composer.tsx"}]
        added = module.with_try_line("## Summary\nA fix.\n", ui, "50041")
        self.assertTrue(added.startswith("## Summary\nA fix.\n\n"))
        self.assertIn("Try: `cmux app try 50041`", added)
        self.assertIn(module.ADDED_MARK, added)
        self.assertRegex(added, module.TRY)
        # Adding is idempotent: the line it wrote counts as present.
        self.assertIsNone(module.with_try_line(added, ui, "50041"))
        self.assertIsNone(module.with_try_line("A fix.", [{"filename": "docs/ui.md"}], "1"))
        self.assertIsNone(module.with_try_line("Try: none, iOS only", ui, "1"))
        self.assertIsNone(module.with_try_line("Open it with `cmux app try 9`.", ui, "9"))
        self.assertIn("Try: `cmux app try 7`", module.with_try_line(None, ui, "7"))

    def test_add_try_line_reads_the_live_body_and_keeps_an_edit(self):
        ui = [{"filename": "webviews/src/chat/Composer.tsx"}]
        calls = []

        def fake_gh(*args, stdin=None):
            calls.append((args, stdin))
            return json.dumps({"body": "edited since the event"}) if args[-1] == "repos/o/r/pulls/5" else "{}"

        original = module.gh
        module.gh = fake_gh
        try:
            self.assertEqual(module.add_try_line("o/r", "5", ui, "Try: none, x"), "try line: not needed")
            self.assertEqual(calls, [])
            self.assertIn("added", module.add_try_line("o/r", "5", ui, "old body"))
            written = json.loads(calls[-1][1])["body"]
            self.assertTrue(written.startswith("edited since the event"))
            self.assertIn("Try: `cmux app try 5`", written)
        finally:
            module.gh = original

    def test_template_carries_the_try_line(self):
        template = (ROOT / ".github/pull_request_template.md").read_text()
        self.assertRegex(template, module.TRY)


if __name__ == "__main__":
    unittest.main()
