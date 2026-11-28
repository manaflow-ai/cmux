"""ci-oops core: classify one red CI job as a kernel "oops" (log it, mark it, keep going, fix it afterwards) or a panic.

Leo, 2026-11-19: "Can we do things where it's like, like the CI doesn't necessarily have to fail and like give up. It
can just be like, okay, you got to fix this afterwards or whatever, just as if it were like a follow-up". So a red job
is classified here, and its class's actor (oops.py act, act_<class>.py) swallows it: infra is retried on a fresh
runner, mechanical is fixed by its fixer, real is handed to an agent, soft (a check nothing requires) is reported and
never holds anything. Only a panic (panic.json: base does not compile, data loss, security, signing, release path,
nightly/promote) stays red, as today.

The block between the begin and end lines is pure: stdlib only, no I/O. It is vendored byte for byte into
manaflow-ai/cmux scripts/ci/oops/oops_core.py and manaflow-ai/leo-workspace tools/ci_oops_core.py by vendor.py, and
each copy's test pins fingerprint() of its block to FINGERPRINT (the ci_log_rule pattern). Change it here, run
`python3 tools/ci-oops/vendor.py --fingerprint` to print the new FINGERPRINT, update it, then vendor.py into each repo.

ctx (what a caller passes; every key optional): repo, workflow, job, run_id, run_attempt, head_sha, head_ref, base_ref,
pr (number or None), pr_author, own_branch (lane/* and an agent author), required (bool), flaky (bool: tap_flakes
knows the failing test as flaky), changed_files, log_tail (the job log's last ~400 lines, str or list), steps (the job's
steps from the jobs API: [{"name", "conclusion", "number"}]).

A rule (rules/<class>.json, a list): {"id": "infra.oom", "class": "infra", "any": [regex, ...], "job": regex,
"workflow": regex, "repo": regex, "base_ref": regex, "head_ref": regex, "when": [predicate, ...], "none": [regex, ...],
"fixer": id, "retries": n, "min": n, "why": line}. It matches when every filter given matches (job/workflow/repo/base_ref/head_ref are
re.search on that ctx value, case-insensitive), every `when` predicate (WHEN) holds, one `any` regex is found in the log
(a rule with no `any` needs none), and no `none` regex is. Regexes are re.search, case-insensitive, per log line.

Verdict: {"class", "rule", "fixer", "evidence", "swallow", "why"}. Precedence: panic > infra > mechanical > soft > real.
A panic match is never swallowed, whatever else matches. Soft is decided from ctx (required false, or flaky), not
regexes; real is the fallthrough for a red on our own PR (own_branch); anything else is unknown, and stays red.
"""
from __future__ import annotations

import hashlib
import json
import re

# ---- ci-oops core (begin) ----
CI_OOPS_VERSION = 1
CLASSES = ("panic", "infra", "mechanical", "soft", "real", "unknown")
PRECEDENCE = ("panic", "infra", "mechanical")  # regex classes, strongest first; soft and real come from ctx after them
SWALLOW = {"panic": False, "infra": True, "mechanical": True, "soft": True, "real": True, "unknown": False}
OUTCOMES = ("retried", "fixed", "agent_fixed", "soft_failed", "blocking", "gave_up", "skipped")
LOG_TAIL_LINES = 400
EVIDENCE_MAX = 300
GH_LOG_PREFIX = re.compile(r"^(?:[^\t]*\t[^\t]*\t)?\ufeff?(?:\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\S*\s?)?")
FILTER_KEYS = ("job", "workflow", "repo", "base_ref", "head_ref")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
SCRIPT_ECHO = "\x1b[36;1m"  # the color GitHub echoes a run step's script in


def _steps(ctx: dict) -> list[dict]:
    return [s for s in (ctx.get("steps") or []) if isinstance(s, dict)]


def _no_step_ran(ctx: dict) -> bool:
    """The job failed with no step of the workflow run: its runner died, went away or was never set up."""
    steps = _steps(ctx)
    if not steps:
        return "steps" in ctx  # the jobs API answered with no steps at all: nothing ran
    ran = [s for s in steps if s.get("conclusion") not in (None, "skipped")
           and s.get("name") not in ("Set up job", "Complete job")]
    return not ran


def _setup_failed(ctx: dict) -> bool:
    """GitHub's or the runner's own setup step failed ("Set up job", "Set up runner"): no workflow code ran yet."""
    return any(s.get("conclusion") == "failure" and str(s.get("name", "")).lower() in ("set up job", "set up runner")
               for s in _steps(ctx))


def _cancelled_mid_step(ctx: dict) -> bool:
    """A step was cancelled while the job failed: its runner was stopped under it (shutdown signal, preemption)."""
    return any(s.get("conclusion") == "cancelled" for s in _steps(ctx))


def _own_branch(ctx: dict) -> bool:
    return bool(ctx.get("own_branch"))


def _not_required(ctx: dict) -> bool:
    return ctx.get("required") is False


WHEN = {"no_step_ran": _no_step_ran, "setup_failed": _setup_failed, "cancelled_mid_step": _cancelled_mid_step,
        "own_branch": _own_branch, "not_required": _not_required}


def log_lines(log_tail) -> list[str]:
    """LOG_TAIL as its last LOG_TAIL_LINES messages: `gh run view --log` job/step columns, time stamps and colors
    dropped, and a step's echoed script left out (GitHub prints it in SCRIPT_ECHO under `##[group]Run ...`), so a
    signature a script spells in a branch it never takes does not count (cmux classify_failures.log_sections)."""
    if isinstance(log_tail, (list, tuple)):
        lines = [str(x) for x in log_tail]
    else:
        lines = str(log_tail or "").splitlines()
    out = []
    for line in lines[-LOG_TAIL_LINES:]:
        if SCRIPT_ECHO in line:
            continue
        out.append(ANSI.sub("", GH_LOG_PREFIX.sub("", line, count=1)).rstrip())
    return out


def _compile(pattern: str):
    return re.compile(pattern, re.IGNORECASE)


def rule_matches(rule: dict, ctx: dict, lines: list[str]) -> str | None:
    """The evidence (the matched log line, or the predicate that held) when RULE matches, else None."""
    for key in FILTER_KEYS:
        if rule.get(key) and not _compile(rule[key]).search(str(ctx.get(key) or "")):
            return None
    whens = rule.get("when") or []
    if isinstance(whens, str):
        whens = [whens]
    for name in whens:
        fn = WHEN.get(name)
        if fn is None or not fn(ctx):
            return None
    anys = rule.get("any") or []
    floor = rule.get("min")
    if isinstance(floor, int) and floor > 1 and anys:
        # `min`: the rule's lines are this many or more: a machine fault this loud (a full disk under every test of the
        # job) outweighs `none`, the code failures it caused (run 44508779820: 28 ENOSPC lines, 41 failed tests)
        rxs = [_compile(p) for p in anys]
        hits = [line for line in lines if any(rx.search(line) for rx in rxs)]
        if len(hits) >= floor:
            return hits[-1].strip()[:EVIDENCE_MAX]
    for pattern in rule.get("none") or []:
        rx = _compile(pattern)
        if any(rx.search(line) for line in lines):
            return None
    if not anys:
        return ("when: " + ",".join(whens)) if whens else "filters"
    for pattern in anys:
        rx = _compile(pattern)
        for line in reversed(lines):  # the last occurrence is nearest the failure
            if rx.search(line):
                return line.strip()[:EVIDENCE_MAX]
    return None


def verdict(cls: str, rule: str, evidence: str = "", fixer=None, why: str = "") -> dict:
    return {"class": cls, "rule": rule, "fixer": fixer, "evidence": evidence, "swallow": SWALLOW[cls], "why": why}


def classify(ctx: dict, rules=()) -> dict:
    """The verdict for one red job: CTX (above) against RULES (every rules/*.json list, concatenated)."""
    lines = log_lines(ctx.get("log_tail"))
    by_class: dict[str, list[dict]] = {c: [] for c in PRECEDENCE}
    for rule in rules or ():
        if isinstance(rule, dict) and rule.get("class") in by_class:
            by_class[rule["class"]].append(rule)
    for cls in PRECEDENCE:
        for rule in by_class[cls]:
            evidence = rule_matches(rule, ctx, lines)
            if evidence is not None:
                got = verdict(cls, str(rule.get("id") or cls), evidence, rule.get("fixer"), str(rule.get("why") or ""))
                if isinstance(rule.get("retries"), int):
                    got["retries"] = rule["retries"]  # infra: how many re-runs this rule's red earns (act_retry)
                return got
    if ctx.get("required") is False:
        return verdict("soft", "soft.not_required", "", None, "no branch protection or merge gate requires this check")
    if ctx.get("flaky"):
        return verdict("soft", "soft.flaky", "", None, "its failing test is a known flake (tap_flakes)")
    if ctx.get("own_branch"):
        return verdict("real", "real.own_branch", (lines[-1].strip()[:EVIDENCE_MAX] if lines else ""), None,
                       "a red on our own lane PR: an agent fixes it as a follow-up")
    return verdict("unknown", "unknown", "", None, "no rule matched and it is no lane PR: stays red as today")


def ledger_line(record: dict) -> str:
    """The one log line every verdict and outcome is printed as: CI_OOPS={json}, read with ci_log_rule.ci_last_marked."""
    return "CI_OOPS=" + json.dumps(record, sort_keys=True, separators=(",", ":"))


def validate_rules(rules) -> list[str]:
    """Problems with RULES (empty when sound): a missing id or class, a duplicate id, a bad regex, an unknown key."""
    known = {"id", "class", "any", "none", "when", "fixer", "why", "fixture", "retries", "min", *FILTER_KEYS}
    problems, seen = [], set()
    for i, rule in enumerate(rules or ()):
        if not isinstance(rule, dict):
            problems.append(f"rule {i}: not an object")
            continue
        rid = rule.get("id")
        if not rid:
            problems.append(f"rule {i}: no id")
        elif rid in seen:
            problems.append(f"rule {rid}: duplicate id")
        seen.add(rid)
        if rule.get("class") not in CLASSES[:-1]:
            problems.append(f"rule {rid}: class {rule.get('class')!r} is none of {CLASSES[:-1]}")
        for key in set(rule) - known:
            problems.append(f"rule {rid}: unknown key {key!r}")
        for pattern in [*(rule.get("any") or []), *(rule.get("none") or []), *[rule[k] for k in FILTER_KEYS if rule.get(k)]]:
            try:
                _compile(pattern)
            except re.error as e:
                problems.append(f"rule {rid}: bad regex {pattern!r}: {e}")
        whens = rule.get("when") or []
        for name in ([whens] if isinstance(whens, str) else whens):
            if name not in WHEN:
                problems.append(f"rule {rid}: unknown when {name!r}")
    return problems
# ---- ci-oops core (end) ----

BEGIN = "# ---- ci-oops core (begin) ----"
END = "# ---- ci-oops core (end) ----"
FINGERPRINT = "aa3143b4f8bd4ee96a49fa442b9feee704bb851d019a6bbdc8cf6fe2e3632b65"


def fingerprint(source: str) -> str:
    """sha256 of the vendored block in SOURCE (this file's text, or a vendored copy's)."""
    block = source.split(BEGIN, 1)[1].split(END, 1)[0]
    return hashlib.sha256(block.encode()).hexdigest()
