#!/usr/bin/env python3
"""scripts/ci/mac_grants.py: which cmux-next Mac PR jobs take a scheduler grant, and on which labels."""
from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import mac_grants  # noqa: E402

PR = {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
      "GITHUB_REPOSITORY_OWNER": "manaflow-ai", "HEAD_REPO": "manaflow-ai/cmux",
      "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2", "XCODE_APP": "/Applications/Xcode_26.6.app"}


class MacGrantsTest(unittest.TestCase):
    def switch(self, data) -> Path:
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        handle.write(data if isinstance(data, str) else json.dumps(data))
        handle.close()
        self.addCleanup(Path(handle.name).unlink)
        return Path(handle.name)

    def test_off_writes_nothing(self):
        for data in ({"jobs": []}, {}, "not json", [], {"jobs": "generated-files"}):
            self.assertEqual(mac_grants.outputs(PR, self.switch(data)), {"grant_runner": "", "grant_jobs": ""})
        self.assertEqual(mac_grants.outputs(PR, Path("/nonexistent/mac-grants.json"))["grant_runner"], "")

    def test_plain_cmux_mac_with_xcode(self):
        out = mac_grants.outputs(PR, self.switch({"jobs": ["generated-files"]}))
        self.assertEqual(out, {"grant_runner": '["cmux-mac","xcode-26.6"]', "grant_jobs": " generated-files "})

    def test_per_run_opt_in(self):
        out = mac_grants.outputs(PR, self.switch({"jobs": ["generated-files", "fast-tier"], "per_run": True}))
        self.assertEqual(json.loads(out["grant_runner"]), ["cmux-123-2-mac", "xcode-26.6"])
        self.assertEqual(out["grant_jobs"], " generated-files fast-tier ")

    def test_no_xcode_no_xcode_label(self):
        out = mac_grants.outputs({**PR, "XCODE_APP": ""}, self.switch({"jobs": ["generated-files"]}))
        self.assertEqual(out["grant_runner"], '["cmux-mac"]')

    def test_forks_pushes_and_other_owners_get_nothing(self):
        path = self.switch({"jobs": ["generated-files"]})
        for env in ({**PR, "HEAD_REPO": "someone/cmux"}, {**PR, "GITHUB_EVENT_NAME": "push"},
                    {**PR, "GITHUB_REPOSITORY": "x/cmux", "GITHUB_REPOSITORY_OWNER": "x", "HEAD_REPO": "x/cmux"},
                    {**PR, "GITHUB_RUN_ID": ""}):
            self.assertEqual(mac_grants.outputs(env, path)["grant_runner"], "")

    def test_bad_job_ids_dropped(self):
        out = mac_grants.outputs(PR, self.switch({"jobs": ["generated-files", "x y", 3, "' || true"]}))
        self.assertEqual(out["grant_jobs"], " generated-files ")

    def test_committed_switch_names_real_jobs(self):
        switch = mac_grants.read_switch()
        workflow = (ROOT / ".github/workflows/cmux-next.yml").read_text(encoding="utf-8")
        for job in switch["jobs"]:
            self.assertRegex(workflow, rf"(?m)^  {re.escape(job)}:$")
            # The job's runs-on reads the grant first, or the switch moves nothing.
            self.assertIn(f"contains(needs.macos-placement.outputs.grant_jobs, ' {job} ')", workflow)

    def test_workflow_jobs_reading_the_grant_need_placement(self):
        workflow = (ROOT / ".github/workflows/cmux-next.yml").read_text(encoding="utf-8")
        jobs = set(re.findall(r"contains\(needs\.macos-placement\.outputs\.grant_jobs, ' ([a-z0-9_-]+) '\)", workflow))
        self.assertIn("generated-files", jobs)
        self.assertIn("grant_runner: ${{ steps.grant.outputs.grant_runner }}", workflow)
        self.assertIn("grant_jobs: ${{ steps.grant.outputs.grant_jobs }}", workflow)


if __name__ == "__main__":
    unittest.main()
