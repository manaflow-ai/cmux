#!/usr/bin/env python3
"""No nightly.yml job can be routed to Blacksmith.

Nightlies run only on our own runners (Lawrence, 2026-10-30: "nightlies never use Blacksmith"). Run
41699137799 still put ten publication jobs on blacksmith-4vcpu-ubuntu-2404 and published-in on
blacksmith-32vcpu-ubuntu-2404; run 41717500642 put signer-build there. Every job takes our nightly
Macs (or, for an owned-Mac signing job glaeda holds whole, the owned nightly slot). A job that holds a
signing secret and that glaeda's exclusive class does not admit stays on GitHub-hosted Ubuntu, the
ephemeral runner the signing-secret rules allow (tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py
rule 7), never on Blacksmith.

Each job's runs-on is evaluated for manaflow-ai over sampled attempts, refs, events and picker outputs.
A picker output that can name a Blacksmith label (nightly_sign_runner.py's picks, the Linux overflow of
nightly_linux_admission.py and portable_job_placement.py, the visual gate's pick) is set to one; the
result must never be a Blacksmith label, nor empty.
"""

from __future__ import annotations

import random
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from nightly_workflow_text import expand as nightly_expand  # noqa: E402
from test_ci_fork_runner_routing import parse_expression  # noqa: E402
from test_nightly_trusted_routing import evaluate  # noqa: E402

import yaml  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
JOBS = yaml.safe_load(nightly_expand((ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")))["jobs"]

BLACKSMITH = "blacksmith-4vcpu-ubuntu-2404"
# What a Blacksmith-reachable runs-on names: a literal label, a RUNNER_POOLS member, or the variables
# that hold Blacksmith labels (LINUX_RUNNER, MACOS_RUNNER_*).
BLACKSMITH_ROUTE = re.compile(r"blacksmith-\d+vcpu-|vars\.RUNNER_POOLS|vars\.MACOS_RUNNER|vars\.LINUX_RUNNER")
# Picker outputs that only ever name Blacksmith labels (nightly_sign_runner.py, nightly_build_runner.py's
# `blacksmith`): no nightly runs-on may read them.
BLACKSMITH_ONLY_OUTPUTS = re.compile(
    r"needs\.pick-nightly-sign-runner\.outputs\.(?:runner|alternate|linux|linux_alternate)\b"
    r"|needs\.pick-nightly-build-runner\.outputs\.blacksmith\b"
    r"|needs\.find-nightly-next-recovery\.outputs\.(?:sign_runner|sign_alternate)\b")
# Outputs whose producer names only our own runners (glaeda picks, the nightly-only variable, the
# per-mini placement), so a sample sets them to an owned label or leaves them empty.
OWNED_OUTPUTS = {
    "needs.pick-nightly-build-runner.outputs.owned", "needs.pick-nightly-build-runner.outputs.trusted",
    "needs.pick-nightly-build-runner.outputs.helper", "needs.pick-nightly-build-runner.outputs.dedicated",
    "needs.pick-nightly-sign-runner.outputs.owned", "needs.pick-nightly-sign-runner.outputs.sign_owned",
    "needs.pick-nightly-sign-runner.outputs.sign_owned_pool",
    # One glaeda-runner-<name> label per post-sign verify job (nightly_build_runner.off_signing_verify_route()).
    "needs.pick-nightly-sign-runner.outputs.verify_signed", "needs.pick-nightly-sign-runner.outputs.verify_dmg",
    "needs.decide.outputs.early_mini_runner", "needs.build-nightly-app.outputs.light_mini_runner",
}
# decide's early placement (nightly_linux_admission.py: a fleet receipt's runner, hosted-light, or its owned
# OVERFLOW) and build-nightly-app's light placement (fleet Linux or an owned mini).
OWNED_PLACEMENT = re.compile(r"needs\.decide\.outputs\.early_\w+_runner|needs\.build-nightly-app\.outputs\.light_\w+_runner")
OWNED_LABEL = '["glaeda-nightly-only-m4pro","glaeda-runner-cmux15-glaeda-nightly-only-3"]'
# Outputs read as conditions, with the values they take.
CONDITION_OUTPUTS = {
    "attempt": ("1", "2", ""), "early_attempt": ("1", "2", ""), "light_attempt": ("1", "2", ""),
    "track": ("nightly-next", "nightly"), "hosted_slow": ("true", "false", ""),
    "result": ("success", "failure", "skipped"), "hit": ("true", "false"),
    "mode": ("off", "gate", ""), "found": ("true", "false"), "accepted": ("true", "false"),
    "fast_build": ("true", "false"),
}
REF = re.compile(r"\b(?:needs\.[\w-]+\.(?:outputs\.\w+|result)|inputs\.\w+|vars\.\w+)")
VARS = {
    "vars.LINUX_RUNNER": ("blacksmith-4vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404", ""),
    "vars.MACOS_RUNNER_26": ("blacksmith-6vcpu-macos-26", ""),
    "vars.RUNNER_POOLS": ('{"linux":"blacksmith-4vcpu-ubuntu-2404","linux_4":"blacksmith-4vcpu-ubuntu-2404",'
                          '"linux_16":"blacksmith-16vcpu-ubuntu-2404","linux_32":"blacksmith-32vcpu-ubuntu-2404",'
                          '"macos_26":"blacksmith-6vcpu-macos-26"}', ""),
    "vars.CI_NIGHTLY_ONLY_RUNNER": ("glaeda-nightly-only-m4pro", ""),
    "vars.CI_NIGHTLY_ONLY_BUILDER_RUNNER": ("glaeda-nightly-only-m4pro-builder", ""),
    "vars.CI_NIGHTLY_NEXT_BUILD_RUNNER": ("glaeda-nightly-std-xcode-26.6", ""),
    "vars.CI_SIDE_LANE_RUNNER": ("glaeda-side-std-xcode-26.6", ""),
    "vars.CI_NIGHTLY_SIGN_RUNNER": ("glaeda-trusted-next-signing", ""),
    "vars.CI_NIGHTLY_SIGNING_POOL": ("glaeda-signing-xcode-26.6", ""),
    "vars.CI_SEED_TRUSTED_POOL": ("glaeda-trusted-std-xcode-26.6", ""),
    "vars.CI_PR_POOL_OWNED": ("1", "0"),
}


def manaflow_route(name: str) -> str:
    """The job's runs-on source for manaflow-ai: what follows the fork short-circuit."""
    runs_on = str(JOBS[name].get("runs-on", ""))
    return re.sub(r"github\.repository_owner != 'manaflow-ai' && '[^']*' \|\|", "", runs_on)


def sample(source: str, rng: random.Random) -> dict:
    context = {
        "github.repository_owner": "manaflow-ai", "github.repository": "manaflow-ai/cmux",
        "github.run_attempt": rng.choice((1, 2, 3)),
        "github.ref": rng.choice(("refs/heads/nightly-next", "refs/heads/main")),
        "github.event_name": rng.choice(("push", "schedule", "workflow_dispatch")),
    }
    context["github.ref_name"] = context["github.ref"].removeprefix("refs/heads/")
    for ref in set(REF.findall(source)):
        leaf = ref.rsplit(".", 1)[-1]
        if ref in VARS:
            context[ref] = rng.choice(VARS[ref])
        elif ref.startswith("vars."):
            context[ref] = rng.choice(("", "1"))
        elif ref.startswith("inputs."):
            context[ref] = rng.choice(("", "x"))
        elif leaf in CONDITION_OUTPUTS:
            context[ref] = rng.choice(CONDITION_OUTPUTS[leaf])
        elif leaf.endswith("_jobs"):
            context[ref] = rng.choice(("", " " + " ".join(JOBS) + " "))
        elif ref in OWNED_OUTPUTS or OWNED_PLACEMENT.fullmatch(ref):
            context[ref] = rng.choice((OWNED_LABEL, ""))
        else:
            context[ref] = rng.choice((BLACKSMITH, ""))
    return context


class NightlyNeverBlacksmith(unittest.TestCase):
    def test_no_runs_on_names_a_blacksmith_route(self) -> None:
        offenders = sorted(name for name, job in JOBS.items()
                           if BLACKSMITH_ROUTE.search(manaflow_route(name).replace("'blacksmith')", "")))
        self.assertEqual(offenders, [], "these nightly jobs can still take a Blacksmith label")

    def test_no_runs_on_reads_a_blacksmith_pick(self) -> None:
        offenders = sorted(name for name in JOBS if BLACKSMITH_ONLY_OUTPUTS.search(manaflow_route(name)))
        self.assertEqual(offenders, [], "these nightly jobs read a picker output that only names Blacksmith")

    def test_every_route_resolves_to_our_runners(self) -> None:
        rng = random.Random(41717500642)
        failures = {}
        for name, job in JOBS.items():
            runs_on = str(job.get("runs-on", ""))
            if job.get("uses"):
                continue  # a reusable workflow: test_called_workflows_never_take_blacksmith reads its jobs
            if runs_on == "${{ matrix.pool }}":
                pools = job["strategy"]["matrix"]["pool"]
                if any(BLACKSMITH_ROUTE.search(re.sub(r"github\.repository_owner != 'manaflow-ai' && '[^']*' \|\|", "", p))
                       for p in pools):
                    failures[name] = pools
                continue
            if runs_on == "${{ needs.route-visual-gate-nightly.outputs.runs_on }}":
                continue  # cmux_next_media_runner.py --idle-now: an idle owned session runner, else the job skips
            if not runs_on.startswith("${{"):
                if "blacksmith" in runs_on or not runs_on:
                    failures[name] = runs_on
                continue
            source = runs_on.removeprefix("${{").removesuffix("}}")
            expression = parse_expression(source)
            for _ in range(400):
                context = sample(source, rng)
                value = evaluate(expression, context)
                if not value or "blacksmith" in str(value).lower():
                    failures[name] = (value, {k: v for k, v in context.items() if v})
                    break
        self.assertEqual(sorted(failures), [], "\n".join(f"{k}: {v}" for k, v in sorted(failures.items())))

    def test_called_workflows_never_take_blacksmith(self) -> None:
        for name, job in JOBS.items():
            uses = str(job.get("uses", ""))
            if not uses.startswith("./.github/workflows/"):
                continue
            called = yaml.safe_load((ROOT / uses.removeprefix("./")).read_text(encoding="utf-8"))
            for inner, spec in called["jobs"].items():
                with self.subTest(job=name, inner=inner):
                    self.assertFalse(BLACKSMITH_ROUTE.search(str(spec.get("runs-on", ""))), spec.get("runs-on"))


    def test_the_sampler_catches_a_blacksmith_fallback(self) -> None:
        source = "needs.pick-nightly-sign-runner.outputs.sign_owned_pool || needs.pick-nightly-sign-runner.outputs.linux"
        rng = random.Random(1)
        values = {evaluate(parse_expression(source), sample(source, rng)) for _ in range(50)}
        self.assertIn(BLACKSMITH, values)


if __name__ == "__main__":
    unittest.main()
