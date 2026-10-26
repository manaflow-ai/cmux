#!/usr/bin/env python3
"""No job waits on one reserved machine, and no compile route evicts another's run.

Leo's rule (2026-10-24): every reservation, a label only one host serves, has a
fallback within minutes, and "a CI test fails on a runs-on that can resolve to a
single-host label with no fallback". Until this file, the only such check was
tests/test_ci_nightly_off_blacksmith.py, and it reads nightly workflows only, so a
single-host label anywhere else (a PR compile, a side lane) went unchecked.

This guard covers every workflow:
- a runs-on never names one machine literally (a glaeda-runner-* label, a mini's
  host name);
- a runs-on that reads a single-host variable (vars.*_TRUSTED_RUNNER) always has a
  later `||` alternative, so an unset or retired host falls through to a pool;
- a compile or fallback job's concurrency group never evicts another head's run.
  GitHub keeps one pending run per group and cancels the older pending one when a
  newer run queues, whatever cancel-in-progress says. So a group shared by
  unrelated heads cancels a fallback compile before it gets a runner: on
  2026-10-26 the private shadow Release compile's single group cancelled about
  forty dispatches in 13 minutes, nx-chat's two fallback compiles among them,
  each with 0 jobs. The group must be keyed per pull request, commit, run or
  branch ref. cancel-in-progress is allowed only where the key is the pull
  request or the ref, where the cancelled run is a superseded head.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# One machine: a per-runner glaeda label, or a mini or perf host's name.
SINGLE_HOST = re.compile(
    r"\b(?:glaeda-runner-[a-z0-9][a-z0-9-]*|cmux\d+s?(?:-perf)?|cmuxs-mac-mini-\d+|cmux-austin-mini-\d+"
    r"|cmux-lawrence)\b",
    re.IGNORECASE,
)
# A repository variable naming one trusted runner (vars.CI_NIGHTLY_TRUSTED_RUNNER and the like).
SINGLE_HOST_VAR = re.compile(r"\bvars\.([A-Z0-9_]*TRUSTED_RUNNER)\b")
# What may follow a single-host variable as its fallback: `||` then a non-empty label literal, or a variable
# that is not another single-host one. A configured variable naming a dead host still never falls through;
# the controller's fall-through and the queue rescue cover that at run time.
POOL_FALLBACK = re.compile(r"\|\|\s*(?:'[^'\s]+'|vars\.(?![A-Z0-9_]*TRUSTED_RUNNER\b)[A-Z0-9_]+)")
# A reserved slot's placement output: the DEV compile slot (side_lane_placement.fresh_route(), one side instance
# per opted-in mini, glaeda#1628, for the compiles a feed's freshness waits on). It names a label only while that slot is idle, and
# the runs-on alternative that reads it must check it is set, then fall through to a later pool literal, so a busy,
# unregistered or unread slot never holds a feed's compile.
RESERVED_OUTPUT = re.compile(r"needs\.[\w-]+\.outputs\.(fresh_runner)\b")
# A job that compiles, or is a fallback route for one.
COMPILE_OR_FALLBACK = re.compile(r"compile|fallback", re.IGNORECASE)
# Keys that scope a group to one pull request, commit, run or branch, as whole identifiers
# (github.ref_type or inputs.profile are no key).
HEAD_KEY = re.compile(r"(?<![\w.])(?:github\.(?:run_id|sha|head_ref|ref|ref_name)|[\w.]*\.head_sha|[\w.]*\.head\.sha"
                      r"|inputs\.(?:sha|pr)|[\w.]*\.pull_request\.number|github\.event\.number)(?![\w.])")
# Keys under which a cancel only ever hits a superseded head of the same pull request or branch, or the same
# run (a group per run holds no other run).
SUPERSEDE_KEY = re.compile(r"(?<![\w.])(?:github\.(?:head_ref|ref|ref_name|run_id)|inputs\.pr|[\w.]*\.pull_request\.number"
                           r"|github\.event\.number)(?![\w.])")
# An alternative taken only on one named branch (`github.ref == 'refs/heads/main' && 'main'`) is a group per
# branch tip, like a github.ref key: a newer tip of that branch is what replaces its pending run.
PINNED_REF = re.compile(r"github\.(?:ref|ref_name)\s*==\s*'[^']+'")
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)


def unwrap(text: str) -> str:
    """`text` without whitespace and enclosing parentheses, `((a))` -> `a`."""
    text = text.strip()
    while wrapped(text):
        text = text[1:-1].strip()
    return text


def unconditional(alternative: str) -> bool:
    """Whether an `||` alternative always yields a runner label: a non-empty label literal, or a group one of
    whose own alternatives does. A variable may be unset, and a conjunction may be false."""
    alternative = unwrap(alternative)
    alternatives = split_top(alternative, "||")
    if len(alternatives) > 1:
        return any(unconditional(part) for part in alternatives)
    return re.fullmatch(r"'[^'\s]+'", alternative) is not None


def conjuncts(text: str) -> list[str]:
    """The `&&` terms of `text`, with parenthesized conjunctions flattened: `a && (b && c)` -> [a, b, c].
    A parenthesized term holding an `||` stays one term."""
    terms = []
    for term in split_top(unwrap(text), "&&"):
        term = unwrap(term)
        nested = split_top(term, "&&")
        terms += conjuncts(term) if len(nested) > 1 and len(split_top(term, "||")) == 1 else [term]
    return terms


def reserved_unsafe(expression: str, falls_through: bool = False) -> list[str]:
    """The reserved-slot reads in `expression` that are not a guarded preference with a fallback.

    An alternative that reads a reserved output must be `... && OUT != '' && OUT`: it yields the slot only when
    one is set, and nothing else. Some later alternative, at its own level or an enclosing one
    (`falls_through`), must always yield a label, so an empty slot never leaves the job without a runner.
    """
    found = []
    alternatives = split_top(unwrap(expression), "||")
    for index, alternative in enumerate(alternatives):
        if not RESERVED_OUTPUT.search(alternative):
            continue
        tail = falls_through or any(unconditional(later) for later in alternatives[index + 1:])
        inner = unwrap(alternative)
        if len(split_top(inner, "||")) > 1:
            found += reserved_unsafe(inner, tail)
            continue
        terms = conjuncts(inner)
        for name in dict.fromkeys(match.group(0) for match in RESERVED_OUTPUT.finditer(inner)):
            guarded = any(re.fullmatch(re.escape(name) + r"\s*!=\s*''", term) for term in terms[:-1])
            if not (guarded and terms[-1] == name and tail):
                found.append(name)
    return found


def split_top(text: str, operator: str) -> list[str]:
    """`text` split on `operator` outside parentheses and quotes."""
    parts, depth, quoted, start, index = [], 0, False, 0, 0
    while index < len(text):
        char = text[index]
        if char == "'":
            quoted = not quoted
        elif not quoted and char == "(":
            depth += 1
        elif not quoted and char == ")":
            depth -= 1
        elif not quoted and depth == 0 and text.startswith(operator, index):
            parts.append(text[start:index])
            index += len(operator)
            start = index
            continue
        index += 1
    parts.append(text[start:])
    return parts


def wrapped(text: str) -> bool:
    """Whether `text` is one parenthesized expression, `( ... )`."""
    return text.startswith("(") and text.endswith(")") and len(split_top(text[1:-1], ")(")) == 1 and \
        _closes_at_end(text)


def _closes_at_end(text: str) -> bool:
    depth, quoted = 0, False
    for index, char in enumerate(text):
        if char == "'":
            quoted = not quoted
        elif not quoted and char == "(":
            depth += 1
        elif not quoted and char == ")":
            depth -= 1
            if depth == 0 and index != len(text) - 1:
                return False
    return depth == 0


def always_keyed(expression: str, key: re.Pattern, falls_through: bool = False) -> bool:
    """Whether every value `expression` (one GitHub expression) can take carries `key`.

    An `||` holds when each alternative does; every alternative but the last falls through to the next when
    its value is falsy. An `&&` chain's value is its last operand, or a falsy operand when it is not the
    last alternative; so a chain holds only where it falls through, and then when a positive
    `github.ref == '<ref>'` operand pins it to one branch (a group per branch tip, like a ref key) or its
    last operand holds. format() holds when an argument its format string interpolates always does; a
    context path holds when it is the key; any other value (a literal, a comparison, a negation, another
    function) does not.
    """
    text = expression.strip()
    while wrapped(text):
        text = text[1:-1].strip()
    alternatives = split_top(text, "||")
    if len(alternatives) > 1:
        return all(always_keyed(alternative, key, index < len(alternatives) - 1 or falls_through)
                   for index, alternative in enumerate(alternatives))
    operands = split_top(text, "&&")
    if len(operands) > 1:
        return falls_through and (any(PINNED_REF.fullmatch(operand.strip()) for operand in operands[:-1])
                                  or always_keyed(operands[-1], key))
    call = re.fullmatch(r"format\s*\((.*)\)", text, re.DOTALL)
    if call and _closes_at_end(text[text.index("("):]):
        arguments = split_top(call.group(1), ",")
        used = {int(index) for index in re.findall(r"\{(\d+)\}", arguments[0])}
        return any(always_keyed(argument, key) for index, argument in enumerate(arguments[1:]) if index in used)
    return bool(re.fullmatch(r"[\w.]+", text)) and bool(key.fullmatch(text))


def keyed(group: str, key: re.Pattern) -> bool:
    """Whether every value `group` can take carries `key` (always_keyed() over one of its expressions)."""
    return any(always_keyed(body, key) for body in EXPRESSION.findall(group))


# Groups shared across heads on purpose, each with why no fallback compile waits in it.
SHARED_GROUP_ALLOWED = {
    # Branch-tip only (push to feat-cmux-next, or a dispatch): each run compiles the change since
    # the last verified commit, so a newer tip that evicts a pending one covers its commits too.
    ("cmux-next-tip-test-compile.yml", "cmux-next-tip-test-compile"),
}


def workflows() -> list[Path]:
    return sorted([*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")])


def load(path: Path) -> dict:
    # BaseLoader keeps `on:` a string key and every scalar a string, as GitHub reads them.
    return yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader) or {}


def runs_on_text(job: dict) -> str:
    value = job.get("runs-on")
    if isinstance(value, dict):
        labels = value.get("labels") or []
        value = [value.get("group", ""), *([labels] if isinstance(labels, str) else labels)]
    if isinstance(value, list):
        return " ".join(str(item) for item in value)
    return str(value or "")


def group_text(concurrency: object) -> tuple[str, str] | None:
    if not concurrency:
        return None
    if isinstance(concurrency, str):
        return concurrency, "false"
    return str(concurrency.get("group") or ""), str(concurrency.get("cancel-in-progress") or "false").strip()


def evicting(name: str, concurrency: object) -> str | None:
    """Why this concurrency evicts another head's run, or None."""
    found = group_text(concurrency)
    if found is None:
        return None
    group, cancel = found
    if (name, group) in SHARED_GROUP_ALLOWED:
        return None
    if not keyed(group, HEAD_KEY):
        return f"group {group!r} is shared by every head"
    if cancel not in ("false", "") and not keyed(group, SUPERSEDE_KEY):
        return f"group {group!r} cancels in progress without a pull request or ref key"
    return None


class RunsOnFallbackTests(unittest.TestCase):
    def test_workflows_are_found(self) -> None:
        self.assertIn("cmux-next.yml", {path.name for path in workflows()})

    def test_no_runs_on_names_one_machine(self) -> None:
        failures = []
        for path in workflows():
            for job_id, job in (load(path).get("jobs") or {}).items():
                match = SINGLE_HOST.search(runs_on_text(job))
                if match:
                    failures.append(f"{path.name} {job_id}: {match.group(0)}")
        self.assertEqual(failures, [], "a runs-on must name a pool, never one machine")

    def test_a_single_host_variable_always_has_a_fallback(self) -> None:
        failures = []
        for path in workflows():
            for job_id, job in (load(path).get("jobs") or {}).items():
                text = runs_on_text(job)
                for match in SINGLE_HOST_VAR.finditer(text):
                    if not POOL_FALLBACK.search(text[match.end():]):
                        failures.append(f"{path.name} {job_id}: vars.{match.group(1)} is the last alternative")
        self.assertEqual(failures, [], "a single-host runner variable needs a later `||` pool fallback")

    def test_a_reserved_slot_always_has_a_fallback(self) -> None:
        failures, seen = [], 0
        for path in workflows():
            for job_id, job in (load(path).get("jobs") or {}).items():
                text = runs_on_text(job)
                seen += len(RESERVED_OUTPUT.findall(text))
                for expression in EXPRESSION.findall(text):
                    for name in reserved_unsafe(expression):
                        failures.append(f"{path.name} {job_id}: {name} without a set check "
                                        "and a later fallback that always names a runner")
        self.assertEqual(failures, [], "a reserved slot is a preference with a fallback, never the only route")
        self.assertGreater(seen, 0, "cmux-next's feed compiles read the freshness slot")

    def test_the_reserved_slot_rule_reads_expression_branches(self) -> None:
        r = "needs.macos-placement.outputs.fresh_runner"
        # Review of #25769: an empty slot and an unset variable yield `false`, not a runner.
        self.assertEqual(reserved_unsafe(f"{r} != '' && {r} || vars.CI_PR_POOL_OWNED == '1' && 'macos-26'"), [r])
        self.assertEqual(reserved_unsafe(f"{r} != '' && {r} || vars.MACOS_RUNNER_26"), [r])
        # A parenthesized preference with its own literal fallback is safe, at any depth.
        self.assertEqual(reserved_unsafe(f"({r} != '' && {r} || 'macos-26')"), [])
        self.assertEqual(reserved_unsafe(f"(a && {r} != '' && {r} || b && 'x') || (c || 'y')"), [])
        self.assertEqual(reserved_unsafe(f"a && {r} != '' && {r} || (b && 'x' || vars.V || 'y')"), [])
        # A guard and value inside a nested conjunction (review of #25769, round 3).
        self.assertEqual(reserved_unsafe(f"github.run_attempt == 1 && ({r} != '' && {r}) || 'macos-26'"), [])
        self.assertEqual(reserved_unsafe(f"a && (b && ({r} != '' && {r})) || 'macos-26'"), [])
        self.assertEqual(reserved_unsafe(f"a && ({r} != '' && {r} && b) || 'macos-26'"), [r])
        # No set check, or a slot that is not the alternative's value.
        self.assertEqual(reserved_unsafe(f"a && {r} || 'x'"), [r])
        self.assertEqual(reserved_unsafe(f"{r} != '' && 'other' || 'x'"), [r])
        self.assertEqual(reserved_unsafe(f"{r} != '' && {r}"), [r])
        self.assertEqual(reserved_unsafe(f"({r} != '' && {r} || b && 'x')"), [r])

    def test_the_freshness_slot_is_a_pool_label(self) -> None:
        place = next(step for step in load(WORKFLOWS / "cmux-next.yml")["jobs"]["macos-placement"]["steps"]
                     if step.get("id") == "place")
        label = place["env"]["FRESH_LABEL"]
        self.assertRegex(label, r"'glaeda-dev-std-xcode-[0-9.]+'")
        self.assertIsNone(SINGLE_HOST.search(label))
        self.assertIsNone(SINGLE_HOST_VAR.search(label))

    def test_compile_and_fallback_routes_never_evict_another_head(self) -> None:
        failures = []
        for path in workflows():
            doc = load(path)
            for job_id, job in (doc.get("jobs") or {}).items():
                if not COMPILE_OR_FALLBACK.search(f"{job_id} {job.get('name') or ''}"):
                    continue
                for where, concurrency in (("job", job.get("concurrency")), ("workflow", doc.get("concurrency"))):
                    why = evicting(path.name, concurrency)
                    if why:
                        failures.append(f"{path.name} {job_id} ({where}): {why}")
        self.assertEqual(failures, [], "a compile or fallback route must be keyed per head")

    def test_the_rules_catch_what_they_are_for(self) -> None:
        # 2026-10-26: the shadow Release compile's one dispatch group.
        self.assertIsNotNone(evicting("x.yml", {"group": "${{ github.event_name == 'workflow_dispatch' && "
                                                         "'shadow-release-compile' || 'pick' }}",
                                                "cancel-in-progress": "false"}))
        self.assertIsNotNone(evicting("x.yml", {"group": "compile-${{ github.sha }}",
                                                "cancel-in-progress": "true"}))
        self.assertIsNone(evicting("x.yml", {"group": "compile-${{ github.event.pull_request.number }}",
                                             "cancel-in-progress": "true"}))
        self.assertIsNone(evicting("x.yml", {"group": "fallback-${{ inputs.pr }}-${{ inputs.sha }}",
                                             "cancel-in-progress": "false"}))
        # A shared dispatch group can hide behind another branch's key, and keys match whole identifiers.
        self.assertIsNotNone(evicting("x.yml", {"group": "${{ github.event_name == 'workflow_dispatch' && "
                                                         "'shadow-release-compile' || github.sha }}"}))
        self.assertIsNotNone(evicting("x.yml", {"group": "c-${{ github.ref_type }}-${{ inputs.profile }}"}))
        self.assertIsNone(evicting("x.yml", {"group": "${{ inputs.fallback && format('f-{0}-{1}', inputs.pr, "
                                                      "inputs.sha) || format('s-{0}', github.run_id) }}"}))
        self.assertIsNone(evicting("x.yml", {"group": "t-${{ github.ref == 'refs/heads/main' && 'main' || "
                                                      "format('sha-{0}', github.sha) }}"}))
        # A key nested where a shared value can win, or a negated ref test, keys nothing.
        self.assertIsNotNone(evicting("x.yml", {"group": "${{ format('compile-{0}', github.event_name == "
                                                         "'workflow_dispatch' && 'shared' || github.sha) }}"}))
        self.assertIsNotNone(evicting("x.yml", {"group": "${{ !(github.ref == 'refs/heads/main') && "
                                                         "'other-branches' || github.sha }}"}))
        self.assertIsNone(evicting("x.yml", {"group": "${{ format('c-{0}-{1}', github.workflow, "
                                                      "(github.event.pull_request.number || github.sha)) }}"}))
        # An argument format() never interpolates, or a conditional one that can be false, keys nothing.
        self.assertIsNotNone(evicting("x.yml", {"group": "${{ format('compile-{0}', github.workflow, "
                                                         "github.run_id) }}", "cancel-in-progress": "true"}))
        self.assertIsNotNone(evicting("x.yml", {"group": "${{ format('compile-{0}', github.event_name == "
                                                         "'pull_request' && github.event.pull_request.number) }}"}))
        self.assertIsNotNone(evicting("x.yml", {"group": "${{ github.ref == 'refs/heads/main' && 'main' }}"}))
        # A scalar `labels` is one label, and an empty or single-host alternative is no fallback.
        self.assertIn("glaeda-runner-cmux15", runs_on_text({"runs-on": {"group": "mac",
                                                                        "labels": "glaeda-runner-cmux15"}}))
        self.assertIsNone(POOL_FALLBACK.search(" || ''"))
        self.assertIsNone(POOL_FALLBACK.search(" || vars.CI_SEED_TRUSTED_RUNNER"))
        self.assertIsNotNone(POOL_FALLBACK.search(" || 'blacksmith-6vcpu-macos-26'"))
        self.assertIsNotNone(POOL_FALLBACK.search(" || vars.MACOS_RUNNER_26 || 'x'"))
        self.assertTrue(SINGLE_HOST.search("glaeda-runner-cmux15"))
        self.assertTrue(SINGLE_HOST.search("runs-on: cmux22"))
        self.assertFalse(SINGLE_HOST.search("glaeda-side-std-xcode-26.6"))
        self.assertFalse(SINGLE_HOST.search("blacksmith-6vcpu-macos-26"))


if __name__ == "__main__":
    unittest.main()
