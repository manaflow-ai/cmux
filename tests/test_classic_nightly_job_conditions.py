#!/usr/bin/env python3
"""Every job of the classic nightly can run, and the one-mini mode leaves no Blacksmith job in nightly.yml.

Lawrence, 2026-11-05: the classic nightly runs on one Mac mini (vars.CI_CLASSIC_NIGHTLY_MINI,
tests/test_classic_nightly_one_mini.py) with 0 Blacksmith jobs.

1. No dead job. A job whose `if:` can never be true for any trigger, input, variable or result of the jobs it
   needs is a job nobody can see is gone. main's nightly.yml had three: generate-nightly-deltas,
   republish-nightly-deltas and close-nightly-failure-issue needed publish-nightly to succeed with
   needs.decide.outputs.should_publish == 'true', and publish-nightly runs only when it is not 'true' (private
   branch artifacts). The published nightly's deltas and its failure-issue close are in
   auto-resume-nightly-notarization.yml (generate-deltas, republish-deltas, publish). The check runs each workflow
   job by job in `needs` order over sampled contexts, with GitHub's job status rules (a job without a status
   function in its `if:` runs only when every job above it succeeded), and fails on a job that no context runs.
   PARKED lists the jobs main parks with a literal `if: false`.

2. The cache warmers refresh-compilation-cache and refresh-test-compilation-cache (Blacksmith macOS, a
   `17 */6 * * *` schedule or a seed_only dispatch) do not run while the one-mini mode is on. With
   vars.CI_CLASSIC_NIGHTLY_MINI unset their `if:` decides exactly as on main before this change (MAIN_WARMER_IF).
"""

from __future__ import annotations

import functools
import json
import random
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
sys.path.insert(0, str(ROOT / "tests"))
from test_ci_fork_runner_routing import parse_expression  # noqa: E402

MINI = "glaeda-nightly-mini"
# workflow -> job -> why main keeps it with a literal `if: false`.
PARKED = {
    "nightly.yml": {
        "await-release-surface-ack": "parked on main; the nightly-next promotion acknowledgement lives on feat-cmux-next",
        "promote-nightly-next-acked": "parked on main; the nightly-next promotion acknowledgement lives on feat-cmux-next",
    },
}
CHECKED = ("nightly.yml", "auto-resume-nightly-notarization.yml")
WARMERS = ("refresh-compilation-cache", "refresh-test-compilation-cache")
# Both warmers' `if:` on main at 2e109a1739d3, before the one-mini gate.
MAIN_WARMER_IF = ("github.event_name == 'schedule' && github.event.schedule == '17 */6 * * *' && "
                  "vars.CI_PR_POOL_OWNED != '1' || github.event_name == 'workflow_dispatch' && inputs.seed_only")
# Values a job output may take: flags, tag states, promotion actions and runner labels.
OUTPUT_VALUES = ("true", "false", "", "updated", "stale", "needs-ack", "blacksmith-6vcpu-macos-26", MINI)
STATUS_FUNCTIONS = ("success", "failure", "always", "cancelled")


def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))


def triggers(document: dict) -> dict:
    # PyYAML reads the bare key `on` as True.
    return document.get("on", document.get(True)) or {}


def needs_of(job: dict) -> list[str]:
    value = job.get("needs") or []
    return [value] if isinstance(value, str) else list(value)


def condition(job: dict) -> str | bool:
    raw = job.get("if", "")
    if isinstance(raw, bool):
        return raw
    text = str(raw).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2].strip()
    return text


def calls(node) -> set[str]:
    if not isinstance(node, tuple):
        return set()
    found = {node[1].lower()} if node[0] == "call" else set()
    for part in node[1:]:
        for child in part if isinstance(part, list) else [part]:
            found |= calls(child)
    return found


def truthy(value) -> bool:
    return value not in ("", None, False, 0)


def number(value) -> float:
    if isinstance(value, bool):
        return float(value)
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value).strip() or 0)
    except ValueError:
        return float("nan")


def compare(op: str, left, right) -> bool:
    if isinstance(left, str) and isinstance(right, str) and op in ("==", "!="):
        return (left.lower() == right.lower()) == (op == "==")
    if op in ("==", "!=") and (left is None or right is None):
        return ((left in (None, "")) == (right in (None, ""))) == (op == "==")
    a, b = number(left), number(right)
    return {"==": a == b, "!=": a != b, "<": a < b, ">": a > b, "<=": a <= b, ">=": a >= b}[op]


class Run:
    """One sampled run of a workflow: its context and the result and outputs of each job so far."""

    def __init__(self, context: dict, jobs: dict) -> None:
        self.context = context
        self.jobs = jobs
        self.results: dict[str, str] = {}
        self.outputs: dict[str, dict[str, str]] = {}

    def ancestors(self, name: str) -> set[str]:
        found, stack = set(), list(needs_of(self.jobs[name]))
        while stack:
            job = stack.pop()
            if job not in found:
                found.add(job)
                stack.extend(needs_of(self.jobs[job]))
        return found

    def ref(self, path: str, job: str):
        if path.startswith("needs."):
            parts = path.split(".")
            if parts[1] == "*" and parts[2] == "result":
                return [self.results.get(need, "skipped") for need in needs_of(self.jobs[job])]
            if len(parts) == 3 and parts[2] == "result":
                return self.results.get(parts[1], "skipped")
            if len(parts) == 4 and parts[2] == "outputs":
                return self.outputs.get(parts[1], {}).get(parts[3], "")
            return ""
        return self.context.get(path, "")

    def evaluate(self, node, job: str):
        kind = node[0]
        if kind == "or":
            value = None
            for child in node[1]:
                value = self.evaluate(child, job)
                if truthy(value):
                    return value
            return value
        if kind == "and":
            value = None
            for child in node[1]:
                value = self.evaluate(child, job)
                if not truthy(value):
                    return value
            return value
        if kind == "not":
            return not truthy(self.evaluate(node[1], job))
        if kind == "literal":
            text = node[1]
            if text.startswith("'"):
                return text[1:-1].replace("''", "'")
            return {"true": True, "false": False, "null": None}.get(text, number(text))
        if kind == "ref":
            return self.ref(node[1], job)
        if kind == "cmp":
            return compare(node[1], self.evaluate(node[2], job), self.evaluate(node[3], job))
        if kind == "call":
            name = node[1].lower()
            if name in ("success", "failure"):
                above = [self.results.get(ancestor, "skipped") for ancestor in self.ancestors(job)]
            if name == "always":
                return True
            if name == "cancelled":
                return False  # no sampled run is cancelled
            if name == "success":
                return all(result == "success" for result in above)
            if name == "failure":
                return any(result == "failure" for result in above)
            args = [self.evaluate(arg, job) for arg in node[2]]
            if name == "contains":
                haystack, needle = args
                if isinstance(haystack, list):
                    return any(str(item).lower() == str(needle).lower() for item in haystack)
                return str(needle).lower() in str(haystack).lower()
            if name == "startswith":
                return str(args[0]).lower().startswith(str(args[1]).lower())
            if name == "endswith":
                return str(args[0]).lower().endswith(str(args[1]).lower())
            if name == "format":
                return str(args[0]).format(*args[1:])
            if name == "fromjson":
                try:
                    return json.loads(args[0])
                except (TypeError, json.JSONDecodeError):
                    return None
            if name == "tojson":
                return json.dumps(args[0])
        raise ValueError(f"unsupported expression node {node!r}")

    def admits(self, job: str) -> bool:
        return truthy(self.evaluate(gate(condition(self.jobs[job])), job))


@functools.lru_cache(maxsize=None)
def gate(source: str | bool) -> tuple:
    """A job's `if:` as an expression tree, with GitHub's implicit `success() &&` when it names no status function."""
    if isinstance(source, bool):
        tree = ("literal", "true" if source else "false")
    else:
        tree = parse_expression(source) if source else ("literal", "true")
    if not calls(tree) & set(STATUS_FUNCTIONS):
        tree = ("and", [("call", "success", []), tree])
    return tree


def order(jobs: dict) -> list[str]:
    done: list[str] = []
    pending = list(jobs)
    while pending:
        ready = [name for name in pending if all(need in done for need in needs_of(jobs[name]))]
        if not ready:
            raise AssertionError(f"a needs cycle among {pending}")
        done.extend(ready)
        pending = [name for name in pending if name not in ready]
    return done


def sample_context(document: dict, rng: random.Random, variables: list[str]) -> dict:
    events = triggers(document)
    event = rng.choice(sorted(events))
    ref = "refs/heads/main" if event in ("schedule", "workflow_run") else rng.choice(
        ("refs/heads/main", "refs/heads/main", "refs/heads/rc/1.2", "refs/heads/feature"))
    context = {
        "github.event_name": event, "github.ref": ref, "github.ref_name": ref.removeprefix("refs/heads/"),
        "github.repository": "manaflow-ai/cmux", "github.repository_owner": "manaflow-ai",
        "github.run_attempt": rng.choice((1, 1, 2)),
        "github.triggering_actor": rng.choice(("lawrencecchen", "github-actions[bot]")),
    }
    if event == "schedule":
        context["github.event.schedule"] = rng.choice([entry["cron"] for entry in events["schedule"]])
    if event == "workflow_run":
        context["github.event.workflow_run.conclusion"] = rng.choice(("success", "failure", "cancelled"))
        context["github.event.workflow_run.head_repository.full_name"] = rng.choice(
            ("manaflow-ai/cmux", "someone/cmux"))
    if event == "workflow_dispatch":
        for name, spec in ((events["workflow_dispatch"] or {}).get("inputs") or {}).items():
            kind = (spec or {}).get("type", "string")
            if kind == "boolean":
                value = rng.choice((True, False))
                context[f"github.event.inputs.{name}"] = "true" if value else "false"
            elif kind == "choice":
                value = rng.choice(spec["options"])
            else:
                value = rng.choice(("", "x", "tick:0123456789abcdef0123456789abcdef01234567",
                                    "0123456789abcdef0123456789abcdef01234567"))
            context[f"inputs.{name}"] = value
    for name in variables:
        context[f"vars.{name}"] = rng.choice(("", "1", MINI))
    return context


def variables_read(document: dict) -> list[str]:
    return sorted(set(re.findall(r"\bvars\.([A-Za-z0-9_]+)", json.dumps(document["jobs"]))))


def simulate(name: str, runs: int, seed: int) -> set[str]:
    """The jobs of workflow `name` that at least one sampled run starts."""
    document = load(name)
    jobs = document["jobs"]
    variables = variables_read(document)
    rng = random.Random(seed)
    started: set[str] = set()
    for _ in range(runs):
        run = Run(sample_context(document, rng, variables), jobs)
        for job in order(jobs):
            if run.admits(job):
                started.add(job)
                run.results[job] = "success" if rng.random() < 0.7 else "failure"
                declared = jobs[job].get("outputs") or {}
                # Half of the outputs are 'true', so a chain of flag checks several jobs deep is still sampled.
                run.outputs[job] = ({key: "true" if rng.random() < 0.5 else rng.choice(OUTPUT_VALUES) for key in declared}
                                    if run.results[job] == "success" else {})
            else:
                run.results[job] = "skipped"
    return started


class ClassicNightlyJobConditions(unittest.TestCase):
    def test_every_job_can_run(self) -> None:
        for name in CHECKED:
            jobs = load(name)["jobs"]
            parked = PARKED.get(name, {})
            with self.subTest(workflow=name):
                for job in parked:
                    self.assertIn(job, jobs, f"stale PARKED entry {name}:{job}")
                    self.assertIs(jobs[job].get("if"), False, f"PARKED {name}:{job} is no longer `if: false`")
                started = simulate(name, runs=8000, seed=41920015425)
                dead = sorted(set(jobs) - started - set(parked))
                self.assertEqual(dead, [], f"{name}: jobs no trigger, input, variable or needs result can start")

    def test_the_evaluator_finds_a_dead_job(self) -> None:
        # Not vacuous: a job that needs another job to succeed where that job cannot run is reported.
        jobs = {
            "decide": {"runs-on": "x", "outputs": {"publish": "${{ steps.d.outputs.publish }}"}},
            "private": {"needs": "decide", "if": "needs.decide.outputs.publish != 'true'"},
            "after": {"needs": ["decide", "private"],
                      "if": "always() && needs.decide.outputs.publish == 'true' && needs.private.result == 'success'"},
        }
        rng = random.Random(1)
        started: set[str] = set()
        for _ in range(500):
            run = Run({}, jobs)
            for job in order(jobs):
                if run.admits(job):
                    started.add(job)
                    run.results[job] = "success"
                    run.outputs[job] = {key: rng.choice(("true", "false")) for key in jobs[job].get("outputs", {})}
                else:
                    run.results[job] = "skipped"
        self.assertEqual(sorted(set(jobs) - started), ["after"])

    def test_the_warmers_skip_in_the_one_mini_mode_and_are_unchanged_without_it(self) -> None:
        jobs = load("nightly.yml")["jobs"]
        rng = random.Random(42)
        main = parse_expression(MAIN_WARMER_IF)
        for job in WARMERS:
            tree = parse_expression(condition(jobs[job]))
            for _ in range(400):
                event = rng.choice(("push", "schedule", "workflow_dispatch"))
                context = {
                    "github.event_name": event,
                    "github.event.schedule": rng.choice(("17 */6 * * *", "47 8 * * *")) if event == "schedule" else "",
                    "inputs.seed_only": rng.choice((True, False)) if event == "workflow_dispatch" else None,
                    "vars.CI_PR_POOL_OWNED": rng.choice(("", "1", "0")),
                }
                off = Run({**context, "vars.CI_CLASSIC_NIGHTLY_MINI": ""}, jobs)
                on = Run({**context, "vars.CI_CLASSIC_NIGHTLY_MINI": MINI}, jobs)
                self.assertEqual(truthy(off.evaluate(tree, job)), truthy(off.evaluate(main, job)), (job, context))
                self.assertFalse(truthy(on.evaluate(tree, job)), (job, context))


if __name__ == "__main__":
    unittest.main()
