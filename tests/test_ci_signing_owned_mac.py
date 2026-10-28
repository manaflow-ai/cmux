#!/usr/bin/env python3
"""A signing job runs on an owned Mac only with the whole Mac to itself and its keychain gone at the end.

Leo, 2026-10-28, on letting the release signing jobs run on our own Macs while
Blacksmith is starved: "ok. idk what the "risk" was before but like.. we can
just read the code and stuff." The order is Linux, then owned Macs, then
Blacksmith macOS last. On an owned Mac a signing job must:

1. reach it only through scripts/ci/signing_runner.py, the picker that offers a
   drained mini (no busy runner) and only while vars.CI_SIGN_OWNED is 1, and
   only on attempt 1 (`github.run_attempt == 1 && <owned pick> && fromJSON(...)`),
   so a re-run leaves the fleet. Every picker output a signing job's runs-on
   reads comes from that script or from nightly_sign_runner.py, which prints
   Blacksmith labels only; any other source fails here;
2. claim the whole Mac before any secret is read: a step that runs
   scripts/ci/signing-runner-claim.sh comes before every step that names a
   secret. glaeda's hook gives the job's (workflow, job) the exclusive class
   (glaeda SIGNING_JOBS, the same list as SIGNING_JOBS here) and writes
   GLAEDA_JOB_CLAIM=exclusive; the claim script fails on an owned Mac without it;
3. make its keychain with scripts/ci/signing-keychain.sh create (the
   certificate is decoded to a private temporary file that create itself
   removes, and delete removes again) and delete it in an `if: always()` step.

The claim script and the drained-mini pick are tested here too.
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
WORKFLOWS = ROOT / ".github/workflows"
sys.path.insert(0, str(ROOT / "scripts/ci"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import signing_runner  # noqa: E402
import test_ci_signing_keychain_is_deleted_before_bundle_code as keychain_guard  # noqa: E402

# The jobs glaeda's job-started hook admits as the exclusive class (glaeda scripts/glaeda-cmux-runner-hook
# SIGNING_JOBS). A signing job routed to owned Macs must be one of them, so a new one is added there too.
SIGNING_JOBS = {
    ("nightly.yml", "build-sign-notarize-nightly"), ("nightly.yml", "recover-nightly-next-notarization"),
    ("nightly.yml", "sign-nightly-identity-legacy"), ("release.yml", "build-sign-notarize"),
    ("repair-v0-64-25-helper-rpaths.yml", "repair"), ("cmux-next-dev-daily.yml", "sign"),
}
OWNED_PICKER = "scripts/ci/signing_runner.py"
BLACKSMITH_PICKER = "scripts/ci/nightly_sign_runner.py"
CLAIM = "scripts/ci/signing-runner-claim.sh"
NEEDS_OUTPUT = re.compile(r"needs\.([\w-]+)\.outputs\.([\w-]+)")
STEP_OUTPUT = re.compile(r"steps\.([\w-]+)\.outputs\.")
KEYCHAIN_DELETE = re.compile(r"signing-keychain\.sh\s+delete\b")


def workflows() -> dict[str, dict]:
    out = {}
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if isinstance(document, dict):
            out[path.name] = document
    return out


def signing_job(job: dict) -> bool:
    """A job that holds the Developer ID certificate or makes a signing keychain."""
    text = json.dumps(keychain_guard.inline_step_scripts(job))
    return "APPLE_CERTIFICATE_BASE64" in text or bool(keychain_guard.CREATE.search(text)) or any(
        script in text for script in keychain_guard.SCRIPT_MADE_KEYCHAINS.values())


def picker_scripts(jobs: dict, needed: str, output: str) -> list[str]:
    """The picker scripts behind needs.<needed>.outputs.<output>: the run of every step its value reads."""
    job = jobs.get(needed) or {}
    value = str((job.get("outputs") or {}).get(output, ""))
    steps = {str(step.get("id")): str(step.get("run", "")) for step in job.get("steps") or [] if isinstance(step, dict)}
    found = []
    for step_id in dict.fromkeys(STEP_OUTPUT.findall(value)):
        run = steps.get(step_id, "")
        found.append(OWNED_PICKER if OWNED_PICKER in run else BLACKSMITH_PICKER if BLACKSMITH_PICKER in run
                     else f"steps.{step_id} ({run.strip()[:60] or 'no run'})")
    return found or [f"needs.{needed}.outputs.{output} (no step output)"]


def check(documents: dict[str, dict]) -> tuple[list[str], int]:
    failures: list[str] = []
    owned_jobs = 0
    for workflow, document in documents.items():
        jobs = document.get("jobs") or {}
        for name, job in jobs.items():
            if not isinstance(job, dict) or not signing_job(job):
                continue
            label = f"{workflow} {name}"
            runs_on = str(job.get("runs-on", ""))
            owned_reads = []
            for needed, output in dict.fromkeys(NEEDS_OUTPUT.findall(runs_on)):
                scripts = picker_scripts(jobs, needed, output)
                for script in scripts:
                    if script == OWNED_PICKER:
                        owned_reads.append(f"needs.{needed}.outputs.{output}")
                    elif script != BLACKSMITH_PICKER:
                        failures.append(f"{label}: runs-on reads needs.{needed}.outputs.{output}, from {script}; a "
                                        f"signing job's runner comes from {OWNED_PICKER} or {BLACKSMITH_PICKER} only")
            if not owned_reads:
                continue
            owned_jobs += 1
            if (workflow, name) not in SIGNING_JOBS:
                failures.append(f"{label}: routed to owned Macs but not in SIGNING_JOBS (add it here and to glaeda's "
                                "SIGNING_JOBS, which gives it the whole mini)")
            for read in owned_reads:
                if not re.search(r"github\.run_attempt\s*==\s*1\s*&&\s*" + re.escape(read) + r"\s*&&\s*fromJSON\(\s*"
                                 + re.escape(read) + r"\s*\)", runs_on):
                    failures.append(f"{label}: reads {read} other than as `github.run_attempt == 1 && {read} && "
                                    f"fromJSON({read})`, so a re-run could stay on the fleet")
            steps = [step for step in keychain_guard.inline_step_scripts(job).get("steps") or []
                     if isinstance(step, dict)]
            claim = next((index for index, step in enumerate(steps) if CLAIM in str(step.get("run", ""))), None)
            first_secret = next((index for index, step in enumerate(steps) if "secrets." in json.dumps(step)), None)
            if claim is None:
                failures.append(f"{label}: routed to owned Macs without a step that runs {CLAIM}")
            elif first_secret is not None and first_secret < claim:
                failures.append(f"{label}: step {first_secret} names a secret before the claim step ({claim})")
            if "secrets." in json.dumps(job.get("env") or {}):
                failures.append(f"{label}: job-level env names a secret, which every step (the claim's too) holds")
            text = json.dumps(steps)
            if "security import" in text:
                failures.append(f"{label}: imports a certificate inline; use scripts/ci/signing-keychain.sh create")
            if not any("always()" in str(step.get("if", "")) and KEYCHAIN_DELETE.search(str(step.get("run", "")))
                       for step in steps):
                failures.append(f"{label}: routed to owned Macs without an `if: always()` step that runs "
                                "scripts/ci/signing-keychain.sh delete")
    return failures, owned_jobs


def runner(name: str, labels: list[str], busy: bool = False, status: str = "online") -> dict:
    return {"name": name, "status": status, "busy": busy, "labels": [{"name": label} for label in labels]}


SIDE = "glaeda-side-std-xcode-26.6"


class SigningOwnedMacTests(unittest.TestCase):
    def test_workflows(self) -> None:
        failures, owned_jobs = check(workflows())
        self.assertEqual(failures, [])
        self.assertGreaterEqual(owned_jobs, 1, "no signing job reads the owned pick: is this the right tree?")

    def test_the_guard_catches_a_missing_claim_and_cleanup(self) -> None:
        picker = {"outputs": {"owned": "${{ steps.pick.outputs.owned }}"},
                  "steps": [{"id": "pick", "run": f"python3 {OWNED_PICKER} owned"}]}
        good = {"runs-on": "${{ github.run_attempt == 1 && needs.pick.outputs.owned && "
                           "fromJSON(needs.pick.outputs.owned) || 'blacksmith-6vcpu-macos-26' }}",
                "steps": [{"run": CLAIM},
                          {"env": {"APPLE_CERTIFICATE_BASE64": "${{ secrets.APPLE_CERTIFICATE_BASE64 }}"},
                           "run": "scripts/ci/signing-keychain.sh create"},
                          {"if": "always()", "run": "scripts/ci/signing-keychain.sh delete"}]}
        self.assertEqual(check({"release.yml": {"jobs": {"pick": picker, "build-sign-notarize": good}}}), ([], 1))
        cases = {
            "not in SIGNING_JOBS": ("other.yml", "sign", good),
            "without a step that runs": ("release.yml", "build-sign-notarize", {**good, "steps": good["steps"][1:]}),
            "names a secret before the claim": ("release.yml", "build-sign-notarize",
                                                {**good, "steps": [good["steps"][1], good["steps"][0], good["steps"][2]]}),
            "without an `if: always()` step": ("release.yml", "build-sign-notarize",
                                               {**good, "steps": good["steps"][:2]}),
            "a re-run could stay": ("release.yml", "build-sign-notarize",
                                    {**good, "runs-on": "${{ needs.pick.outputs.owned || 'blacksmith-6vcpu-macos-26' }}"}),
        }
        for needle, (workflow, name, job) in cases.items():
            with self.subTest(needle):
                failures, _ = check({workflow: {"jobs": {"pick": picker, name: job}}})
                self.assertTrue(any(needle in failure for failure in failures), failures)
        other = {"outputs": {"owned": "${{ steps.pick.outputs.owned }}"},
                 "steps": [{"id": "pick", "run": "python3 scripts/ci/nightly_build_runner.py verify"}]}
        failures, _ = check({"release.yml": {"jobs": {"pick": other, "build-sign-notarize": good}}})
        self.assertTrue(any("signing job's runner comes from" in failure for failure in failures), failures)

    def test_drained_runner_takes_only_a_mini_running_nothing(self) -> None:
        runners = [
            runner("cmux12-glaeda", [SIDE, "glaeda-runner-cmux12-glaeda"]),
            runner("cmux12-glaeda-2", ["glaeda-gui-std-xcode-26.6"], busy=True),  # a busy gui runner: not drained
            runner("cmux13-glaeda-3", [SIDE, "glaeda-runner-cmux13-glaeda-3"]),
            runner("cmux13-glaeda-nightly-next", ["glaeda-trusted-next-nightly"]),
            runner("cmux14-glaeda", [SIDE]),  # no runner label of its own: cannot be pinned
            runner("cmux15-glaeda", [SIDE, "glaeda-runner-cmux15-glaeda"], status="offline"),
        ]
        labels, why = signing_runner.drained_runner(runners, [SIDE])
        self.assertEqual(json.loads(labels), [SIDE, "glaeda-runner-cmux13-glaeda-3"], why)
        runners[3]["busy"] = True  # the mini's dedicated builder is building: that mini is not drained either
        self.assertEqual(signing_runner.drained_runner(runners, [SIDE]), (
            "", f"no mini with an idle `{SIDE}` runner is drained now"))
        self.assertEqual(signing_runner.drained_runner(runners, ["blacksmith-6vcpu-macos-26"])[0], "")
        self.assertEqual(signing_runner.member("cmux13-glaeda-nightly-next"), "cmux13")
        self.assertEqual(signing_runner.member("blacksmith-runner"), "")

    def test_owned_pick_is_off_unless_enabled_on_attempt_one_with_a_token(self) -> None:
        runners = [runner("cmux12-glaeda", [SIDE, "glaeda-runner-cmux12-glaeda"])]
        env = {"ENABLED": "1", "ROUTE_TOKEN": "t", "GITHUB_REPOSITORY": "manaflow-ai/cmux", "OWNED_LABELS": SIDE,
               "GITHUB_RUN_ATTEMPT": "1"}
        read = lambda token, repo: runners  # noqa: E731
        self.assertTrue(signing_runner.owned_pick(env, read)[0])
        for change in ({"ENABLED": ""}, {"ENABLED": "0"}, {"GITHUB_RUN_ATTEMPT": "2"}, {"ROUTE_TOKEN": ""}):
            with self.subTest(change):
                self.assertEqual(signing_runner.owned_pick({**env, **change}, read)[0], "")

        def broken(token: str, repo: str) -> list:
            raise RuntimeError("403")

        self.assertEqual(signing_runner.owned_pick(env, broken)[0], "")
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            self.assertEqual(signing_runner.main({**env, "GITHUB_OUTPUT": os.fspath(output)}, ["owned"], read), 0)
            self.assertEqual(output.read_text(), f'owned=["{SIDE}","glaeda-runner-cmux12-glaeda"]\n')
            output.unlink()
            self.assertEqual(signing_runner.main({**env, "GITHUB_OUTPUT": os.fspath(output), "ENABLED": "0"}, [],
                                                 read, lambda t, r: None), 0)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(values["owned"], "")
            self.assertTrue(values["runner"].startswith("blacksmith-"))
            self.assertTrue(values["alternate"].startswith("blacksmith-"))


class ClaimScriptTests(unittest.TestCase):
    def run_claim(self, tmp: Path, **env: str) -> subprocess.CompletedProcess:
        security = tmp / "security"
        security.write_text('#!/bin/sh\n[ "$1" = delete-keychain ] && rm -f "$KEYCHAINS/$2-db"\n'
                            'echo "$@" >> "$KEYCHAINS/calls"\n')
        security.chmod(0o755)
        environ = {"PATH": "/usr/bin:/bin", "HOME": os.fspath(tmp), "KEYCHAINS": os.fspath(tmp / "keychains"),
                   "CMUX_SECURITY_TOOL": os.fspath(security), "CMUX_KEYCHAIN_DIR": os.fspath(tmp / "keychains"),
                   "CMUX_FLEET_DIR": os.fspath(tmp / "no-fleet"), **env}
        return subprocess.run(["bash", os.fspath(ROOT / CLAIM)], env=environ, capture_output=True, text=True,
                              timeout=30, check=False)

    def test_claim(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            (tmp / "keychains").mkdir()
            ephemeral = self.run_claim(tmp, RUNNER_NAME="blacksmith-6vcpu-macos-26-abc")
            self.assertEqual(ephemeral.returncode, 0, ephemeral.stdout + ephemeral.stderr)
            self.assertIn("is ephemeral", ephemeral.stdout)
            for env in ({"RUNNER_NAME": "cmux12-glaeda-3"}, {"RUNNER_NAME": "cmux12-glaeda"},
                        {"RUNNER_NAME": "mini", "CMUX_FLEET_DIR": raw},
                        {"RUNNER_NAME": "cmux12-glaeda", "GLAEDA_JOB_CLAIM": "light"}):
                with self.subTest(env):
                    refused = self.run_claim(tmp, **env)
                    self.assertEqual(refused.returncode, 1, refused.stdout)
                    self.assertIn("did not give the job the whole mini", refused.stdout)
            (tmp / "keychains" / "build.keychain-db").write_text("left by a killed job")
            claimed = self.run_claim(tmp, RUNNER_NAME="cmux12-glaeda-3", GLAEDA_JOB_CLAIM="exclusive")
            self.assertEqual(claimed.returncode, 0, claimed.stdout + claimed.stderr)
            self.assertIn("holds the whole mini", claimed.stdout)
            self.assertIn("removed the signing keychain build.keychain", claimed.stdout)
            self.assertFalse((tmp / "keychains" / "build.keychain-db").exists())


if __name__ == "__main__":
    unittest.main()
