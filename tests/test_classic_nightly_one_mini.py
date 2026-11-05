#!/usr/bin/env python3
"""The classic nightly runs on one Mac mini while vars.CI_CLASSIC_NIGHTLY_MINI is set.

Lawrence, 2026-11-04: "we need to just make nightlies build on a single mac mini", for next and classic, and
no one cancels nightlies. Classic run 41920015425 built, signed and verified on Blacksmith macOS, prepared on
cmux7s's trusted-main runner and decided on cmux12s.

With vars.CI_CLASSIC_NIGHTLY_MINI set (to cmux15's light nightly-only label, `glaeda-nightly-mini`), every job of
main's nightly.yml on a main push or schedule, on every attempt and picker output, takes a label only cmux15 carries
(cmuxterm-hq build-fleet/nightly_mini_policy_test.py):
  - build-nightly-app: vars.CI_CLASSIC_NIGHTLY_MINI_BUILDER (`glaeda-nightly-mini-builder`, the warm builders);
  - every other job: vars.CI_CLASSIC_NIGHTLY_MINI.
Except KEPT: every job that holds a secret (tests/test_ci_fork_runner_routing.py: no variable may move it; rule 7
of tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py for signing material) and verify-signed-nightly,
which runs the signed bundle (rule 6). Main has no owned-Mac path for them yet (feat-cmux-next's claim gate, Blacksmith
twin and test_ci_signing_owned_mac.py), so they keep their ephemeral route until that is ported. build-nightly-app
holds the cache-writer keys too, but its owned route is a documented exception already (SECRET_RUNNER_EXCEPTIONS).
The variable is separate from NEXT's vars.CI_NIGHTLY_MINI, so classic switches on its own. A workflow_dispatch and
an rc/** push keep their earlier routes: cmux15's trusted runners take only main's push and schedule jobs
(glaeda trusted_refusal), and its nightly-only runners only nightly-next and main.
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

JOBS = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8"))["jobs"]
MINI, BUILDER, SIGN = "glaeda-nightly-mini", "glaeda-nightly-mini-builder", "glaeda-trusted-next-signing"
MODE = {"vars.CI_CLASSIC_NIGHTLY_MINI": MINI, "vars.CI_CLASSIC_NIGHTLY_MINI_BUILDER": BUILDER,
        "vars.CI_NIGHTLY_SIGN_RUNNER": SIGN}
# glaeda scripts/glaeda-cmux-runner-hook SIGNING_JOBS, nightly.yml entries: the jobs that take the whole Mac.
SIGNING = {"promote-nightly-next", "build-sign-notarize-nightly", "recover-nightly-next-notarization",
           "publish-nightly", "publish-nightly-next-github", "publish-nightly-next-github-names",
           "sign-nightly-identity-legacy", "generate-nightly-deltas"}
REF = re.compile(r"\b(?:needs\.[\w-]+\.(?:outputs\.\w+|result)|inputs\.\w+|vars\.\w+)")
BLACKSMITH = "blacksmith-6vcpu-macos-26"


KEPT = SIGNING | {"verify-signed-nightly", "promote-nightly-next-acked", "await-release-surface-ack",
                  "refresh-compilation-cache", "refresh-test-compilation-cache", "pick-nightly-app-runner",
                  "pick-classic-prepare-runner", "republish-nightly-deltas"}


def want(name: str) -> str:
    return BUILDER if name == "build-nightly-app" else MINI


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
    def test_every_job_takes_the_nightly_mini(self) -> None:
        rng = random.Random(41920015425)
        failures = {}
        for name, job in JOBS.items():
            if job.get("uses"):
                continue  # the tag permission probe: a dispatch-only promote child, out of this mode
            for source in sources(job):
                for _ in range(200):
                    event = rng.choice(("push", "schedule"))
                    value, context = resolve(source, rng, "refs/heads/main", event, MODE)
                    if name in KEPT:
                        if value in (MINI, BUILDER, SIGN):
                            failures[name] = (value, {k: v for k, v in context.items() if v})
                            break
                    elif value != want(name):
                        failures[name] = (value, {k: v for k, v in context.items() if v})
                        break
        self.assertEqual(sorted(failures), [], "\n".join(f"{k}: {v}" for k, v in sorted(failures.items())))

    def test_the_mode_is_off_without_the_variable(self) -> None:
        rng = random.Random(7)
        off = {**MODE, "vars.CI_CLASSIC_NIGHTLY_MINI": "", "vars.CI_CLASSIC_NIGHTLY_MINI_BUILDER": ""}
        for name, job in JOBS.items():
            if job.get("uses") or name in KEPT:
                continue
            for source in sources(job):
                for _ in range(50):
                    value, _ = resolve(source, rng, "refs/heads/main", "push", off)
                    self.assertNotIn(value, (MINI, BUILDER), name)

    def test_a_dispatch_or_rc_push_keeps_its_route(self) -> None:
        # cmux15's trusted runners refuse a dispatch, and its nightly-only runners an rc/** ref.
        rng = random.Random(11)
        for name, job in JOBS.items():
            if job.get("uses"):
                continue
            for source in sources(job):
                for ref, event in (("refs/heads/main", "workflow_dispatch"), ("refs/heads/rc/1.2", "push")):
                    for _ in range(30):
                        value, _ = resolve(source, rng, ref, event, MODE)
                        self.assertNotIn(value, (MINI, BUILDER), (name, ref, event))

    def test_the_variables_hold_only_the_mini_labels(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import runner_label_policy as policy  # noqa: E402
        for name, good in (("CI_CLASSIC_NIGHTLY_MINI", MINI), ("CI_CLASSIC_NIGHTLY_MINI_BUILDER", BUILDER)):
            for value in ("", good):
                self.assertEqual(policy.drifted_runner_variables({name: value}), [], (name, value))
            for value in ("glaeda-nightly-only-m4pro", BLACKSMITH, "macos-15", "ubuntu-24.04"):
                self.assertTrue(policy.drifted_runner_variables({name: value}), (name, value))


if __name__ == "__main__":
    unittest.main()
