#!/usr/bin/env python3
"""Classic nightly's continuation (auto-resume-nightly-notarization.yml) runs on cmux15 while vars.CI_CLASSIC_NIGHTLY_MINI is set.

Lawrence, 2026-11-05: classic nightly runs fully on cmux15, 0 Blacksmith. glaeda (teamleaderleo/glaeda#1858,
AUTO_RESUME) admits main's exact copy of this workflow on its workflow_run after main's own nightly.yml run on main,
and on its workflow_dispatch from main (glaeda #1858 at 05ee748405c7 admits all eleven jobs):

- SIGNER_JOBS hold a release key (Apple certificate, notary API key, Sparkle key or R2 key) and take cmux15's trusted
  signing runner, the literal glaeda-trusted-next-signing (glaeda's exclusive class: the whole Mac). Each starts with
  the claim gate (tests/test_signing_runner_claim.py CLAIM_GATE), runs scripts/ci/signing-runner-claim.sh before any
  step that names a secret, names no secret in its job env, and deletes the keychain scripts/ci/signing-keychain.sh
  made in an `if: always()` step.
- LIGHT_JOBS hold no key and take vars.CI_CLASSIC_NIGHTLY_MINI (cmux15's nightly-only label, glaeda-nightly-mini).

A workflow_run from an rc/** nightly keeps every route (glaeda refuses it on cmux15). A workflow_run from any other
non-main branch (nightly-next on feat-cmux-next, most of this workflow's triggers) skips preflight in this mode: its
preflight only ever answered ready=false (reason nightly-next-continues-on-its-own-track), and cmux15 would refuse it.

Unset, every route, timeout and condition is the one it had before (BEFORE).
"""

from __future__ import annotations

import json
import random
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from test_ci_fork_runner_routing import parse_expression  # noqa: E402
from test_classic_nightly_one_mini import CLAIM_SCRIPT, RELEASE_SECRET, SECRET, evaluate  # noqa: E402
import test_signing_runner_claim as claim  # noqa: E402

WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/auto-resume-nightly-notarization.yml").read_text(encoding="utf-8"))
JOBS = WORKFLOW["jobs"]
MINI, SIGN = "glaeda-nightly-mini", "glaeda-trusted-next-signing"
CMUX15 = (MINI, SIGN, "glaeda-nightly-mini-builder")
# glaeda #1858 AUTO_RESUME_SIGNING_JOBS and AUTO_RESUME_LIGHT_JOBS. poll-outer, poll-stapled and publish ran only on
# Ubuntu until #36561 made them bash 3.2 safe.
SIGNER_JOBS = {"poll", "wait-and-staple", "poll-outer", "staple-outer", "poll-stapled", "staple-stapled", "publish",
               "generate-deltas", "republish-deltas"}
LIGHT_JOBS = {"preflight", "verify-stapled"}
GATE_MINUTES = 120
# The hook that admits main's classic nightly dispatch on cmux15: glaeda #1854 (ONE_MINI_NIGHTLY). glaeda's hook
# refuses a signing job whose commit does not list its sha (glaeda #1761).
# TODO(glaeda #1858): add the sha256 of the hook glaeda merges and pins for #1858 (AUTO_RESUME) to
# scripts/ci/glaeda-signing-hooks.txt and here, before this switch is set. Its open heads' hooks (7f286e38...,
# d2af2426...) are not final and are not listed.
ADMITTING_HOOKS = {"ef41cbd5be20def2d90c6faa6632641fa1310e5bb55c24c281a57c27d0047ad6"}

UBUNTU = ("github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_CLOUD_OVERFLOW_SAVED && "
          "'blacksmith-16vcpu-ubuntu-2404' || 'blacksmith-4vcpu-ubuntu-2404'")
MACOS = "github.repository_owner != 'manaflow-ai' && 'macos-26' || 'blacksmith-6vcpu-macos-26'"
# Each job's runs-on, timeout-minutes and (preflight) if before the switch: what it must stay while the variable is unset.
BEFORE_ROUTE = {"preflight": UBUNTU, "poll": UBUNTU, "wait-and-staple": MACOS, "poll-outer": UBUNTU,
                "staple-outer": MACOS, "poll-stapled": UBUNTU, "staple-stapled": MACOS, "verify-stapled": MACOS,
                "publish": UBUNTU, "generate-deltas": MACOS, "republish-deltas": UBUNTU}
BEFORE_TIMEOUT = {"preflight": 75, "poll": 90, "wait-and-staple": 180, "poll-outer": 360, "staple-outer": 150,
                  "poll-stapled": 360, "staple-stapled": 90, "verify-stapled": 30, "publish": 360,
                  "generate-deltas": 45, "republish-deltas": 360}
BEFORE_PREFLIGHT_IF = ("github.event_name == 'workflow_dispatch' || ((github.event.workflow_run.conclusion == 'failure' "
                       "|| github.event.workflow_run.conclusion == 'success') && "
                       "github.event.workflow_run.head_repository.full_name == github.repository)")


def context(rng: random.Random, event: str, branch: str, mode: str) -> dict:
    return {"github.repository_owner": rng.choice(("manaflow-ai", "manaflow-ai", "someone")),
            "github.repository": "manaflow-ai/cmux", "github.ref": "refs/heads/main", "github.event_name": event,
            "github.event.workflow_run.head_branch": branch if event == "workflow_run" else "",
            "github.event.workflow_run.conclusion": rng.choice(("success", "failure", "cancelled")),
            "github.event.workflow_run.head_repository.full_name": rng.choice(("manaflow-ai/cmux", "fork/cmux")),
            "vars.CI_CLOUD_OVERFLOW_SAVED": rng.choice(("", "1")), "vars.CI_CLASSIC_NIGHTLY_MINI": mode}


def value(source: object, ctx: dict) -> object:
    text = str(source).strip()
    if not text.startswith("${{"):
        return int(text) if text.isdigit() else text
    result = evaluate(parse_expression(text.removeprefix("${{").removesuffix("}}")), ctx)
    return int(result) if isinstance(result, (int, float)) or str(result).isdigit() else result


def condition(source: str, ctx: dict) -> bool:
    return bool(evaluate(parse_expression(source.strip().removeprefix("${{").removesuffix("}}")), ctx))


def cases(rng: random.Random, count: int):
    for _ in range(count):
        event = rng.choice(("workflow_run", "workflow_dispatch"))
        yield event, rng.choice(("main", "nightly-next", "rc/1.2", "feat-x")) if event == "workflow_run" else ""


class AutoResumeOneMini(unittest.TestCase):
    def test_the_job_sets_match_glaedas(self) -> None:
        self.assertEqual(SIGNER_JOBS | LIGHT_JOBS, set(JOBS))
        # Every job with release material signs on the signer; the light jobs hold none.
        held = {name for name, job in JOBS.items() if RELEASE_SECRET.search(json.dumps(job))}
        self.assertEqual(held, SIGNER_JOBS)

    def test_routes_with_the_switch_on(self) -> None:
        rng = random.Random(1858)
        for name, job in JOBS.items():
            for event, branch in cases(rng, 300):
                ctx = context(rng, event, branch, MINI)
                got = value(job["runs-on"], ctx)
                to_cmux15 = ctx["github.repository_owner"] == "manaflow-ai" and (
                    event == "workflow_dispatch" or branch == "main")
                want = (SIGN if name in SIGNER_JOBS else MINI) if to_cmux15 else value("${{ " + BEFORE_ROUTE[name] + " }}", ctx)
                self.assertEqual(got, want, (name, event, branch, ctx))

    def test_everything_is_as_before_with_the_switch_off(self) -> None:
        rng = random.Random(7)
        for name, job in JOBS.items():
            for event, branch in cases(rng, 200):
                ctx = context(rng, event, branch, "")
                self.assertEqual(value(job["runs-on"], ctx), value("${{ " + BEFORE_ROUTE[name] + " }}", ctx), name)
                self.assertEqual(value(job.get("timeout-minutes", 360), ctx), BEFORE_TIMEOUT[name], name)
            if name == "preflight":
                for event, branch in cases(rng, 200):
                    ctx = context(rng, event, branch, "")
                    self.assertEqual(condition(job["if"], ctx), condition(BEFORE_PREFLIGHT_IF, ctx), ctx)

    def test_a_routed_job_has_room_for_the_capacity_wait(self) -> None:
        # glaeda's capacity wait counts toward timeout-minutes (run 41967078498).
        for name in SIGNER_JOBS | LIGHT_JOBS:
            on = value(JOBS[name].get("timeout-minutes", 360), {"vars.CI_CLASSIC_NIGHTLY_MINI": MINI})
            self.assertEqual(on, BEFORE_TIMEOUT[name] + GATE_MINUTES, name)

    def test_preflight_skips_a_non_main_branch_cmux15_refuses(self) -> None:
        rng = random.Random(42029464345)
        job = JOBS["preflight"]
        for event, branch in cases(rng, 400):
            ctx = context(rng, event, branch, MINI)
            before = condition(BEFORE_PREFLIGHT_IF, ctx)
            skip = event == "workflow_run" and branch != "main" and not branch.startswith("rc/")
            self.assertEqual(condition(job["if"], ctx), before and not skip, ctx)

    def test_no_job_with_release_material_reaches_a_shared_label(self) -> None:
        rng = random.Random(20261105)
        for name, job in JOBS.items():
            if not RELEASE_SECRET.search(json.dumps(job)):
                continue
            for event, branch in cases(rng, 300):
                ctx = context(rng, event, branch, rng.choice((MINI, "", "blacksmith-6vcpu-macos-26")))
                got = value(job["runs-on"], ctx)
                self.assertFalse(str(got).startswith("glaeda-nightly-"), (name, got))

    def test_a_signer_job_holds_the_whole_mac_before_any_credential(self) -> None:
        self.assertFalse(SECRET.search(json.dumps(WORKFLOW.get("env") or {})), "workflow env names a secret")
        for name in SIGNER_JOBS:
            job = JOBS[name]
            steps = job["steps"]
            with self.subTest(job=name):
                first = steps[0]
                self.assertEqual((first.get("id"), first.get("name")), (claim.CLAIM_GATE_ID, claim.CLAIM_GATE_NAME))
                self.assertEqual(str(first.get("run", "")).strip(), claim.CLAIM_GATE.strip())
                self.assertNotIn("if", first, "the gate is unconditional")
                self.assertFalse(SECRET.search(json.dumps(job.get("env") or {})), "job env names a secret")
                claims = [i for i, step in enumerate(steps) if CLAIM_SCRIPT in str(step.get("run", ""))]
                secrets = [i for i, step in enumerate(steps) if SECRET.search(json.dumps(step))]
                self.assertTrue(claims and secrets, (claims, secrets))
                self.assertLess(claims[0], secrets[0], "the claim script runs before the first step with a secret")
                self.assertNotIn("if", steps[claims[0]], "the claim script is unconditional")
                if "signing-keychain.sh create" in json.dumps(steps):
                    self.assertTrue(any("always()" in str(step.get("if", "")) and
                                        "signing-keychain.sh delete" in str(step.get("run", "")) for step in steps),
                                    "an always() step deletes the keychain")

    def test_the_admitting_hooks_are_listed(self) -> None:
        self.assertLessEqual(ADMITTING_HOOKS, set(claim.SIGNING_HOOKS))

    def test_a_light_job_reads_no_secret(self) -> None:
        for name in LIGHT_JOBS:
            self.assertFalse(SECRET.search(json.dumps(JOBS[name])), name)


if __name__ == "__main__":
    unittest.main()
