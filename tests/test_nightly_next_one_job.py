#!/usr/bin/env python3
"""nightly-next can build, sign, notarize and publish in one job on one Mac (nightly-next-one).

Leo, 2026-11-12: "Why isn't it just like the single machine does the thing end to end? I thought we were
already doing that, and then we stopped doing that." With the repository variable NIGHTLY_NEXT_ONE_JOB set
to `on`, a nightly-next push (or the loop's retry) runs decide and resolve, then one job on cmux15
(cmux15's signer label, glaeda-trusted-next-signing) that compiles warm, prepares, signs,
notarizes, verifies and writes the feed in one workspace: no artifact hop of the app. The split
build/sign pipeline jobs skip in that mode, and with the variable unset they run exactly as before.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
sys.path.insert(0, str(ROOT / "scripts/ci"))

import signing_runner  # noqa: E402

JOB = "nightly-next-one"
GATE_ON = "needs.decide.outputs.one_job == 'true'"
GATE_OFF = "needs.decide.outputs.one_job != 'true'"
# The jobs that start the split pipeline: everything else on its path needs one of them to succeed.
PIPELINE_ROOTS = (
    "pick-nightly-build-runner", "build-nightly-app", "build-nightly-remote-daemon", "build-nightly-inputs",
    "resolve-nightly-ghostty-cli-helper", "check-nightly-webviews", "find-nightly-next-recovery",
    "route-visual-gate-nightly",
)
# The split pipeline's jobs: each one, with the one-job gate on, is skipped (a root, or it needs a root's success).
PIPELINE_JOBS = PIPELINE_ROOTS + (
    "build-nightly-ghostty-cli-helper", "prepare-nightly-variant-primary", "prepare-nightly-variant",
    "pick-nightly-sign-runner", "build-sign-notarize-nightly", "verify-signed-nightly",
    "verify-final-dmg-nightly", "await-nightly-tree-marker", "dispatch-nightly-next-sign",
    "recover-nightly-next-notarization", "verify-recovered-nightly-next", "publish-nightly",
)
# Artifact names that carry the app itself between jobs or runs.
APP_ARTIFACT = re.compile(r"unsigned-app|prepared-app|signed-app|signed-unnotarized|release-archive|"
                          r"notarization-recovery|unsigned-resume")


def workflow() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def one_line(value) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip()


class NightlyNextOneJobTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.doc = workflow()
        cls.jobs = cls.doc["jobs"]
        cls.job = cls.jobs.get(JOB) or {}

    def test_the_job_exists_and_is_gated_on_decides_one_job_output(self) -> None:
        self.assertTrue(self.job, f"nightly.yml has no {JOB} job")
        self.assertIn(GATE_ON, one_line(self.job.get("if")))
        needs = self.job.get("needs")
        self.assertIn("decide", needs)
        self.assertIn("resolve-nightly-cmux-tui-client", needs)
        decide = self.jobs["decide"]
        self.assertEqual(one_line(decide["outputs"].get("one_job")), "${{ steps.decide.outputs.one_job }}")
        step = next(s for s in decide["steps"] if s.get("id") == "decide")
        self.assertEqual(step["env"].get("NIGHTLY_NEXT_ONE_JOB"), "${{ vars.NIGHTLY_NEXT_ONE_JOB || '' }}")
        script = step["with"]["script"]
        # Only the variable's exact value `on`, only on nightly-next's push or the loop's retry, only a build
        # that publishes; the old pipeline is off exactly when this is on.
        match = re.search(r"const oneJob = (.+?);\n", script)
        self.assertIsNotNone(match, "decide does not compute oneJob")
        expr = match.group(1)
        for term in ("isNextRef", "track === 'nightly-next'", "shouldPublish", "!notaryPaused", "!notaryTest",
                     "!continueOnly", "!unsignedResume", "process.env.NIGHTLY_NEXT_ONE_JOB === 'on'",
                     "context.eventName === 'push' || Boolean(process.env.LOOP_RETRY)"):
            self.assertIn(term, expr)
        self.assertIn("core.setOutput('one_job', oneJob ? 'true' : 'false')", script)
        pipeline = re.search(r"const pipeline = (.+?);\n", script).group(1)
        self.assertIn("!oneJob", pipeline)

    def test_it_runs_on_the_one_job_label(self) -> None:
        runs_on = one_line(self.job.get("runs-on"))
        # cmux15's signer label, a literal (no variable chooses where signing secrets go).
        self.assertEqual(runs_on, "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_NIGHTLY_MINI != '' && "
                                  "'glaeda-trusted-next-signing' || 'glaeda-trusted-next-signing' }}")
        self.assertEqual(self.job.get("environment"), "${{ needs.decide.outputs.environment }}")

    def test_no_artifact_carries_the_app_into_or_out_of_it(self) -> None:
        for step in self.job.get("steps") or []:
            uses = str(step.get("uses") or "")
            self.assertNotIn("download-artifact", uses, f"{step.get('name')}: the one job downloads nothing")
            run = str(step.get("run") or "")
            self.assertNotRegex(run, r"download-run-artifact|fetch_run_artifact|resume-unsigned-nightly",
                                f"{step.get('name')}: the one job fetches no artifact")
            if "upload-artifact" in uses:
                name = str((step.get("with") or {}).get("name") or "")
                path = str((step.get("with") or {}).get("path") or "")
                self.assertNotRegex(name, APP_ARTIFACT, f"{step.get('name')} uploads the app")
                self.assertNotRegex(path, r"\.app\b|cmux-nightly-unsigned|prepared-app|signed-app",
                                    f"{step.get('name')} uploads the app")

    def test_it_holds_its_own_concurrency_group_and_never_cancels_a_started_run(self) -> None:
        # Scoped to the run: a shared group would let a newer run replace this one's pending job
        # (tests/test_nightly_delivery_concurrency.py); the push group already runs one nightly-next at a time.
        self.assertEqual(self.job.get("concurrency"), {"group": "${{ format('nightly-next-one-{0}', github.run_id) }}",
                                                       "cancel-in-progress": False})

    def test_it_is_admitted_as_a_signing_job(self) -> None:
        self.assertIn(JOB, signing_runner.SIGNING_JOBS["nightly.yml"])
        steps = self.job.get("steps") or []
        self.assertEqual(steps[0].get("id"), "claim-gate", "the whole-Mac claim gate is the first step")
        runs = [str(s.get("run") or "") for s in steps]
        claim = next(i for i, run in enumerate(runs) if "signing-runner-claim.sh" in run)
        first_secret = next(i for i, s in enumerate(steps) if "secrets." in json.dumps(s))
        self.assertLess(claim, first_secret, "the claim script runs before any secret is in reach")

    def test_it_keeps_the_split_paths_checks(self) -> None:
        names = [str(s.get("name") or "") for s in self.job.get("steps") or []]
        for name in ("Import signing cert", "Codesign apps", "Notarize app ticket through final DMG",
                     "Delete signing keychain after the DMG signature", "Gate distribution with syspolicy_check",
                     "Generate Sparkle appcasts (nightly)", "Verify version surfaces",
                     "Verify bundled CLI commands run from the bundle alone",
                     "Verify signed diff sidecar protocol contract",
                     "Verify signed app entitlements and the Computer Use helper ticket",
                     "Run bundled Ghostty theme picker helper regression", "Verify signed app SSH daemon contract",
                     "Verify final DMG artifact", "Launch smoke from a fresh home",
                     "Require every DMG to match a tested digest", "Take the nightly-next publish lease",
                     "Recheck the recovered build against both feeds", "Guard nightly-next publication",
                     "Final publication gate", "Upload nightly-next appcasts to R2",
                     "Read the live nightly-next feed back", "Release the nightly-next publish lease",
                     "Finish the webview checks before any signing secret", "Wait for the build commit's tree-commit marker"):
            self.assertIn(name, names)
        notarize = next(s for s in self.job["steps"] if s.get("name") == "Notarize app ticket through final DMG")
        # As today: the app, its staple, the DMG around the stapled app, its staple.
        self.assertEqual(notarize["env"]["CMUX_STAPLE_APP_IN_DMG"], "true")
        # A slow notarization fails the job (the loop retries it) instead of handing an artifact to a later run.
        self.assertEqual(notarize["env"]["CMUX_NOTARY_PENDING_ON_TIMEOUT"], "false")

    def test_the_split_pipeline_skips_in_one_job_mode(self) -> None:
        for name in PIPELINE_ROOTS:
            condition = one_line(self.jobs[name].get("if"))
            if condition.startswith("${{") and condition.endswith("}}"):
                condition = condition[3:-2].strip()
            self.assertEqual(condition.count(f" && {GATE_OFF}"), 1, f"{name} if has no && {GATE_OFF}")
            # Unchanged with the variable unset: the gate is the only mention, one top-level conjunct.
            before = condition.replace(f" && {GATE_OFF}", "")
            self.assertNotIn("one_job", before)
            self.assertNotIn("||", re.sub(r"\([^()]*\)", "", re.sub(r"\([^()]*\)", "", before)),
                             f"{name}: an `||` outside parentheses would bind looser than the appended gate")
        # Every other split job needs a root (or a job that does) and checks its success, so it skips too.
        skipped = set(PIPELINE_ROOTS)
        changed = True
        while changed:
            changed = False
            for name in PIPELINE_JOBS:
                if name in skipped:
                    continue
                needs = self.jobs[name].get("needs") or []
                needs = [needs] if isinstance(needs, str) else needs
                condition = one_line(self.jobs[name].get("if"))
                if any(need in skipped and (f"needs.{need}.result == 'success'" in condition
                                            or f"needs.{need}.outputs" in condition
                                            or "!cancelled()" not in condition and "always()" not in condition)
                       for need in needs):
                    skipped.add(name)
                    changed = True
        self.assertEqual(sorted(set(PIPELINE_JOBS) - skipped), [])

    def test_the_jobs_after_the_feed_read_the_one_job(self) -> None:
        for name in ("published-build", "dispatch-published-in", "retry-nightly-next", "report-nightly-failure",
                     "attest-nightly-remote-daemon"):
            job = self.jobs[name]
            self.assertIn(JOB, job["needs"], f"{name} does not need {JOB}")
            self.assertIn(f"needs.{JOB}.", one_line(job.get("if")), f"{name} if does not read {JOB}")
        retry = one_line(self.jobs["retry-nightly-next"]["if"])
        self.assertIn(f"needs.{JOB}.result != 'success'", retry)
        # The one job publishes the outputs publish-nightly and build-nightly-app give the record.
        outputs = self.job.get("outputs") or {}
        for name in ("already_published", "behind", "behind_hours", "build", "build_sha", "downloads", "refused",
                     "source", "source_archive", "tag_status", "tested_pattern", "tip_sha", "variant_pattern",
                     "daemon_build", "daemon_version", "feed_check", "refusal_reason", "feed_written"):
            self.assertIn(name, outputs)

    # Build-time code and the app's own code share this job with the signing and publication secrets, so each set
    # of secrets is fenced by a stray-process check, and nothing from the bundle runs while signing secrets exist.
    STRAY_CHECKS = ("Refuse stray processes before secrets", "Refuse stray processes before secrets (publication)")
    SIGNING_SECRET = re.compile(r"secrets\.(APPLE_|ASC_API_|SPARKLE_|NIGHTLY_SPARKLE_)")
    PUBLICATION_SECRET = re.compile(r"secrets\.(CMUX_RELEASE_APP_|NIGHTLY_NEXT_R2_)|steps\.writer-token\.")
    # The steps that execute the built app or a binary from its bundle (verify-signed-nightly's and
    # verify-final-dmg-nightly's, which run without secrets in the split path).
    BUNDLE_RUNNERS = (
        "Verify version surfaces", "Verify bundled CLI commands run from the bundle alone",
        "Verify signed diff sidecar protocol contract", "Verify signed app entitlements and the Computer Use helper ticket",
        "Run bundled Ghostty theme picker helper regression", "Verify signed app SSH daemon contract",
        "Verify final DMG artifact", "Launch smoke from a fresh home",
    )

    def test_stray_processes_are_refused_before_each_set_of_secrets(self) -> None:
        steps = self.job.get("steps") or []
        names = [s.get("name") for s in steps]
        blobs = [yaml.safe_dump(s) for s in steps]
        first, second = (names.index(n) for n in self.STRAY_CHECKS)
        for index in (first, second):
            self.assertIn("refuse_stray_processes.py", steps[index].get("run", ""))
            self.assertNotIn("secrets.", blobs[index])
        signing = [i for i, b in enumerate(blobs) if self.SIGNING_SECRET.search(b)]
        publication = [i for i, b in enumerate(blobs) if self.PUBLICATION_SECRET.search(b)]
        self.assertTrue(signing and publication)
        self.assertEqual(min(signing), first + 1, "the first check sits right before the first signing secret")
        self.assertEqual(min(publication), second + 1, "the second check sits right before the publication secrets")
        self.assertLess(max(signing), second, "no signing secret after the publication check")

        runners = [names.index(n) for n in self.BUNDLE_RUNNERS]
        for index in runners:
            # Nothing from the bundle runs while the signing secrets are in the job, and the publication check
            # comes after the last of them, so nothing such a step left behind meets the publication secrets.
            self.assertGreater(index, max(signing), names[index])
            self.assertLess(index, second, names[index])

    def test_a_warm_mac_skips_the_zig_package_restore_and_installs_zig_once(self) -> None:
        # "Cache Zig packages" restored 647 MB over the Mac's kept ~/.cache/zig in 69-81 s (runs 43390156751,
        # 43395323737), and "Install compilation dependencies" downloaded ghostty-next's Zig again (20 s) after
        # "Install Zig" had put it in CMUX_VT_ZIG.
        steps = self.job.get("steps") or []
        names = [str(s.get("name") or "") for s in steps]
        probe = names.index("Read whether the kept Zig package cache is complete")
        restore = names.index("Cache Zig packages")
        mark = names.index("Mark the kept Zig package cache complete")
        self.assertLess(probe, restore)
        self.assertLess(names.index("Build the cmux-next source archive"), mark)
        self.assertIn("steps.zig-kept.outputs.kept != 'true'", one_line(steps[restore].get("if")))
        # The source archive's own condition, after it passed (it blocks), never its soft outcome.
        archive = steps[names.index("Build the cmux-next source archive")]
        self.assertNotIn("continue-on-error", archive)
        self.assertEqual(one_line(steps[mark].get("if")), "success() && " + one_line(archive.get("if")))
        key = "zig-packages-${{ hashFiles('ghostty/build.zig.zon', 'ghostty/build.zig.zon.json') }}"
        self.assertEqual(steps[restore]["with"]["key"], key)
        self.assertEqual(steps[probe]["env"]["KEY"], key)
        self.assertEqual(steps[mark]["env"]["KEY"], key)
        split = workflow()["jobs"]["build-nightly-ghostty-cli-helper"]["steps"]
        split_restore = next(s for s in split if s.get("name") == "Cache Zig packages")
        self.assertEqual(split_restore["with"], steps[restore]["with"])
        self.assertEqual(one_line(split_restore["if"]), "inputs.nightly_next_unsigned_run == ''")
        deps = one_line(steps[names.index("Install compilation dependencies")]["run"])
        self.assertIn('[ -x "${CMUX_VT_ZIG:-}" ]', deps)
        self.assertLess(names.index("Install Zig"), names.index("Install compilation dependencies"))

    def test_the_kept_zig_cache_marker(self) -> None:
        script = ROOT / "scripts/ci/nightly-steps/zig-cache-kept.sh"
        key = "zig-packages-" + "a" * 64
        with tempfile.TemporaryDirectory() as tmp:
            cache, out = Path(tmp) / "zig", Path(tmp) / "out"

            def run(mode: str, value: str) -> str:
                out.write_text("")
                env = {**os.environ, "CMUX_KEPT_ZIG_CACHE": str(cache), "KEY": value, "GITHUB_OUTPUT": str(out)}
                subprocess.run(["bash", str(script), mode], env=env, check=True, capture_output=True)
                return out.read_text().strip()

            self.assertEqual(run("check", key), "kept=false", "no cache yet")
            (cache / "p").mkdir(parents=True)
            self.assertEqual(run("check", key), "kept=false", "packages but no marker")
            run("mark", key)
            self.assertEqual(run("check", key), "kept=true")
            self.assertEqual(run("check", "zig-packages-" + "b" * 64), "kept=false", "another Ghostty revision")
            self.assertEqual(run("check", "zig-packages-"), "kept=false", "an empty hashFiles")
            run("mark", "zig-packages-")
            self.assertEqual(run("check", key), "kept=true", "an invalid key marks nothing")

    def test_the_published_record_reads_the_one_job(self) -> None:
        needs = {
            "decide": {"result": "success", "outputs": {"track": "nightly-next"}},
            "resolve-nightly-cmux-tui-client": {"result": "success", "outputs": {"build_sha": "a" * 40}},
            "build-nightly-app": {"result": "skipped", "outputs": {}},
            "publish-nightly": {"result": "skipped", "outputs": {}},
            JOB: {"result": "success", "outputs": {"build": "4321", "tag_status": "updated", "daemon_build": "4321",
                                                   "daemon_version": "1.2.3-nightly.4321"}},
        }
        with tempfile.TemporaryDirectory() as tmp:
            record = Path(tmp) / "record.json"
            env = dict(os.environ, NEEDS=json.dumps(needs), RUN_ID="1", RUN_ATTEMPT="1", SHA="b" * 40,
                       RECORD_FILE=str(record))
            subprocess.run([sys.executable, str(ROOT / "scripts/ci/nightly_published_build.py"), "pack"],
                           check=True, env=env, capture_output=True)
            rec = json.loads(record.read_text())
        self.assertEqual(rec["publish_result"], "success")
        self.assertEqual(rec["publish_build"], "4321")
        self.assertEqual(rec["publish_tag_status"], "updated")
        self.assertEqual(rec["daemon_version"], "1.2.3-nightly.4321")
        self.assertEqual(rec["resolve_build_sha"], "a" * 40)


if __name__ == "__main__":
    unittest.main()
