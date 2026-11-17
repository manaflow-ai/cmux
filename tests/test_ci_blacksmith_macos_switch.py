#!/usr/bin/env python3
"""No same-repository macOS job reaches Blacksmith past the CI_BLACKSMITH_MACOS switch.

The repository variable CI_BLACKSMITH_MACOS is the off switch for Blacksmith
macOS (Leo, 2026-11-11: "just stop using blacksmith temporarily"): only `on`
lets a job take a Blacksmith macOS label. feat-cmux-next's runs-on read it
(`vars.CI_BLACKSMITH_MACOS != 'on' && vars.CI_SIDE_LANE_RUNNER || <Blacksmith>`,
#43255) and so does its placement (next_macos_cascade.blacksmith_allowed()).
Main's did not. On 2026-11-17, with the switch off since 05:40Z the day before,
cmux#44924's app-host shards 1/7 and 3/7 sat queued five hours on
blacksmith-12vcpu-macos-26 (run 43990120167): compile admission ran on the
owned light pool, and the shards it did not own took the picker's Blacksmith
retry_runner. Main's own app-host 1/7, 3/7 and 6/7 went red the same way.

This guard evaluates every macOS runs-on in .github/workflows with the switch
off, for a same-repository run (push, pull_request, schedule, workflow_dispatch,
as far as the workflow or a reusable workflow's callers run for them; attempts 1 to 3; a person or github-actions[bot] as the triggering actor), the
owned pools on (CI_PR_POOL_OWNED=1, the side lanes set), every runner variable
unset and every picker output empty (a picker that chose nothing, the case its
fallback is for). A job whose runs-on still names a Blacksmith macOS label, a
literal or a RUNNER_POOLS macOS key, fails, unless it is listed with why:
test_ci_paid_queue_pin.PAID_ONLY_JOBS (it must stay on an ephemeral Mac) or
NEEDS_BLACKSMITH below (a capability the owned Macs lack). Picker outputs pass:
the picker itself honours the switch (simple_pool_picker.blacksmith_allowed(),
tested in tests/test_ci_simple_pool_picker_blacksmith_switch.py).

A listed job that no longer reaches Blacksmith, or no longer exists, fails too,
so the lists only shrink. The handbook pattern page "label-no-pool-lists"
(cmuxterm-hq docs/handbook) covers this class; this test is its detector on
main.
"""

from __future__ import annotations

import importlib.util
import itertools
import json
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
TESTS = Path(__file__).resolve().parent


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name, TESTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


routing = _load("test_ci_fork_runner_routing")
paid = _load("test_ci_paid_queue_pin")

BLACKSMITH_MACOS = re.compile(r"^blacksmith-\d+vcpu-macos-[a-z0-9.-]+$")
SWITCH = "vars.CI_BLACKSMITH_MACOS != 'on' && vars.CI_SIDE_LANE_RUNNER"
SIDE = "glaeda-side-std-xcode-26.6"
LIGHT = "glaeda-side-light-xcode-26.6"
RUNNER_POOLS = json.dumps({
    "macos_15": "blacksmith-6vcpu-macos-15", "macos_26": "blacksmith-6vcpu-macos-26",
    "macos_26_large": "blacksmith-12vcpu-macos-26", "macos_latest": "blacksmith-6vcpu-macos-latest",
})
DYNAMIC_INDEX = re.compile(r"\[format\('[^']*'(?:, [A-Za-z0-9_.-]+)*\)\]")
EVENTS = ("push", "pull_request", "schedule", "workflow_dispatch")
ATTEMPTS = ("1", "2", "3")
ACTORS = ("octocat", "github-actions[bot]")

# Jobs that need a Blacksmith macOS image for a capability the owned Macs (macOS 26, Xcode 26.6) lack,
# beyond PAID_ONLY_JOBS. Keyed (workflow file name, job key), each with why.
NEEDS_BLACKSMITH: dict[tuple[str, str], str] = {
    ("ci-macos.yml", "swift-package-tests"):
        "a full suite that checks the Release build first builds the Release Ghostty CLI helper against an SDK 15 "
        "Xcode, which only the Blacksmith macOS 15 image carries; every other run takes the picker's side label",
    ("app-host-test-rerun.yml", "rerun"):
        "re-runs a product the original run built on macOS 15, which loads only under that image's Xcode; "
        "a macOS 26 product takes the side lane, the switch's fallback included",
    ("iroh-release-gate.yml", "tailscale-version-skew"):
        "pins the macOS 15 pool's Xcode 26.3 when e2e_runner_pool.py finds no free owned machine",
    ("nightly.yml", "build-nightly-app"):
        "the shipped nightly build; cmux15 (CI_NIGHTLY_TRUSTED_RUNNER) first, and it signs on the same machine",
    ("nightly.yml", "prepare-nightly-variant"): "packages the shipped nightly variant with its signing inputs",
    ("nightly.yml", "build-sign-notarize-nightly"): paid.SIGNING,
    ("nightly.yml", "verify-signed-nightly"): "verifies the signed nightly on a clean image, which a mini is not",
    ("cmux-next-dev-daily.yml", "verify"): paid.SIGNING + " (its own picker, needs.runner, places it first)",
    ("cmux-next-dev-daily.yml", "tip-dmg-build"): paid.SIGNING + " (its own picker, needs.runner, places it first)",
    ("cmux-next-dev-daily.yml", "tip-deltas"): paid.SIGNING + " (its own picker, needs.runner, places it first)",
}

EXEMPT = {**paid.PAID_ONLY_JOBS, **NEEDS_BLACKSMITH}


class _Unreadable(ValueError):
    pass


def _number(value: object) -> float | None:
    if isinstance(value, bool):
        return float(value)
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str) and re.fullmatch(r"-?\d+(?:\.\d+)?", value.strip()):
        return float(value)
    return None


def _truthy(value: object) -> bool:
    return value not in ("", None, False, 0) and value != 0.0


def _index(value: object, path: str) -> object:
    """Apply a `.a['b'][0]` path to a value; a missing key is null, as in GitHub."""
    for part in re.findall(r"\.([A-Za-z0-9_*-]+)|\[([^\]]+)\]", path):
        key = part[0] or part[1].strip("'")
        if isinstance(value, dict):
            value = value.get(key)
        elif isinstance(value, list) and key.isdigit() and int(key) < len(value):
            value = value[int(key)]
        else:
            return None
    return value


class Context:
    """One same-repository run with the switch off, every runner variable and picker output empty."""

    def __init__(self, workflow: str, event: str, attempt: str, actor: str, extra: dict[str, str] | None = None):
        self.values = {
            "github.repository_owner": "manaflow-ai", "github.repository": "manaflow-ai/cmux",
            "github.event_name": event, "github.run_attempt": attempt, "github.triggering_actor": actor,
            "github.actor": actor, "github.ref": "refs/heads/main", "github.ref_name": "main",
            "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux",
            "github.workflow_ref": f"manaflow-ai/cmux/.github/workflows/{workflow}@refs/heads/main",
            "vars.CI_BLACKSMITH_MACOS": "", "vars.CI_PR_POOL_OWNED": "1",
            "vars.CI_SIDE_LANE_RUNNER": SIDE, "vars.CI_LIGHT_LANE_RUNNER": LIGHT, "vars.RUNNER_POOLS": RUNNER_POOLS,
            "inputs.source_repository": "manaflow-ai/cmux", "inputs.owned_head_repos": "[]",
        }
        self.values.update(extra or {})

    def ref(self, path: str) -> object:
        path = re.sub(r"\['([A-Za-z_][A-Za-z0-9_-]*)'\]", r".\1", path)
        if path in self.values:
            return self.values[path]
        if re.fullmatch(r"needs\.[A-Za-z0-9_-]+\.outputs\.trusted_ref", path):
            return "true"
        if path.split(".", 1)[0] in ("vars", "inputs", "needs", "matrix", "env", "steps", "secrets", "github"):
            return ""
        raise _Unreadable(path)


def evaluate(node: tuple, context: Context) -> object:
    """GitHub Actions expression semantics for the subset runs-on uses (|| and && return operands)."""
    kind = node[0]
    if kind == "or":
        value: object = None
        for child in node[1]:
            value = evaluate(child, context)
            if _truthy(value):
                return value
        return value
    if kind == "and":
        value = None
        for child in node[1]:
            value = evaluate(child, context)
            if not _truthy(value):
                return value
        return value
    if kind == "not":
        return not _truthy(evaluate(node[1], context))
    if kind == "literal":
        text = node[1]
        if text.startswith("'"):
            return text[1:-1].replace("''", "'")
        if text in ("true", "false", "null"):
            return {"true": True, "false": False, "null": None}[text]
        return float(text)
    if kind == "ref":
        return context.ref(node[1])
    if kind == "cmp":
        left, right = evaluate(node[2], context), evaluate(node[3], context)
        op = node[1]
        a, b = _number(left), _number(right)
        if op in ("==", "!="):
            if a is not None and b is not None:
                equal = a == b
            else:
                equal = str(left if left is not None else "").lower() == str(right if right is not None else "").lower()
            return equal == (op == "==")
        if a is None or b is None:
            return False
        return {"<": a < b, "<=": a <= b, ">": a > b, ">=": a >= b}[op]
    if kind == "call":
        name, args = node[1], [evaluate(arg, context) for arg in node[2]]
        if name == "fromJSON" and len(args) == 1:
            text = str(args[0])
            try:
                value = json.loads(text) if text else None
            except json.JSONDecodeError as error:
                raise _Unreadable(f"fromJSON({text!r})") from error
        elif name in ("contains", "startsWith", "endsWith") and len(args) == 2:
            haystack, needle = args
            if isinstance(haystack, list):
                value = any(str(item).lower() == str(needle).lower() for item in haystack)
            else:
                haystack, needle = str(haystack or "").lower(), str(needle or "").lower()
                value = {"contains": needle in haystack, "startsWith": haystack.startswith(needle),
                         "endsWith": haystack.endswith(needle)}[name]
        elif name == "format" and args:
            value = re.sub(r"\{(\d+)\}", lambda m: str(args[1 + int(m.group(1))]), str(args[0]))
        elif name == "toJSON" and len(args) == 1:
            value = json.dumps(args[0])
        else:
            raise _Unreadable(f"{name}()")
        return _index(value, node[3]) if len(node) > 3 else value
    raise _Unreadable(repr(node))


def runs_on_text(job: dict) -> str:
    runs_on = job.get("runs-on")
    if isinstance(runs_on, list):
        return " ".join(str(item) for item in runs_on)
    if isinstance(runs_on, dict):
        return " ".join(str(item) for item in runs_on.values())
    return str(runs_on or "")


def labels(runs_on: str, context: Context) -> list[str]:
    """The labels a runs-on asks for in one context: each ${{ }}'s value, list values flattened."""
    found: list[str] = []
    for expression in routing.EXPRESSION.findall(runs_on):
        # A computed index (`[format('shard-{0}', matrix.shard)]`) reads a picker's map, which is empty here.
        expression = DYNAMIC_INDEX.sub("['computed']", expression)
        value = evaluate(routing.parse_expression(expression), context)
        found.extend(str(item) for item in (value if isinstance(value, list) else [value]))
    found.extend(routing.EXPRESSION.sub(" ", runs_on).split())
    return found


def _workflows() -> dict[str, dict]:
    return {path.name: yaml.safe_load(path.read_text()) or {} for path in sorted(WORKFLOWS.glob("*.y*ml"))}


def _on(workflow: dict) -> set[str]:
    # PyYAML reads the bare key `on` as True.
    on = workflow.get("on", workflow.get(True))
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return {str(item) for item in on}
    return {str(key) for key in on} if isinstance(on, dict) else set()


LOCAL_USES = re.compile(r"^\./\.github/workflows/([\w.-]+\.ya?ml)(?:@.*)?$")


def trusted_events(workflows: dict[str, dict]) -> dict[str, set[str]]:
    """{workflow file name: the same-repository events it runs for}: its own triggers among EVENTS, and for a
    reusable workflow its local callers' as well (a fixed point over nested calls)."""
    callers: dict[str, set[str]] = {}
    for name, workflow in workflows.items():
        for job in (workflow.get("jobs") or {}).values():
            match = LOCAL_USES.match(str(job.get("uses") or "")) if isinstance(job, dict) else None
            if match:
                callers.setdefault(match.group(1), set()).add(name)
    events = {name: _on(workflow) & set(EVENTS) for name, workflow in workflows.items()}
    changed = True
    while changed:
        changed = False
        for name, by in callers.items():
            if name not in events:
                continue
            union = events[name].union(*(events.get(caller, set()) for caller in by))
            if union != events[name]:
                events[name], changed = union, True
    return events


def macos_jobs() -> dict[tuple[str, str], tuple[str, tuple[str, ...]]]:
    """{(workflow file name, job key): (runs-on, events)} for every job whose runs-on can name a macOS runner."""
    workflows = _workflows()
    events = trusted_events(workflows)
    jobs: dict[tuple[str, str], tuple[str, tuple[str, ...]]] = {}
    for name, workflow in workflows.items():
        for key, job in (workflow.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            runs_on = runs_on_text(job)
            if re.search(r"macos|MACOS", runs_on) and events.get(name):
                jobs[(name, key)] = (runs_on, tuple(event for event in EVENTS if event in events[name]))
    return jobs


def blacksmith_route(workflow: str, runs_on: str, events: tuple[str, ...] = EVENTS) -> str | None:
    """The first same-repository scenario in which runs-on names a Blacksmith macOS label, if any."""
    for event, attempt, actor in itertools.product(events, ATTEMPTS, ACTORS):
        context = Context(workflow, event, attempt, actor)
        try:
            picked = labels(runs_on, context)
        except (_Unreadable, routing.ExpressionSyntaxError) as error:
            return f"cannot be evaluated ({error})"
        hit = next((label for label in picked if BLACKSMITH_MACOS.match(label)), None)
        if hit:
            return f"{hit} on a {event} run, attempt {attempt}, triggered by {actor}"
    return None


def routes() -> dict[tuple[str, str], str]:
    return {job: why for job, (runs_on, events) in macos_jobs().items()
            if (why := blacksmith_route(job[0], runs_on, events))}


class BlacksmithMacosSwitch(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.routes = routes()

    def test_no_job_reaches_blacksmith_past_the_switch(self) -> None:
        unlisted = {job: why for job, why in self.routes.items() if job not in EXEMPT}
        self.assertFalse(unlisted, "\n".join(
            ["with vars.CI_BLACKSMITH_MACOS off, these same-repository macOS jobs still name a Blacksmith macOS "
             f"label. Put `{SWITCH} ||` ahead of the Blacksmith fallback, inside the job's own trust gate "
             "(CI_PR_POOL_OWNED, the trusted events), as feat-cmux-next does, or list the job in NEEDS_BLACKSMITH "
             "with the capability the owned Macs lack:"]
            + [f"  {path}:{job}: {why}" for (path, job), why in sorted(unlisted.items())]))

    def test_the_exempt_list_only_shrinks(self) -> None:
        stale = sorted(job for job in NEEDS_BLACKSMITH if job not in self.routes)
        self.assertFalse(stale, "\n".join(
            ["these NEEDS_BLACKSMITH entries no longer reach Blacksmith with the switch off, or no longer exist; "
             "remove them:"] + [f"  {path}:{job}" for path, job in stale]))

    def test_the_pr_picker_reads_the_switch(self) -> None:
        """The app-host shards, cli-product and the rest take the picker's outputs, so the picker must see it."""
        steps = yaml.safe_load((WORKFLOWS / "ci.yml").read_text())["jobs"]["changes"]["steps"]
        pick = next(step for step in steps if step.get("id") == "macos-pool")
        self.assertIn("simple_pool_picker.py", pick["run"])
        self.assertEqual(pick["env"].get("CI_BLACKSMITH_MACOS"), "${{ vars.CI_BLACKSMITH_MACOS }}")

    def test_the_evaluator_reads_the_shapes_it_must(self) -> None:
        context = Context("x.yml", "push", "2", "octocat")
        fork_only = ("${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.event_name == "
                     "'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && "
                     "'blacksmith-6vcpu-macos-26' || vars.CI_SIDE_LANE_RUNNER }}")
        self.assertEqual(labels(fork_only, context), [SIDE])
        retry = ("${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_PR_POOL_OWNED == '1' && "
                 "(github.run_attempt == 1 && vars.CI_LIGHT_LANE_RUNNER) || vars.MACOS_RUNNER_15 || "
                 "'blacksmith-6vcpu-macos-15' }}")
        self.assertIsNotNone(blacksmith_route("x.yml", retry))
        switched = retry.replace("vars.MACOS_RUNNER_15 ||", f"{SWITCH} || vars.MACOS_RUNNER_15 ||")
        self.assertIsNone(blacksmith_route("x.yml", switched))
        on = Context("x.yml", "push", "2", "octocat", {"vars.CI_BLACKSMITH_MACOS": "on"})
        self.assertEqual(labels(switched, on), ["blacksmith-6vcpu-macos-15"])
        pools = "${{ fromJSON(vars.RUNNER_POOLS).macos_26_large }}"
        self.assertEqual(labels(pools, context), ["blacksmith-12vcpu-macos-26"])
        shard = ("${{ fromJSON(needs.late-placement.outputs.runners || '{}')[format('shard-{0}', matrix.shard)] || "
                 "(github.run_attempt > 2 && github.triggering_actor == 'github-actions[bot]') && "
                 "inputs.pr_retry_runner || inputs.pr_shard_runner }}")
        self.assertIsNone(blacksmith_route("x.yml", shard))


if __name__ == "__main__":
    unittest.main()
