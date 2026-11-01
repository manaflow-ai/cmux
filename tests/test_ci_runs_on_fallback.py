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
  request or the ref, where the cancelled run is a superseded head;
- no runs-on lands on blacksmith-12vcpu-macos-26 when every picker before it
  answers nothing. That label started no job from about 02:11Z on 2026-10-28
  (and for hours on 10-20 and 10-26) while 61 cmux jobs queued on it; GitHub
  never moves a queued job. A job may still take 12 vCPU from a picker that
  skips a stalled label (next_macos_cascade.py, simple_pool_picker.py,
  nightly_sign_runner.py), never as its literal last resort. A variable naming
  12 vCPU is checked where its value is known, by ci-repo-variables.yml.
"""

from __future__ import annotations

import json
import importlib.util
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
sys.path.insert(0, str(Path(__file__).resolve().parent))

import runs_on_labels  # noqa: E402

# Blacksmith's 12 vCPU macOS 26 label: 5 slots, and stalled for hours on 2026-10-20, -26 and -28.
LARGE_MAC = "blacksmith-12vcpu-macos-26"
# What a picker job, an input or a matrix leg gives a runs-on; '' when the picker answered nothing.
PICKER_CONTEXTS = ("needs", "inputs", "steps", "matrix", "env", "jobs", "strategy")
# Jobs that keep the label as their literal last resort, and why. None today: the keyed signing jobs read a
# stall-aware picker since cmux#27066. A new entry needs a reason; one no job needs any more fails the test.
LARGE_MAC_LAST_RESORT: dict[str, str] = {}

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
# Runner variables that name an owned, reserved or otherwise single-host route.
# A terminal value from any of these is a dead-end queue when its listener is
# offline; every one needs a later pool fallback in the same runs-on chain.
RESERVED_RUNNER_VARIABLES = (
    "vars.CI_SIDE_LANE_RUNNER", "vars.CI_LIGHT_LANE_RUNNER", "vars.CI_FAST_LANE_RUNNER",
    "vars.CI_SESSION_LANE_RUNNER", "vars.CI_NIGHTLY_NEXT_BUILD_RUNNER",
    "vars.CI_DEV_COMPILE_RUNNER", "vars.CI_NIGHTLY_TRUSTED_RUNNER",
    "vars.CI_NIGHTLY_NEXT_TRUSTED_RUNNER", "vars.CI_IOS_INTERNAL_RUNNER",
)
# An owned GUI or session label: one console-token or logged-in-session queue per pool, a single pool with no
# second member (glaeda_fleet_labels.gui_label(), session_label()). GitHub never moves a job queued on it.
OWNED_ROLE_LABEL = re.compile(r"'(glaeda-(?:[a-z]+-)*?(?:gui|session)-[a-z0-9.-]+)'")
# A placement's role route and the health-checked overflow that must sit beside it (side_lane_placement.py).
ROLE_OUTPUT = re.compile(r"needs\.([\w-]+)\.outputs\.(?:gui_runner|session_runner)\b")
RESCUE = WORKFLOWS / "ci-owned-pool-rescue.yml"
# A session label (glaeda-session-<class>-xcode-<v>, pr_runner_pool.session_label()) and a variable naming one
# (vars.CI_SESSION_LANE_RUNNER; a switch like vars.CI_SESSION_LABEL names no label). A runs-on takes one only
# from a placement output that role_room() judged.
SESSION_LITERAL = re.compile(r"'(glaeda-(?:[a-z]+-)*?session-[a-z0-9.-]+)'")
SESSION_VARIABLE = re.compile(r"\bvars\.([A-Z0-9_]*SESSION[A-Z0-9_]*RUNNER[A-Z0-9_]*)\b")
SESSION_LANE_GUARD = re.compile(r"needs\.[\w-]+\.outputs\.session_lane_runner\s*!=\s*''")
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


def terminal_reserved(expression: str, variable: str) -> bool:
    """Whether the final value of a runs-on chain is a reserved label variable.

    A variable in a guarded preference is safe only when a later alternative
    names a pool. If the final ``||``/``&&`` value is the reserved variable,
    an offline or non-listening reservation leaves GitHub with one dead queue.
    Keep this structural check independent of the particular runner class so
    newly added reserved labels cannot bypass the no-single-host rule.
    """
    text = unwrap(expression)
    alternatives = split_top(text, "||")
    if len(alternatives) > 1:
        return terminal_reserved(alternatives[-1], variable)
    operands = split_top(text, "&&")
    if len(operands) > 1:
        return terminal_reserved(operands[-1], variable)
    return text.strip() == variable


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


MATRIX_KEY = re.compile(r"\bmatrix\.([A-Za-z_][\w-]*)")


def lands_on_large_mac(job: dict) -> bool:
    """Whether a job can run on LARGE_MAC with every picker before it silent (vars unknown or unset).

    Fails closed: a runs-on that spells LARGE_MAC but whose value the resolver cannot read (a fromJSON() or
    format() of it, an expression it cannot parse) counts as landing there.
    """
    text = runs_on_text(job)
    matrix = (job.get("strategy") or {}).get("matrix") if isinstance(job.get("strategy"), dict) else None
    for key in MATRIX_KEY.findall(text):
        if isinstance(matrix, str):
            # A matrix built at run time (fromJSON of a picker's output): fails closed only if it spells the label.
            if LARGE_MAC in matrix:
                return True
            continue
        if not isinstance(matrix, dict):
            continue
        # The axis itself, and every include entry that sets that key (`include:` adds or extends combinations).
        includes = matrix.get("include") if isinstance(matrix.get("include"), list) else []
        values = [matrix.get(key, ""), *(entry.get(key, "") for entry in includes if isinstance(entry, dict))]
        if LARGE_MAC in yaml.safe_dump(values) or (isinstance(matrix.get("include"), str) and LARGE_MAC in matrix["include"]):
            return True
    if LARGE_MAC not in text:
        return False
    runs_on = job.get("runs-on")
    if isinstance(runs_on, dict):
        runs_on = [runs_on.get("group", ""), *([runs_on.get("labels")] if isinstance(runs_on.get("labels"), str)
                                                 else runs_on.get("labels") or [])]
    try:
        labels = runs_on_labels.resolve_labels(runs_on, silent=PICKER_CONTEXTS)
    except ValueError:
        return True
    unread = any(isinstance(label, runs_on_labels.Unknown) and str(label).endswith("(...)") for label in labels)
    return unread or LARGE_MAC in {str(label) for label in labels}


# The rescue's re-run actors (owned_pool_rescue.RESCUE_ACTOR, pr_runner_pool.RESCUE_ACTORS) and the attempts
# it can reach. An alternative that names an owned role label must be false for each of them on each attempt
# after the first, so the rescue never re-queues a job on the pool it moved it from.
RESCUE_BOTS = ("github-actions[bot]", "cmux-bot[bot]")
RESCUE_ATTEMPTS = (2, 3, 4, 9, 99)
ATTEMPT_TEST = re.compile(r"github\.run_attempt\s*(==|!=|<=|>=|<|>)\s*'?(\d+)'?")
ACTOR_TEST = re.compile(r"(!?)\s*contains\(\s*fromJSON\(\s*'(\[[^']*\])'\s*\)\s*,\s*github\.triggering_actor\s*\)")
COMPARE = {"==": int.__eq__, "!=": int.__ne__, "<=": int.__le__, ">=": int.__ge__, "<": int.__lt__, ">": int.__gt__}


def gate_value(term: str, attempt: int, actor: str) -> bool | None:
    """`term` on that attempt and actor: True, False, or None when it reads anything else (a variable, an
    output), which may be either. Covers `||`, `&&`, `!`, parentheses, attempt comparisons and the actor's
    membership in a fromJSON list; a bare github.run_attempt or github.triggering_actor is a non-empty value."""
    text = unwrap(term)
    alternatives = split_top(text, "||")
    if len(alternatives) > 1:
        values = [gate_value(alternative, attempt, actor) for alternative in alternatives]
        return True if True in values else (False if all(value is False for value in values) else None)
    terms = split_top(text, "&&")
    if len(terms) > 1:
        values = [gate_value(inner, attempt, actor) for inner in terms]
        return False if False in values else (True if all(value is True for value in values) else None)
    match = ATTEMPT_TEST.fullmatch(text)
    if match:
        return COMPARE[match.group(1)](attempt, int(match.group(2)))
    match = ACTOR_TEST.fullmatch(text)
    if match:
        try:
            listed = actor in json.loads(match.group(2))
        except ValueError:
            return None
        return (not listed) if match.group(1) else listed
    if text.startswith("!") and not text.startswith("!="):
        inner = gate_value(text[1:], attempt, actor)
        return None if inner is None else not inner
    if text in ("github.run_attempt", "github.triggering_actor"):
        return True
    return None


def attempt_gate(term: str) -> bool:
    """Whether `term` is false for every rescue bot on every attempt after the first (gate_value()), so the
    alternative it guards is never the rescue's re-run route. `github.run_attempt == 1` and
    `!contains(fromJSON('["github-actions[bot]","cmux-bot[bot]"]'), github.triggering_actor)` are; an attempt
    bound such as `<= 3`, a list missing a bot, or an `||` with a variable is not."""
    return all(gate_value(term, attempt, actor) is False for attempt in RESCUE_ATTEMPTS for actor in RESCUE_BOTS)


def ungated_role_labels(expression: str, gated: bool = False) -> list[str]:
    """The owned role labels in `expression` that an alternative yields with no github.run_attempt term."""
    found = []
    for alternative in split_top(unwrap(expression), "||"):
        inner = unwrap(alternative)
        if len(split_top(inner, "||")) > 1:
            found += ungated_role_labels(inner, gated)
            continue
        terms = conjuncts(inner)
        here = gated or any(attempt_gate(term) for term in terms[:-1])
        last = unwrap(terms[-1])
        if len(split_top(last, "||")) > 1:
            found += ungated_role_labels(last, here)
        elif OWNED_ROLE_LABEL.fullmatch(last) and not here:
            found.append(last.strip("'"))
    return found


def rescued_paths() -> set[str]:
    """The workflows ci-owned-pool-rescue.yml watches: a queue on an owned label there is re-dispatched."""
    return set(str(load(RESCUE)["env"]["SOURCE_WORKFLOW_PATHS"]).split())


def role_label_problems(path: str, text: str, rescued: set[str]) -> list[str]:
    """Why a runs-on that can take an owned GUI or session label could wait on that one pool with no way off.

    Leo, 2026-10-24: "a CI test fails on a runs-on that can resolve to a single-host label with no fallback";
    2026-10-28: "I hate pins". A gui or session label is one queue per class. #26809 (2026-10-29): eleven swift
    tests waited 45+ minutes on the std gui label while it existed but had no room. Such a runs-on needs
    - a last alternative that always names a runner off the owned pools (a Blacksmith macOS label), so the
      route has a member to fall to;
    - its workflow watched by ci-owned-pool-rescue.yml, so a job already queued there is moved after the
      queue alarm, and the alternative that names the label gated on github.run_attempt, so the rescue's
      re-run leaves that queue instead of joining it again;
    - where it reads a placement's gui_runner or session_runner, the same placement's gui_overflow too:
      the route side_lane_placement.role_room() takes when that queue is deeper than the pool.
    """
    labels = OWNED_ROLE_LABEL.findall(text)
    if not labels:
        return []
    found = []
    for expression in EXPRESSION.findall(text) or [text]:
        if not OWNED_ROLE_LABEL.search(expression):
            continue
        last = unwrap(split_top(unwrap(expression), "||")[-1])
        while len(split_top(last, "||")) > 1:
            last = unwrap(split_top(last, "||")[-1])
        if not (unconditional(last) and not last.strip("'").startswith("glaeda-")):
            found.append(f"{labels[0]} has no last alternative off the owned pools")
        found += [f"{label} is taken on every attempt, so a re-run queues on it again"
                  for label in ungated_role_labels(expression)]
    if path not in rescued:
        found.append(f"{labels[0]} is not watched by ci-owned-pool-rescue.yml")
    for placement in dict.fromkeys(ROLE_OUTPUT.findall(text)):
        if f"needs.{placement}.outputs.gui_overflow" not in text:
            found.append(f"reads needs.{placement}'s gui route without its gui_overflow")
    return found
# A pull request from a fork: its own fixed route, before any placement output is read.
FORK_CLAUSE = "head.repo.full_name != github.repository"
# A Blacksmith macOS label literal.
BLACKSMITH_MAC_LITERAL = re.compile(r"'blacksmith-[0-9]+vcpu-macos-[0-9.]+'")


def flat_alternatives(expression: str) -> list[str]:
    """The `||` alternatives of `expression` in the order they are tried, with parenthesized groups of
    alternatives flattened: `a || (b || c) || d` -> [a, b, c, d]."""
    found = []
    for part in split_top(unwrap(expression), "||"):
        part = unwrap(part)
        found += flat_alternatives(part) if len(split_top(part, "||")) > 1 else [part]
    return found


def separate_pr_cascade(alternative: str) -> bool:
    """A complete non-display PR picker route, separate from the later push GUI route.

    Require allocated overflow legs and fresh owned/retry outputs; an event-gated
    fixed label alone is still a pin, not a separate picker route.
    """
    terms = conjuncts(alternative)
    if len(terms) != 2 or terms[0] != "github.event_name == 'pull_request'":
        return False
    route = terms[1]
    if "outputs.gui_overflow" in route or not unconditional(route):
        return False
    legs = flat_alternatives(route)
    freshness = "needs.macos-placement.outputs.placed_attempt == format('{0}', github.run_attempt)"
    for output in ("blacksmith_12_jobs", "blacksmith_6_jobs", "owned_jobs"):
        matches = [leg for leg in legs if f"outputs.{output}" in leg]
        if len(matches) != 1 or freshness not in conjuncts(matches[0]):
            return False
    if not any(freshness in conjuncts(leg) and conjuncts(leg)[-1] ==
               "needs.macos-placement.outputs.retry_runner" for leg in legs):
        return False
    # Every literal before the terminal fallback must come from an allocation.
    for leg in legs[:-1]:
        if BLACKSMITH_MAC_LITERAL.search(leg) and not any(
            f"outputs.blacksmith_{size}_jobs" in leg for size in (12, 6)
        ):
            return False
    return True


def overflow_preempted(text: str) -> list[str]:
    """The alternatives that send a GUI job to a fixed Blacksmith macOS label before its placement's gui_overflow.

    side_lane_placement.py writes gui_overflow as the Blacksmith size the GUI jobs take when no owned GUI runner
    has room (next_macos_cascade.gui_overflow_label(): 12 vCPU while it moves, else 6 vCPU), on attempt 1 and
    on the rescue's re-run. An alternative before it that names a Blacksmith literal decides the size instead:
    run 41123927916 (cmux#28497, 2026-10-30) ran swift-test on 6 vCPU on both attempts through such legs
    (`runner != '' && 'blacksmith-6vcpu-macos-26'`, `github.run_attempt != 1 && 'blacksmith-6vcpu-macos-26'`).
    A fork clause or complete non-display PR picker route may come first; a literal after
    the gui_overflow read is the last resort.
    """
    found = []
    for expression in EXPRESSION.findall(text) or [text]:
        if "outputs.gui_overflow" not in expression:
            continue
        for alternative in flat_alternatives(expression):
            if "outputs.gui_overflow" in alternative:
                break
            if (BLACKSMITH_MAC_LITERAL.search(alternative) and FORK_CLAUSE not in alternative
                    and not separate_pr_cascade(alternative)):
                found.append(alternative)
    return found


def leaves(expression: str) -> list[str]:
    """`expression`'s `||` alternatives, with each parenthesized alternation opened up in place."""
    found = []
    for alternative in split_top(unwrap(expression), "||"):
        inner = unwrap(alternative)
        if len(split_top(inner, "||")) > 1:
            found += leaves(inner)
            continue
        terms = conjuncts(inner)
        last = unwrap(terms[-1]) if terms else inner
        if len(split_top(last, "||")) > 1:
            # `a && (b || c)`: each of b and c is taken under a's conjuncts.
            found += [" && ".join([*terms[:-1], leaf]) for leaf in leaves(last)]
        else:
            found.append(inner)
    return found


def session_label_problems(text: str) -> list[str]:
    """Why a runs-on can send a job to a session label without a placement having judged that label's queue.

    The session label's runners are often online and busy on gui jobs while it starts nothing: on 2026-10-29
    cmux#24295's daemon tests waited 90 minutes on glaeda-session-std-xcode-26.6, twice, with five session
    runners online (36 offline) and the gui label beside it starting jobs within a minute, and the janitor
    opened "Runner label starved" issues for it twice that day. The gui-or-session rule above passed those
    jobs, because it counts ci-owned-pool-rescue.yml's watch as the way off; but the rescue watches a cmux-next
    run "refusals-only" while Blacksmith has no free slot, as it had none that day, so it never moved them,
    and GitHub never moves a queued job. So a session label reaches a job only from a placement output
    (side_lane_placement.py's session_runner, session_lane_runner, free_session_runner), whose role_room()
    declines a label the janitor found unserved:
    - no runs-on names a session label literally;
    - an alternative that reads a session variable (vars.CI_SESSION_LANE_RUNNER) also requires the
      placement's session_lane_runner to be set, so the variable is taken only while role_room() held for it.
    """
    found = [f"names {label} literally" for label in dict.fromkeys(SESSION_LITERAL.findall(text))]
    for expression in EXPRESSION.findall(text) or [text]:
        for leaf in leaves(expression):
            variables = SESSION_VARIABLE.findall(leaf)
            if variables and not any(SESSION_LANE_GUARD.fullmatch(unwrap(term)) for term in conjuncts(leaf)):
                found.append(f"reads vars.{variables[0]} without the placement's session_lane_runner")
    return found


# Side-workflow Mac jobs placed through cmux-next's cascade (scripts/ci/side_lane_placement.py and
# next_macos_cascade.py): (workflow, job) -> (the placing job, the key the placement lists the job under).
# Such a job takes an idle owned Mac, else a free Blacksmith macOS slot, and never waits on one busy side
# label: on 2026-10-29 the NEXT post-publish launch smoke waited 45 minutes to 2 hours on
# glaeda-side-std-xcode-26.6 (build 4086860262501 published 12:18Z, smoked from 13:14Z).
CASCADE_PLACED = {("nightly-next-launch-smoke.yml", "smoke"): ("pick", "launch-smoke")}


def cascade_placed_failures(name: str, job_id: str, jobs: dict, placer: str, key: str) -> list[str]:
    """Why `job_id`'s runs-on can wait on the side label without reading its placement's Blacksmith slot."""
    failures = []
    runs_on = runs_on_text(jobs[job_id])
    place = next((step for step in jobs[placer].get("steps") or []
                  if "side_lane_placement.py" in str(step.get("run") or "")), None)
    if place is None:
        return [f"{name} {placer}: no side_lane_placement.py step"]
    env = place.get("env") or {}
    for variable in ("JOBS", "CASCADE_RUNS", "CASCADE_JOBS"):
        if key not in str(env.get(variable) or "").split():
            failures.append(f"{name} {placer}: {variable} does not list {key}")
    side = runs_on.find("CI_SIDE_LANE_RUNNER")
    for output, label in (("blacksmith_12_jobs", "blacksmith-12vcpu-macos-26"), ("blacksmith_6_jobs", "blacksmith-6vcpu-macos-26")):
        if f"${{{{ steps.{place.get('id')}.outputs.{output} }}}}" != str((jobs[placer].get("outputs") or {}).get(output)):
            failures.append(f"{name} {placer}: output {output} is not the placement's")
        read = (f"needs.{placer}.outputs.placed_attempt == format('{{0}}', github.run_attempt) && "
                f"contains(needs.{placer}.outputs.{output}, ' {key} ') && '{label}'")
        at = runs_on.find(read)
        if at < 0 or (side >= 0 and at > side):
            failures.append(f"{name} {job_id}: runs-on does not take `{label}` for {key} ahead of the side label")
    # A re-run of the job alone keeps the placing job's outputs from the attempt before: a slot read then.
    if "github.run_attempt" not in str((jobs[placer].get("outputs") or {}).get("placed_attempt") or ""):
        failures.append(f"{name} {placer}: no placed_attempt output for the attempt that placed")
    expressions = EXPRESSION.findall(runs_on)
    if not expressions or not unconditional(split_top(unwrap(expressions[0]), "||")[-1]):
        failures.append(f"{name} {job_id}: runs-on does not end in a label literal")
    return failures


def smoke_tooling():
    path = ROOT / "scripts" / "ci" / "nightly_next_launch_smoke.py"
    spec = importlib.util.spec_from_file_location("_runs_on_fallback_launch_smoke", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CascadePlacedSideJobs(unittest.TestCase):
    def test_a_placed_side_job_takes_the_cascade_before_the_side_label(self) -> None:
        failures = []
        for (name, job_id), (placer, key) in CASCADE_PLACED.items():
            failures += cascade_placed_failures(name, job_id, load(WORKFLOWS / name)["jobs"], placer, key)
        self.assertEqual(failures, [], "a placed side job reads its Blacksmith slot before the side label")

    def test_the_rule_catches_a_job_left_on_the_side_label(self) -> None:
        jobs = load(WORKFLOWS / "nightly-next-launch-smoke.yml")["jobs"]
        pinned = {**jobs, "smoke": {**jobs["smoke"], "runs-on": "${{ github.run_attempt == 1 && "
                                                             "vars.CI_SIDE_LANE_RUNNER || 'blacksmith-6vcpu-macos-26' }}"}}
        self.assertTrue(cascade_placed_failures("x.yml", "smoke", pinned, "pick", "launch-smoke"))
        unplaced = {**jobs, "pick": {**jobs["pick"], "steps": [s for s in jobs["pick"]["steps"]
                                                               if "side_lane_placement.py" not in str(s.get("run"))]}}
        self.assertTrue(cascade_placed_failures("x.yml", "smoke", unplaced, "pick", "launch-smoke"))

    def test_the_cascade_takes_a_side_workflows_own_job(self) -> None:
        path = ROOT / "scripts" / "ci" / "next_macos_cascade.py"
        spec = importlib.util.spec_from_file_location("_runs_on_fallback_next_macos_cascade", path)
        module = importlib.util.module_from_spec(spec)
        import sys
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        env = {"JOBS": "launch-smoke", "CASCADE_RUNS": " launch-smoke ", "CASCADE_JOBS": "launch-smoke"}
        self.assertEqual(module.candidates(env, ()), ["launch-smoke"])
        self.assertEqual(module.candidates({**env, "CASCADE_JOBS": ""}, ()), [])


class OneLaunchSmokePerBuild(unittest.TestCase):
    """The post-publish launch smoke's ticks never queue a second smoke of a build (up to three per build
    on 2026-10-29, each holding a side-label slot): a scheduled tick skips a build whose smoke another run
    has queued or running."""

    def test_a_scheduled_tick_skips_a_build_another_run_is_smoking(self) -> None:
        jobs = load(WORKFLOWS / "nightly-next-launch-smoke.yml")["jobs"]
        steps = {step.get("id"): step for step in jobs["pick"]["steps"]}
        self.assertIn("nightly_next_launch_smoke.py in-flight", steps["in-flight"]["run"])
        self.assertEqual(jobs["pick"]["outputs"]["in_flight"], "${{ steps.in-flight.outputs.in_flight }}")
        self.assertIn("(github.event_name != 'schedule' || needs.pick.outputs.in_flight == '')", jobs["smoke"]["if"])
        self.assertEqual(jobs["smoke"]["name"], "smoke ${{ needs.pick.outputs.build }}")
        # A smoke that does run (a dispatch, a pull request) is still placed: only a skipped tick is not.
        self.assertIn("(github.event_name != 'schedule' || steps.in-flight.outputs.in_flight == '')", steps["place"]["if"])

    def test_a_second_smoke_of_a_build_cannot_start(self) -> None:
        tooling = smoke_tooling()
        runs = [{"id": 4, "status": "in_progress", "event": "pull_request"},
                {"id": 2, "status": "queued", "event": "schedule"}, {"id": 1, "status": "completed", "event": "schedule"}]
        jobs = {2: [{"name": tooling.smoke_job(200), "status": "queued", "conclusion": None}],
                1: [{"name": tooling.smoke_job(100), "status": "completed", "conclusion": "success"}],
                4: [{"name": tooling.smoke_job(500), "status": "queued", "conclusion": None}]}
        self.assertEqual(tooling.in_flight(runs, jobs.__getitem__, 200, own_run=3), 2)
        self.assertEqual(tooling.in_flight(runs, jobs.__getitem__, 500, own_run=3), 4)  # a pull request's smoke too
        self.assertIsNone(tooling.in_flight(runs, jobs.__getitem__, 100, own_run=3))
        self.assertIsNone(tooling.in_flight(runs, jobs.__getitem__, 300, own_run=3))


class RunsOnFallbackTests(unittest.TestCase):
    def test_workflows_are_found(self) -> None:
        self.assertIn("cmux-next.yml", {path.name for path in workflows()})

    def test_no_job_falls_back_to_the_large_blacksmith_mac(self) -> None:
        failures, seen = [], set()
        for path in workflows():
            for job_id, job in (load(path).get("jobs") or {}).items():
                key = f"{path.name}#{job_id}"
                hit = lands_on_large_mac(job)
                if hit and key in LARGE_MAC_LAST_RESORT:
                    seen.add(key)
                elif hit:
                    failures.append(key)
        self.assertEqual(failures, [], f"{LARGE_MAC} stalls for hours at a time: take it only from a picker that "
                                       "skips a stalled label, with an owned Mac or blacksmith-6vcpu-macos-26 last")
        self.assertEqual(set(LARGE_MAC_LAST_RESORT) - seen, set(), "an exception no job needs any more: drop it")

    def test_no_runs_on_names_one_machine(self) -> None:
        failures = []
        for path in workflows():
            for job_id, job in (load(path).get("jobs") or {}).items():
                match = SINGLE_HOST.search(runs_on_text(job))
                if match:
                    failures.append(f"{path.name} {job_id}: {match.group(0)}")
        self.assertEqual(failures, [], "a runs-on must name a pool, never one machine")

    def test_the_nightly_only_builder_is_reached_only_through_its_idle_pick(self) -> None:
        # One runner per dedicated Mac carries it, so a queue on it could wait a whole build. Only
        # nightly_build_runner.nightly_only_builder_route() names it, and only while one is idle now;
        # otherwise, and when unread, the build takes the plain ten-runner glaeda-nightly-only-m4pro.
        failures = [f"{path.name} {job_id}" for path in workflows()
                    for job_id, job in (load(path).get("jobs") or {}).items()
                    if re.search(r"nightly-only-m4pro-builder|CI_NIGHTLY_ONLY_BUILDER_RUNNER", runs_on_text(job))]
        self.assertEqual(failures, [], "the warm nightly builder label is a pick, never a runs-on literal")

    def test_a_single_host_variable_always_has_a_fallback(self) -> None:
        failures = []
        for path in workflows():
            for job_id, job in (load(path).get("jobs") or {}).items():
                text = runs_on_text(job)
                for match in SINGLE_HOST_VAR.finditer(text):
                    if not POOL_FALLBACK.search(text[match.end():]):
                        failures.append(f"{path.name} {job_id}: vars.{match.group(1)} is the last alternative")
        self.assertEqual(failures, [], "a single-host runner variable needs a later `||` pool fallback")

    def test_a_picked_signing_label_has_a_rerun_alternative(self) -> None:
        # A Blacksmith macOS label picked once can stall after the pick, and GitHub never
        # re-routes a queued job: only a re-run leaves it. nightly.yml's signing jobs read the
        # picker's other macOS 26 size on attempt 2 on, so a re-run never queues on the label
        # that stalled (run 40489472569, 2026-10-27, waited on blacksmith-6vcpu-macos-26).
        jobs = load(WORKFLOWS / "nightly.yml")["jobs"]
        picked = re.compile(r"\|\| (needs\.(?:pick-nightly-sign-runner|find-nightly-next-recovery|legacy-identity-target)"
                            r"\.outputs\.)(runner|sign_runner) \|\|")
        failures, seen = [], set()
        for job_id, job in jobs.items():
            text = runs_on_text(job)
            for match in picked.finditer(text):
                seen.add(job_id)
                alternate = match.group(1) + ("alternate" if match.group(2) == "runner" else "sign_alternate")
                if f"|| github.run_attempt > 1 && {alternate} {match.group(0)}" not in text:
                    failures.append(f"nightly.yml {job_id}: {match.group(1)}{match.group(2)} has no re-run alternative")
        self.assertIn("build-sign-notarize-nightly", seen)
        self.assertEqual(failures, [], "a picked signing label needs `github.run_attempt > 1 && <alternate>` before it")

    def test_a_picked_owned_mac_is_read_only_on_the_attempt_that_picked_it(self) -> None:
        # The owned-only form of the rule above. Nightlies never use Blacksmith (Lawrence, 2026-10-30, a7b6a61175c),
        # so sign-nightly-identity-legacy and its verify read the picker's owned Mac, not a Blacksmith label with an
        # alternate. A re-run of failed jobs keeps the old pick, so the owned read must hold only on the attempt that
        # ran the picker; a re-run then falls through to the owned slot or pool, never to the Mac that stalled.
        jobs = load(WORKFLOWS / "nightly.yml")["jobs"]
        owned = re.compile(r"needs\.(pick-nightly-sign-runner)\.outputs\.(?:sign_owned|owned)\b")
        failures, seen = [], set()
        for job_id, job in jobs.items():
            for expression in EXPRESSION.findall(runs_on_text(job)):
                for alternative in split_top(unwrap(expression), "||"):
                    match = owned.search(alternative)
                    if not match:
                        continue
                    seen.add(job_id)
                    guards = {f"needs.{match.group(1)}.outputs.attempt == github.run_attempt", "github.run_attempt == 1"}
                    if not guards & {term.strip() for term in conjuncts(alternative)}:
                        failures.append(f"nightly.yml {job_id}: {alternative.strip()}")
        self.assertTrue({"sign-nightly-identity-legacy", "verify-nightly-identity-legacy"} <= seen, seen)
        self.assertEqual(failures, [], "an owned pick needs its picker's attempt check in the same alternative")

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

    def test_an_owned_gui_or_session_label_always_has_a_way_off(self) -> None:
        rescued, failures, seen = rescued_paths(), [], 0
        for path in workflows():
            for job_id, job in (load(path).get("jobs") or {}).items():
                text = runs_on_text(job)
                seen += bool(OWNED_ROLE_LABEL.search(text))
                for why in role_label_problems(f".github/workflows/{path.name}", text, rescued):
                    failures.append(f"{path.name} {job_id}: {why}")
        self.assertEqual(failures, [], "a gui or session pool is one queue: it needs a member off it")
        self.assertGreaterEqual(seen, 3, "cmux-next's swift-test, daemon-test and generated-files read the gui pool")

    def test_no_runs_on_chain_ends_on_the_reserved_side_label(self) -> None:
        failures = []
        for path in workflows():
            for job_id, job in (load(path).get("jobs") or {}).items():
                for expression in EXPRESSION.findall(runs_on_text(job)):
                    for variable in RESERVED_RUNNER_VARIABLES:
                        if terminal_reserved(expression, variable):
                            failures.append(f"{path.name} {job_id}: terminal {variable} has no pool fallback")
        self.assertEqual(failures, [], "a reserved runner label must never be the final runs-on value")

    def test_cmux_next_fast_tier_uses_the_cascade_before_deferring_to_base_queue(self) -> None:
        fast = load(WORKFLOWS / "cmux-next.yml")["jobs"]["fast-tier"]
        expression = runs_on_text(fast)
        retry = expression.index("needs.macos-placement.outputs.retry_runner")
        deferred = expression.index("needs.macos-placement.outputs.deferred_runner")
        legacy = expression.index("vars.CI_SIDE_LANE_RUNNER")
        self.assertLess(retry, deferred)
        self.assertLess(deferred, legacy)
        self.assertIn(".github/workflows/cmux-next.yml", rescued_paths())
        self.assertNotIn("needs.macos-placement.outputs", fast["if"])

    def test_the_role_label_rule_catches_what_it_is_for(self) -> None:
        here = ".github/workflows/x.yml"
        gui = "'glaeda-gui-std-xcode-26.6'"
        # A bare gui label, or one whose last alternative is another owned label or a variable.
        self.assertTrue(role_label_problems(here, f"${{{{ {gui} }}}}", {here}))
        self.assertTrue(role_label_problems(here, f"${{{{ a && {gui} || 'glaeda-side-std-xcode-26.6' }}}}", {here}))
        self.assertTrue(role_label_problems(here, f"${{{{ a && {gui} || vars.MACOS_RUNNER_26 }}}}", {here}))
        # A gui label on every attempt: the rescue's re-run would queue on it again.
        self.assertTrue(role_label_problems(here, f"${{{{ a && {gui} || 'blacksmith-6vcpu-macos-26' }}}}", {here}))
        self.assertEqual(role_label_problems(
            here, f"${{{{ a && github.run_attempt == 1 && (b && {gui} || {gui}) || 'blacksmith-6vcpu-macos-26' }}}}",
            {here}), [])
        # Review of #27201: an attempt test that another `||` branch can bypass is no gate.
        self.assertTrue(role_label_problems(
            here, f"${{{{ (github.run_attempt == 1 || vars.X) && {gui} || 'blacksmith-6vcpu-macos-26' }}}}", {here}))
        for bypass in ("github.triggering_actor", "github.run_attempt", "github.run_attempt > 1",
                       "github.run_attempt != 1", "contains(fromJSON('[\"cmux-bot[bot]\"]'), github.triggering_actor)",
                       # Review of #27201 at 175560bc: a bot list that misses a rescue actor, and bounds the re-run meets.
                       "!contains(fromJSON('[\"github-actions[bot]\"]'), github.triggering_actor)",
                       "github.run_attempt == 2", "github.run_attempt <= 3", "github.run_attempt <= 99"):
            self.assertTrue(role_label_problems(
                here, f"${{{{ (github.run_attempt == 1 || {bypass}) && {gui} || 'blacksmith-6vcpu-macos-26' }}}}",
                {here}), bypass)
        self.assertEqual(role_label_problems(
            here, f"${{{{ (github.run_attempt == 1 || !contains(fromJSON('[\"github-actions[bot]\",\"cmux-bot[bot]\"]'), "
                  f"github.triggering_actor)) && {gui} || 'blacksmith-6vcpu-macos-26' }}}}", {here}), [])
        self.assertTrue(role_label_problems(
            here, f"${{{{ github.run_attempt <= 3 && {gui} || 'blacksmith-6vcpu-macos-26' }}}}", {here}))
        self.assertEqual(role_label_problems(
            here, f"${{{{ vars.X == '1' && github.run_attempt == 1 && {gui} || 'blacksmith-6vcpu-macos-26' }}}}", {here}), [])
        # A Blacksmith last member, but nothing watches the workflow's queue.
        self.assertTrue(role_label_problems(here, f"${{{{ a && {gui} || 'blacksmith-6vcpu-macos-26' }}}}", set()))
        self.assertEqual(role_label_problems(
            here, f"${{{{ github.run_attempt == 1 && ({gui}) || vars.X || 'blacksmith-6vcpu-macos-26' }}}}", {here}), [])
        # A placement's gui route without its health-checked overflow.
        placed = f"${{{{ needs.p.outputs.gui_runner || github.run_attempt == 1 && {gui} || 'blacksmith-6vcpu-macos-26' }}}}"
        self.assertTrue(role_label_problems(here, placed, {here}))
        self.assertEqual(role_label_problems(here, placed.replace(
            "|| github.run_attempt == 1", "|| needs.p.outputs.gui_overflow || github.run_attempt == 1"), {here}), [])

    def test_no_fixed_blacksmith_leg_comes_before_the_gui_overflow(self) -> None:
        failures, seen = [], 0
        for path in workflows():
            for job_id, job in (load(path).get("jobs") or {}).items():
                labels = {"runs-on": runs_on_text(job)}
                runner_copy = (job.get("env") or {}).get("CMUX_NEXT_RUNNER")
                if isinstance(runner_copy, str):
                    labels["CMUX_NEXT_RUNNER"] = runner_copy
                for key, text in labels.items():
                    seen += "outputs.gui_overflow" in text
                    failures += [f"{path.name} {job_id} {key}: {alternative}" for alternative in overflow_preempted(text)]
        self.assertEqual(failures, [], "a GUI job takes the Blacksmith size its placement names (gui_overflow); a fixed "
                                       "Blacksmith leg may come only after it, as the last resort, or for a fork")
        self.assertGreaterEqual(seen, 6, "cmux-next's swift-test, daemon-test and generated-files read gui_overflow")

    def test_the_overflow_rule_catches_what_it_is_for(self) -> None:
        overflow = "needs.p.outputs.gui_overflow != '' && needs.p.outputs.gui_overflow"
        fork = "github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-6vcpu-macos-26'"
        small = "'blacksmith-6vcpu-macos-26'"
        self.assertEqual(overflow_preempted(f"${{{{ {fork} || needs.p.outputs.gui_runner || {overflow} || {small} }}}}"), [])
        # Run 41123927916's two legs, at the top level or inside a group.
        self.assertTrue(overflow_preempted(f"${{{{ (needs.p.outputs.runner != '' && {small}) || {overflow} || {small} }}}}"))
        self.assertTrue(overflow_preempted(f"${{{{ a || ({fork} || github.run_attempt != 1 && {small} || {overflow}) }}}}"))
        self.assertTrue(overflow_preempted(f"${{{{ x && 'blacksmith-12vcpu-macos-26' || {overflow} || {small} }}}}"))
        # No gui_overflow read: another rule's business.
        self.assertEqual(overflow_preempted(f"${{{{ a && {small} || 'glaeda-side-std-xcode-26.6' }}}}"), [])

    def test_a_session_label_comes_only_from_a_placement_that_judged_it(self) -> None:
        failures, placed = [], 0
        for path in workflows():
            for job_id, job in (load(path).get("jobs") or {}).items():
                text = runs_on_text(job)
                placed += "outputs.session_runner" in text
                failures += [f"{path.name} {job_id}: {why}" for why in session_label_problems(text)]
        self.assertEqual(failures, [], "a session label starts nothing for hours while its runners look online")
        self.assertGreaterEqual(placed, 1, "cmux-next's daemon tests read the placement's session_runner")

    def test_the_session_label_rule_catches_what_it_is_for(self) -> None:
        session = "'glaeda-session-std-xcode-26.6'"
        gui = "'glaeda-gui-std-xcode-26.6'"
        # cmux#24295's route: the literal session label behind a variable switch, gated and with a Blacksmith end.
        self.assertTrue(session_label_problems(
            f"${{{{ github.run_attempt == 1 && (vars.CI_SESSION_LABEL == '1' && {session} || {gui}) "
            "|| 'blacksmith-6vcpu-macos-26' }}"))
        self.assertTrue(session_label_problems(f"${{{{ {session} }}}}"))
        self.assertTrue(session_label_problems("glaeda-session-light-xcode-26.6".join("''")))
        # A session variable taken without the placement's verdict, or behind another `||` branch.
        self.assertTrue(session_label_problems(
            "${{ vars.CI_SESSION_LANE_RUNNER != '' && vars.CI_SESSION_LANE_RUNNER || 'blacksmith-6vcpu-macos-26' }}"))
        self.assertTrue(session_label_problems(
            "${{ a && (needs.p.outputs.session_lane_runner != '' || b) && vars.CI_SESSION_LANE_RUNNER || 'x' }}"))
        self.assertEqual(session_label_problems(
            "${{ needs.p.outputs.session_lane_runner != '' && (b || vars.CI_SESSION_LANE_RUNNER) || 'x' }}"), [])
        # The placement's outputs, and the variable under the placement's verdict, pass.
        self.assertEqual(session_label_problems(
            "${{ needs.p.outputs.free_session_runner || needs.p.outputs.session_runner || needs.p.outputs.gui_runner "
            f"|| github.run_attempt == 1 && {gui} || 'blacksmith-6vcpu-macos-26' }}}}"), [])
        self.assertEqual(session_label_problems(
            "${{ vars.CI_SESSION_LANE_RUNNER != '' && needs.p.outputs.session_lane_runner != '' && "
            "(github.run_attempt == 1 || x) && vars.CI_SESSION_LANE_RUNNER || 'blacksmith-6vcpu-macos-26' }}"), [])

    def test_separate_pr_cascade_does_not_preempt_push_gui_overflow(self) -> None:
        jobs = load(WORKFLOWS / "cmux-next.yml")["jobs"]
        route = runs_on_text(jobs["swift-test"])
        self.assertEqual(overflow_preempted(route), [])
        # Losing the allocation or its attempt freshness must not create an exemption.
        self.assertTrue(overflow_preempted(route.replace("outputs.owned_jobs", "outputs.missing_jobs")))
        self.assertTrue(overflow_preempted(route.replace("outputs.placed_attempt", "outputs.stale_attempt")))
        for prefix in ("github.event_name == 'pull_request' && ", ""):
            self.assertTrue(overflow_preempted(
                "${{ " + prefix + "'blacksmith-6vcpu-macos-26' || needs.p.outputs.gui_overflow }}"))

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
        # The large-Mac rule: a literal last resort fails; a picker's answer, or a 6 vCPU last resort, passes.
        owner = "github.repository_owner != 'manaflow-ai' && 'macos-26' || "
        self.assertTrue(lands_on_large_mac({"runs-on": "blacksmith-12vcpu-macos-26"}))
        self.assertTrue(lands_on_large_mac({"runs-on": "${{ " + owner + "needs.p.outputs.runner || "
                                                       "'blacksmith-12vcpu-macos-26' }}"}))
        self.assertTrue(lands_on_large_mac({"runs-on": "${{ " + owner + "vars.X || 'blacksmith-12vcpu-macos-26' }}"}))
        self.assertTrue(lands_on_large_mac({"runs-on": "${{ matrix.pool }}",
                                            "strategy": {"matrix": {"pool": ["blacksmith-12vcpu-macos-26"]}}}))
        self.assertFalse(lands_on_large_mac({"runs-on": "${{ " + owner + "needs.p.outputs.runner || "
                                                        "'blacksmith-6vcpu-macos-26' }}"}))
        # A literal hidden in a function the resolver cannot read fails closed; a matrix key runs-on never reads
        # does not count.
        self.assertTrue(lands_on_large_mac({"runs-on": "${{ " + owner + "fromJSON(needs.p.outputs.runs_on || "
                                                       "'[\"blacksmith-12vcpu-macos-26\"]') }}"}))
        self.assertFalse(lands_on_large_mac({"runs-on": "${{ matrix.pool }}", "strategy": {"matrix": {
            "pool": ["blacksmith-6vcpu-macos-26"], "note": ["blacksmith-12vcpu-macos-26"]}}}))
        self.assertTrue(lands_on_large_mac({"runs-on": "${{ matrix.pool }}", "strategy": {"matrix": {
            "include": [{"pool": "blacksmith-6vcpu-macos-26"}, {"pool": "blacksmith-12vcpu-macos-26"}]}}}))
        self.assertFalse(lands_on_large_mac({"runs-on": "${{ matrix.pool }}", "strategy": {"matrix": {
            "include": [{"pool": "blacksmith-6vcpu-macos-26", "note": "blacksmith-12vcpu-macos-26"}]}}}))
        self.assertFalse(lands_on_large_mac({"runs-on": "${{ " + owner + "needs.p.outputs.large == 'true' && "
                                                        "'blacksmith-12vcpu-macos-26' || 'blacksmith-6vcpu-macos-26' }}"}))


if __name__ == "__main__":
    unittest.main()
