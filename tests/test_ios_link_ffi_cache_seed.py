#!/usr/bin/env python3
"""ios-link-ffi-cache-seed.yml saves CmuxMobileLinkFFI.xcframework under exactly the keys and the path the iOS jobs
restore it from: the same key template, the same path, the same enableCrossOsArchive (the cache version hashes the
path and that flag, so any difference is a miss). It runs on the feat-cmux-next push, where a pull request's run can
read what it saved, and builds only when its lookup missed."""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
SEED = WORKFLOWS / "ios-link-ffi-cache-seed.yml"
XCF = "cmux-next-ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework"
INPUTS = 'inputs="$(python3 scripts/ci/ios_link_ffi_key.py)"'
STEP_REF = re.compile(r"^\$\{\{\s*steps\.([\w-]+)\.outputs\.([\w-]+)\s*\}\}$")
NEEDS_REF = re.compile(r"^\$\{\{\s*needs\.([\w-]+)\.outputs\.([\w-]+)\s*\}\}$")


def load(path: Path) -> dict:
    with path.open() as f:
        return yaml.safe_load(f)


def template(jobs: dict, job: str, expr: str) -> str:
    """The `echo "NAME=TEMPLATE"` text behind a `steps.X.outputs.NAME` or `needs.J.outputs.O` key expression."""
    expr = expr.strip()
    m = NEEDS_REF.match(expr)
    if m:
        return template(jobs, m.group(1), jobs[m.group(1)]["outputs"][m.group(2)])
    m = STEP_REF.match(expr)
    if not m:
        raise AssertionError(f"{job}: unexpected key expression {expr!r}")
    step_id, name = m.groups()
    step = next(s for s in jobs[job]["steps"] if s.get("id") == step_id)
    found = re.search(rf'echo "{re.escape(name)}=([^"]+)"', step.get("run", ""))
    if not found:
        raise AssertionError(f"{job}: step {step_id} writes no {name}=")
    assert INPUTS in step["run"], f"{job}: step {step_id} does not read the inputs from ios_link_ffi_key.py"
    return found.group(1)


def cache_steps(path: Path, action: str):
    """(job, step name, key template, cross-OS flag) for every actions/cache/ACTION step on the xcframework."""
    jobs = load(path).get("jobs") or {}
    for job, body in jobs.items():
        for step in body.get("steps") or []:
            uses = step.get("uses") or ""
            with_ = step.get("with") or {}
            if not uses.startswith(f"actions/cache/{action}@") or with_.get("path") != XCF:
                continue
            yield job, step.get("name"), template(jobs, job, str(with_["key"])), bool(with_.get("enableCrossOsArchive"))


class CacheSeedMatchesRestores(unittest.TestCase):
    def setUp(self):
        self.seed = load(SEED)
        self.saves = {(t, x) for _, _, t, x in cache_steps(SEED, "save")}
        self.restores = [
            (wf.name, job, name, t, x)
            for wf in sorted(WORKFLOWS.glob("*.yml")) if wf != SEED and XCF in wf.read_text()
            for job, name, t, x in cache_steps(wf, "restore")
        ]

    def test_every_restore_has_a_seeded_entry(self):
        self.assertGreaterEqual(len(self.restores), 5, self.restores)
        for wf, job, name, t, x in self.restores:
            with self.subTest(workflow=wf, job=job, step=name):
                self.assertIn((t, x), self.saves, f"{wf} {job}: {name} restores {t!r} (cross-OS {x}) and no seed saves it")

    def test_kit_fleet_entry_is_seeded_byte_for_byte(self):
        fleet = ("cmux-next-ios-link-ffi-xcf-fleet-v1-${inputs}", True)
        mac = ("cmux-next-ios-link-ffi-xcf-${RUNNER_OS}-${RUNNER_ARCH}-${xcode}-${inputs}", False)
        kit = {(t, x) for wf, job, _, t, x in self.restores if wf == "cmux-next-ios-kit.yml" and job == "kit-tests"}
        self.assertEqual(kit, {fleet, mac})
        self.assertEqual(self.saves, {fleet, mac})

    def test_the_ios_fast_verdict_reads_the_fleet_entry_on_a_hosted_mac(self):
        # cmux#61812 (2026-11-27): the hosted fallback built the FFI for 286 s of a 645 s verdict build.
        fast = {(t, x) for wf, job, _, t, x in self.restores if wf == "pr-pipeline.yml" and job == "ios-fast"}
        self.assertEqual(fast, {("cmux-next-ios-link-ffi-xcf-fleet-v1-${inputs}", True)})
        steps = load(WORKFLOWS / "pr-pipeline.yml")["jobs"]["ios-fast"]["steps"]
        names = [s.get("name") for s in steps]
        mark = names.index("Mark the restored CmuxMobileLinkFFI.xcframework as this job's copy")
        self.assertLess(names.index("Restore the fleet-built CmuxMobileLinkFFI.xcframework"), mark)
        self.assertLess(mark, names.index("Build the changed iOS target and run its tests"))
        key_step = next(s for s in steps if s.get("id") == "xcf-key")
        self.assertIn('"${RUNNER_NAME:-}" == blacksmith*', key_step["run"])  # an owned Mac keeps its warm copy
        mark_run = steps[mark]["run"]
        self.assertIn(".ios-fast-verdict-ffi", mark_run)  # scripts/ci/ios_fast_verdict.sh's stamp
        self.assertIn("$RUNNER_TEMP/link-ffi-fleet.key", mark_run)  # scripts/ci/ios_link_ffi.sh's mark

    def test_runs_on_the_base_push_and_builds_only_on_a_miss(self):
        on = self.seed.get("on") or self.seed.get(True)
        self.assertEqual(on["push"]["branches"], ["feat-cmux-next"])
        self.assertNotIn("pull_request", on)
        self.assertFalse(self.seed["concurrency"]["cancel-in-progress"])
        jobs = self.seed["jobs"]
        lookup = next(s for s in jobs["key"]["steps"] if s.get("id") == "lookup")
        self.assertTrue(lookup["with"]["lookup-only"])
        for job in ("fleet", "mac"):
            self.assertIn("needs.key.outputs.hit != 'true'", jobs[job]["if"], job)

    def test_the_mac_saves_only_a_build_without_drift(self):
        steps = [s.get("name") for s in self.seed["jobs"]["mac"]["steps"]]
        drift = steps.index("Checked-in bindings match the generated ones")
        for i, name in enumerate(steps):
            if name and name.startswith("Save "):
                self.assertGreater(i, drift, name)


R2_URL = "https://ci-cache-next.cmux.com"
FLEET = "cmux-next-ios-link-ffi-xcf-fleet-v1-${inputs}"


def r2_restores():
    """(workflow, job, key template, namespace, public URL) for every R2 restore of the xcframework."""
    for wf in sorted(WORKFLOWS.glob("*.yml")):
        if wf == SEED or XCF not in wf.read_text():
            continue
        jobs = load(wf).get("jobs") or {}
        for job, body in jobs.items():
            for step in body.get("steps") or []:
                with_ = step.get("with") or {}
                if step.get("uses") != "./.github/actions/cache-restore" or with_.get("path") != XCF:
                    continue
                env = step.get("env") or {}
                yield (wf.name, job, step, template(jobs, job, str(with_["key"])), env.get("CI_CACHE_R2_NAMESPACE"),
                       env.get("CI_CACHE_R2_PUBLIC_URL"), with_.get("backend"))


class R2CopyMatchesRestores(unittest.TestCase):
    """The Blacksmith Macs miss the GitHub-store entry (their actions/cache reads another store), so the seed copies
    it to R2 and every hosted reader restores that copy: the same key, the `any` namespace, the public URL."""

    def setUp(self):
        self.seed = load(SEED)
        self.restores = list(r2_restores())

    def test_seed_copies_the_fleet_entry_to_r2(self):
        jobs = self.seed["jobs"]
        r2 = jobs["r2"]
        self.assertEqual(set(r2["needs"]), {"key", "fleet", "mac"})
        self.assertIn("!cancelled()", r2["if"])
        self.assertIn("needs.key.outputs.r2_hit != 'true'", r2["if"])
        self.assertIn("refs/heads/feat-cmux-next", r2["if"])
        self.assertIn("next-cache-writer", r2["environment"])
        self.assertEqual(self.seed["env"]["CI_CACHE_R2_NAMESPACE"], "any")
        self.assertEqual(self.seed["env"]["CI_CACHE_R2_PUBLIC_URL"], R2_URL)
        restore, save = r2["steps"][1], r2["steps"][2]
        self.assertEqual(template(jobs, "r2", restore["with"]["key"]), FLEET)
        self.assertTrue(restore["with"]["enableCrossOsArchive"])
        self.assertIn("r2-cache.sh save", save["run"])
        self.assertIn(XCF, save["run"])
        self.assertEqual(save["env"]["KEY"], "${{ needs.key.outputs.key }}")
        self.assertIn("steps.restore.outputs.cache-hit == 'true'", save["if"])
        lookup = next(s for s in jobs["key"]["steps"] if s.get("id") == "r2-lookup")
        self.assertIn("/v1/${CI_CACHE_R2_NAMESPACE}/objects/${KEY}.${ext}", lookup["run"])

    def test_every_hosted_reader_restores_the_r2_copy(self):
        found = {(wf, job) for wf, job, *_ in self.restores}
        self.assertEqual(found, {("pr-pipeline.yml", "ios-fast"), ("cmux-next-ios-kit.yml", "kit-tests"),
                                 ("swift-linux-packages.yml", "mac-fallback")},
                         found)
        for wf, job, step, key, ns, url, backend in self.restores:
            with self.subTest(workflow=wf, job=job):
                self.assertEqual((key, ns, url, backend), (FLEET, "any", R2_URL, "r2"))
                self.assertIn("steps.xcf-fleet-restore.outputs.cache-hit != 'true'", step["if"])

    def test_a_build_or_wait_skips_on_an_r2_hit(self):
        """Every step that ran on a fleet-restore miss (build, wait, save) also skips on an R2 hit."""
        for wf in sorted({wf for wf, *_ in self.restores}):
            jobs = load(WORKFLOWS / wf)["jobs"]
            for job, body in jobs.items():
                for step in body.get("steps") or []:
                    cond = str(step.get("if") or "")
                    if step.get("id") == "xcf-r2-restore" or "steps.xcf-fleet-restore.outputs.cache-hit != 'true'" not in cond:
                        continue
                    with self.subTest(workflow=wf, job=job, step=step.get("name")):
                        self.assertIn("steps.xcf-r2-restore.outputs.cache-hit != 'true'", cond)

    def test_ios_fast_marks_an_r2_copy_as_its_own(self):
        steps = load(WORKFLOWS / "pr-pipeline.yml")["jobs"]["ios-fast"]["steps"]
        names = [s.get("name") for s in steps]
        r2 = names.index("Restore the fleet-built CmuxMobileLinkFFI.xcframework from R2")
        mark = names.index("Mark the restored CmuxMobileLinkFFI.xcframework as this job's copy")
        self.assertLess(r2, mark)
        self.assertIn("steps.xcf-r2-restore.outputs.cache-hit == 'true'", steps[mark]["if"])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
