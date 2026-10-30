#!/usr/bin/env python3
"""pr_design_spec_check warns, never fails, when a PR changes a UI surface without citing its design spec."""
from __future__ import annotations

import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import pr_design_spec_check as check  # noqa: E402

QMM = "webviews/src/agent-session/acpmux/QuickModelMenu.tsx"
SURFACES = {
    "model-picker": {"spec": "leo-workspace design/model-picker.md", "paths": [QMM, "webviews/x/modelPicker.css"]},
    "sidebar": {"spec": "leo-workspace design/sidebar.md", "paths": ["Packages/Sidebar/"]},
}


class Check(unittest.TestCase):
    def test_a_changed_surface_without_its_spec_is_warned(self):
        uncited, gone = check.check(SURFACES, [QMM, "README.md"], "Fix the picker.")
        self.assertEqual(len(uncited), 1)
        self.assertIn("model-picker surface", uncited[0])
        self.assertIn("design/model-picker.md", uncited[0])
        self.assertEqual(gone, [])

    def test_citing_the_spec_in_any_form_clears_it(self):
        for body in ("Spec: leo-workspace `design/model-picker.md`.", "Follows MODEL-PICKER.md",
                     "https://github.com/o/leo-workspace/blob/main/design/model-picker.md"):
            self.assertEqual(check.check(SURFACES, [QMM], body)[0], [], body)
        # a different spec's name does not count
        self.assertEqual(len(check.check(SURFACES, [QMM], "see sidebar.md and old-model-picker.md")[0]), 1)

    def test_directories_own_what_is_under_them(self):
        uncited, _ = check.check(SURFACES, ["Packages/Sidebar/Row.swift", "Packages/SidebarActions/A.swift"], "")
        self.assertEqual(len(uncited), 1)
        self.assertIn("sidebar surface (Packages/Sidebar/Row.swift)", uncited[0])

    def test_unrelated_changes_and_spec_changes_pass(self):
        self.assertEqual(check.check(SURFACES, ["docs/x.md"], ""), ([], []))
        local = {"s": {"spec": "design/s.md", "paths": ["src/s.ts"]}}
        self.assertEqual(check.check(local, ["src/s.ts", "design/s.md"], "")[0], [])

    def test_mapped_paths_that_are_gone_are_warned(self):
        _, gone = check.check(SURFACES, [], "", tree={QMM, "Packages/Sidebar/Row.swift"})
        self.assertEqual(len(gone), 1)
        self.assertIn("webviews/x/modelPicker.css", gone[0])

    def test_the_repository_map_is_valid_and_every_path_exists(self):
        surfaces = check.load_map(ROOT / ".github" / "design-surfaces.json")
        self.assertIn("model-picker", surfaces)
        self.assertIn(QMM, surfaces["model-picker"]["paths"])
        for name, s in surfaces.items():
            self.assertRegex(s["spec"], r"design/[a-z0-9-]+\.md$", name)
            for p in s["paths"]:
                self.assertTrue((ROOT / p).exists(), f"{name}: {p} does not exist")

    def test_main_never_fails_on_findings(self):
        with tempfile.TemporaryDirectory() as d:
            m, body, paths = Path(d, "m.json"), Path(d, "b.md"), Path(d, "p.txt")
            m.write_text(json.dumps({"surfaces": SURFACES}))
            body.write_text("no spec here")
            paths.write_text(QMM + "\n")
            out = io.StringIO()
            with redirect_stdout(out):
                code = check.main(["--body-file", str(body), "--paths-file", str(paths), "--map", str(m)])
            self.assertEqual(code, 0)
            self.assertIn("::warning title=Design spec::", out.getvalue())
            m.write_text("{}")
            with redirect_stdout(io.StringIO()):
                self.assertEqual(check.main(["--body-file", str(body), "--paths-file", str(paths), "--map", str(m)]), 2)

    def test_the_workflow_only_warns_and_runs_the_base_script(self):
        wf = (ROOT / ".github" / "workflows" / "pr-design-spec-check.yml").read_text()
        self.assertIn("continue-on-error: true", wf)
        self.assertIn("ref: ${{ github.event.pull_request.base.ref }}", wf)
        self.assertIn("|| true", wf)
        self.assertIn("permissions: {}", wf)
        self.assertNotIn("pull_request_target", wf)


if __name__ == "__main__":
    unittest.main()
