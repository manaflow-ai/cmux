#!/usr/bin/env python3
"""Roll-up gates never read an absent signal as green.

ci-status and macOS status summarize the jobs they need. A `skipped` need is
a pass only when that job's routing turned it off; a job its routing selected
that never ran (a cancelled, missing or skipped upstream) must fail the gate.
scripts/ci/gate_verdict.py decides that from each job's own `if:`. This test:

- checks the gate's workflow reader against a full YAML parse;
- checks each gate runs the verdict, on everything it needs, and that the
  needs graph is closed so every `if:` can be evaluated;
- checks every job of the workflow is summarized by its gate unless it cannot
  fail the run;
- walks the needs graph over seeded routing scenarios: the routed results must
  pass, and each selected need turned skipped, cancelled or failed must fail;
- pins the GitHub expression semantics the verdict relies on.
"""
from __future__ import annotations

import functools
import importlib.util
import json
import random
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/gate_verdict.py"
GATES = {
    ".github/workflows/ci.yml": "ci-status",
    ".github/workflows/ci-macos.yml": "macos-status",
}
# Jobs a gate does not summarize, other than ones that cannot fail the run
# (job-level continue-on-error), each with the reason it does not block.
NOT_SUMMARIZED = {
    (".github/workflows/ci.yml", "dogfood-build"):
        "label-requested delivery of a dogfood ZIP; it tests nothing",
}
# Gates that decide admission rather than report a verdict: everything they
# read must also reach the verdict gate, so letting a skip through admits work
# but cannot pass a pull request.
PRE_GATES = {
    ".github/workflows/ci.yml": ("macos-admission-gate",),
}
VERDICT_STEP = "Every selected job reported"
SCENARIOS = 400


def load():
    spec = importlib.util.spec_from_file_location("gate_verdict", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["gate_verdict"] = module
    spec.loader.exec_module(module)
    return module


verdict = load()


@functools.lru_cache(maxsize=None)
def parsed(path: str) -> dict:
    return yaml.safe_load((ROOT / path).read_text())


def condition_of(job: dict) -> str | None:
    value = job.get("if")
    if value is None:
        return None
    return value if isinstance(value, str) else str(value).lower()


def needs_of(job: dict) -> tuple[str, ...]:
    value = job.get("needs") or ()
    return (value,) if isinstance(value, str) else tuple(value)


def verdict_step(path: str) -> dict:
    gate = parsed(path)["jobs"][GATES[path]]
    steps = [step for step in gate["steps"] if step.get("name") == VERDICT_STEP]
    if len(steps) != 1:
        raise AssertionError(f"{path} {GATES[path]}: expected one {VERDICT_STEP!r} step")
    return steps[0]


def context_only(path: str) -> frozenset[str]:
    match = re.search(r"--context-only (\S+)", verdict_step(path)["run"])
    return frozenset(match.group(1).split(",")) if match else frozenset()


def reads_variables(job) -> bool:
    return "vars." in (job.condition or "")


REFERENCE = re.compile(r"\b(needs|inputs|vars|github)((?:\.[A-Za-z0-9_*-]+)+)")
LITERAL = re.compile(r"'((?:[^']|'')*)'|\b(\d+)\b")
_REF = r"(?:needs|inputs|vars|github)(?:\.[A-Za-z0-9_*-]+)+"
COMPARED = re.compile(
    rf"(?P<ref>{_REF})\s*(?:==|!=|<=|>=|<|>)\s*'(?P<lit>(?:[^']|'')*)'"
    rf"|(?P<fn>startsWith|endsWith|contains)\(\s*(?P<fref>{_REF})\s*,\s*'(?P<flit>(?:[^']|'')*)'\s*\)",
    re.IGNORECASE)
EXPRESSION = re.compile(r"\$\{\{\s*toJSON\((github(?:\.[A-Za-z0-9_]+)+)\)\s*\}\}")


@functools.lru_cache(maxsize=None)
def jobs_of(path: str) -> dict:
    return verdict.read_jobs((ROOT / path).read_text())


class Scenario:
    """One seeded routing: event fields, variables, inputs and job outputs."""

    def __init__(self, path: str, rng: random.Random):
        self.path = path
        self.jobs = jobs_of(path)
        self.gate = GATES[path]
        conditions = " ".join(job.condition or "" for job in self.jobs.values())
        literals = {match.group(1) if match.group(1) is not None else match.group(2)
                    for match in LITERAL.finditer(conditions)}
        domain = sorted(literals | {"", "x"})
        refs = {(m.group(1), m.group(2)) for m in REFERENCE.finditer(conditions)}

        # Each reference mostly takes a value its own conditions compare it
        # with, so long conjunctions are reached as often as their negations.
        compared: dict[str, set[str]] = {}
        for match in COMPARED.finditer(conditions):
            if match.group("fn"):
                ref, literal = match.group("fref"), match.group("flit")
            else:
                ref, literal = match.group("ref"), match.group("lit")
            literal = literal.replace("''", "'")
            if match.group("fn"):
                literal = {"startswith": literal + "std", "endswith": "std" + literal}.get(
                    match.group("fn").lower(), "a" + literal + "b")
            compared.setdefault(ref, set()).add(literal)

        def pick(ref: str = ""):
            near = sorted(compared.get(ref, ()))
            return rng.choice(near) if near and rng.random() < 0.8 else rng.choice(domain)

        self.outputs: dict[str, dict[str, str]] = {}
        self.inputs: dict[str, str] = {}
        variables: dict[str, str] = {}
        for root, rest in sorted(refs):
            parts = rest.strip(".").split(".")
            if root == "needs" and len(parts) == 3 and parts[1] == "outputs":
                self.outputs.setdefault(parts[0], {})[parts[2]] = pick(root + rest)
            elif root == "inputs":
                self.inputs[parts[0]] = pick(root + rest)
            elif root == "vars" and rng.random() < 0.8:
                variables[parts[0]] = pick(root + rest)  # sometimes unset
        template = verdict_step(path)["env"]["GATE_GITHUB"]
        events = [value for value in domain if value in {"pull_request", "merge_group", "workflow_dispatch", "push"}]

        def fill(match: re.Match) -> str:
            field = match.group(1)
            if field == "github.event_name":
                return json.dumps(rng.choice(events or ["pull_request"]))
            if field == "github.run_attempt":
                return json.dumps(str(rng.randint(1, 4)))
            return json.dumps(pick(field) if rng.random() < 0.9 else None)

        self.context = verdict.context_from_environment({
            "GATE_VARS": json.dumps(variables),
            "GATE_INPUTS": json.dumps(self.inputs),
            "GATE_GITHUB": EXPRESSION.sub(fill, template),
        })

    def routed(self) -> dict[str, dict]:
        """Each job's result as GitHub would route it: ran and passed, or skipped."""
        needs: dict[str, dict] = {}
        pending = list(self.jobs[self.gate].needs)
        while pending:
            progressed = False
            for name in list(pending):
                job = self.jobs[name]
                if any(need not in needs for need in job.needs):
                    continue
                ran = verdict.selected(job, needs, self.context, jobs=self.jobs,
                                       tolerate_variable_flips=False)
                needs[name] = {"result": "success" if ran else "skipped",
                               "outputs": dict(self.outputs.get(name, {})) if ran else {}}
                pending.remove(name)
                progressed = True
            if not progressed:
                raise AssertionError(f"{self.path}: needs cycle among {pending}")
        return {name: needs[name] for name in self.jobs[self.gate].needs}


class ReaderTests(unittest.TestCase):
    def test_reader_matches_yaml_for_every_job(self):
        for path in GATES:
            with self.subTest(path=path):
                jobs = verdict.read_jobs((ROOT / path).read_text())
                full = parsed(path)["jobs"]
                self.assertEqual(sorted(jobs), sorted(full))
                for name, job in full.items():
                    self.assertEqual(jobs[name].needs, needs_of(job), name)
                    self.assertEqual(jobs[name].condition, condition_of(job), name)


class WiringTests(unittest.TestCase):
    def test_gate_runs_the_verdict_on_everything_it_needs(self):
        for path, gate in GATES.items():
            with self.subTest(path=path):
                step = verdict_step(path)
                self.assertNotIn("continue-on-error", step)
                expected = f"python3 scripts/ci/gate_verdict.py --workflow {path} --gate {gate}"
                if context_only(path):
                    expected += " --context-only " + ",".join(sorted(context_only(path)))
                self.assertEqual(step["run"].strip(), expected)
                self.assertEqual(step["env"]["GATE_NEEDS"], "${{ toJSON(needs) }}")
                self.assertEqual(step["env"]["GATE_VARS"], "${{ toJSON(vars) }}")
                self.assertEqual(step["env"]["GATE_INPUTS"], "${{ toJSON(inputs) }}")
                job = parsed(path)["jobs"][gate]
                steps = job["steps"]
                checkout = steps[steps.index(step) - 1]
                self.assertTrue(checkout.get("uses", "").startswith("actions/checkout@"))
                sparse = checkout["with"]["sparse-checkout"].split()
                self.assertIn("scripts/ci/gate_verdict.py", sparse)
                self.assertIn(path, sparse)
                self.assertEqual(job.get("if"), "${{ !cancelled() }}")

    def test_needs_graph_is_closed_under_the_gate(self):
        for path, gate in GATES.items():
            jobs = verdict.read_jobs((ROOT / path).read_text())
            seen = set(jobs[gate].needs)
            for name in jobs[gate].needs:
                for need in verdict._ancestors(jobs[name], jobs):
                    with self.subTest(path=path, job=name, need=need):
                        self.assertIn(need, seen, f"{gate} must need {need} to read {name}'s `if:`")

    def test_every_job_that_can_fail_is_summarized(self):
        for path, gate in GATES.items():
            full = parsed(path)["jobs"]
            summarized = set(needs_of(full[gate]))
            for name, job in full.items():
                if name == gate or name in summarized or job.get("continue-on-error") is True:
                    continue
                with self.subTest(path=path, job=name):
                    self.assertIn((path, name), NOT_SUMMARIZED,
                                  f"{name} can fail but {gate} does not summarize it")

    def test_pre_gates_feed_the_verdict_gate(self):
        for path, names in PRE_GATES.items():
            full = parsed(path)["jobs"]
            summarized = set(needs_of(full[GATES[path]]))
            for name in names:
                with self.subTest(path=path, job=name):
                    self.assertIn(name, summarized)
                    self.assertLessEqual(set(needs_of(full[name])), summarized)

    def test_every_event_field_an_if_reads_is_passed(self):
        for path, gate in GATES.items():
            jobs = verdict.read_jobs((ROOT / path).read_text())
            passed = set(EXPRESSION.findall(verdict_step(path)["env"]["GATE_GITHUB"]))
            for name in jobs[gate].needs:
                for match in REFERENCE.finditer(jobs[name].condition or ""):
                    if match.group(1) == "github":
                        with self.subTest(path=path, job=name):
                            self.assertIn("github" + match.group(2), passed)


class NeedsGraphWalk(unittest.TestCase):
    def test_absent_signals_fail_and_routed_skips_pass(self):
        for path, gate in GATES.items():
            rng = random.Random(f"{path}:20261020")
            best_effort = context_only(path)
            selected_seen: set[str] = set()
            skipped_seen: set[str] = set()
            for index in range(SCENARIOS):
                scenario = Scenario(path, rng)
                needs = scenario.routed()

                def check(broken):
                    return verdict.problems(scenario.jobs, gate, broken, scenario.context, best_effort)

                self.assertEqual(check(needs), [], f"{path} scenario {index}: routed results must pass")
                for name, entry in needs.items():
                    if entry["result"] == "skipped":
                        skipped_seen.add(name)
                        mutations = ("failure", "cancelled")
                    else:
                        selected_seen.add(name)
                        mutations = ("cancelled", "failure")
                        # A skip a repository-variable flip explains is accepted.
                        if not reads_variables(scenario.jobs[name]):
                            mutations = ("skipped", *mutations)
                    for result in mutations:
                        found = check({**needs, name: {"result": result, "outputs": {}}})
                        mentions = any(line.startswith(f"{name}:") for line in found)
                        if name in best_effort:
                            self.assertFalse(mentions, f"{path} scenario {index}: best-effort {name} "
                                                       f"{result} must not fail {gate}")
                        else:
                            self.assertTrue(mentions, f"{path} scenario {index}: {gate} passed with {name} {result}")
                    missing = {key: value for key, value in needs.items() if key != name}
                    self.assertTrue(check(missing))
            # The walk reached every need both ways, so no job escaped it.
            every = set(scenario.jobs[gate].needs)
            self.assertEqual(selected_seen, every, f"{path}: needs never selected")
            self.assertTrue(skipped_seen, f"{path}: no routed skip was exercised")

    def test_best_effort_needs_cannot_hold_back_what_needs_them(self):
        # A context-only need is never judged, so it must be one whose result
        # cannot stop a dependent: every step continue-on-error, and every job
        # that needs it runs whatever its result (a status function, and no
        # read of its result).
        for path, gate in GATES.items():
            full = parsed(path)["jobs"]
            jobs = jobs_of(path)
            for name in context_only(path):
                with self.subTest(path=path, job=name):
                    self.assertIn(name, jobs[gate].needs)
                    self.assertTrue(all(step.get("continue-on-error") is True
                                        for step in full[name]["steps"]))
                    for other, job in jobs.items():
                        if other == gate or name not in job.needs:
                            continue
                        condition = verdict.strip_expression(job.condition or "")
                        self.assertRegex(condition, verdict._STATUS, other)
                        self.assertNotIn(f"needs.{name}.result", condition, other)

    def test_variable_flip_between_routing_and_gate_is_not_red(self):
        path = ".github/workflows/ci-macos.yml"
        jobs = jobs_of(path)
        job = jobs["late-placement"]
        needs = {"macos-compile-admission": {"result": "success", "outputs": {}}}
        github = {"event_name": "pull_request", "repository": "manaflow-ai/cmux",
                  "repository_owner": "manaflow-ai", "run_attempt": "1", "triggering_actor": "a",
                  "event": {"pull_request": {"head": {"repo": {"full_name": "manaflow-ai/cmux"}}}}}
        context = verdict.context_from_environment({
            "GATE_VARS": json.dumps({"CI_PR_POOL_OWNED": "1", "GLAEDA_ROUTE_APP_ID": "7"}),
            "GATE_GITHUB": json.dumps(github)})
        # Routed with these variables, it runs ...
        self.assertTrue(verdict.selected(job, needs, context, tolerate_variable_flips=False))
        # ... but had CI_PR_POOL_OWNED been off when it was routed, its skip is explained.
        self.assertFalse(verdict.selected(job, needs, context))

    def test_pr_21287_compile_admission_never_ran(self):
        # macOS compile admission sat queued until merge; had it ended without
        # running, the gate must not have read its skip as a routed one.
        path = ".github/workflows/ci-macos.yml"
        jobs = verdict.read_jobs((ROOT / path).read_text())
        inputs = {"macos": "true", "cli": "false", "full_suite": "false", "compile_admitted": "false",
                  "unit_suite": "false", "swift_packages": "false", "release_build": "true",
                  "pr_root_runner": "glaeda-root-std-xcode-26.6", "pr_owned_jobs": " admission "}
        context = verdict.context_from_environment({
            "GATE_INPUTS": json.dumps(inputs),
            "GATE_VARS": json.dumps({"CI_OWNED_SPREAD": "0"}),
            "GATE_GITHUB": json.dumps({
                "event_name": "pull_request", "repository": "manaflow-ai/cmux",
                "repository_owner": "manaflow-ai", "run_attempt": "1", "triggering_actor": "a",
                "event": {"pull_request": {"head": {"repo": {"full_name": "manaflow-ai/cmux"}}}}}),
        })
        needs = {name: {"result": "skipped", "outputs": {}} for name in jobs["macos-status"].needs}
        found = verdict.problems(jobs, "macos-status", needs, context, context_only(path))
        self.assertEqual([line.split(":")[0] for line in found], ["macos-compile-admission"])


class ExpressionSemantics(unittest.TestCase):
    STATUS = {"cancelled": False, "always": True, "success": True, "failure": False}

    def run_expression(self, text: str, **context):
        return verdict.evaluate(text, context, self.STATUS)

    def test_string_comparison_ignores_case(self):
        self.assertTrue(self.run_expression("a == 'TRUE'", a="true"))

    def test_missing_output_is_null_and_differs_from_false(self):
        needs = verdict._Strict({"changes": {"result": "success", "outputs": {}}}, deep=False)
        self.assertTrue(self.run_expression("needs.changes.outputs.web != 'false'", needs=needs))

    def test_unknown_need_or_event_field_is_unresolved(self):
        needs = verdict._Strict({}, deep=False)
        with self.assertRaises(verdict.Unresolved):
            self.run_expression("needs.other.result == 'success'", needs=needs)
        github = verdict._Strict({"event_name": "pull_request"}, deep=True)
        with self.assertRaises(verdict.Unresolved):
            self.run_expression("github.ref == 'x'", github=github)

    def test_unset_variable_is_empty_string(self):
        self.assertTrue(self.run_expression("vars.X == ''", vars=verdict._Vars()))
        self.assertTrue(self.run_expression("vars.X != '1'", vars=verdict._Vars()))

    def test_and_or_short_circuit_and_return_operands(self):
        needs = verdict._Strict({}, deep=False)
        self.assertFalse(self.run_expression("false && needs.other.result", needs=needs))
        self.assertEqual(self.run_expression("'' || 'b'"), "b")
        self.assertEqual(self.run_expression("'a' && 'b'"), "b")

    def test_number_coercion(self):
        self.assertTrue(self.run_expression("a <= 2", a="2"))
        self.assertFalse(self.run_expression("a <= 2", a="3"))

    def test_functions(self):
        self.assertTrue(self.run_expression("startsWith(a, 'glaeda-root-')", a="glaeda-root-std"))
        self.assertTrue(self.run_expression("contains(a, ' admission ')", a="x admission y"))
        self.assertTrue(self.run_expression("contains(fromJSON(a), 'o/r')", a='["o/r"]'))
        self.assertTrue(self.run_expression("contains(e.labels.*.name, 'full-ci')",
                                            e={"labels": [{"name": "full-ci"}]}))
        with self.assertRaises(verdict.Unresolved):
            self.run_expression("hashFiles('x')")

    def test_status_functions_see_every_ancestor(self):
        # A skipped, B ran under !cancelled(), C has an implicit success():
        # GitHub skips C, so its skip is a routed one, not an absent signal.
        jobs = {
            "a": verdict.Job("a", (), "${{ inputs.x == 'true' }}"),
            "b": verdict.Job("b", ("a",), "${{ !cancelled() }}"),
            "c": verdict.Job("c", ("b",), "${{ inputs.y == 'true' }}"),
            "gate": verdict.Job("gate", ("a", "b", "c"), "${{ !cancelled() }}"),
        }
        context = {"inputs": {"x": "false", "y": "true"}}
        needs = {"a": {"result": "skipped"}, "b": {"result": "success"}, "c": {"result": "skipped"}}
        self.assertFalse(verdict.selected(jobs["c"], needs, context, jobs=jobs))
        self.assertEqual(verdict.problems(jobs, "gate", needs, context), [])
        ran = {**needs, "a": {"result": "success"}}
        found = verdict.problems(jobs, "gate", ran, {"inputs": {"x": "true", "y": "true"}})
        self.assertEqual(len(found), 1)
        self.assertTrue(found[0].startswith("c: skipped, though its own `if:` selected it"), found)

    def test_implicit_success_without_a_status_function(self):
        job = verdict.Job("j", ("a",), "${{ inputs.x == 'true' }}")
        context = {"inputs": {"x": "true"}}
        self.assertFalse(verdict.selected(job, {"a": {"result": "skipped"}}, context))
        self.assertTrue(verdict.selected(job, {"a": {"result": "success"}}, context))
        explicit = verdict.Job("j", ("a",), "${{ !cancelled() && inputs.x == 'true' }}")
        self.assertTrue(verdict.selected(explicit, {"a": {"result": "skipped"}}, context))


if __name__ == "__main__":
    unittest.main()
