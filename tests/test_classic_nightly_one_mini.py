#!/usr/bin/env python3
"""The classic nightly runs its open jobs on one Mac mini while vars.CI_CLASSIC_NIGHTLY_MINI is set.

Lawrence, 2026-11-04: "we need to just make nightlies build on a single mac mini", for next and classic, and
no one cancels nightlies. Classic run 41920015425 built, signed and verified on Blacksmith macOS, prepared on
cmux7s's trusted-main runner and decided on cmux12s.

With vars.CI_CLASSIC_NIGHTLY_MINI set (to cmux15's light nightly-only label, `glaeda-nightly-mini`), every job of
main's nightly.yml on main (push, schedule or dispatch: glaeda-nightly-only-admit takes all three there), on every
attempt and picker output, takes that label, except KEPT. The variable is separate from NEXT's vars.CI_NIGHTLY_MINI,
so classic switches on its own. An rc/** push keeps every route (the nightly-only runners refuse rc/**).

KEPT keep their route: every job that holds a key (signing material, Sparkle, R2, App keys, Sentry:
tests/test_ci_fork_runner_routing.py lets no variable move them, and they must not run on the shared nightly-only
runners), verify-signed-nightly, which runs the signed bundle (rule 6 of
tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py), and the helper build (Zig 0.15.2 cannot link main's
helper on macOS 26). Main has no owned-Mac signing path yet (feat-cmux-next's claim gate and Blacksmith twin), and
glaeda's trusted runners refuse a dispatch, which is most of main's nightly runs.
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
MINI, SIGN = "glaeda-nightly-mini", "glaeda-trusted-next-signing"
MODE = {"vars.CI_CLASSIC_NIGHTLY_MINI": MINI, "vars.CI_NIGHTLY_SIGN_RUNNER": SIGN}
# glaeda scripts/glaeda-cmux-runner-hook SIGNING_JOBS, nightly.yml entries: the jobs that take the whole Mac.
SIGNING = {"promote-nightly-next", "build-sign-notarize-nightly", "recover-nightly-next-notarization",
           "publish-nightly", "publish-nightly-next-github", "publish-nightly-next-github-names",
           "sign-nightly-identity-legacy", "generate-nightly-deltas"}
REF = re.compile(r"\b(?:needs\.[\w-]+\.(?:outputs\.\w+|result)|inputs\.\w+|vars\.\w+)")
BLACKSMITH = "blacksmith-6vcpu-macos-26"


KEPT = SIGNING | {"verify-signed-nightly", "promote-nightly-next-acked", "await-release-surface-ack",
                  "refresh-compilation-cache", "refresh-test-compilation-cache", "pick-nightly-app-runner",
                  "pick-classic-prepare-runner", "republish-nightly-deltas",
                  "build-nightly-app", "build-nightly-ghostty-cli-helper"}


def want(name: str) -> str:
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
    def test_every_job_takes_the_nightly_mini(self) -> None:
        rng = random.Random(41920015425)
        failures = {}
        for name, job in JOBS.items():
            if job.get("uses"):
                continue  # the tag permission probe: a dispatch-only promote child, out of this mode
            for source in sources(job):
                for _ in range(200):
                    event = rng.choice(("push", "schedule", "workflow_dispatch"))
                    value, context = resolve(source, rng, "refs/heads/main", event, MODE)
                    if name in KEPT:
                        if value in (MINI, SIGN):
                            failures[name] = (value, {k: v for k, v in context.items() if v})
                            break
                    elif value != want(name):
                        failures[name] = (value, {k: v for k, v in context.items() if v})
                        break
        self.assertEqual(sorted(failures), [], "\n".join(f"{k}: {v}" for k, v in sorted(failures.items())))

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
                    value, _ = resolve(source, rng, "refs/heads/main", "push", off)
                    self.assertNotEqual(value, MINI, name)

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
                        self.assertNotEqual(value, MINI, (name, ref, event))

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
