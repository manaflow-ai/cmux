"""cmux-next pushes check generated files in daemon-test, on its package build.

Both jobs ran the same `swift build --build-tests` of Packages/macOS/CmuxNext on
a push (265-579 s of Mac time each). On a push that daemon-test runs on,
generated-files is skipped and daemon-test runs its checks and its verdict.
Pull requests keep the generated-files job."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
FOLD = "env.CMUX_NEXT_FOLD_GENERATED == 'true'"
STALE = "::error::Generated cmux-next files are stale. Regenerate them as the step summary says."


class GeneratedFoldTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        cls.daemon = cls.jobs["daemon-test"]
        cls.generated = cls.jobs["generated-files"]

    def steps(self, job):
        return [s.get("name", "") for s in job["steps"]]

    def step(self, job, name):
        return next(s for s in job["steps"] if s.get("name") == name)

    def test_daemon_test_folds_only_a_routed_push(self):
        self.assertEqual(
            self.daemon["env"]["CMUX_NEXT_FOLD_GENERATED"],
            "${{ github.event_name == 'push' && inputs.same_tree_sha == '' && needs.path_route.outputs.generated == 'true' }}")

    def test_generated_files_skips_exactly_the_pushes_daemon_test_runs_on(self):
        gen_if = self.generated["if"]
        clause = ("!(github.event_name == 'push' && inputs.same_tree_origin != 'push' && inputs.same_tree_sha == '' "
                  "&& needs.path_route.outputs.daemon == 'true' && needs.path_route.outputs.tree_state == 'ready')")
        self.assertIn(clause, gen_if)
        # daemon-test's push condition: the folded clause plus what generated-files' own if already requires.
        daemon_if = self.daemon["if"]
        for part in ("inputs.same_tree_origin != 'push'", "!cancelled()",
                     "(needs.web-bundles.result == 'success' || needs.web-bundles.result == 'skipped')",
                     "inputs.same_tree_sha == '' && needs.path_route.outputs.daemon == 'true' && "
                     "needs.push-head-preflight.outputs.current == 'true' && needs.path_route.outputs.tree_state == 'ready'"):
            self.assertIn(part, daemon_if)
        for part in ("!cancelled()", "(needs.web-bundles.result == 'success' || needs.web-bundles.result == 'skipped')",
                     "needs.path_route.outputs.generated == 'true'", "needs.push-head-preflight.outputs.current == 'true'"):
            self.assertIn(part, gen_if)
        self.assertEqual(self.daemon["needs"], self.generated["needs"])

    def test_the_checks_run_on_the_build_before_the_catalogs_compile(self):
        names = self.steps(self.daemon)
        build = names.index("Build package and tests")
        catalogs = names.index("Compile string catalogs into the resource bundles")
        actions = names.index("Check generated action catalog, surfaces and inventory")
        settings = names.index("Check the settings exports")
        self.assertLess(build, actions)
        self.assertLess(settings, catalogs)
        for name in ("Check generated action catalog, surfaces and inventory", "Check the settings exports"):
            ours, theirs = self.step(self.daemon, name), self.step(self.generated, name)
            self.assertEqual(ours["if"], "${{ " + FOLD + " }}")
            self.assertTrue(ours["continue-on-error"])
            self.assertEqual(ours["run"], theirs["run"])
            self.assertEqual(ours.get("id"), theirs.get("id"))
        self.assertEqual(self.step(self.daemon, "Check generated action catalog, surfaces and inventory")["env"],
                         {"CMUX_ACTION_SURFACES_SKIP_BUILD": "1"})

    def test_the_verdict_is_the_generated_files_verdict_after_the_daemon_suites(self):
        names = self.steps(self.daemon)
        suites = names.index("Run the live-daemon suites")
        for name in ("Regenerate stale files", "Upload the regenerated files", "Fail on stale generated files"):
            self.assertGreater(names.index(name), suites)
            ours, theirs = self.step(self.daemon, name), self.step(self.generated, name)
            self.assertIn("!cancelled()", ours["if"])
            for key in ("run", "with", "id"):
                self.assertEqual(ours.get(key), theirs.get(key), f"{name}: {key}")
        self.assertIn(STALE, self.step(self.daemon, "Fail on stale generated files")["run"])

    def test_the_exports_cache_accepts_a_folded_push(self):
        cache = self.jobs["swift-exports-cache"]
        self.assertIn("path_route", cache["needs"])
        self.assertIn("(needs.generated-files.result == 'success' || needs.generated-files.result == 'skipped' "
                      "&& needs.path_route.outputs.generated == 'true')", cache["if"])
        self.assertIn("needs.daemon-test.result == 'success'", cache["if"])

    def test_the_check_script_skips_the_build_only_when_asked(self):
        script = (ROOT / "scripts/cmux-next/check-action-surfaces.sh").read_text()
        self.assertRegex(script, re.escape('[[ "${CMUX_ACTION_SURFACES_SKIP_BUILD:-}" != 1 ]] || skip_build=(--skip-build)'))
        # bash 3.2 (macOS /bin/bash) treats an empty "${a[@]}" as unbound under set -u.
        self.assertIn('${skip_build[@]+"${skip_build[@]}"}', script)


if __name__ == "__main__":
    unittest.main()
