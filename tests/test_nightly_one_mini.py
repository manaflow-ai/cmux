"""The whole nightly runs on one Mac mini while vars.CI_NIGHTLY_MINI is set.

Lawrence, 2026-11-04: "we need to just make nightlies build on a single mac mini", and no one cancels nightlies.
Before this, nightly-next run 41900945757 ran on cmux15, cmux7s and GitHub-hosted Ubuntu, and build-nightly-app
sometimes on ultra1. The whole-Mac signing claim on cmux15 then held jobs sent elsewhere (a verify waited 35 min).

With vars.CI_NIGHTLY_MINI (cmux15's light nightly-only runners, `glaeda-nightly-mini`), every job of nightly.yml,
on every attempt, event and picker output, takes one of three labels that only that mini carries
(cmuxterm-hq build-fleet/nightly_mini_policy_test.py):
  - glaeda's signing jobs (the hook's SIGNING_JOBS for nightly.yml, the whole-Mac claim):
    vars.CI_NIGHTLY_SIGN_RUNNER (`glaeda-trusted-next-signing`);
  - build-nightly-app: vars.CI_NIGHTLY_MINI_BUILDER (`glaeda-nightly-mini-builder`, the two warm builders);
  - every other job: vars.CI_NIGHTLY_MINI,
except the tail jobs that hold a release key (Sentry, content signing, R2, a GitHub App key, the pr-media terms) and
whose whole-Mac hold on the trusted signing runner would be long or wait-bound
(test_nightly_owned_minis_only.HOSTED_TAIL_JOBS): the mini's nightly-only runners are shared and persistent, so these
take an ephemeral one-job JIT VM (cmux-gcp-nightly-jit-x64) on every attempt, never GitHub-hosted Ubuntu (it starts
nothing in manaflow-ai; Leo, 2026-11-21: "the ci must flow") and never Blacksmith, and they run only outside the push
group. republish-nightly-deltas takes the signer only on nightly-next; classic and RC runs take the JIT VM
(test_nightly_owned_minis_only.NIGHTLY_NEXT_ONLY_OWNED), as their release uploads may wait out the rate limit.
Every Mac job (build, sign, notarize, verify, publish) runs on the mini. The light Linux jobs that hold no key
(LINUX_POOL_JOBS) take cmux-linux, the one label of every own-branch Linux job, in this mode too.
The nightly visual gate needs a GUI session runner, which the mini has not, so it skips in this mode.
"""
from __future__ import annotations

import random
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_nightly_never_blacksmith import JOBS, evaluate, parse_expression, sample  # noqa: E402
from test_nightly_owned_minis_only import (HOSTED_DISPATCH_JOBS, HOSTED_LOOP_JOBS, HOSTED_PREFLIGHT_JOBS,  # noqa: E402
                                           HOSTED_TAIL_JOBS,
                                           JIT_LABEL, NIGHTLY_NEXT_ONLY_OWNED, NIGHTLY_PINNED_JOBS, hosted_route)
import workflow_jobs  # noqa: E402

MINI, BUILDER, SIGN = "glaeda-nightly-mini", "glaeda-nightly-mini-builder", "glaeda-trusted-next-signing"
MODE = {"vars.CI_NIGHTLY_MINI": MINI, "vars.CI_NIGHTLY_MINI_BUILDER": BUILDER, "vars.CI_NIGHTLY_SIGN_RUNNER": SIGN}
# glaeda scripts/glaeda-cmux-runner-hook SIGNING_JOBS, nightly.yml entries: the jobs that take the whole Mac.
SIGNING = {"promote-nightly-next", "build-sign-notarize-nightly", "recover-nightly-next-notarization",
           "publish-nightly", "sign-nightly-identity-legacy", "generate-nightly-deltas",
           "promote-nightly-next-acked", "keep-published-dsyms", "republish-nightly-deltas", "nightly-next-one",
           "sign-live-code-variant",
           # RFD 0134 cut 2 (#54859): the .pkg build and sign, on the signer label with the rest.
           "nightly-next-pkg"}
VISUAL_GATE = {"route-visual-gate-nightly"}
LINUX_POOL_JOBS = {"resolve-nightly-cmux-tui-client", "resolve-nightly-ghostty-cli-helper",
                   "prepare-nightly-variant-primary", "prepare-nightly-variant", "await-nightly-tree-marker",
                   "check-nightly-app-store-shelf", "published-build",
                   "check-nightly-webviews", "early-nightly-webviews"}
# RFD 0021: the essential ones (test_nightly_owned_minis_only.NIGHTLY_PINNED_JOBS) take the nightly's reserved Linux
# label on a first push, schedule or dispatch attempt, and cmux-linux on a rerun or loop retry, in this mode too.
PINNED_LINUX = "cmux-gcp-nightly-x64"
WORKFLOWS = Path(__file__).resolve().parents[1] / ".github/workflows"


# The ephemeral route of a secret-holding job off the mini: the owned one-job JIT VM, never GitHub-hosted.
EPHEMERAL = JIT_LABEL
# nightly-tag-permission-probe.yml under any caller but nightly.yml (a standalone repair dispatch).
REPAIR_JIT = "cmux-gcp-repair-jit-x64"
NIGHTLY_CALLER = "manaflow-ai/cmux/.github/workflows/nightly.yml@refs/heads/nightly-next"


def want(name: str, ref: str = "refs/heads/nightly-next", attempt: object = 2, first: bool = False) -> str | list[str]:
    if name in NIGHTLY_NEXT_ONLY_OWNED and ref != "refs/heads/nightly-next":
        return EPHEMERAL  # classic and RC: their rate-limit waits must not hold the mini
    if name == "nightly-next-deltas":
        return [SIGN, MINI]  # both trusted signing and the declared one-mini label
    if name in SIGNING:
        return SIGN
    if name == "build-nightly-app":
        return BUILDER
    if name in NIGHTLY_PINNED_JOBS and first:
        return PINNED_LINUX
    if name in LINUX_POOL_JOBS:
        return "cmux-linux"
    # A tail or loop job takes the JIT nightly label on every attempt (test_nightly_owned_minis_only.hosted_route).
    return hosted_route(name, attempt) if name in HOSTED_TAIL_JOBS or name in HOSTED_LOOP_JOBS or name in HOSTED_PREFLIGHT_JOBS \
        or name in HOSTED_DISPATCH_JOBS else MINI


def resolve(source: str, rng: random.Random, extra: dict | None = None) -> tuple[object, dict]:
    if not source.startswith("${{"):
        return source, {}  # a plain label
    expression = source.removeprefix("${{").removesuffix("}}")
    context = {**sample(expression, rng), **MODE, **(extra or {})}
    return evaluate(parse_expression(expression), context), context


class NightlyOneMini(unittest.TestCase):
    def test_every_job_takes_the_nightly_mini(self) -> None:
        rng = random.Random(41900945757)
        failures = {}
        for name, job in JOBS.items():
            if job.get("uses") or name in VISUAL_GATE or name.startswith("visual-gate-") or name == "report-visual-gate-nightly":
                continue
            # Each matrix cell (`${{ matrix.pool }}` read as its values) is a route of its own.
            sources = workflow_jobs.runs_on_cells(job)
            if sources is None:
                failures[name] = "runs-on has a matrix value nothing resolves"
                continue
            for source in sources or [""]:
                for _ in range(200):
                    value, context = resolve(source, rng)
                    attempt = context.get("github.run_attempt", 2)
                    event = context.get("github.event_name")
                    first = attempt == 1 and (event in ("push", "schedule") or event == "workflow_dispatch"
                                              and not context.get("inputs.nightly_next_loop_retry"))
                    if value != want(name, context.get("github.ref", "refs/heads/nightly-next"), attempt, first):
                        failures[name] = (value, {k: v for k, v in context.items() if v and k.startswith(("github", "vars"))})
                        break
        self.assertEqual(sorted(failures), [], "\n".join(f"{k}: {v}" for k, v in sorted(failures.items())))

    def test_the_mode_is_off_without_the_variable(self) -> None:
        # Unset, every job keeps its route: build-nightly-app never asks for the mini's builder label.
        rng = random.Random(7)
        source = workflow_jobs.single_runs_on(JOBS["build-nightly-app"])
        for _ in range(200):
            value, _ = resolve(source, rng, {"vars.CI_NIGHTLY_MINI": "", "vars.CI_NIGHTLY_MINI_BUILDER": ""})
            self.assertNotEqual(value, BUILDER)

    def test_the_visual_gate_skips_on_the_mini(self) -> None:
        # The gate runs on an idle GUI session runner of another Mac; on one mini it does not run.
        condition = str(JOBS["route-visual-gate-nightly"]["if"])
        self.assertIn("vars.CI_NIGHTLY_MINI == ''", condition)

    def test_the_tag_permission_probe_keeps_its_ephemeral_runner(self) -> None:
        # It holds GLAEDA_ROUTE_APP_KEY, contents: write and OIDC; and glaeda admits it on the mini only when
        # nightly.yml calls it, so a standalone dispatch there would wait for ever. It takes a one-job JIT VM (never
        # a reused mini, never GitHub-hosted): the nightly's label under nightly.yml, the repair label otherwise.
        text = (WORKFLOWS / "nightly-tag-permission-probe.yml").read_text(encoding="utf-8")
        runs_on = re.findall(r"^\s+runs-on: (.+)$", text, re.M)
        self.assertTrue(runs_on)
        rng = random.Random(3)
        for source in runs_on:
            for caller, label in ((NIGHTLY_CALLER, EPHEMERAL),
                                  ("manaflow-ai/cmux/.github/workflows/nightly-tag-permission-probe.yml@refs/heads/main",
                                   REPAIR_JIT)):
                value, _ = resolve(source.strip(), rng, {"github.workflow_ref": caller})
                self.assertEqual(value, label, (caller, source))

    def test_the_variables_hold_only_the_mini_labels(self) -> None:
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
        import runner_label_policy as policy  # noqa: E402
        for name, good in (("CI_NIGHTLY_MINI", MINI), ("CI_NIGHTLY_MINI_BUILDER", BUILDER)):
            for value in ("", good):
                self.assertEqual(policy.drifted_runner_variables({name: value}), [], (name, value))
            for value in ("glaeda-nightly-only-m4pro", "blacksmith-6vcpu-macos-26", "macos-15", "ubuntu-24.04"):
                self.assertTrue(policy.drifted_runner_variables({name: value}), (name, value))

if __name__ == "__main__":
    unittest.main()
