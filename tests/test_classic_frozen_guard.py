#!/usr/bin/env python3
"""The classic-frozen guard fails a PR that changes a classic-frozen path unless it carries `classic-migration`."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "classic_frozen_guard.py"
MANIFEST = ROOT / ".github" / "classic-frozen.txt"
WORKFLOW = ROOT / ".github" / "workflows" / "classic-frozen-guard.yml"

spec = importlib.util.spec_from_file_location("classic_frozen_guard", SCRIPT)
assert spec and spec.loader
guard = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = guard
spec.loader.exec_module(guard)

RULES = guard.load(MANIFEST)


class ClassicFrozenGuardTests(unittest.TestCase):
    def test_classic_api_into_next_fails(self) -> None:
        code, lines = guard.check(RULES, "feat-cmux-next", [], ["web/app/api/vm/route.ts"])
        self.assertEqual(code, 1)
        self.assertIn("web/app/api/vm/route.ts", lines[0])
        self.assertIn("classic-migration", lines[-1])

    def test_runs_and_db_are_frozen_everywhere(self) -> None:
        for base in ("feat-cmux-next", "main"):
            for path in ("web/services/runs/model.ts", "web/db/schema.ts", "web/app/api/runs/route.ts"):
                code, _ = guard.check(RULES, base, [], [path])
                self.assertEqual(code, 1, (base, path))

    def test_label_lets_it_through(self) -> None:
        code, lines = guard.check(RULES, "main", ["classic-migration"], ["web/app/api/vm/route.ts"])
        self.assertEqual(code, 0)
        self.assertTrue(lines[0].startswith("::notice::classic-migration"))

    def test_next_devbox_image_and_docs_stay_open_on_next(self) -> None:
        paths = [
            "web/services/vms/images/devbox/setup.sh",
            "web/scripts/build-devbox-freestyle.ts",
            "web/data/next-docs/cloud.mdx",
            ".github/workflows/cloud-vm-dogfood.yml",
            "Packages/macOS/CmuxNext/Sources/CmuxNextCloud/CloudAPIClient.swift",
            "backend/apps/api/src/index.ts",
            "workers/cmux-vm/src/index.ts",
        ]
        code, lines = guard.check(RULES, "feat-cmux-next", [], paths)
        self.assertEqual(code, 0, lines)

    def test_all_of_web_and_the_classic_image_are_frozen_into_main(self) -> None:
        for path in ("web/services/vms/images/devbox/setup.sh", "web/scripts/build-devbox-freestyle.ts",
                     "web/data/next-docs/cloud.mdx", ".github/workflows/cloud-vm-canary.yml"):
            code, _ = guard.check(RULES, "main", [], [path])
            self.assertEqual(code, 1, path)

    def test_the_manifest_and_its_check_freeze_themselves(self) -> None:
        for path in (".github/classic-frozen.txt", ".github/workflows/classic-frozen-guard.yml",
                     "scripts/ci/classic_frozen_guard.py"):
            code, _ = guard.check(RULES, "feat-cmux-next", [], [path])
            self.assertEqual(code, 1, path)

    def test_short_listing_fails_without_the_label(self) -> None:
        code, lines = guard.check(RULES, "feat-cmux-next", [], ["README.md"], expected_files=3001, listed_records=3000)
        self.assertEqual(code, 1)
        self.assertIn("past its end", lines[0])
        code, _ = guard.check(RULES, "feat-cmux-next", ["classic-migration"], ["README.md"], 3001, 3000)
        self.assertEqual(code, 0)

    def test_malformed_line_refuses(self) -> None:
        with self.assertRaises(ValueError):
            guard.parse("web/app/api/** everywhere reason\n")
        with self.assertRaises(ValueError):
            guard.parse("# only comments\n")

    def test_cli_reads_labels_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            paths = Path(tmp) / "paths.txt"
            paths.write_text("web/app/api/vm/route.ts\n")
            args = ["--base", "feat-cmux-next", "--paths-file", str(paths), "--manifest", str(MANIFEST)]
            self.assertEqual(guard.main(args + ["--labels-json", '["ci"]']), 1)
            self.assertEqual(guard.main(args + ["--labels-json", '["classic-migration"]']), 0)
            self.assertEqual(guard.main(args + ["--labels-json", "not json"]), 1)

    def test_workflow_runs_the_base_guard_on_label_changes(self) -> None:
        text = WORKFLOW.read_text()
        self.assertIn("ref: ${{ github.event.pull_request.base.sha }}", text)
        self.assertIn("labeled, unlabeled", text)
        self.assertIn("pull_request_target:", text)
        self.assertNotIn("\n  pull_request:", text)
        self.assertIn("branches: [main, feat-cmux-next]", text)
        self.assertIn("name: classic-frozen-guard", text)


if __name__ == "__main__":
    unittest.main()
