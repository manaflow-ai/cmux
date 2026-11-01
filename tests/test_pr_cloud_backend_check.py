#!/usr/bin/env python3
"""pr_cloud_backend_check warns, never fails, when a PR adds cloud backend code to cmux instead of cmux-platform."""
from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import pr_cloud_backend_check as check  # noqa: E402

BACKEND = ["backend/apps/api", "web/services", "workers/cmux-vm"]
STAYS = ["workers/cmux-vm/cli"]


class Check(unittest.TestCase):
    def test_an_added_backend_file_names_cmux_platform(self):
        status = check.parse_status("A\tbackend/apps/api/src/new-route.ts\nM\tREADME.md\n")
        warnings = check.check(BACKEND, STAYS, status, "Adds a route.")
        self.assertEqual(len(warnings), 1)
        self.assertIn("adds cloud backend code", warnings[0])
        self.assertIn("manaflow-ai/cmux-platform", warnings[0])
        self.assertIn("backend/apps/api/src/new-route.ts", warnings[0])

    def test_a_changed_backend_file_gets_the_softer_warning(self):
        warnings = check.check(BACKEND, STAYS, check.parse_status("M\tweb/services/vms/x.ts\n"), "")
        self.assertEqual(len(warnings), 1)
        self.assertIn("changes cloud backend code", warnings[0])

    def test_client_cli_and_protocol_paths_are_not_warned(self):
        status = check.parse_status("A\tworkers/cmux-vm/cli/main.ts\nM\tbackend/packages/protocol/x.ts\n"
                                    "A\tPackages/macOS/Foo.swift\nM\tweb/services-other/x.ts\n")
        self.assertEqual(check.check(BACKEND, STAYS, status, ""), [])

    def test_a_cmux_platform_line_clears_it(self):
        status = check.parse_status("A\tbackend/apps/api/src/new-route.ts\n")
        for body in ("Moves it.\n\ncmux-platform: manaflow-ai/cmux-platform#120 landed first; this deletes the copy.",
                     "- **cmux-platform:** fix to code that has not moved yet",
                     "CMUX-PLATFORM: not moved yet"):
            self.assertEqual(check.check(BACKEND, STAYS, status, body), [], body)
        for body in ("cmux-platform:", "see cmux-platform: later", "We should use cmux-platform."):
            self.assertEqual(len(check.check(BACKEND, STAYS, status, body)), 1, body)

    def test_a_directory_owns_only_what_is_under_it(self):
        self.assertEqual(check.check(BACKEND, STAYS, check.parse_status("A\tweb/servicesX.ts\n"), ""), [])
        self.assertEqual(len(check.check(BACKEND, STAYS, check.parse_status("D\tweb/services\n"), "")), 1)

    def test_main_only_warns_and_exits_0(self):
        with tempfile.TemporaryDirectory() as d:
            body, status, m = Path(d, "body.md"), Path(d, "status.txt"), Path(d, "map.json")
            body.write_text("no answer")
            status.write_text("A\tweb/services/vms/new.ts\n")
            m.write_text(json.dumps({"backend": BACKEND, "stays": STAYS}))
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(check.main(["--body-file", str(body), "--status-file", str(status), "--map", str(m)]), 0)
            self.assertIn("::warning title=Cloud backend belongs in cmux-platform::", out.getvalue())
            for bad in ({"backend": "web/services"}, [], None):
                m.write_text(json.dumps(bad))
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(check.main(["--body-file", str(body), "--status-file", str(status), "--map", str(m)]), 2)

    def test_the_repository_map_is_valid_and_its_paths_exist(self):
        backend, stays = check.load_map(ROOT / check.DEFAULT_MAP)
        for p in backend + stays:
            self.assertTrue((ROOT / p).exists(), f"{check.DEFAULT_MAP} lists {p}, which does not exist")
        for s in stays:
            self.assertTrue(any(check.under(b, s) for b in backend), f"stays path {s} is under no backend path")

    def test_the_workflow_only_warns_and_runs_the_base_script(self):
        wf = (ROOT / ".github" / "workflows" / "pr-cloud-backend-check.yml").read_text()
        self.assertIn("continue-on-error: true", wf)
        self.assertIn("ref: ${{ github.event.pull_request.base.ref }}", wf)
        self.assertIn("|| echo \"::warning title=Cloud backend belongs in cmux-platform::the check could not run", wf)
        self.assertIn("permissions: {}", wf)
        self.assertNotIn("pull_request_target", wf)


if __name__ == "__main__":
    unittest.main()
