#!/usr/bin/env python3
"""scripts/ci/mac_grants.py: which cmux-next Mac PR jobs take a scheduler grant, and on which labels."""
from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
import os
from unittest import mock

import yaml
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import mac_grants  # noqa: E402

PR = {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
      "GITHUB_REPOSITORY_OWNER": "manaflow-ai", "HEAD_REPO": "manaflow-ai/cmux",
      "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1", "XCODE_APP": "/Applications/Xcode_26.6.app"}


class PinnedPipelineRunnerTest(unittest.TestCase):
    def test_versioned_pin_selects_the_capability_and_missing_pin_stays_generic(self):
        for version in ("26.6", "27.2", "28.1.3"):
            for suffix in ("", "/Contents/Developer"):
                with self.subTest(version=version, suffix=suffix):
                    pin = f"/Applications/Xcode_{version}.app{suffix}"
                    self.assertEqual(json.loads(mac_grants.pinned_runner(pin)), ["cmux-mac", f"xcode-{version}"])
        for pin in (None, "", "  "):
            self.assertEqual(json.loads(mac_grants.pinned_runner(pin)), ["cmux-mac"])
        with self.assertRaisesRegex(ValueError, "must name a version"):
            mac_grants.pinned_runner("/Applications/Xcode.app")

    def test_router_and_recovery_emit_the_same_selector(self):
        import pr_router
        import ios_fast_dispatch as dispatch
        head, merge, base = "a" * 40, "b" * 40, "c" * 40
        pr = {"state": "open", "head": {"sha": head, "repo": {"full_name": "manaflow-ai/cmux"}},
              "base": {"ref": "feat-cmux-next"}, "merge_commit_sha": merge}
        commit = {"parents": [{"sha": base}, {"sha": head}]}
        for version in ("26.6", "27.2", "28.1.3"):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "outputs"
                env = {"CMUX_CI_XCODE_APP": f"/Applications/Xcode_{version}.app", "GITHUB_OUTPUT": str(output),
                       "REPO": "manaflow-ai/cmux", "PR": "63161", "SHA": head, "GH_TOKEN": "test"}
                with mock.patch.dict(os.environ, env), mock.patch.object(dispatch, "get", side_effect=[pr, commit]):
                    pr_router.write_outputs([], {}, [])
                    self.assertEqual(dispatch.main(["resolve"]), 0)
                selectors = [json.loads(line.partition("=")[2]) for line in output.read_text().splitlines()
                             if line.startswith("mac_runner=")]
                self.assertEqual(selectors, [["cmux-mac", f"xcode-{version}"]] * 2)

    def test_every_caller_supplies_the_pin_and_all_pinned_jobs_keep_fork_routes(self):
        def load(name):
            return yaml.safe_load((ROOT / ".github/workflows" / name).read_text())
        pipeline, router, recovery = map(load, ("pr-pipeline.yml", "pr-router.yml", "ios-fast-verdict-dispatch.yml"))
        inputs = pipeline.get("on", pipeline.get(True))["workflow_call"]["inputs"]
        self.assertEqual(inputs["mac_runner"], {"required": True, "type": "string"})
        for workflow, source, output_step in ((router, "route", "route"), (recovery, "resolve", "resolve")):
            job = workflow["jobs"][source]
            self.assertEqual(job["outputs"]["mac_runner"], f"${{{{ steps.{output_step}.outputs.mac_runner }}}}")
            step = next(s for s in job["steps"] if s.get("id") == output_step)
            self.assertEqual(step["env"]["CMUX_CI_XCODE_APP"], "${{ vars.CMUX_CI_XCODE_APP_MACOS_26 }}")
            checkout = next(s for s in job["steps"] if "actions/checkout" in s.get("uses", ""))
            self.assertIn("scripts/ci/mac_grants.py", checkout["with"]["sparse-checkout"].split())
            for caller in workflow["jobs"].values():
                if caller.get("uses") == "./.github/workflows/pr-pipeline.yml":
                    self.assertEqual(caller["with"]["mac_runner"], f"${{{{ needs.{source}.outputs.mac_runner }}}}")
        selected = []
        for name, job in pipeline["jobs"].items():
            if job.get("env", {}).get("CMUX_CI_XCODE_APP") != "${{ vars.CMUX_CI_XCODE_APP_MACOS_26 }}":
                continue
            selected.append(name)
            self.assertEqual(job["runs-on"], "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
                             "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != "
                             "github.repository && 'blacksmith-6vcpu-macos-26' || fromJSON(inputs.mac_runner) }}")
        self.assertEqual(selected, ["ios-macos", "mac", "mac-fallback"])


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
        self.assertEqual(json.loads(out["grant_runner"]), ["cmux-123-1-mac", "xcode-26.6"])
        self.assertEqual(out["grant_jobs"], " generated-files fast-tier ")

    def test_a_rerun_takes_no_per_run_label(self):
        # A re-run (the wait bound's, or a person's) must land on a label a runner serves, not a fresh per-run one.
        for attempt in ("2", "7"):
            env = {**PR, "GITHUB_RUN_ATTEMPT": attempt}
            out = mac_grants.outputs(env, self.switch({"jobs": ["generated-files"], "per_run": True}))
            self.assertEqual(out, {"grant_runner": "", "grant_jobs": ""}, attempt)
            out = mac_grants.outputs(env, self.switch({"jobs": ["generated-files"]}))
            self.assertEqual(json.loads(out["grant_runner"]), ["cmux-mac", "xcode-26.6"], attempt)

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

    WORKFLOWS = {".github/workflows/cmux-next.yml": "macos-placement",
                 ".github/workflows/cmux-next-pr-autofix.yml": "action-areas"}

    def grant_readers(self) -> dict[str, str]:
        """{job id: workflow} for every job whose runs-on reads the grant."""
        readers = {}
        for rel, need in self.WORKFLOWS.items():
            text = (ROOT / rel).read_text(encoding="utf-8")
            pattern = rf"contains\(needs\.{re.escape(need)}\.outputs\.grant_jobs, ' ([a-z0-9_-]+) '\) && fromJSON\(needs\.{re.escape(need)}\.outputs\.grant_runner\)"
            for job in re.findall(pattern, text):
                self.assertRegex(text, rf"(?m)^  {re.escape(job)}:$")
                readers[job] = rel
            self.assertIn("grant_runner: ${{ steps.grant.outputs.grant_runner }}", text)
            self.assertIn("grant_jobs: ${{ steps.grant.outputs.grant_jobs }}", text)
        return readers

    def test_committed_switch_names_real_jobs(self):
        # Every switched job's runs-on reads the grant first, or the switch moves nothing.
        readers = self.grant_readers()
        for job in mac_grants.read_switch()["jobs"]:
            self.assertIn(job, readers)

    def test_routed_jobs_read_the_grant(self):
        self.assertEqual(self.grant_readers(), {
            "generated-files": ".github/workflows/cmux-next.yml",
            "daemon-test": ".github/workflows/cmux-next.yml",
            "action-exports": ".github/workflows/cmux-next-pr-autofix.yml"})

if __name__ == "__main__":
    unittest.main()
