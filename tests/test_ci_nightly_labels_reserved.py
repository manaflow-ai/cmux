#!/usr/bin/env python3
"""No pull request or merge-queue job can take the nightly's reserved Linux labels.

Leo asked for "ci for linux/related improvements and consolidation (nightlies
publishing is a consequence)" and, earlier, "why isn't nightly getting priority
then? on the linux things". The fix gave nightly and release work two reserved
Linux labels: cmux-gcp-nightly-x64, and cmux-gcp-nightly-jit-x64, which only
one-job VMs that are kept warm serve. The reservation holds only while no job a
pull request or the merge queue starts can route to them.

This guard evaluates, for every workflow those events reach, each job's
`runs-on` (every matrix cell), every `with:` value and every `env:` value that
names a reserved label, under pull_request, pull_request_target and
merge_group, for the upstream owner and a fork, attempts 1-3 and several refs,
with the repository's variables as tests/test_ci_tui_routes_avoid_nightly_label.py
records them. None may come out as a reserved label.

- A workflow with no PR or merge-queue trigger that is not reusable is outside
  the rule (app-ffi-release.yml, cmux-tui-artifacts.yml, ... use the labels on
  push and dispatch).
- A reusable workflow runs under its caller's event. It is walked from each
  PR-triggered caller with the inputs that caller passes, and github.workflow_ref
  naming that caller; one no PR-triggered workflow calls today is evaluated with
  its input defaults under stand-in PR callers, since a PR caller can be added
  any time.
- A runner read from `needs.X.outputs.Y` evaluates to '' here, which could hide
  a leak, so the producing job (its steps, the scripts they run, a reusable
  workflow it calls) must not name a reserved label.
"""
from __future__ import annotations

import functools
import itertools
import re
import sys
from pathlib import Path
from typing import Any, Iterator, Mapping

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from test_ci_fork_runner_routing import parse_expression  # noqa: E402
from test_ci_tui_routes_avoid_nightly_label import LIVE_VARS, _value, route  # noqa: E402
import workflow_jobs  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
RESERVED = ("cmux-gcp-nightly-x64", "cmux-gcp-nightly-jit-x64")
PR_EVENTS = ("pull_request", "pull_request_target", "merge_group")
UPSTREAM = "manaflow-ai"
FORK = "someone-else"
# (repository_owner, the pull request head's repository): an upstream branch, a
# fork's pull request into upstream, and the fork's own repository.
OWNERS = (
    (UPSTREAM, f"{UPSTREAM}/cmux"),
    (UPSTREAM, f"{FORK}/cmux"),
    (FORK, f"{FORK}/cmux"),
)
REFS = (
    "refs/pull/1/merge",
    "refs/heads/feat-cmux-next",
    "refs/heads/main",
    # pull_request_target runs on the base branch's ref: a pull request into nightly-next.
    "refs/heads/nightly-next",
    "refs/heads/gh-readonly-queue/feat-cmux-next/pr-1-0123456789abcdef",
)
ATTEMPTS = (1, 2, 3)
# A reusable workflow no PR-triggered workflow calls is evaluated as if these called it.
STAND_IN_CALLERS = ("cmux-next.yml", "ci.yml")
LOCAL_CALL = re.compile(r"^\./\.github/workflows/([A-Za-z0-9_.-]+\.ya?ml)$")
NEEDS_OUTPUT = re.compile(r"needs\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)")
REPO_FILE = re.compile(r"(?<![A-Za-z0-9_./-])((?:scripts|\.github|tests)/[A-Za-z0-9_./-]+\.(?:py|sh|js|mjs|ts|json|ya?ml))")

# Producing jobs whose text names a reserved label but provably never hands it to a
# PR job. Each entry needs a reason; none is needed today.
PRODUCER_EXEMPTIONS: dict[tuple[str, str], str] = {}
# Files a PR workflow's producing job only names as text, never runs or reads, though they name a reserved label.
# (PR workflow, file) -> why. Only the file is exempt: the producer's own text and every other file it names are
# still checked.
NAMED_FILE_EXEMPTIONS: dict[tuple[str, str], str] = {
    # nightly.yml's hosted tail jobs take cmux-gcp-nightly-jit-x64 on attempt 1 (Leo, 2026-11-19, ask-b3e8183722:
    # "why isn't nightly getting priority then? on the linux things"; test_nightly_trusted_routing.JIT_ARM_JOBS).
    # ci.yml's `changes` names the file only as a changed-path case pattern that sets remote_daemon=true; no step
    # runs or reads it, and nightly.yml has no PR or merge-queue trigger.
    ("ci.yml", ".github/workflows/nightly.yml"): "a changed-path pattern in `changes`; nothing runs or reads it",
}


@functools.lru_cache(maxsize=None)
def _document(name: str) -> dict:
    return workflow_jobs.document(WORKFLOWS / name)


@functools.lru_cache(maxsize=None)
def _text(path: str) -> str:
    try:
        return (ROOT / path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""


def _workflow_names() -> list[str]:
    return sorted(p.name for p in WORKFLOWS.iterdir() if p.suffix in (".yml", ".yaml"))


def triggers(document: Mapping) -> set[str]:
    # PyYAML's safe loader reads the `on:` key as True.
    on = document.get("on", document.get(True))
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return {str(item) for item in on}
    return {str(key) for key in on} if isinstance(on, Mapping) else set()


def pr_triggers(document: Mapping) -> set[str]:
    return triggers(document) & set(PR_EVENTS)


def reusable(document: Mapping) -> bool:
    return "workflow_call" in triggers(document)


def in_rule(document: Mapping) -> bool:
    return bool(pr_triggers(document)) or reusable(document)


def _input_defaults(document: Mapping) -> dict[str, Any]:
    on = document.get("on", document.get(True))
    if not isinstance(on, Mapping):
        return {}
    defaults: dict[str, Any] = {}
    for trigger in ("workflow_call", "workflow_dispatch"):
        spec = on.get(trigger)
        inputs = spec.get("inputs") if isinstance(spec, Mapping) else None
        for name, declared in (inputs or {}).items():
            if isinstance(declared, Mapping) and "default" in declared:
                defaults.setdefault(str(name), declared["default"])
    return defaults


@functools.lru_cache(maxsize=None)
def _parsed(expression: str) -> tuple:
    return parse_expression(expression)


class Unevaluable(Exception):
    """An expression the shared evaluator cannot read (format(), toJSON(), ...)."""


def evaluate(text: Any, context: Mapping) -> Any:
    """`text` as Actions renders it: a lone `${{ }}` keeps its value's type, anything else becomes a string."""
    if not isinstance(text, str):
        return text
    spans = workflow_jobs.expression_spans(text)
    if not spans:
        return text
    try:
        if spans == [(0, len(text.strip()))] and text == text.strip():
            return _value(_parsed(text[3:-2]), context)
        out, last = [], 0
        for start, end in spans:
            value = _value(_parsed(text[start + 3:end - 2]), context)
            out += [text[last:start], "" if value is None else str(value)]
            last = end
        return "".join(out) + text[last:]
    except Exception as error:  # an unsupported node or call, or a parse the shared parser refuses
        raise Unevaluable(f"{text!r}: {error}") from error


def _labels(value: Any) -> Iterator[str]:
    if isinstance(value, Mapping):
        for item in value.values():
            yield from _labels(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from _labels(item)
    elif value is not None:
        for label in str(value).split(","):
            yield label.strip().strip("'\"").lower()


def reserved_in(value: Any) -> str | None:
    """The reserved label a rendered runner asks for, if any."""
    return next((label for label in _labels(value) if label in RESERVED), None)


def names_reserved(text: str) -> bool:
    lowered = text.lower()
    return any(label in lowered for label in RESERVED)


def contexts(caller: str, events: set[str]) -> Iterator[dict]:
    """Every github context a PR or merge-queue run of `caller` sees, with the live variables."""
    for (owner, head), event, ref, attempt, owned in itertools.product(
            OWNERS, sorted(events), REFS, ATTEMPTS, ("1", "")):
        repository = f"{owner}/cmux"
        context: dict[str, Any] = {
            "github.repository_owner": owner,
            "github.repository": repository,
            "github.event_name": event,
            "github.ref": ref,
            "github.ref_name": ref.rsplit("/", 1)[-1],
            "github.run_attempt": attempt,
            "github.workflow_ref": f"{repository}/.github/workflows/{caller}@{ref}",
            "github.head_ref": "lane/some-change",
            "github.base_ref": "feat-cmux-next",
            "github.event.pull_request.head.repo.full_name": head,
            "github.event.pull_request.head.repo.fork": head != repository,
            "github.event.pull_request.base.ref": "feat-cmux-next",
            "github.event.pull_request.number": 1,
        }
        for name, value in {**LIVE_VARS, "CI_PR_POOL_OWNED": owned}.items():
            context[f"vars.{name}"] = value
        yield context


def _with_inputs(context: Mapping, inputs: Mapping[str, Any]) -> dict:
    scoped = {key: value for key, value in context.items() if not key.startswith("inputs.")}
    scoped.update({f"inputs.{name}": value for name, value in inputs.items()})
    return scoped


def _strings(value: Any, path: str) -> Iterator[tuple[str, str]]:
    if isinstance(value, Mapping):
        for key, item in value.items():
            yield from _strings(item, f"{path}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from _strings(item, f"{path}[{index}]")
    elif isinstance(value, str):
        yield path, value


def _named_values(document: Mapping, job_name: str, job: Mapping) -> Iterator[tuple[str, str]]:
    """Every `with:` and `env:` value in a job (and the workflow's env) that names a reserved label.
    A value that names none can only produce one through a variable (LIVE_VARS holds none), an
    input (each caller's `with:` is checked here too) or an output (the producer check)."""
    sources = [(f"env", document.get("env")), (f"jobs.{job_name}.env", job.get("env")),
               (f"jobs.{job_name}.with", job.get("with"))]
    for index, step in enumerate(job.get("steps") or []):
        if isinstance(step, Mapping):
            sources += [(f"jobs.{job_name}.steps[{index}].env", step.get("env")),
                        (f"jobs.{job_name}.steps[{index}].with", step.get("with"))]
    for path, value in sources:
        for where, text in _strings(value, path):
            if names_reserved(text):
                yield where, text


def _runs_on_cells(job: Mapping) -> list[tuple[str, ...]]:
    cells = workflow_jobs.runs_on_label_cells(job)
    if cells is None:
        # A matrix nothing resolves: its `matrix.*` reads are '' here. _matrix_findings checks that the
        # matrix itself names no reserved label, and _producer_findings that an output it reads is clean.
        items = [item for item in workflow_jobs.runs_on_items(job) if isinstance(item, str)]
        cells = [tuple(items)] if items else []
    return cells


_DUMPS: dict[tuple[int, str], tuple[str, str]] = {}


def _producer_files(document: Mapping, producer: str, seen: set[str]) -> Iterator[tuple[str, str]]:
    """(where, text) of everything that can write `needs.<producer>.outputs.*`."""
    if producer in seen:
        return
    seen.add(producer)
    job = (document.get("jobs") or {}).get(producer)
    if not isinstance(job, Mapping):
        return
    key = (id(document), producer)
    if key not in _DUMPS:
        # Its runs-on and the `env:`/`with:` values that name a reserved label are evaluated under every PR
        # context by leaks_in, so an output built from them is already judged; the rest of its text (steps'
        # scripts, outputs, the files it runs) is what could print a label nothing evaluates.
        _DUMPS[key] = (yaml.safe_dump(dict(job), sort_keys=False),
                       yaml.safe_dump(_blank_evaluated(job), sort_keys=False))
    text, judged = _DUMPS[key]
    yield f"jobs.{producer}", judged
    files = set(REPO_FILE.findall(text))
    called = LOCAL_CALL.match(str(job.get("uses", "")))
    if called:
        files.add(f".github/workflows/{called.group(1)}")
        files.update(REPO_FILE.findall(_text(f".github/workflows/{called.group(1)}")))
    for path in sorted(files):
        yield path, _text(path)
    for upstream, _ in NEEDS_OUTPUT.findall(text):
        yield from _producer_files(document, upstream, seen)


def _blank_evaluated(job: Mapping) -> dict:
    """The job with its runs-on and each `env:`/`with:` value that names a reserved label (job and step level)
    blanked: leaks_in evaluates those under every PR context."""
    def blank(section: Any) -> Any:
        if not isinstance(section, Mapping):
            return section
        return {key: "<evaluated>" if isinstance(value, str) and names_reserved(value) else value
                for key, value in section.items()}

    out = {key: blank(value) if key in ("env", "with") else value for key, value in job.items()}
    if isinstance(out.get("runs-on"), str) and names_reserved(out["runs-on"]):
        out["runs-on"] = "<evaluated>"  # the job's own runner is a runs-on leaks_in evaluates
    out["steps"] = [{key: blank(value) if key in ("env", "with") else value for key, value in step.items()}
                    if isinstance(step, Mapping) else step for step in job.get("steps") or []]
    return out


def _producer_findings(workflow: str, document: Mapping, job_name: str, text: str) -> list[str]:
    findings = []
    for producer, output in sorted(set(NEEDS_OUTPUT.findall(text))):
        if (workflow, producer) in PRODUCER_EXEMPTIONS:
            continue
        for where, body in _producer_files(document, producer, set()):
            if (workflow, where) in NAMED_FILE_EXEMPTIONS:
                continue
            if names_reserved(body):
                findings.append(f"{workflow} jobs.{job_name} reads needs.{producer}.outputs.{output}, "
                                f"and {where} names a reserved label")
    return findings


def _matrix_findings(workflow: str, job_name: str, job: Mapping) -> list[str]:
    """A matrix nothing resolves leaves `matrix.*` runners as '' in leaks_in, so it may not name a reserved label."""
    if workflow_jobs.runs_on_label_cells(job) is not None:
        return []
    matrix = yaml.safe_dump((job.get("strategy") or {}).get("matrix"))
    return [f"{workflow} jobs.{job_name}: its runs-on reads a matrix nothing resolves, and the matrix names a "
            f"reserved label"] if names_reserved(matrix) else []


def _output_reads(job_name: str, job: Mapping) -> str:
    """The text of a job's runner sources an output could fill: runs-on, matrix and a reusable call's `with:`."""
    parts = [workflow_jobs.runs_on(job), yaml.safe_dump((job.get("strategy") or {}).get("matrix"))]
    if job.get("uses"):
        parts.append(yaml.safe_dump(job.get("with")))
    return "\n".join(parts)


_PLANS: dict[str, list] = {}


def _plan(workflow: str) -> list[tuple[str, Mapping, list, list, str | None]]:
    """Per job, what leaks_in evaluates: (name, job, runs-on cells, reserved-naming env/with values, called file)."""
    if workflow not in _PLANS:
        document = _document(workflow)
        plan = []
        for job_name, job in workflow_jobs.jobs(document).items():
            called = LOCAL_CALL.match(str(job.get("uses", "")))
            plan.append((job_name, job, _runs_on_cells(job), list(_named_values(document, job_name, job)),
                         called.group(1) if called else None))
        _PLANS[workflow] = plan
    return _PLANS[workflow]


def leaks_in(workflow: str, context: Mapping, inputs: Mapping[str, Any], stack: tuple[str, ...] = ()) -> list[str]:
    """Every reserved label `workflow` routes a job to under `context`, its reusable calls walked with the inputs
    they pass. Unevaluable runners are findings too unless they name no reserved label."""
    document = _document(workflow)
    context = _with_inputs(context, {**_input_defaults(document), **inputs})
    where_run = (context["github.repository_owner"], context["github.event.pull_request.head.repo.full_name"],
                 context["github.event_name"], context["github.ref"], context["github.run_attempt"],
                 context["github.workflow_ref"])
    via = " <- ".join((workflow, *stack))
    findings = []
    for job_name, job, cells, named, called in _plan(workflow):
        for cell in cells:
            for label in cell:
                try:
                    found = reserved_in(evaluate(label, context))
                except Unevaluable as error:
                    found = next((name for name in RESERVED if name in label.lower()), None)
                    if found is None:
                        continue  # it names no reserved label; outputs are the producer check's
                    found = f"{found} (unevaluable: {error})"
                if found:
                    findings.append(f"{via} jobs.{job_name}.runs-on -> {found} {where_run}")
        for where, text in named:
            try:
                found = reserved_in(evaluate(text, context))
            except Unevaluable as error:
                found = f"a reserved label (unevaluable: {error})"
            if found:
                findings.append(f"{via} {where} -> {found} {where_run}")
        if called and called not in stack and called != workflow:
            passed: dict[str, Any] = {}
            for name, value in (job.get("with") or {}).items():
                try:
                    passed[str(name)] = evaluate(value, context)
                except Unevaluable:
                    passed[str(name)] = ""  # names no reserved label, or _named_values flagged it above
            findings += leaks_in(called, context, passed, (workflow, *stack))
    return findings


def _reusable_callers() -> dict[str, list[str]]:
    """Each reusable workflow and the PR-triggered workflows whose runs reach it (through any depth of calls)."""
    roots: dict[str, set[str]] = {}

    def walk(root: str, workflow: str, seen: frozenset[str]) -> None:
        for job in (_document(workflow).get("jobs") or {}).values():
            called = LOCAL_CALL.match(str(job.get("uses", ""))) if isinstance(job, Mapping) else None
            if called and called.group(1) not in seen and (WORKFLOWS / called.group(1)).exists():
                roots.setdefault(called.group(1), set()).add(root)
                walk(root, called.group(1), seen | {called.group(1)})

    for name in _workflow_names():
        if pr_triggers(_document(name)):
            walk(name, name, frozenset({name}))
    return {name: sorted(callers) for name, callers in roots.items()}


def all_leaks() -> list[str]:
    findings: list[str] = []
    reached = _reusable_callers()
    for name in _workflow_names():
        document = _document(name)
        events = pr_triggers(document)
        if events:
            for context in contexts(name, events):
                findings += leaks_in(name, context, {})
        elif reusable(document) and not reached.get(name):
            # No PR-triggered workflow calls it today; a caller added tomorrow would run it on PR events.
            for caller in STAND_IN_CALLERS:
                for context in contexts(caller, set(PR_EVENTS)):
                    findings += leaks_in(name, context, {})
        if in_rule(document):
            for job_name, job in workflow_jobs.jobs(document).items():
                findings += _producer_findings(name, document, job_name, _output_reads(job_name, job))
                findings += _matrix_findings(name, job_name, job)
    return list(dict.fromkeys(findings))


def test_no_pr_or_merge_queue_job_routes_to_a_reserved_label() -> None:
    findings = all_leaks()
    assert not findings, "a PR or merge-queue job can take a reserved nightly label:\n  " + "\n  ".join(findings[:40])


def test_the_rule_covers_the_workflows_it_should() -> None:
    names = set(_workflow_names())
    # Push- and dispatch-only workflows may use the labels freely.
    for free in ("app-ffi-release.yml", "cmux-tui-artifacts.yml", "cmux-tui-tree-request.yml", "app-ffi-repin.yml"):
        assert free in names, free
        assert not in_rule(_document(free)), f"{free} has a PR or merge-queue trigger or is reusable now"
    # These are PR-triggered or reusable: inside the rule.
    for ruled in ("cmux-next.yml", "ci.yml", "cmux-tui-build-package.yml"):
        assert in_rule(_document(ruled)), ruled
    assert reusable(_document("cmux-tui-build-package.yml"))
    assert "merge_group" in pr_triggers(_document("ci.yml"))
    # The labels really are in use off the rule, so the rule is not vacuous about them.
    assert any(names_reserved((WORKFLOWS / free).read_text(encoding="utf-8")) for free in
               ("app-ffi-release.yml", "cmux-tui-artifacts.yml", "cmux-tui-tree-request.yml", "app-ffi-repin.yml"))
    # No repository variable the routes read holds a reserved label (a variable read evaluates to its live value).
    assert not any(names_reserved(str(value)) for value in LIVE_VARS.values())


def test_reusable_build_package_stays_off_the_labels_under_a_pr_caller() -> None:
    # The reusable build names cmux-gcp-nightly-x64 for cmux-tui-artifacts.yml's dispatch and nightly-next runs.
    # Called from a PR workflow it must not.
    assert names_reserved((WORKFLOWS / "cmux-tui-build-package.yml").read_text(encoding="utf-8"))
    for caller in STAND_IN_CALLERS:
        for context in contexts(caller, set(PR_EVENTS)):
            assert not leaks_in("cmux-tui-build-package.yml", context, {}), (caller, context["github.ref"])
    # The same expression does pick the label for its real, push-only caller: the evaluator is not blind to it.
    context = next(contexts("cmux-tui-artifacts.yml", {"pull_request"}))
    context.update({"github.event_name": "workflow_dispatch", "github.ref": "refs/heads/nightly-next",
                    "github.workflow_ref": f"{UPSTREAM}/cmux/.github/workflows/cmux-tui-artifacts.yml@refs/heads/nightly-next"})
    assert leaks_in("cmux-tui-build-package.yml", context, {}), "the dispatch route no longer reads as the nightly label"


def test_cmux_next_jit_arm_is_push_only() -> None:
    # cmux-next.yml names cmux-gcp-nightly-jit-x64 (when a sibling change has landed) only behind
    # github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' && github.run_attempt == 1.
    document = _document("cmux-next.yml")
    assert pr_triggers(document) == {"pull_request"}
    for context in contexts("cmux-next.yml", set(PR_EVENTS)):
        assert not leaks_in("cmux-next.yml", context, {})


def test_the_guard_catches_a_leak() -> None:
    leak = "${{ github.run_attempt == 1 && 'cmux-gcp-nightly-x64' || 'ubuntu-24.04' }}"
    context = next(c for c in contexts("cmux-next.yml", {"pull_request"}) if c["github.run_attempt"] == 1)
    assert reserved_in(evaluate(leak, context)) == "cmux-gcp-nightly-x64"
    assert route(leak, context) == "cmux-gcp-nightly-x64"
    on_retry = dict(context, **{"github.run_attempt": 2})
    assert reserved_in(evaluate(leak, on_retry)) is None
    # A whole synthetic workflow: the leak shows up as a finding from the same walk the real workflows take.
    synthetic = yaml.safe_dump({
        "on": {"pull_request": {}},
        "jobs": {"build": {"runs-on": leak, "steps": [{"run": "true"}]},
                 "list": {"runs-on": ["self-hosted", "cmux-gcp-nightly-jit-x64"], "steps": [{"run": "true"}]},
                 "call": {"uses": "./.github/workflows/cmux-tui-build-package.yml",
                          "with": {"linux_runner": "cmux-gcp-nightly-x64"}}},
    })
    name = "__synthetic_leak__.yml"
    original = _document

    def fake(workflow: str) -> dict:
        return workflow_jobs.document(synthetic) if workflow == name else original(workflow)

    findings = []
    for context in contexts(name, {"pull_request"}):
        findings += _leaks_with(fake, name, context)
    assert any("jobs.build.runs-on -> cmux-gcp-nightly-x64" in f for f in findings), findings[:5]
    assert any("jobs.list.runs-on -> cmux-gcp-nightly-jit-x64" in f for f in findings), findings[:5]
    assert any("jobs.call.with.linux_runner -> cmux-gcp-nightly-x64" in f for f in findings), findings[:5]
    # The input reaches the reusable build's runs-on (`inputs.linux_runner != '' && ... && inputs.linux_runner`).
    assert any("cmux-tui-build-package.yml <- " + name in f for f in findings), findings[:5]
    # A needs output whose producer prints the label is caught although the runner reads as ''.
    producer = workflow_jobs.document(yaml.safe_dump({
        "on": {"pull_request": {}},
        "jobs": {"pick": {"runs-on": "ubuntu-24.04", "outputs": {"runner": "${{ steps.p.outputs.runner }}"},
                          "steps": [{"id": "p", "run": "echo runner=cmux-gcp-nightly-x64 >> \"$GITHUB_OUTPUT\""}]},
                 "use": {"needs": "pick", "runs-on": "${{ needs.pick.outputs.runner }}", "steps": [{"run": "true"}]}},
    }))
    assert _producer_findings(name, producer, "use", _output_reads("use", producer["jobs"]["use"]))


def _leaks_with(document_reader, name: str, context: Mapping) -> list[str]:
    """leaks_in with `document_reader` standing in for the workflow loader (the self-check's synthetic file)."""
    global _document
    saved = _document
    _document = document_reader
    _PLANS.clear()
    try:
        return leaks_in(name, context, {})
    finally:
        _document = saved
        _PLANS.clear()


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
