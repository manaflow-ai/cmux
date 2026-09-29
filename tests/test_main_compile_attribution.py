#!/usr/bin/env python3
"""main_compile_attribution.py names the merge that broke main's compile.

The cases replay 2026-09-29: #15550 (ff12362) broke PaneDropTargetIdentityTests
alone, #15116 (ad7906) landed while its seed was replaced, and 217ef's seed
showed #15116's errors on top. They pin reading errors out of a seed log,
attributing each error to where it first appeared, the probe choice, the
already-fixing check that keeps the fixer from duplicating a person's fix,
the headline ci-dash reads, and the workflows' trust and trigger wiring.
"""

from __future__ import annotations

import sys
import textwrap
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import main_compile_attribution as mca  # noqa: E402

ATTRIBUTION = ROOT / ".github/workflows/ci-compile-attribution.yml"
PROBE = ROOT / ".github/workflows/main-compile-probe.yml"
SEED = ROOT / ".github/workflows/seed-derived-data.yml"

# Trimmed from job 109345503595 (seed, glaeda-trusted-std-xcode-26.6).
SEED_LOG = textwrap.dedent("""\
    2026-09-29T09:34:07.9935360Z /tmp/cmux-ci/src/cmuxTests/PaneDropTargetIdentityTests.swift:61:27: error: contextual type for closure argument list expects 1 argument, which cannot be implicitly ignored
    2026-09-29T09:34:07.9935710Z     |                           `- error: contextual type for closure argument list expects 1 argument, which cannot be implicitly ignored
    2026-09-29T09:34:07.9960960Z /tmp/cmux-ci/src/cmuxTests/PaneDropTargetIdentityTests.swift:61:27: error: contextual type for closure argument list expects 1 argument, which cannot be implicitly ignored
    2026-09-29T09:44:01.0000000Z /private/tmp/cmux-ci-2/src/cmuxTests/RemoteTmuxMirrorCLIObservabilityTests.swift:399:34: error: immutable value 'self.nonMirrorPanelID' may only be initialized once
    2026-09-29T09:44:02.0000000Z error: No space left on device
    2026-09-29T09:44:03.0000000Z ** TEST BUILD FAILED **
""")

ED, FF, AD, TWO = "ed49329987" + "0" * 30, "ff12362be9" + "0" * 30, "ad7906a261" + "0" * 30, "217ef1338a" + "0" * 30
PANE = mca.CompileError("cmuxTests/PaneDropTargetIdentityTests.swift", 61, "closure expects 1 argument")
MIRROR = mca.CompileError("cmuxTests/RemoteTmuxMirrorCLIObservabilityTests.swift", 399, "immutable value 'self.mirror' may only be initialized once")
FILES = {
    FF: ["Sources/PaneDropRoutingSupport.swift", "cmuxTests/PaneDropTargetIdentityTests.swift"],
    AD: ["cmuxTests/RemoteTmuxMirrorCLIObservabilityTests.swift", "Sources/Workspace.swift"],
    TWO: ["scripts/ci/package_interface.py"],
}


def states(**overrides):
    base = {
        ED: mca.State(ED, "green"),
        FF: mca.State(FF, "red", {PANE.key: PANE}),
        AD: mca.State(AD, "unknown"),
        TWO: mca.State(TWO, "red", {PANE.key: PANE, MIRROR.key: MIRROR}),
    }
    base.update(overrides)
    return base


def attribute(window, known):
    return mca.attribute(window, known, files_of=lambda sha: FILES.get(sha, []), text_of=lambda sha: "")


class ParseErrors(unittest.TestCase):
    def test_source_errors_only_once_each_relative_to_the_checkout(self):
        errors = mca.parse_errors(SEED_LOG)
        self.assertEqual(
            [e.render() for e in errors.values()],
            [
                "cmuxTests/PaneDropTargetIdentityTests.swift:61: error: contextual type for closure argument list expects 1 argument, which cannot be implicitly ignored",
                "cmuxTests/RemoteTmuxMirrorCLIObservabilityTests.swift:399: error: immutable value 'self.nonMirrorPanelID' may only be initialized once",
            ],
        )

    def test_a_machine_failure_is_no_verdict(self):
        self.assertEqual(mca.parse_errors("2026-09-29T09:44:02Z error: No space left on device\n** BUILD FAILED **\n"), {})

    def test_the_key_ignores_the_line_so_a_moved_error_is_not_new(self):
        moved = mca.CompileError(PANE.path, 75, PANE.message)
        self.assertEqual(moved.key, PANE.key)


class Attribute(unittest.TestCase):
    def test_each_error_goes_to_where_it_first_appeared(self):
        state, newest, breaks = attribute([TWO, AD, FF, ED], states())
        self.assertEqual((state, newest.sha), ("red", TWO))
        self.assertEqual(len(breaks), 2)
        newer, older = breaks
        # 217ef's new error appeared after ff12362: two merges, #15116's diff reaches it.
        self.assertEqual((newer.base, newer.commits, newer.confirmed), (FF, [AD, TWO], False))
        self.assertEqual([e.key for e in newer.errors], [MIRROR.key])
        self.assertEqual(newer.culprits, [{"sha": AD}])
        self.assertEqual(newer.probes, [AD])
        # The pane error was already red at ff12362, whose parent compiled: confirmed.
        self.assertEqual((older.base, older.commits, older.confirmed), (ED, [FF], True))
        self.assertEqual(older.culprits, [{"sha": FF}])
        self.assertEqual(older.probes, [])

    def test_a_probe_result_confirms_the_suspect(self):
        known = states(**{AD: mca.State(AD, "red", {PANE.key: PANE, MIRROR.key: MIRROR})})
        _, _, breaks = attribute([TWO, AD, FF, ED], known)
        self.assertEqual((breaks[0].commits, breaks[0].confirmed), ([AD], True))

    def test_green_head_means_nothing_to_attribute(self):
        state, newest, breaks = attribute([TWO, AD], {TWO: mca.State(TWO, "green")})
        self.assertEqual((state, newest.sha, breaks), ("green", TWO, []))

    def test_no_known_green_leaves_the_range_open_and_unconfirmed(self):
        _, _, breaks = attribute([TWO, AD, FF], {TWO: states()[TWO]})
        self.assertEqual(len(breaks), 1)
        self.assertIsNone(breaks[0].base)
        self.assertFalse(breaks[0].confirmed)
        self.assertEqual(breaks[0].commits, [FF, AD, TWO])

    def test_no_diff_reaching_the_error_names_nobody(self):
        top, scores = mca.suspects([TWO], [MIRROR], files_of=lambda sha: FILES[sha], text_of=lambda sha: "")
        self.assertEqual((top, scores), ([], {TWO: 0}))

    def test_a_quoted_symbol_in_the_diff_scores_below_the_file(self):
        err = mca.CompileError("cmuxTests/A.swift", 1, "cannot find 'frameForZone' in scope")
        top, scores = mca.suspects([AD, TWO], [err], files_of=lambda sha: [],
                                   text_of=lambda sha: "-    let frameForZone: (Zone) -> CGRect" if sha == AD else "")
        self.assertEqual((top, scores[AD]), ([AD], 1))

    def test_probes_start_in_the_middle(self):
        self.assertEqual(mca.probe_order(list("abcdefg"), 3), ["d", "c", "e"])
        self.assertEqual(mca.probe_order(list("ab"), 4), ["a", "b"])


class JobVerdicts(unittest.TestCase):
    def job(self, conclusion):
        return {"steps": [{"name": "Resolve Swift packages", "conclusion": "success"},
                          {"name": "Build", "conclusion": conclusion}]}

    def test_the_compile_step_decides(self):
        self.assertEqual(mca.job_verdict(self.job("success"), "Build"), "green")
        self.assertEqual(mca.job_verdict(self.job("failure"), "Build"), "red")
        self.assertEqual(mca.job_verdict(self.job(None), "Build"), "unknown")
        self.assertEqual(mca.job_verdict({"steps": []}, "Build"), "unknown")

    def test_a_real_error_outranks_a_green_pool(self):
        red = mca.State(TWO, "red", {PANE.key: PANE})
        self.assertIs(mca.merge([mca.State(TWO, "unknown"), red, mca.State(TWO, "green")]), red)


class FollowThrough(unittest.TestCase):
    CULPRIT = {"pr": 15550, "sha": FF, "author": "austinywang", "merger": "austinywang", "title": "Fix pane drop"}

    def report(self, confirmed=True):
        brk = {"base": ED, "head": FF, "commits": [FF], "confirmed": confirmed, "culprits": [self.CULPRIT],
               "errors": [PANE.render()], "error_keys": [PANE.key], "files": [PANE.path],
               "evidence": "https://github.com/manaflow-ai/cmux/actions/runs/1/job/2", "probing": []}
        return {"head": FF, "state": "red", "newest_known": FF, "breaks": [brk]}

    def test_a_person_already_fixing_it_stops_the_fixer(self):
        prs = [{"number": 15561, "title": "fix(tests): compile cmuxTests again after #15116 and #15550",
                "body": "", "created_at": "2026-09-29T10:00:00Z", "head": {"ref": "fix/compile"}}]
        self.assertEqual(mca.already_fixing(prs, 15550, "2026-09-29T09:26:21Z")["number"], 15561)
        self.assertIsNone(mca.already_fixing(prs, 15551, "2026-09-29T09:26:21Z"))
        # Our own branch counts whatever its title says.
        ours = [{"number": 1, "title": "x", "body": "", "created_at": "", "head": {"ref": "compile-fix/217ef1338a-15550"}}]
        self.assertEqual(mca.already_fixing(ours, 15550, None)["number"], 1)

    def test_comment_pings_and_fences_the_errors(self):
        report = self.report()
        body = mca.render_culprit_comment(report, report["breaks"][0], self.CULPRIT, {})
        self.assertTrue(body.startswith("<!-- main-compile-culprit pr=15550 errors="))
        self.assertIn("@austinywang:", body)
        self.assertEqual(body.count("@austinywang"), 1)
        self.assertIn("```\n" + PANE.render() + "\n```", body)
        self.assertIn("so this pull request is the cause", body)

    def test_headline_names_culprits_for_ci_dash(self):
        report = self.report()
        report["headline"] = mca.headline(report)
        self.assertEqual(report["headline"], "culprit: Seed DerivedData red since #15550 by @austinywang (self-merged)")
        self.assertTrue(mca.headline({"state": "green", "newest_known": ED}).startswith("main compiles"))

    def test_fix_target_needs_one_named_culprit_or_a_confirmed_one(self):
        self.assertEqual(mca.fix_target(self.report())["culprit"]["pr"], 15550)
        tied = self.report(confirmed=False)
        tied["breaks"][0]["culprits"] = [self.CULPRIT, {**self.CULPRIT, "pr": 15116}]
        self.assertIsNone(mca.fix_target(tied))

    def test_pull_request_texts(self):
        report = self.report()
        report["fix"] = {"break": report["breaks"][0], "culprit": self.CULPRIT}
        title, branch, body = mca.fix_pr_body(report, "Adapt the test to the new closure.")
        self.assertEqual((title, branch), ("fix(main): compile again after #15550", "compile-fix/ff12362be9-15550"))
        self.assertIn("auto-merge", body)
        title, branch, _ = mca.revert_pr_body(report, "")
        self.assertEqual((title, branch), ("Revert #15550: main does not compile", "compile-revert/15550"))
        self.assertIn("#15550", mca.prompt(report))


class Workflows(unittest.TestCase):
    def load(self, path):
        data = yaml.safe_load(path.read_text())
        return data, data.get("on", data.get(True))

    def test_attribution_follows_the_seed_and_probe_runs_by_name(self):
        data, on = self.load(ATTRIBUTION)
        self.assertEqual(on["workflow_run"]["workflows"], [mca.SEED_WORKFLOW, mca.PROBE_WORKFLOW])
        self.assertEqual(yaml.safe_load(SEED.read_text())["name"], mca.SEED_WORKFLOW)
        self.assertEqual(yaml.safe_load(PROBE.read_text())["name"], mca.PROBE_WORKFLOW)

    def test_only_later_jobs_write_and_analyze_reads(self):
        data, _ = self.load(ATTRIBUTION)
        self.assertEqual(data["permissions"], {})
        analyze = data["jobs"]["analyze"]["permissions"]
        self.assertTrue(all(v in ("read", "none") for v in analyze.values()), analyze)
        self.assertEqual(data["jobs"]["report"]["name"], "${{ needs.analyze.outputs.headline || 'report' }}")

    def test_the_verdict_steps_exist_where_attribution_reads_them(self):
        seed = yaml.safe_load(SEED.read_text())["jobs"]["seed"]
        probe = yaml.safe_load(PROBE.read_text())["jobs"]["compile"]
        self.assertIn(mca.COMPILE_STEPS[mca.SEED_WORKFLOW_FILE], [s.get("name") for s in seed["steps"]])
        self.assertIn(mca.COMPILE_STEPS[mca.PROBE_WORKFLOW_FILE], [s.get("name") for s in probe["steps"]])

    def test_the_seed_starts_attribution_only_after_its_build_fails(self):
        seed = yaml.safe_load(SEED.read_text())["jobs"]["seed"]
        step = next(s for s in seed["steps"] if s.get("name") == "Start compile attribution")
        self.assertIn("steps.build.outcome == 'failure'", step["if"])
        self.assertTrue(step["continue-on-error"])
        self.assertIn("ci-compile-attribution.yml/dispatches", step["run"])

    def test_the_probe_is_named_by_its_commit(self):
        data = yaml.safe_load(PROBE.read_text())
        self.assertEqual(data["run-name"], "Main compile probe ${{ inputs.sha }}")


if __name__ == "__main__":
    unittest.main()
