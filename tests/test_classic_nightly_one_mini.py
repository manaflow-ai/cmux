#!/usr/bin/env python3
"""The classic nightly runs end to end on one Mac mini, cmux15, while vars.CI_CLASSIC_NIGHTLY_MINI is set.

Lawrence, 2026-11-04: "we need to just make nightlies build on a single mac mini", for next and classic, and
no one cancels nightlies. Classic run 41920015425 built, signed and verified on Blacksmith macOS, prepared on
cmux7s's trusted-main runner and decided on cmux12s. Lawrence, 2026-11-05: every classic nightly job on cmux15,
0 Blacksmith, behind the same switch (run 41985952019 still signed and verified on Blacksmith).

With vars.CI_CLASSIC_NIGHTLY_MINI set (to cmux15's light nightly-only label, `glaeda-nightly-mini`), every job of
main's nightly.yml on main, on every attempt and picker output, takes one of cmux15's labels:

- SIGNER_JOBS, the jobs that sign (Developer ID, notarization and Sparkle keys), take cmux15's trusted signing
  runner, the literal glaeda-trusted-next-signing, on a push or schedule (the events glaeda's trusted_refusal admits
  there; a dispatch can check out any ref, so it keeps its route). A literal: no variable chooses where signing
  secrets go. Each starts with the claim gate (tests/test_signing_runner_claim.py CLAIM_GATE), runs
  scripts/ci/signing-runner-claim.sh before any step that names a secret, and deletes the keychain
  scripts/ci/signing-keychain.sh made in an `if: always()` step. glaeda gives each the exclusive class (SIGNING,
  glaeda's SIGNING_JOBS), so it holds the whole Mac.
- build-nightly-app takes cmux15's nightly-only builder label, glaeda-nightly-mini-builder.
- every other job takes `glaeda-nightly-mini` (glaeda-nightly-only-admit takes push, schedule and dispatch there).
  A job there that holds a secret reads it only in steps that do not run in this mode, except OPEN_SECRETS.

KEPT keep their route: the three publication jobs that never run on main (UNREACHED_ON_MAIN), NEXT's
promotion (a dispatch of main every few minutes, which the trusted signing runner refuses;
tests/test_nightly_signing_on_cmux15.py on feat-cmux-next keeps it too), and the two Blacksmith cache warmers, which write
caches only Blacksmith pull request jobs read and run only on a seed_only dispatch while CI_PR_POOL_OWNED is 1 (tests/test_ci_nightly_off_blacksmith.py NOT_NIGHTLY_JOBS).

The variable is separate from NEXT's vars.CI_NIGHTLY_MINI, so classic switches on its own. Unset, every route is
the one it had before. An rc/** push keeps every route (cmux15's nightly-only runners refuse rc/**, and its trusted
runners take only main).
"""

from __future__ import annotations

import json
import random
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from test_ci_fork_runner_routing import parse_expression  # noqa: E402

WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8"))
JOBS = WORKFLOW["jobs"]
MINI, SIGN, BUILDER = "glaeda-nightly-mini", "glaeda-trusted-next-signing", "glaeda-nightly-mini-builder"
CMUX15 = (MINI, SIGN, BUILDER)
MODE = {"vars.CI_CLASSIC_NIGHTLY_MINI": MINI, "vars.CI_NIGHTLY_SIGN_RUNNER": SIGN}
# glaeda scripts/glaeda-cmux-runner-hook SIGNING_JOBS, nightly.yml entries: the jobs that take the whole Mac.
SIGNING = {"promote-nightly-next", "build-sign-notarize-nightly", "recover-nightly-next-notarization",
           "publish-nightly", "publish-nightly-next-github", "publish-nightly-next-github-names",
           "sign-nightly-identity-legacy", "generate-nightly-deltas"}
SIGNER_JOBS = {"build-sign-notarize-nightly"}
TRUSTED_EVENTS = ("push", "schedule")
REF = re.compile(r"\b(?:needs\.[\w-]+\.(?:outputs\.\w+|result)|inputs\.\w+|vars\.\w+)")
BLACKSMITH = "blacksmith-6vcpu-macos-26"
# publish-nightly runs only while decide's should_publish is false, which a push or schedule of main never is (main
# publishes through auto-resume-nightly-notarization.yml), so on main it never takes a runner.
UNREACHED_ON_MAIN = {"publish-nightly"}
KEPT = {"promote-nightly-next", "await-release-surface-ack", "promote-nightly-next-acked",
        "refresh-compilation-cache", "refresh-test-compilation-cache"} | UNREACHED_ON_MAIN
# Jobs on the shared nightly-only runners that hold a secret in this mode, by design: the CI cache writer keys and
# the Sentry token of the app build, as on feat-cmux-next's one-mini nightly.
OPEN_SECRETS = {"build-nightly-app"}
# Release material (rule 6 of tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py) and App keys.
RELEASE_SECRET = re.compile(r"secrets\.(APPLE_|ASC_API_|IOS_|SPARKLE_|NIGHTLY_SPARKLE_|CMUX_RELEASE_APP_|CF_R2_"
                            r"|CONTENT_SIGNING_|NIGHTLY_NEXT_R2_|HOMEBREW_TAP_TOKEN)")
SECRET = re.compile(r"\bsecrets\.(?!GITHUB_TOKEN\b)\w+|create-github-app-token@")
CLAIM_SCRIPT = "scripts/ci/signing-runner-claim.sh"


def want(name: str, event: str) -> str | None:
    """The label the job takes in this mode on main, or None for its old route (never one of CMUX15)."""
    if name in SIGNER_JOBS:
        return SIGN if event in TRUSTED_EVENTS else None
    if name == "build-nightly-app":
        return BUILDER
    return MINI


def evaluate(node, context):
    kind = node[0]
    if kind in ("and", "or"):
        value = None
        for child in node[1]:
            value = evaluate(child, context)
            if bool(value) == (kind == "or"):
                return value
        return value
    if kind == "literal":
        value = node[1]
        if value.startswith("'"):
            return value[1:-1].replace("''", "'")
        return {"true": True, "false": False, "null": None}.get(value, value)
    if kind == "ref":
        return context.get(node[1], "")
    if kind == "cmp":
        left, right = (str(evaluate(arg, context)).lower() for arg in node[2:])
        if node[1] in (">", "<", ">=", "<="):
            left, right = float(left or 0), float(right or 0)
            return {">": left > right, "<": left < right, ">=": left >= right, "<=": left <= right}[node[1]]
        return (left == right) == (node[1] == "==")
    if kind == "not":
        return not evaluate(node[1], context)
    if kind == "call":
        args = [evaluate(arg, context) for arg in node[2]]
        name = node[1].lower()
        if name == "startswith":
            return str(args[0]).lower().startswith(str(args[1]).lower())
        if name == "format":
            return args[0].format(*args[1:])
        if name == "fromjson":
            try:
                return json.loads(args[0])
            except (TypeError, json.JSONDecodeError):
                return {}
        if name == "contains":
            return str(args[1]).lower() in str(args[0]).lower()
    if kind == "prop":
        value = evaluate(node[1], context)
        return value.get(node[2], "") if isinstance(value, dict) else ""
    raise ValueError(node)


def sample(source: str, rng: random.Random, ref: str, event: str) -> dict:
    context = {"github.repository_owner": "manaflow-ai", "github.repository": "manaflow-ai/cmux",
               "github.run_attempt": rng.choice((1, 2, 3)), "github.ref": ref, "github.event_name": event,
               "github.ref_name": ref.removeprefix("refs/heads/")}
    for found in set(REF.findall(source)):
        leaf = found.rsplit(".", 1)[-1]
        if found.startswith("vars."):
            context[found] = rng.choice(("", "1", BLACKSMITH, "glaeda-trusted-std-xcode-26.6"))
        elif found.startswith("inputs."):
            context[found] = rng.choice(("", "x"))
        elif leaf in ("attempt",):
            context[found] = rng.choice(("1", "2", ""))
        elif leaf in ("trusted", "fast_build"):
            context[found] = rng.choice(("true", "false", ""))
        else:
            context[found] = rng.choice((BLACKSMITH, ""))
    return context


def resolve(source: str, rng: random.Random, ref: str, event: str, mode: dict) -> tuple[object, dict]:
    if not source.startswith("${{"):
        return source, {}
    expression = source.removeprefix("${{").removesuffix("}}")
    context = {**sample(expression, rng, ref, event), **mode}
    return evaluate(parse_expression(expression), context), context


def sources(job: dict) -> list[str]:
    runs_on = str(job.get("runs-on", ""))
    return list(job["strategy"]["matrix"]["pool"]) if runs_on == "${{ matrix.pool }}" else [runs_on]


class ClassicNightlyOneMini(unittest.TestCase):
    def test_every_job_takes_a_cmux15_label(self) -> None:
        rng = random.Random(41920015425)
        failures = {}
        for name, job in JOBS.items():
            if job.get("uses"):
                continue  # the tag permission probe: a dispatch-only promote child, out of this mode
            for source in sources(job):
                for _ in range(200):
                    event = rng.choice(("push", "schedule", "workflow_dispatch"))
                    value, context = resolve(source, rng, "refs/heads/main", event, MODE)
                    expected = None if name in KEPT else want(name, event)
                    if (value in CMUX15) if expected is None else (value != expected):
                        failures[name] = (event, value, {k: v for k, v in context.items() if v})
                        break
        self.assertEqual(sorted(failures), [], "\n".join(f"{k}: {v}" for k, v in sorted(failures.items())))

    def test_the_signer_jobs_are_glaedas_signing_jobs(self) -> None:
        self.assertLessEqual(SIGNER_JOBS, SIGNING)
        held = {name for name, job in JOBS.items() if RELEASE_SECRET.search(json.dumps(job))}
        # Every job with release material signs on the signer, except NEXT's promotion (KEPT).
        self.assertEqual(held - KEPT, SIGNER_JOBS)

    def test_no_job_with_release_material_reaches_a_shared_label(self) -> None:
        # Any event, attempt, picker output and switch value: never the nightly-only runners.
        rng = random.Random(20261105)
        for name, job in JOBS.items():
            if job.get("uses") or not RELEASE_SECRET.search(json.dumps(job)):
                continue
            for source in sources(job):
                for _ in range(300):
                    event = rng.choice(("push", "schedule", "workflow_dispatch"))
                    mode = {**MODE, "vars.CI_CLASSIC_NIGHTLY_MINI": rng.choice((MINI, "", BLACKSMITH))}
                    value, _ = resolve(source, rng, rng.choice(("refs/heads/main", "refs/heads/rc/1.2")), event, mode)
                    self.assertNotIn(value, (MINI, BUILDER), name)
                    self.assertFalse(str(value).startswith("glaeda-nightly-"), (name, value))

    def test_a_signer_job_holds_the_whole_mac_before_any_credential(self) -> None:
        import test_signing_runner_claim as claim  # noqa: PLC0415
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
                text = json.dumps(steps)
                if "signing-keychain.sh create" in text:
                    self.assertTrue(any("always()" in str(step.get("if", "")) and
                                        "signing-keychain.sh delete" in str(step.get("run", "")) for step in steps),
                                    "an always() step deletes the keychain")

    def test_a_mini_job_reads_no_secret_in_this_mode(self) -> None:
        # The nightly-only runners share cmux15 with every other nightly job: a secret there could outlive the job.
        rng = random.Random(5323)
        for name, job in JOBS.items():
            if job.get("uses") or name in KEPT | SIGNER_JOBS | OPEN_SECRETS:
                continue
            self.assertFalse(SECRET.search(json.dumps({k: v for k, v in job.items() if k != "steps"})), name)
            for step in job.get("steps") or []:
                if not SECRET.search(json.dumps(step)):
                    continue
                condition = str(step.get("if", "")).strip()
                with self.subTest(job=name, step=step.get("name")):
                    self.assertTrue(condition, "a step with a secret on the mini needs an if that is false here")
                    expression = condition.removeprefix("${{").removesuffix("}}")
                    for _ in range(50):
                        event = rng.choice(("push", "schedule", "workflow_dispatch"))
                        context = {**sample(expression, rng, "refs/heads/main", event), **MODE}
                        context.update({"steps.route-token.outcome": rng.choice(("failure", "success", ""))})
                        self.assertFalse(evaluate(parse_expression(expression), context), context)

    def test_a_mini_job_has_room_for_the_capacity_wait(self) -> None:
        # glaeda's job-started hook on cmux15 waits for capacity inside "Set up runner" with no limit, and the wait
        # counts toward timeout-minutes: run 41967078498's pick-classic-sign-runner (6 min) was cancelled there
        # before its first step. With the mode on, a mini job's fixed limit gets GATE_MINUTES more; off, it is unchanged.
        gate = 120
        rng = random.Random(41967078498)
        short = {}
        for name, job in JOBS.items():
            route = " ".join(sources(job)) if "runs-on" in job or "strategy" in job else ""
            if "CI_CLASSIC_NIGHTLY_MINI" not in route or "timeout-minutes" not in job:
                continue
            raw = job["timeout-minutes"]
            expression = str(raw).removeprefix("${{").removesuffix("}}")
            limits = []
            for value in ("", MINI):
                result = evaluate(parse_expression(expression), {"vars.CI_CLASSIC_NIGHTLY_MINI": value})
                limits.append(int(result))
            if limits[0] < 6 * 60 and limits[1] != limits[0] + gate:
                short[name] = tuple(limits)
        self.assertEqual(short, {}, "mini jobs whose timeout has no room for glaeda's capacity wait")

    def test_the_mode_is_off_without_the_variable(self) -> None:
        rng = random.Random(7)
        off = {**MODE, "vars.CI_CLASSIC_NIGHTLY_MINI": ""}
        for name, job in JOBS.items():
            if job.get("uses") or name in KEPT:
                continue
            for source in sources(job):
                for _ in range(50):
                    event = rng.choice(("push", "schedule", "workflow_dispatch"))
                    value, _ = resolve(source, rng, "refs/heads/main", event, off)
                    self.assertNotIn(value, CMUX15, name)

    def test_an_rc_push_keeps_its_route(self) -> None:
        # cmux15's nightly-only runners refuse an rc/** ref.
        rng = random.Random(11)
        for name, job in JOBS.items():
            if job.get("uses"):
                continue
            for source in sources(job):
                for ref, event in (("refs/heads/rc/1.2", "push"), ("refs/heads/rc/1.2", "workflow_dispatch")):
                    for _ in range(30):
                        value, _ = resolve(source, rng, ref, event, MODE)
                        self.assertNotIn(value, CMUX15, (name, ref, event))

    def test_the_variables_hold_only_the_mini_labels(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import runner_label_policy as policy  # noqa: E402
        for name, good in (("CI_CLASSIC_NIGHTLY_MINI", MINI),):
            for value in ("", good):
                self.assertEqual(policy.drifted_runner_variables({name: value}), [], (name, value))
            for value in ("glaeda-nightly-only-m4pro", BLACKSMITH, "macos-15", "ubuntu-24.04"):
                self.assertTrue(policy.drifted_runner_variables({name: value}), (name, value))


if __name__ == "__main__":
    unittest.main()
