#!/usr/bin/env python3
"""The classic API guard fails a main PR that changes classic's auto-deployed API without a reason."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "classic_api_guard.py"
CONFIG = ROOT / "scripts" / "ci" / "classic-auto-deploy.json"
WORKFLOW = ROOT / ".github" / "workflows" / "classic-api-guard.yml"

spec = importlib.util.spec_from_file_location("classic_api_guard", ROOT / "scripts" / "ci" / "classic_api_guard.py")
assert spec and spec.loader
guard = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = guard
spec.loader.exec_module(guard)

CFG = guard.load_config(CONFIG)


class ClassicApiGuardTests(unittest.TestCase):
    def test_main_api_change_without_reason_fails(self) -> None:
        code, lines = guard.check(CFG, "main", "## Summary\nfix\n", ["web/app/api/vm/route.ts"])
        self.assertEqual(code, 1)
        self.assertTrue(any("vercel-cmux-com" in line for line in lines))

    def test_main_api_change_with_reason_passes(self) -> None:
        body = "## Summary\n\nClassic API change: customers hit a 500 on /api/vm\n"
        code, lines = guard.check(CFG, "main", body, ["web/services/vms/workflows.ts"])
        self.assertEqual(code, 0)
        self.assertIn("customers hit a 500", lines[0])

    def test_placeholder_reason_does_not_count(self) -> None:
        code, _ = guard.check(CFG, "main", "Classic API change: <reason>\n", ["web/db/schema.ts"])
        self.assertEqual(code, 1)

    def test_empty_reason_does_not_swallow_the_next_line(self) -> None:
        body = "Classic API change:\n\n## Testing\npython3 tests.py\n"
        code, _ = guard.check(CFG, "main", body, ["web/app/api/vm/route.ts"])
        self.assertEqual(code, 1)

    def test_feat_cmux_next_only_warns(self) -> None:
        code, lines = guard.check(CFG, "feat-cmux-next", "", ["web/app/api/vm/route.ts"])
        self.assertEqual(code, 0)
        self.assertTrue(lines[0].startswith("::warning::"))

    def test_unguarded_and_excluded_paths_pass(self) -> None:
        paths = [
            "web/scripts/cloud-vm/smoke-vm-api.mjs",
            "web/tests/vm-idle-pause.test.ts",
            "web/messages/en.json",
            "web/app/[locale]/components/site-footer.tsx",
            "web/services/vms/README.md",
            "workers/fleet-artifacts/src/index.ts",
            "Sources/AppDelegate.swift",
        ]
        code, lines = guard.check(CFG, "main", "", paths)
        self.assertEqual(code, 0, lines)

    def test_relays_only_dry_run_on_push_so_are_not_guarded(self) -> None:
        for path in ("workers/iroh-v2/src/index.ts", "cmux-tui/relays/cloudflare-do/src/lib.rs"):
            code, _ = guard.check(CFG, "main", "", [path])
            self.assertEqual(code, 0, path)

    def test_api_data_inputs_are_guarded(self) -> None:
        for path in ("web/data/mobile-mac-compat.ts", "web/data/agent-models.ts"):
            code, _ = guard.check(CFG, "main", "", [path])
            self.assertEqual(code, 1, path)

    def test_truncated_listing_fails_into_main(self) -> None:
        code, _ = guard.check(CFG, "main", "", ["Sources/A.swift"], expected_files=3500)
        self.assertEqual(code, 1)
        code, _ = guard.check(CFG, "main", "Classic API change: big refactor\n", ["Sources/A.swift"], expected_files=3500)
        self.assertEqual(code, 0)
        code, _ = guard.check(CFG, "feat-cmux-next", "", ["Sources/A.swift"], expected_files=3500)
        self.assertEqual(code, 0)
        code, _ = guard.check(CFG, "main", "", ["Sources/A.swift"], expected_files=1)
        self.assertEqual(code, 0)

    def test_glob_semantics(self) -> None:
        self.assertTrue(guard.glob_regex("web/app/api/**").match("web/app/api/a/b.ts"))
        self.assertFalse(guard.glob_regex("web/app/*.ts").match("web/app/x/y.ts"))
        self.assertTrue(guard.glob_regex("**/*.md").match("web/services/vms/README.md"))
        self.assertTrue(guard.glob_regex("**/*.md").match("README.md"))

    def test_cli_exit_code(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            body = Path(tmp, "body.md")
            body.write_text("no reason here")
            paths = Path(tmp, "paths.txt")
            paths.write_text("web/app/handler/after-sign-in/handler.ts\n")
            self.assertEqual(guard.main(["--base", "main", "--body-file", str(body), "--paths-file", str(paths)]), 1)
            body.write_text("Classic API change: sign-in fix for cmux.com users\n")
            self.assertEqual(guard.main(["--base", "main", "--body-file", str(body), "--paths-file", str(paths)]), 0)

    def test_config_is_well_formed(self) -> None:
        data = json.loads(CONFIG.read_text())
        ids = [d["id"] for d in data["deploys"]]
        self.assertEqual(len(ids), len(set(ids)))
        for deploy in data["deploys"]:
            for key in ("id", "branch", "trigger", "target", "guarded", "paths"):
                self.assertIn(key, deploy, deploy.get("id"))
        self.assertTrue(any(d["guarded"] for d in data["deploys"]))

    def test_renames_do_not_hide_a_truncated_listing(self) -> None:
        paths = [f"Sources/F{i}.swift" for i in range(3000)] + ["Sources/Old.swift"]
        code, _ = guard.check(CFG, "main", "", paths, expected_files=3001, listed_records=3000)
        self.assertEqual(code, 1)

    def test_build_inputs_the_ignore_script_names_are_guarded(self) -> None:
        for path in ("workers/presence/src/generated/managedRelayCatalog.ts", "web/data/model-catalog/snapshot.json"):
            code, _ = guard.check(CFG, "main", "", [path])
            self.assertEqual(code, 1, path)

    def test_workflow_runs_the_base_copy_on_both_bases(self) -> None:
        text = WORKFLOW.read_text()
        self.assertIn("branches: [main, feat-cmux-next]", text)
        self.assertIn("edited", text)
        self.assertNotIn("changes.body", text)
        self.assertIn("--expected-files", text)
        self.assertIn("--listed-records", text)
        self.assertIn("grep -q -- '--listed-records' scripts/ci/classic_api_guard.py", text)
        self.assertIn("ref: ${{ github.event.pull_request.base.sha }}", text)
        self.assertIn("scripts/ci/classic_api_guard.py", text)
        self.assertNotIn("pull_request_target", text)


if __name__ == "__main__":
    unittest.main()
