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
2. claim the whole Mac before any credential is in reach: its first step is
   CLAIM_GATE, inline and unconditional, before the checkout (which holds the
   job token) and every other step. glaeda's hook gives the job's (workflow,
   job) the exclusive class (glaeda SIGNING_JOBS, the same list as
   SIGNING_JOBS here) and writes GLAEDA_JOB_CLAIM=exclusive; the gate fails
   on an owned Mac without it. A step that runs
   scripts/ci/signing-runner-claim.sh (the same check, and it removes a
   signing keychain a killed job left) comes before every step that names a
   secret, and neither the job's nor the workflow's env names a secret;
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
from typing import Any

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
CLAIM_GATE_NAME = "Hold the whole Mac before any credential"
# The first step of an owned-routed signing job, word for word: it needs no checkout.
CLAIM_GATE = """owned=""
case "${RUNNER_NAME:-}" in *-glaeda|*-glaeda-*) owned=1 ;; esac
if [ -d /Users/Shared/cmux-build-fleet ]; then owned=1; fi
if [ -n "$owned" ] && [ "${GLAEDA_JOB_CLAIM:-}" != exclusive ]; then
  echo "::error title=Signing runner::This owned Mac did not give the job the whole mini; its re-run takes Blacksmith."
  exit 1
fi
"""
NEEDS_OUTPUT = re.compile(r"needs\.([\w-]+)\.outputs\.([\w-]+)")
STEP_OUTPUT = re.compile(r"steps\.([\w-]+)\.outputs\.")
KEYCHAIN_DELETE = re.compile(r"signing-keychain\.sh\s+delete\b")
# needs['a'].outputs['b'] and secrets['X'] are the same references as needs.a.outputs.b and secrets.X; the guard
# reads them in dot form (dotted()), and a reference left with an index that is not a literal (secrets[format(...)],
# needs[x]) fails an owned-routed job, since the guard cannot tell what it reads.
LITERAL_INDEX = re.compile(r"\[\s*'([A-Za-z0-9_-]+)'\s*\]|\[\s*\"([A-Za-z0-9_-]+)\"\s*\]")
DYNAMIC_INDEX = re.compile(r"\b(?:secrets|needs|outputs)\s*\[")
# Status functions that let a step run after an earlier step failed.
RUNS_AFTER_FAILURE = re.compile(r"\b(?:always|failure|cancelled)\s*\(")


def dotted(value: Any) -> Any:
    """value with every literal index (['x'] or [\"x\"]) in its expressions written as .x."""
    if isinstance(value, str):
        return LITERAL_INDEX.sub(lambda m: "." + (m.group(1) or m.group(2)), value)
    if isinstance(value, dict):
        return {dotted(key): dotted(item) for key, item in value.items()}
    if isinstance(value, list):
        return [dotted(item) for item in value]
    return value


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
        document = dotted(document)
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
            if not owned_reads and DYNAMIC_INDEX.search(runs_on):
                failures.append(f"{label}: runs-on indexes needs or outputs with an expression the guard cannot read")
            if not owned_reads:
                continue
            if DYNAMIC_INDEX.search(json.dumps(job)) or DYNAMIC_INDEX.search(json.dumps(document.get("env") or {})):
                failures.append(f"{label}: indexes secrets, needs or outputs with an expression the guard cannot read")
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
            gate = steps[0] if steps else {}
            if (str(gate.get("run", "")).strip() != CLAIM_GATE.strip() or set(gate) - {"name", "run", "shell"}
                    or str(gate.get("shell", "bash")) != "bash"):
                failures.append(f"{label}: the first step must be the claim gate ({CLAIM_GATE_NAME}): CLAIM_GATE word "
                                "for word, with no if, uses, env or continue-on-error, before the checkout's token")
            claim = next((index for index, step in enumerate(steps) if CLAIM in str(step.get("run", ""))), None)
            first_secret = next((index for index, step in enumerate(steps) if "secrets." in json.dumps(step)), None)
            if claim is None:
                failures.append(f"{label}: routed to owned Macs without a step that runs {CLAIM}")
            elif first_secret is not None and first_secret < claim:
                failures.append(f"{label}: step {first_secret} names a secret before the claim step ({claim})")
            else:
                if steps[claim].get("if") is not None or str(steps[claim].get("continue-on-error", "false")) != "false":
                    failures.append(f"{label}: the claim step must run unconditionally and fail the job "
                                    "(no `if`, no continue-on-error)")
                for index, step in enumerate(steps[1:], 1):
                    if "secrets." in json.dumps(step) and RUNS_AFTER_FAILURE.search(str(step.get("if", ""))):
                        failures.append(f"{label}: step {index} names a secret and runs after a failed claim "
                                        f"(if: {step.get('if')})")
            if "secrets." in json.dumps(job.get("env") or {}):
                failures.append(f"{label}: job-level env names a secret, which every step (the claim's too) holds")
            if "secrets." in json.dumps(document.get("env") or {}):
                failures.append(f"{label}: workflow-level env names a secret, which every step (the claim's too) holds")
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
                "steps": [{"name": CLAIM_GATE_NAME, "run": CLAIM_GATE}, {"run": CLAIM},
                          {"env": {"APPLE_CERTIFICATE_BASE64": "${{ secrets.APPLE_CERTIFICATE_BASE64 }}"},
                           "run": "scripts/ci/signing-keychain.sh create"},
                          {"if": "always()", "run": "scripts/ci/signing-keychain.sh delete"}]}
        self.assertEqual(check({"release.yml": {"jobs": {"pick": picker, "build-sign-notarize": good}}}), ([], 1))
        cases = {
            "not in SIGNING_JOBS": ("other.yml", "sign", good),
            "without a step that runs": ("release.yml", "build-sign-notarize",
                                         {**good, "steps": [good["steps"][0], *good["steps"][2:]]}),
            "names a secret before the claim": ("release.yml", "build-sign-notarize",
                                                {**good, "steps": [good["steps"][0], good["steps"][2], good["steps"][1],
                                                                   good["steps"][3]]}),
            "without an `if: always()` step": ("release.yml", "build-sign-notarize",
                                               {**good, "steps": good["steps"][:3]}),
            "must run unconditionally": ("release.yml", "build-sign-notarize",
                                         {**good, "steps": [good["steps"][0], {"run": CLAIM, "continue-on-error": True},
                                                            *good["steps"][2:]]}),
            "runs after a failed claim": ("release.yml", "build-sign-notarize",
                                          {**good, "steps": [*good["steps"][:2], {**good["steps"][2], "if": "always()"},
                                                             good["steps"][3]]}),
            "the first step must be the claim gate": ("release.yml", "build-sign-notarize",
                                                      {**good, "steps": [{"uses": "actions/checkout@v6"},
                                                                         *good["steps"]]}),
            "the first step must be the claim gate (Hold": ("release.yml", "build-sign-notarize",
                                      {**good, "steps": [{**good["steps"][0], "if": "success()"}, *good["steps"][1:]]}),
            "a re-run could stay": ("release.yml", "build-sign-notarize",
                                    {**good, "runs-on": "${{ needs.pick.outputs.owned || 'blacksmith-6vcpu-macos-26' }}"}),
        }
        for needle, (workflow, name, job) in cases.items():
            with self.subTest(needle):
                failures, _ = check({workflow: {"jobs": {"pick": picker, name: job}}})
                self.assertTrue(any(needle in failure for failure in failures), failures)
        failures, _ = check({"release.yml": {"env": {"K": "${{ secrets.K }}"},
                                             "jobs": {"pick": picker, "build-sign-notarize": good}}})
        self.assertTrue(any("workflow-level env names a secret" in failure for failure in failures), failures)
        brackets = {**good, "runs-on": "${{ github.run_attempt == 1 && needs['pick'].outputs['owned'] && "
                                       "fromJSON(needs[\"pick\"].outputs.owned) || 'blacksmith-6vcpu-macos-26' }}",
                    "steps": [good["steps"][0], {"env": {"K": "${{ secrets['APPLE_CERTIFICATE_BASE64'] }}"},
                                                 "run": "true"}, *good["steps"][1:]]}
        failures, owned = check({"release.yml": {"jobs": {"pick": picker, "build-sign-notarize": brackets}}})
        self.assertEqual(owned, 1, "bracket notation still reads as the owned pick")
        self.assertTrue(any("names a secret before the claim" in failure for failure in failures), failures)
        dynamic = {**good, "steps": [*good["steps"][:2], {"env": {"K": "${{ secrets[format('A{0}', 'X')] }}"},
                                                           "run": "true"}, *good["steps"][2:]]}
        failures, _ = check({"release.yml": {"jobs": {"pick": picker, "build-sign-notarize": dynamic}}})
        self.assertTrue(any("cannot read" in failure for failure in failures), failures)
        failures, _ = check({"release.yml": {"jobs": {"pick": picker, "build-sign-notarize": {
            **good, "runs-on": "${{ fromJSON(needs[format('pi{0}', 'ck')].outputs.owned) }}"}}}})
        self.assertTrue(any("cannot read" in failure for failure in failures), failures)
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
        runners.append(runner("cmux13-glaeda-5", ["glaeda-gui-std-xcode-26.6"], status="offline"))
        self.assertEqual(signing_runner.drained_runner(runners, [SIDE])[0], "",
                         "an offline runner may still run a job: its mini is not offered")
        runners.pop()
        runners[3]["busy"] = True  # the mini's dedicated builder is building: that mini is not drained either
        self.assertEqual(signing_runner.drained_runner(runners, [SIDE]), (
            "", f"no mini with an idle `{SIDE}` runner is drained now"))
        self.assertEqual(signing_runner.drained_runner(runners, ["blacksmith-6vcpu-macos-26"])[0], "")
        slot = "glaeda-nightly-std-xcode-26.6"  # glaeda's nightly slot, which CI_NIGHTLY_NEXT_BUILD_RUNNER may name
        labels, why = signing_runner.drained_runner(
            [runner("cmux20-glaeda-nightly", [slot, "glaeda-runner-cmux20-glaeda-nightly"])], [slot])
        self.assertEqual(json.loads(labels), [slot, "glaeda-runner-cmux20-glaeda-nightly"], why)
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


class SearchListTests(unittest.TestCase):
    """delete puts back the user search list create replaced, and falls back to the login keychain when create could
    not read it or nothing it saw is left, so an owned Mac never keeps the deleted signing keychain as its list."""

    def delete(self, tmp: Path) -> list[str]:
        security = tmp / "security"
        security.write_text('#!/bin/sh\necho "$@" >> "$CALLS"\n')
        security.chmod(0o755)
        env = {"PATH": "/usr/bin:/bin", "HOME": os.fspath(tmp), "CALLS": os.fspath(tmp / "calls"),
               "CMUX_SECURITY_TOOL": os.fspath(security), "CMUX_KEYCHAIN_DIR": os.fspath(tmp / "keychains"),
               "CMUX_SIGNING_KEYCHAIN_STATE_DIR": os.fspath(tmp / "state")}
        done = subprocess.run(["bash", os.fspath(ROOT / "scripts/ci/signing-keychain.sh"), "delete"], env=env,
                              capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        calls = (tmp / "calls").read_text().splitlines() if (tmp / "calls").exists() else []
        (tmp / "calls").unlink(missing_ok=True)
        return [call for call in calls if call.startswith("list-keychains")]

    def test_search_list(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            (tmp / "keychains").mkdir()
            state = tmp / "state"
            state.mkdir()
            login = tmp / "keychains" / "login.keychain-db"
            login.write_text("")
            other = tmp / "keychains" / "other.keychain-db"
            other.write_text("")
            (state / "search-list").write_text(f"{login}\n{other}\n{tmp}/gone.keychain-db\n")
            self.assertEqual(self.delete(tmp), [f"list-keychains -d user -s {login} {other}"])
            self.assertFalse((state / "search-list").exists())
            (state / "search-list.failed").write_text("")
            self.assertEqual(self.delete(tmp), [f"list-keychains -d user -s {login}"], "the capture failed")
            self.assertFalse((state / "search-list.failed").exists())
            (state / "search-list").write_text(f"{tmp}/gone.keychain-db\n")
            self.assertEqual(self.delete(tmp), [f"list-keychains -d user -s {login}"], "nothing it saw is left")
            self.assertEqual(self.delete(tmp), [], "no create in this job: the list is left alone")


class ClaimGateTests(unittest.TestCase):
    def test_gate(self) -> None:
        def gate(**env: str) -> subprocess.CompletedProcess:
            return subprocess.run(["bash", "-e", "-c", CLAIM_GATE], env={"PATH": "/usr/bin:/bin", **env},
                                  capture_output=True, text=True, timeout=30, check=False)

        fleet = Path("/Users/Shared/cmux-build-fleet").is_dir()
        if not fleet:
            self.assertEqual(gate(RUNNER_NAME="blacksmith-6vcpu-macos-26-abc").returncode, 0)
        for env in ({"RUNNER_NAME": "cmux12-glaeda-3"}, {"RUNNER_NAME": "cmux12-glaeda", "GLAEDA_JOB_CLAIM": "light"}):
            with self.subTest(env):
                refused = gate(**env)
                self.assertEqual(refused.returncode, 1, refused.stdout)
                self.assertIn("did not give the job the whole mini", refused.stdout)
        self.assertEqual(gate(RUNNER_NAME="cmux12-glaeda-3", GLAEDA_JOB_CLAIM="exclusive").returncode, 0)


if __name__ == "__main__":
    unittest.main()
