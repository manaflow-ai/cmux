#!/usr/bin/env python3
"""Ownership for the workflow-guard-tests Linux matrix.

Step ownership is read from ci-guards.yml itself: each step's
`if: ${{ matrix.group == '<group>' }}` names its group, and every path the
step's `run:` executes directly belongs to that group. Only inputs a step reads
indirectly are listed by hand in PATH_OWNERS.

Nothing here is a second copy of the workflow, so two pull requests that each
pass on their own cannot combine into a manifest that disagrees with it.

Unknown paths deliberately return None so the caller can fail open to every
group, and a workflow this module cannot read fails open to every group.
"""

from __future__ import annotations

import re
from functools import lru_cache
from pathlib import Path


GUARD_WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/ci-guards.yml"
GUARD_JOB = "workflow-guard-tests"
# A path a step runs directly, such as `python3 tests/x.py` or `./scripts/y.sh`.
DIRECT_PATH = re.compile(r"(?:\./)?((?:tests(?:_v2)?|scripts|ios/tests)/[A-Za-z0-9_./-]+)")
GROUP_CONDITION = re.compile(r"\$\{\{ matrix\.group == '([^']+)' \}\}")
# A guard job gates itself on the route that selects it, so the workflow also
# names which route owns which job.
ROUTE_CONDITION = re.compile(r"\$\{\{ inputs\.([A-Za-z0-9_]+) == 'true' \}\}")
JOB_HEADER = re.compile(r"  ([A-Za-z0-9_-]+):\s*$")

GROUPS = (
    "preflight",
    "ci",
    "app-host-execution",
    "app-host-process",
    "app-host-cache",
    "release-ios",
    "release-notary",
    "release-tooling",
    "quality-sharding",
    "quality-runtime",
    "quality-determinism",
)

# Inputs a guard step reads without naming them in its `run:` (a script a test
# imports, a working-directory, a submodule). Paths a step runs directly are
# derived from ci-guards.yml by direct_path_owners() and need no entry here.
PATH_OWNERS = {
    ".github/workflows/ci-main-full-suite.yml": frozenset(("ci",)),

    # test_ci_runner_capability_resolver.py reads the capability map, the
    # resolver it imports, the reusable workflow that publishes the map, and
    # the one workflow wired to consume it.
    ".github/runners.json": frozenset(("ci",)),
    ".github/workflows/resolve-runners.yml": frozenset(("ci",)),
    ".github/workflows/ios-app-store.yml": frozenset(("ci",)),
    "scripts/ci/resolve_runners.py": frozenset(("ci",)),

    ".github/workflows/ci-health-report.yml": frozenset(("ci",)),
    ".github/workflows/ci-queue-janitor.yml": frozenset(("ci",)),
    ".github/workflows/required-checks-drift.yml": frozenset(("ci",)),
    # Many groups load the two reusable workflows with yaml.safe_load rather
    # than naming them in a `run:`, so every group observes an edit to them.
    ".github/workflows/ci-macos.yml": frozenset(GROUPS),
    ".github/workflows/ci-web.yml": frozenset(GROUPS),
    ".github/workflows/web-complexity.yml": frozenset(("ci",)),
    ".github/workflows/web-complexity-trusted.yml": frozenset(("ci",)),
    ".github/review-fabric-policy.json": frozenset(("preflight",)),
    ".github/review-fabric.md": frozenset(("preflight",)),
    ".github/scripts/review_fabric.py": frozenset(("preflight",)),
    ".github/workflows/ios-testflight.yml": frozenset(("preflight", "ci", "release-ios")),
    "agent-chat/test/claude-environment.test.ts": frozenset(("preflight",)),
    "ghostty": frozenset(("release-tooling",)),
    "ios/scripts/fetch-testflight-notes-history.sh": frozenset(("release-ios",)),
    "ios/scripts/upload-testflight.sh": frozenset(("release-ios",)),
    "scripts/ci/app_host_test_products.py": frozenset(("preflight",)),
    "scripts/ci/build_input_fingerprint.py": frozenset(("preflight",)),
    "scripts/ci/build_graph_health.py": frozenset(("preflight",)),
    "scripts/ci/compile-app-host-test-product.sh": frozenset(("preflight",)),
    "scripts/ci/find_admitted_build.py": frozenset(("preflight",)),
    "scripts/ci/main_full_suite.py": frozenset(("ci",)),

    "scripts/ci/ios_upload_batch_decision.py": frozenset(("release-ios",)),
    "scripts/ci/peer_product_source.py": frozenset(("preflight",)),
    "scripts/ci/persistent_mac_route.py": frozenset(("preflight",)),
    "scripts/ci/product_input_identity.py": frozenset(("preflight",)),
    "scripts/ci/ci_health_report.py": frozenset(("ci",)),
    "scripts/ci/queue_janitor.py": frozenset(("ci",)),
    "scripts/ci/required_status_checks.py": frozenset(("ci",)),
    "scripts/ci/restore-app-host-test-product.sh": frozenset(("preflight",)),
    "scripts/ci/reuse_app_host_products.py": frozenset(("preflight",)),
    "scripts/ci/run_python_test_lane.py": frozenset(("preflight",)),
    "scripts/ci/ci_process_tree.py": frozenset(("app-host-execution",)),
    "scripts/ci/hung_test_watchdog.py": frozenset(("app-host-execution",)),
    "scripts/ci/run_with_timeout.py": frozenset(("app-host-execution",)),
    "scripts/ci/require_swift_test_execution.py": frozenset(("app-host-execution",)),
    "scripts/ci/run-swift-testing-suites.sh": frozenset(("app-host-execution",)),
    "scripts/ci/sanitize-xcode-source-packages-cache.py": frozenset(("preflight",)),
    # detect_ci_change_areas.py imports this to decide the swift-package-tests
    # route, so the ci group's router tests observe an edit to it even though
    # no guard step names it in a `run:`.
    "scripts/ci/select_package_tests.py": frozenset(("ci",)),
    "scripts/ci/swift_incremental_diagnostics.py": frozenset(("preflight",)),
    "scripts/ci/test_execution_registry.py": frozenset(("preflight",)),
    "skills/cmux-cloud-vm/SKILL.md": frozenset(("preflight",)),
    "skills/cmux-cloud-vm/references/agent-workflows.md": frozenset(("preflight",)),
    "skills/cmux-cloud-vm/references/commands.md": frozenset(("preflight",)),
    "skills/cmux-cloud-vm/references/guest.md": frozenset(("preflight",)),
    "tests/test-execution.toml": frozenset(("preflight",)),
}

# Changes here can alter which required work runs. They always exercise every
# group, including when the candidate implementation would route more narrowly.
ROUTING_POLICY_PATHS = frozenset({
    ".github/workflows/ci.yml",
    ".github/workflows/ci-guards.yml",
    "scripts/ci/detect_ci_change_areas.py",
    "scripts/ci/detect_linux_guard_changes.py",
    "scripts/ci/workflow_guard_groups.py",
    "tests/test_ci_change_areas.py",
    "tests/test_ci_fork_runner_routing.py",
    "tests/test_ci_linux_guard_routing.py",
    "tests/test_ci_guard_workflow_structure.py",
    "tests/test_ci_app_host_guard_structure.py",
    "tests/test_ci_quality_guard_structure.py",
    "tests/test_ci_release_guard_structure.py",
})

DETERMINISM_SUFFIXES = (".swift", ".py", ".sh", ".ts", ".tsx", ".js", ".mjs")


def _python_syntax_scan(path: str) -> bool:
    return path.endswith(".py") and path.startswith(("tests/", "tests_v2/", "scripts/"))


def _determinism_scan(path: str) -> bool:
    if not path.endswith(DETERMINISM_SUFFIXES):
        return False
    if path.startswith(("cmuxTests/", "cmuxUITests/", "ios/cmuxUITests/",
                        "tests/", "tests_v2/", "web/tests/", "webviews/test/")):
        return True
    return path.startswith("Packages/") and "/Tests/" in path


class GuardWorkflowError(ValueError):
    """ci-guards.yml does not have the shape the step scanner reads."""


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _job_body(text: str, job_name: str) -> list[str]:
    lines = text.splitlines()
    try:
        start = lines.index(f"  {job_name}:") + 1
    except ValueError as error:
        raise GuardWorkflowError(f"job {job_name} not found") from error
    end = next(
        (index for index in range(start, len(lines))
         if lines[index].strip() and _indent(lines[index]) <= 2
         and not lines[index].lstrip().startswith("#")),
        len(lines),
    )
    return lines[start:end]


def job_names(text: str) -> tuple[str, ...]:
    """Every top-level job in the guard workflow, in file order."""
    _, marker, body = text.partition("\njobs:\n")
    if not marker:
        raise GuardWorkflowError("workflow has no jobs: block")
    names: list[str] = []
    for line in body.splitlines():
        match = JOB_HEADER.fullmatch(line)
        if match is None:
            continue
        if match.group(1) in names:
            raise GuardWorkflowError(f"duplicate job {match.group(1)!r}")
        names.append(match.group(1))
    if not names:
        raise GuardWorkflowError("workflow declares no jobs")
    return tuple(names)


def job_steps(text: str, job_name: str = GUARD_JOB) -> tuple[dict[str, str], ...]:
    """Return the scalar fields of each step in one job.

    The router runs on the runner's bare python3, which has no PyYAML, so this
    reads the job with a small line scanner. The guard tests check that it
    agrees with yaml.safe_load on the real workflow.
    """
    job = _job_body(text, job_name)
    try:
        steps_at = next(index for index, line in enumerate(job) if line.rstrip() == "    steps:")
    except StopIteration as error:
        raise GuardWorkflowError(f"{job_name} has no steps") from error

    steps: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    index = steps_at + 1
    while index < len(job):
        line = job[index]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            index += 1
            continue
        if line.startswith("      - "):
            current = {}
            steps.append(current)
            line = "        " + line[len("      - "):]
        elif _indent(line) < 8:
            raise GuardWorkflowError(f"unexpected line in {job_name} steps: {line!r}")
        if current is None:
            raise GuardWorkflowError(f"{job_name} step content before the first step")
        index += 1
        if _indent(line) != 8:
            continue  # nested mapping such as `with:` values
        match = re.fullmatch(r"\s*([A-Za-z0-9_-]+):(?:\s+(.*))?", line.rstrip())
        if match is None:
            raise GuardWorkflowError(f"unreadable step line: {line!r}")
        key, value = match.group(1), (match.group(2) or "").strip()
        if value[:1] in {"|", ">"}:
            block: list[str] = []
            while index < len(job) and (not job[index].strip() or _indent(job[index]) > 8):
                block.append(job[index])
                index += 1
            while block and not block[-1].strip():
                block.pop()
            depth = min((_indent(item) for item in block if item.strip()), default=0)
            current[key] = "\n".join(item[depth:] for item in block)
        else:
            current[key] = _unquote(value)
    if not steps:
        raise GuardWorkflowError(f"{job_name} has no steps")
    return tuple(steps)


def guard_steps(text: str) -> tuple[dict[str, str], ...]:
    """The workflow-guard-tests steps."""
    return job_steps(text, GUARD_JOB)


def step_owners(text: str) -> dict[str, str]:
    """Map each group-conditioned step name to its group."""
    owners: dict[str, str] = {}
    for step in guard_steps(text):
        match = GROUP_CONDITION.fullmatch(step.get("if", ""))
        if match is None:
            continue
        name = step.get("name", "")
        if not name or name in owners:
            raise GuardWorkflowError(f"group-conditioned step name missing or repeated: {name!r}")
        owners[name] = match.group(1)
    return owners


def direct_path_owners(text: str) -> dict[str, frozenset[str]]:
    """Map each path a group-conditioned step runs directly to its groups."""
    owners: dict[str, set[str]] = {}
    for step in guard_steps(text):
        match = GROUP_CONDITION.fullmatch(step.get("if", ""))
        if match is None:
            continue
        for path in DIRECT_PATH.findall(step.get("run", "")):
            owners.setdefault(path, set()).add(match.group(1))
    return {path: frozenset(groups) for path, groups in owners.items()}


def job_route(text: str, job_name: str) -> str | None:
    """The workflow input that gates a job, from its own top-level `if:`."""
    for line in _job_body(text, job_name):
        if _indent(line) != 4:
            continue
        key, separator, value = line.strip().partition(":")
        if key == "if" and separator:
            match = ROUTE_CONDITION.fullmatch(_unquote(value))
            return match.group(1) if match else None
        if not separator:
            continue
    return None


def route_direct_paths(text: str) -> dict[str, frozenset[str]]:
    """Map each guard route to the paths its job's steps run directly.

    A guard job names the route that selects it (`if: inputs.<route> ==
    'true'`) and names the tests and scripts it runs. Both halves of "which
    diffs does this guard observe" therefore already live in ci-guards.yml,
    and the router reads them instead of keeping a parallel copy.
    """
    routes: dict[str, set[str]] = {}
    for job_name in job_names(text):
        route = job_route(text, job_name)
        if route is None:
            continue
        paths = routes.setdefault(route, set())
        for step in job_steps(text, job_name):
            paths.update(DIRECT_PATH.findall(step.get("run", "")))
    if not routes:
        raise GuardWorkflowError("no job is gated on a workflow input")
    return {route: frozenset(paths) for route, paths in routes.items()}


@lru_cache(maxsize=1)
def _workflow_path_owners() -> dict[str, frozenset[str]] | None:
    try:
        return direct_path_owners(GUARD_WORKFLOW.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, GuardWorkflowError):
        return None


def groups_for_path(path: str) -> tuple[str, ...] | None:
    """Return current observers for path, or None when ownership is unknown."""
    if path in ROUTING_POLICY_PATHS:
        return GROUPS

    derived = _workflow_path_owners()
    if derived is None:
        return GROUPS

    owners = set(PATH_OWNERS.get(path, ()))
    owners.update(derived.get(path, ()))
    if _python_syntax_scan(path):
        owners.add("preflight")
    if _determinism_scan(path):
        owners.add("quality-determinism")

    if path == ".github/workflows/ios-testflight.yml":
        owners.update(("preflight", "ci"))

    if not owners:
        return None
    return tuple(group for group in GROUPS if group in owners)
