#!/usr/bin/env python3
"""cmux-tui macOS jobs never take the nightly build's Blacksmith label.

Blacksmith's macOS capacity is shared org-wide, and the nightly app build runs
on blacksmith-12vcpu-macos-26. Two cmux-tui workloads reached that label through
vars.MACOS_RUNNER_PR (which names it):

- cmux-tui.yml's release-path dogfood build, on every attempt (#20612).
- cmux-tui-artifacts.yml's cmux_next_ daemon tests and macOS build legs on a
  re-run: attempt 1 takes the owned side label, but
  cmux-tui-artifacts-retry re-runs a failed run's jobs (attempt 2 and 3), and
  those fell through to vars.MACOS_RUNNER_PR. Run 38579574731 attempt 2 ran
  the daemon tests on blacksmith-12vcpu-macos-26.

This test evaluates each route expression against the repository's variables
for every owner, event, ref and attempt the workflows see.
"""
from __future__ import annotations

import itertools
import json
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

from test_ci_fork_runner_routing import parse_expression  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
NIGHTLY_LABEL = "blacksmith-12vcpu-macos-26"
SIDE_LABEL = "glaeda-side-std-xcode-26.6"
PROMOTE_LABEL = "glaeda-promote-trusted-std-xcode-26.6"
DAEMON_LABEL = "glaeda-daemon-tests-xcode-26.6"

# The repository's variables as of 2026-10-14 (gh variable list), the ones
# these routes read. MACOS_RUNNER_PR is the nightly label.
LIVE_VARS = {
    "CI_PR_POOL_OWNED": "1",
    "CI_SIDE_LANE_RUNNER": SIDE_LABEL,
    "CI_LIGHT_LANE_RUNNER": "glaeda-side-light-xcode-26.6",
    "CI_NEXT_PROMOTE_POOL": PROMOTE_LABEL,
    "CI_NEXT_DAEMON_POOL": "",
    "CI_PAID_MACOS_OVERFLOW": "",
    "MACOS_RUNNER_15": "blacksmith-6vcpu-macos-15",
    "MACOS_RUNNER_26": NIGHTLY_LABEL,
    "MACOS_RUNNER_BACKGROUND": "blacksmith-6vcpu-macos-15",
    "MACOS_RUNNER_PR": NIGHTLY_LABEL,
}
OWNERS = ("manaflow-ai", "someone-else")
EVENTS = ("push", "pull_request", "pull_request_target", "workflow_dispatch", "schedule")
REFS = (
    "refs/heads/feat-cmux-next",
    "refs/heads/cmux-tui-pin-0123456789ab",
    "refs/heads/main",
    "refs/heads/feat-some-lane",
)
ATTEMPTS = (1, 2, 3)


class _Missing:
    """An unset variable or input: falsy, and equal to ''."""


def _value(node: tuple, context: dict) -> object:
    kind = node[0]
    if kind == "or":
        result: object = None
        for child in node[1]:
            result = _value(child, context)
            if _truthy(result):
                return result
        return result
    if kind == "and":
        result = None
        for child in node[1]:
            result = _value(child, context)
            if not _truthy(result):
                return result
        return result
    if kind == "not":
        return not _truthy(_value(node[1], context))
    if kind == "literal":
        text = node[1]
        if text.startswith("'"):
            return text[1:-1].replace("''", "'")
        if text in ("true", "false"):
            return text == "true"
        if text == "null":
            return None
        return float(text)
    if kind == "ref":
        return context.get(node[1], "")
    if kind == "cmp":
        left, right = _value(node[2], context), _value(node[3], context)
        if isinstance(left, (int, float)) or isinstance(right, (int, float)):
            left, right = float(left or 0), float(right or 0)
        else:
            left, right = str(left or "").lower(), str(right or "").lower()
        return {
            "==": left == right,
            "!=": left != right,
            "<": left < right,
            ">": left > right,
            "<=": left <= right,
            ">=": left >= right,
        }[node[1]]
    if kind == "call":
        name, args = node[1], [_value(arg, context) for arg in node[2]]
        if name == "fromJSON":
            return json.loads(args[0])
        if name == "contains":
            haystack, needle = args
            if isinstance(haystack, list):
                return str(needle).lower() in [str(item).lower() for item in haystack]
            return str(needle).lower() in str(haystack).lower()
        if name == "startsWith":
            return str(args[0]).lower().startswith(str(args[1]).lower())
        if name == "endsWith":
            return str(args[0]).lower().endswith(str(args[1]).lower())
    raise AssertionError(f"unsupported expression node {node!r}")


def _truthy(value: object) -> bool:
    return value not in (None, False, "", 0, 0.0)


def route(expression: str, context: dict) -> str:
    source = expression.strip()
    assert source.startswith("${{") and source.endswith("}}"), source
    return str(_value(parse_expression(source[3:-2]), context))


def contexts(**overrides: str):
    for owner, event, ref, attempt in itertools.product(OWNERS, EVENTS, REFS, ATTEMPTS):
        context = {
            "github.repository_owner": owner,
            "github.event_name": event,
            "github.ref": ref,
            "github.run_attempt": attempt,
            "inputs.macos_runner": "",
            "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux",
            "github.repository": "manaflow-ai/cmux",
        }
        for name, value in {**LIVE_VARS, **overrides}.items():
            context[f"vars.{name}"] = value
        yield context


def load(name: str) -> dict:
    return yaml.load((WORKFLOWS / name).read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def test_dogfood_artifacts_never_take_the_nightly_label() -> None:
    build = load("cmux-tui.yml")["jobs"]["build-artifacts"]["with"]
    for owned in ("1", ""):
        for context in contexts(CI_PR_POOL_OWNED=owned):
            for key in ("macos_runner", "macos_retry_runner"):
                label = route(build[key], context)
                where = (key, context["github.repository_owner"], context["github.event_name"],
                         context["github.ref"], context["github.run_attempt"], owned)
                if context["github.repository_owner"] != "manaflow-ai":
                    assert label == "macos-26", where
                    continue
                assert label != NIGHTLY_LABEL, where
                # #20612: dogfood never waits for the side lane either.
                assert not label.startswith("glaeda-"), where
                assert label == "blacksmith-6vcpu-macos-15", where


def test_daemon_tests_stay_on_the_owned_minis_on_every_attempt() -> None:
    runs_on = load("cmux-tui-artifacts.yml")["jobs"]["cmux-next-daemon-tests"]["runs-on"]
    trusted = {"push", "pull_request", "workflow_dispatch", "schedule"}
    for owned in ("1", ""):
        for context in contexts(CI_PR_POOL_OWNED=owned):
            label = route(runs_on, context)
            where = (context["github.repository_owner"], context["github.event_name"],
                     context["github.ref"], context["github.run_attempt"], owned)
            if context["github.repository_owner"] != "manaflow-ai":
                assert label == "macos-26", where
                continue
            assert label != NIGHTLY_LABEL, where
            # cx-km8nz: attempt 1 of a feat-cmux-next push takes the reserved
            # promote runners, whatever the owned-pool switch says.
            if (
                context["github.event_name"] == "push"
                and context["github.ref"] == "refs/heads/feat-cmux-next"
                and context["github.run_attempt"] == 1
            ):
                assert label == PROMOTE_LABEL, where
                continue
            if owned != "1" or context["github.event_name"] not in trusted:
                assert label == "blacksmith-6vcpu-macos-15", where
                continue
            # A cmux-tui-pin-* push, and every re-run, stays on the minis.
            assert label == SIDE_LABEL, where


def test_daemon_tests_take_their_own_promote_time_pool_when_set() -> None:
    # 2026-10-15: one mini serves CI_NEXT_PROMOTE_POOL, and cmux-next.yml's
    # Release compile runs there too, so the daemon tests queued behind it
    # for over an hour (runs 38702524262, 38702991658, 38705858681,
    # 38706222238) and nightly-next promotion stalled. CI_NEXT_DAEMON_POOL
    # takes attempt 1 of a feat-cmux-next push when set; empty, the promote
    # pool keeps it. Every other context routes as before.
    runs_on = load("cmux-tui-artifacts.yml")["jobs"]["cmux-next-daemon-tests"]["runs-on"]
    for owned in ("1", ""):
        for unset, set_ in zip(contexts(CI_PR_POOL_OWNED=owned),
                               contexts(CI_PR_POOL_OWNED=owned, CI_NEXT_DAEMON_POOL=DAEMON_LABEL)):
            where = (set_["github.repository_owner"], set_["github.event_name"],
                     set_["github.ref"], set_["github.run_attempt"], owned)
            promote_slot = (
                set_["github.repository_owner"] == "manaflow-ai"
                and set_["github.event_name"] == "push"
                and set_["github.ref"] == "refs/heads/feat-cmux-next"
                and set_["github.run_attempt"] == 1
            )
            if promote_slot:
                assert route(runs_on, unset) == PROMOTE_LABEL, where
                assert route(runs_on, set_) == DAEMON_LABEL, where
            else:
                assert route(runs_on, set_) == route(runs_on, unset), where
                assert route(runs_on, set_) != DAEMON_LABEL, where
            # The dispatch input still wins over the new pool.
            set_["inputs.macos_runner"] = "blacksmith-6vcpu-macos-26"
            assert route(runs_on, set_) == "blacksmith-6vcpu-macos-26", where


def test_artifact_build_legs_never_rerun_on_the_nightly_label() -> None:
    build = load("cmux-tui-artifacts.yml")["jobs"]["build"]["with"]
    for owned in ("1", ""):
        for context in contexts(CI_PR_POOL_OWNED=owned):
            for key in ("macos_runner", "macos_retry_runner"):
                label = route(build[key], context)
                where = (key, context["github.repository_owner"], context["github.event_name"],
                         context["github.ref"], context["github.run_attempt"], owned)
                assert label != NIGHTLY_LABEL, where


def test_a_dispatch_runner_input_still_wins() -> None:
    artifacts = load("cmux-tui-artifacts.yml")["jobs"]
    for context in contexts(**{}):
        context["inputs.macos_runner"] = "blacksmith-6vcpu-macos-26"
        assert route(artifacts["cmux-next-daemon-tests"]["runs-on"], context) == "blacksmith-6vcpu-macos-26"
        assert route(artifacts["build"]["with"]["macos_runner"], context) == "blacksmith-6vcpu-macos-26"


def main() -> int:
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_") and callable(value)]
    failures = 0
    for test in tests:
        try:
            test()
        except AssertionError as error:
            failures += 1
            print(f"FAIL {test.__name__}: {error}")
        else:
            print(f"ok   {test.__name__}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
