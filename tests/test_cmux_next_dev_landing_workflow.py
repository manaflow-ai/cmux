#!/usr/bin/env python3
"""cmux-next.yml's landing compile: every feat-cmux-next landing compiles the DEV Release app at once.

dev-landing-place (scripts/ci/dev_landing_place.py) picks the owned Mac whose cache is nearest,
dev-landing-compile compiles there and records the app under the reuse key the DEV run reads,
and leaves the holder record the next landing's placement reads. These pin the wiring:
landings only, never cancelled, one producer of a landing's DEV app, Blacksmith only as overflow.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import dev_landing_place as place  # noqa: E402
import dev_release_product_reuse as reuse  # noqa: E402


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.load((ROOT / ".github/workflows/cmux-next.yml").read_text(), Loader=yaml.BaseLoader)["jobs"]

    def test_only_feat_cmux_next_landings_run_it(self):
        condition = self.jobs["dev-landing-place"]["if"]
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next'", condition)
        self.assertIn("vars.CMUX_NEXT_DEV_LANDING_COMPILE", condition)
        self.assertEqual(self.jobs["dev-landing-compile"]["needs"], "dev-landing-place")

    def test_each_landing_compiles_in_its_own_never_cancelled_group(self):
        concurrency = self.jobs["dev-landing-compile"]["concurrency"]
        self.assertIn("github.run_id", concurrency["group"])
        self.assertEqual(concurrency["cancel-in-progress"], "false")
        for job in ("dev-landing-place", "dev-landing-compile"):
            self.assertNotIn("push-head-preflight", str(self.jobs[job].get("needs", "")),
                             "a superseded landing still compiles: it warms the next one")

    def test_runs_on_takes_the_placement_then_blacksmith(self):
        runs_on = self.jobs["dev-landing-compile"]["runs-on"]
        self.assertIn("fromJSON(needs.dev-landing-place.outputs.runs_on)", runs_on)
        self.assertTrue(runs_on.rstrip(" }").endswith("'blacksmith-12vcpu-macos-26'"), runs_on)
        self.assertIn("needs.dev-landing-place.outputs.runner_label", self.jobs["dev-landing-compile"]["env"]["CMUX_NEXT_RUNNER"])

    def test_the_compile_records_its_app_where_the_dev_run_looks(self):
        job = self.jobs["dev-landing-compile"]
        self.assertIn(job["name"], reuse.PRODUCER_JOBS, "the DEV run's lookup refuses a record of an unknown job")
        steps = {step.get("name"): step for step in job["steps"]}
        self.assertIn("job_input_fingerprint.py dev-release-product", steps["Look up the DEV Release app compiled on the same inputs"]["run"])
        self.assertEqual(steps["Upload the cmux NEXT DEV Release app"]["with"]["name"],
                         reuse.PRODUCT_PREFIX + "${{ github.sha }}")
        self.assertEqual(steps["Upload the DEV Release app record"]["with"]["name"],
                         reuse.RECORD_PREFIX + "${{ steps.dev-product.outputs.key }}")
        compile_run = steps["Compile the cmux NEXT DEV Release app"]["run"]
        self.assertIn("scripts/cmux-next/compile-dev-release.sh", compile_run)
        # The DEV run's key inputs: the same build settings as cmux-scheme-compile's DEV step.
        dev = {step.get("id"): step for step in self.jobs["cmux-scheme-compile"]["steps"]}["compile-cmux-next-dev-release"]["env"]
        landing = steps["Compile the cmux NEXT DEV Release app"]["env"]
        for key in ("CMUX_NEXT_CONFIGURATION", "CMUX_NEXT_PRODUCT_NAME", "CMUX_NEXT_BUNDLE_ID",
                    "CMUX_NEXT_CODE_SIGN_ENTITLEMENTS", "CMUX_NEXT_AUTH_CALLBACK_SCHEME", "CMUX_NEXT_TUI_MODE",
                    "CMUX_NEXT_BROWSER_DATA_IMPORT", "CMUX_NEXT_COMPILATION_CACHE", "CMUX_NEXT_SWIFT_COMPILATION_MODE"):
            self.assertEqual(landing[key], dev[key], key)

    def test_a_host_build_leaves_the_record_the_picker_reads(self):
        steps = {step.get("name"): step for step in self.jobs["dev-landing-compile"]["steps"]}
        upload = steps["Record this host's cache for the next landing's placement"]
        self.assertEqual(upload["with"]["name"], place.HOLDER_PREFIX + "${{ steps.report.outputs.holder }}")
        self.assertEqual(upload["with"]["overwrite"], "true")
        self.assertIn("scripts/cmux-next/dev-cas-holder.sh", steps["Report the landing compile"]["run"])
        # The DEV run's host build moves a host's cache too.
        dev = {step.get("name"): step for step in self.jobs["cmux-scheme-compile"]["steps"]}
        self.assertIn("scripts/cmux-next/dev-cas-holder.sh", dev["Record this host's cache for the next landing's placement"]["run"])
        # Its record's commit is the run's head_sha: a same-tree dispatch compiles another commit.
        self.assertIn("inputs.same_tree_sha == '' || inputs.same_tree_sha == github.sha",
                      dev["Record this host's cache for the next landing's placement"]["if"])
        self.assertEqual(dev["Upload this host's cache record"]["with"]["name"],
                         place.HOLDER_PREFIX + "${{ steps.dev-holder.outputs.holder }}")

    def test_a_push_has_one_producer_of_its_dev_app(self):
        # While the landing compile is on, cmux-scheme-compile builds a push's DEV app only when it is off.
        dev = {step.get("id"): step for step in self.jobs["cmux-scheme-compile"]["steps"]}
        for step_id in ("dev-product", "compile-cmux-next-dev-release"):
            condition = dev[step_id]["if"]
            push_branch = condition[:condition.index("(github.event_name == 'workflow_dispatch'")]
            self.assertIn("github.event_name == 'push'", push_branch)
            # The exact complement of dev-landing-place's condition: one of the two produces.
            self.assertIn("(format('{0}', vars.CMUX_NEXT_DEV_LANDING_COMPILE) == '0' || github.repository != 'manaflow-ai/cmux')",
                          push_branch)
        landing = self.jobs["dev-landing-place"]["if"]
        self.assertIn("github.repository == 'manaflow-ai/cmux'", landing)
        self.assertIn("format('{0}', vars.CMUX_NEXT_DEV_LANDING_COMPILE) != '0'", landing)

    def test_a_landing_hands_its_app_to_the_publisher_at_once(self):
        # Dispatch lag: the landing's app goes to main's publisher from the push run itself, on the
        # routing App's budget first, never waiting for a DEV dispatch run or the dispatcher's cron.
        job = self.jobs["dev-landing-publish"]
        self.assertEqual(job["needs"], ["dev-landing-place", "dev-landing-compile"])
        condition = job["if"]
        self.assertTrue(condition.startswith("${{ !cancelled()"), "a failed compile must still ask for a DEV build")
        # A failed placement still asks for a DEV build; a skipped one (the landing compile off)
        # leaves the push to cmux-scheme-compile and the kick, as before.
        self.assertIn("needs.dev-landing-place.result != 'skipped'", condition)
        self.assertNotIn("needs.dev-landing-place.result == 'success'", condition)
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next'", condition)
        self.assertNotIn("concurrency", job, "a handoff never cancels or replaces another")
        self.assertEqual(job["permissions"], {"actions": "write"})
        self.assertEqual(job["environment"], "ci-routing-agent")
        self.assertNotIn("vars.", job["runs-on"], "a job holding the App key runs on an ephemeral runner")
        self.assertIn("ubuntu", job["runs-on"])
        steps = {step.get("id") or step.get("name"): step for step in job["steps"]}
        self.assertEqual(steps["handoff-token"]["with"]["permission-actions"], "write")
        run = steps["Hand the landing's app to the publisher, else ask for a DEV build"]
        script = run["run"]
        self.assertEqual(run["env"]["COMPILED"], "${{ needs.dev-landing-compile.result == 'success' }}")
        self.assertIn('cmux-next-dev-daily.yml --repo "$GH_REPO" --ref main -f "source_run_id=$SOURCE_RUN_ID"', script)
        self.assertIn('cmux-next-dev-daily-dispatch.yml --repo "$GH_REPO" --ref main', script)
        self.assertIn('for token in "$APP_TOKEN" "$REPO_TOKEN"', script, "App token first, GITHUB_TOKEN second")
        # It starts no cmux-next run: a cmux-next run the App started would fire cmux-next's
        # workflow_run listeners (nightly-next-tick) on top of this push run's own completion.
        self.assertNotIn("cmux-next.yml", script.replace("cmux-next-dev-", ""))
        # The publisher's artifact is the landing compile's.
        upload = {step.get("name"): step for step in self.jobs["dev-landing-compile"]["steps"]}["Upload the cmux NEXT DEV Release app"]
        self.assertEqual(upload["with"]["name"], "cmux-next-dev-daily-unsigned-${{ github.sha }}")

    def test_the_handoff_script_falls_back_and_picks_its_target(self):
        # The step's own bash, against a stub gh that records each call and refuses the App token.
        import os, shutil, subprocess, tempfile
        if not shutil.which("bash"):
            self.skipTest("bash is required")
        step = next(s for s in self.jobs["dev-landing-publish"]["steps"]
                    if s.get("name") == "Hand the landing's app to the publisher, else ask for a DEV build")

        def run(compiled, app_token, app_ok=True, repo_ok=True):
            with tempfile.TemporaryDirectory() as tmp:
                gh = os.path.join(tmp, "gh")
                with open(gh, "w") as f:
                    f.write('#!/bin/bash\necho "$GH_TOKEN $*" >> "$STUB_DIR/calls"\n'
                            '[ "$GH_TOKEN" = app ] && exit "$APP_RC"\n[ "$GH_TOKEN" = repo ] && exit "$REPO_RC"\nexit 9\n')
                os.chmod(gh, 0o755)
                env = {"PATH": f"{tmp}:/usr/bin:/bin", "STUB_DIR": tmp, "APP_TOKEN": app_token, "REPO_TOKEN": "repo",
                       "GH_REPO": "o/r", "COMPILED": compiled, "SOURCE_RUN_ID": "42",
                       "APP_RC": "0" if app_ok else "1", "REPO_RC": "0" if repo_ok else "1"}
                result = subprocess.run(["bash", "-c", step["run"]], env=env, capture_output=True, text=True, timeout=60)
                calls = open(os.path.join(tmp, "calls")).read().splitlines() if os.path.exists(os.path.join(tmp, "calls")) else []
                return result.returncode, calls

        publish = "workflow run cmux-next-dev-daily.yml --repo o/r --ref main -f source_run_id=42"
        dispatcher = "workflow run cmux-next-dev-daily-dispatch.yml --repo o/r --ref main"
        self.assertEqual(run("true", "app"), (0, [f"app {publish}"]))
        self.assertEqual(run("true", "app", app_ok=False), (0, [f"app {publish}", f"repo {publish}"]))
        self.assertEqual(run("true", ""), (0, [f"repo {publish}"]), "no App token: GITHUB_TOKEN alone")
        self.assertEqual(run("false", "app"), (0, [f"app {dispatcher}"]), "no landing app: ask the dispatcher")
        rc, calls = run("true", "app", app_ok=False, repo_ok=False)
        self.assertNotEqual(rc, 0, "a handoff nobody took fails the job")
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
