#!/usr/bin/env python3
"""A required check must be bounded, and a superseded PR run must be cancelled.

Two properties, both of which CI is structurally unable to complain about
because neither one makes anything fail.

A job with no `timeout-minutes` inherits GitHub's six-hour default. Every job
in `ci.yml` declares one between 5 and 20 minutes except `ci-status`, which is
the required aggregate: the check every pull request in the repository is
blocked on. A hang there blocks the whole repository for six hours and reads
as "still running" the entire time.

A `pull_request` workflow with no concurrency group starts a fresh run per
push and lets the superseded ones finish. `ci.yml` and most of its neighbours
already cancel; five path-filtered workflows had no group at all.

A bare `bun install` (or `bun i`) in any workflow step waits forever on a
registry connection that stops answering: bun has no idle limit of its own,
so the job sits silent until its timeout cancels it (2026-11-09, hosted Linux
runners). Every workflow installs through scripts/ci/bun-install.sh, which
gives bun an idle limit and retries, bounds each attempt, and ends a stall
with a named "bun install stalled" error.

Both rules stay derived rather than listed. The required contexts come from
the repository ruleset and are matched to jobs by name, and a context that
stops matching any job fails this test rather than quietly guarding nothing.
"""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

import yaml

from test_web_complexity_trusted_workflow import REQUIRED_CHECK, validate_metadata_routing


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"

# The required contexts on main, from the one in-tree mirror of the ruleset.
# scripts/ci/required_status_checks.py reconciles that mirror against GitHub.
_SPEC = importlib.util.spec_from_file_location(
    "required_status_checks", ROOT / "scripts/ci/required_status_checks.py"
)
_required_status_checks = importlib.util.module_from_spec(_SPEC)
assert _SPEC.loader is not None
# Registered before execution: the module defines a dataclass.
sys.modules["required_status_checks"] = _required_status_checks
_SPEC.loader.exec_module(_required_status_checks)
# A hung job wastes runners whether or not its check is required.
ALWAYS_BOUNDED = ("ci-status", "web-validation", "Web complexity")
# pull_request workflows that end a superseded run themselves instead of with a
# concurrency group, and why a group would be wrong there.
OWN_SUPERSESSION = {
    # Its pull_request and push runs only debounce: each waits for quiet (at
    # most a few minutes) and exits 0 once it sees a newer event's run
    # (next_batch.py `superseded`), within its 15-minute timeout. Cancelling one
    # instead would read as a red run on the pull request.
    "cmux-next-batch.yml": "debounce runs supersede themselves and exit 0",
}
# Every context whose workflows must be bounded. Tests patch this name.
REQUIRED_CONTEXTS = tuple(dict.fromkeys((*_required_status_checks.REQUIRED_CHECKS, *ALWAYS_BOUNDED)))


# `bun install` or `bun i` as a command, not `bun-install.sh` or `bun install` inside a quoted string.
BARE_BUN_INSTALL = re.compile(r"(?<![\w./$-])bun\s+(?:install|i)(?![\w.-])")


def unquoted(line: str) -> str:
    """The line with its quoted text and trailing comment blanked out. A command substitution (`$(...)` or backticks)
    runs even inside double quotes, so its text is kept."""
    out: list[str] = []
    quote = None  # None, "'" or '"'
    depth = 0  # open $( ... ) inside double quotes
    i = 0
    while i < len(line):
        ch = line[i]
        if quote == "'":
            out.append(" ")
            if ch == "'":
                quote = None
        elif quote == '"' and depth == 0:
            if line.startswith("$(", i):
                depth = 1
                out.append("$(")
                i += 2
                continue
            out.append(" ")
            if ch == "\\":
                out.append(" ")
                i += 2
                continue
            if ch == '"':
                quote = None
        elif quote == '"':
            if line.startswith("$(", i):
                depth += 1
            elif ch == ")":
                depth -= 1
            out.append(ch)
        elif ch in "\"'":
            quote = ch
            out.append(" ")
        elif ch == "#" and (not out or out[-1].isspace()):
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def bare_bun_installs(workflow: dict) -> list[str]:
    """Each step command that runs bun install without scripts/ci/bun-install.sh, as job: line."""
    found = []
    for job_id, job in (workflow.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        for step in job.get("steps") or ():
            run = step.get("run") if isinstance(step, dict) else None
            if not isinstance(run, str):
                continue
            # A backslash-newline continues one shell line.
            for line in re.sub(r"\\\n[ \t]*", " ", run).splitlines():
                stripped = line.strip()
                for command in re.split(r"&&|\|\||[;|&()`]", unquoted(stripped)):
                    # `timeout N bun install` is bounded too (a trusted job whose base predates the script).
                    if BARE_BUN_INSTALL.search(command) and not re.match(r"\s*(?:\w+=\S*\s+)*timeout\b", command):
                        found.append(f"{job_id}: {stripped}")
                        break
    return found


def load(path: Path) -> dict:
    parsed = yaml.safe_load(path.read_text(encoding="utf-8"))
    return parsed if isinstance(parsed, dict) else {}


def triggers(workflow: dict) -> set[str]:
    # PyYAML resolves a bare `on:` key to the boolean True.
    on = workflow.get("on", workflow.get(True, {}))
    if isinstance(on, dict):
        return set(on)
    if isinstance(on, str):
        return {on}
    return set(on or ())



def reachable(roots: set[Path], workflows: dict[Path, dict]) -> set[Path]:
    """Required-check workflows plus the local reusable ones they call.

    ci.yml delegates whole areas through `uses: ./.github/workflows/...`.
    Those jobs run under ci.yml's run and gate ci-status exactly like its own
    jobs do, so a bound is worth just as much there. They are easy to miss
    because a reusable workflow has no runs of its own to look at.
    """
    seen: set[Path] = set()
    queue = list(roots)
    while queue:
        path = queue.pop()
        if path in seen or path not in workflows:
            continue
        seen.add(path)
        for job in (workflows[path].get("jobs") or {}).values():
            if not isinstance(job, dict):
                continue
            uses = job.get("uses", "")
            if isinstance(uses, str) and uses.startswith("./.github/workflows/"):
                queue.append(ROOT / uses.removeprefix("./"))
    return seen


def context_of(job_id: str, job: dict, path: Path, workflow: dict) -> str:
    name = job.get("name") or job_id
    if path.name == "web-complexity-trusted.yml" and job_id == "complexity" and "${{" in name:
        # Interpret only the validated routing contract. Unknown expressions
        # must remain unmatched instead of silently dropping timeout coverage.
        try:
            validate_metadata_routing(workflow)
        except (AssertionError, KeyError, TypeError):
            return name
        return REQUIRED_CHECK
    if path.name == "cla-policy-guard.yml" and job_id == "validate":
        from test_cla_guard_metadata_routing import (
            REQUIRED_CHECK as CLA_REQUIRED_CHECK,
            validate_metadata_routing as validate_cla_metadata_routing,
        )
        try:
            validate_cla_metadata_routing(workflow)
        except (AssertionError, KeyError, TypeError) as error:
            if "${{" in str(name) or "if" in job:
                raise ValueError("CLA metadata route violates its condition/name contract") from error
        else:
            return CLA_REQUIRED_CHECK
    return name


def main() -> int:
    workflows = {p: load(p) for p in sorted(WORKFLOWS.glob("*.y*ml"))}
    failures: list[str] = []

    # Which workflows own a required check, by what their jobs are called.
    owners: dict[str, set[Path]] = {}
    for path, workflow in workflows.items():
        for job_id, job in (workflow.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            try:
                context = context_of(job_id, job, path, workflow)
            except ValueError as error:
                failures.append(f"{path.name}:{job_id}: {error}")
                continue
            if context in REQUIRED_CONTEXTS:
                owners.setdefault(context, set()).add(path)

    unmatched = [c for c in REQUIRED_CONTEXTS if c not in owners]
    if unmatched:
        failures.append(
            "required contexts match no job; the ruleset and this list have "
            f"drifted apart: {', '.join(unmatched)}"
        )

    required_workflows = {path for paths in owners.values() for path in paths}
    for path in sorted(reachable(required_workflows, workflows)):
        for job_id, job in (workflows[path].get("jobs") or {}).items():
            if not isinstance(job, dict) or "uses" in job:
                continue
            if "timeout-minutes" not in job:
                failures.append(
                    f"{path.relative_to(ROOT)}:{job_id} has no "
                    "timeout-minutes, so it inherits GitHub's six-hour "
                    "default -- in a workflow that owns a required or always-bounded check"
                )

    for path, workflow in workflows.items():
        if "pull_request" not in triggers(workflow):
            continue
        # A group is the requirement; what it does with a superseded run is
        # the workflow's call. repair-nightly-appcast-content-types.yml sets
        # cancel-in-progress: false on purpose because it writes to R2, and
        # serializing is as good an answer as cancelling.
        if not workflow.get("concurrency") and path.name not in OWN_SUPERSESSION:
            failures.append(
                f"{path.relative_to(ROOT)} runs on pull_request with no "
                "concurrency group, so every push leaves the superseded run "
                "running"
            )

    for name, reason in sorted(OWN_SUPERSESSION.items()):
        workflow = workflows.get(WORKFLOWS / name)
        if workflow is None or not reason.strip():
            failures.append(f"OWN_SUPERSESSION names {name}, which no longer exists or has no reason")
        elif "pull_request" not in triggers(workflow) or workflow.get("concurrency"):
            failures.append(f"{name} no longer needs its OWN_SUPERSESSION entry; remove it")

    for path, workflow in workflows.items():
        for hit in bare_bun_installs(workflow):
            failures.append(
                f"{path.relative_to(ROOT)}:{hit} runs a bare bun install, which waits "
                "forever on a registry that stops answering; run "
                'bash "$GITHUB_WORKSPACE/scripts/ci/bun-install.sh" with the same arguments'
            )

    if failures:
        print("unbounded CI:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print(
        f"{len(REQUIRED_CONTEXTS)} required and always-bounded checks are bounded; "
        "every pull_request workflow has a concurrency group; no workflow runs a bare bun install"
    )
    return 0


def self_test() -> None:
    """The bare-install detector on the shapes workflows use."""
    def hits(run: str) -> list[str]:
        return bare_bun_installs({"jobs": {"j": {"steps": [{"run": run}]}}})
    for bare in ("bun install --frozen-lockfile", "cd web && bun install", "(cd x && bun i)",
                 "bun install -g some-tool || true", "[ -d node_modules ] || bun install --frozen-lockfile",
                 'echo "Installing dependencies"; bun install --frozen-lockfile', 'printf "Installing\\n" && bun i',
                 "echo bun install", "timeout 600 echo x; bun install",
                 'install_log="$(bun install --frozen-lockfile)"', "bun \\\n  install --frozen-lockfile",
                 "out=`bun i`", 'echo "$(cd web && bun install)"'):
        assert hits(bare), bare
    for bounded in ('bash "$GITHUB_WORKSPACE/scripts/ci/bun-install.sh" --frozen-lockfile',
                    'bash ../scripts/ci/bun-install.sh --', 'echo "bun install --frozen-lockfile in x"',
                    '(cd x && bash "$RUNNER_TEMP/bun-install.sh") || fail "bun install"',
                    "# bun install runs below", "bun run install-hooks", "bun index.ts",
                    "X=1 timeout --kill-after=15 600 bun install --frozen-lockfile",
                    'echo "$(date) bun install starts"', "echo 'run $(bun install) later'"):
        assert not hits(bounded), bounded


if __name__ == "__main__":
    self_test()
    sys.exit(main())
