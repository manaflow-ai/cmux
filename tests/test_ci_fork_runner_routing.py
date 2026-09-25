#!/usr/bin/env python3
"""Fork pull-request workflows must use GitHub-hosted runners with zero setup."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

FORK_LINUX_BRANCH = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'"
# A fork running CI in its own repository compiles on GitHub-hosted macos-26,
# the image and Xcode main compiles with, so it can hit main's public caches.
FORK_MACOS_BRANCH = "github.repository_owner != 'manaflow-ai' && 'macos-26'"
# Only jobs that need the macOS 15 image itself keep a macos-15 fork branch.
FORK_MACOS_15_BRANCH = "github.repository_owner != 'manaflow-ai' && 'macos-15'"
MACOS_15_FORK_JOBS = {
    # Builds the release Ghostty CLI helper against the macOS 15 SDK.
    ("ci-macos.yml", "swift-package-tests"),
    ("release.yml", "build-ghostty-cli-helper"),
    ("nightly.yml", "build-nightly-ghostty-cli-helper"),
    # Its matrix exists to cover each macOS major; only the macOS 15 row.
    ("ci-macos-compat.yml", "compat-tests"),
    # Exists to exercise the paste worker on macOS 15.
    ("plain-paste-worker.yml", "macos-15"),
    # Seeds the macOS 15 pool's SwiftPM manifest cache, keyed on its Xcode.
    ("seed-swiftpm-manifests.yml", "seed"),
}
# A matrix job may instead pick a hosted label per row, e.g. to spread
# app-host shards over macos-15 and macos-26. Accepted only when every
# `hosted_runner:` value in the workflow is a GitHub-hosted macOS label.
FORK_MACOS_MATRIX_BRANCH = "github.repository_owner != 'manaflow-ai' && matrix.hosted_runner"
HOSTED_MACOS_LABELS = {"macos-15", "macos-26"}
# Any Blacksmith runner label. Script names such as
# scripts/blacksmith-bounded-command.sh have no `-Nvcpu-` part.
BLACKSMITH_LABEL = re.compile(r"blacksmith-\d+vcpu-[a-z0-9]+(?:[.-][a-z0-9]+)*")
FORK_BRANCHES = (FORK_LINUX_BRANCH, FORK_MACOS_BRANCH, FORK_MACOS_15_BRANCH, FORK_MACOS_MATRIX_BRANCH)
OWNER_ONLY_JOB_IF = "if: github.repository_owner == 'manaflow-ai'"
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}")
JOB_HEADER = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$")
INPUT_HEADER = re.compile(r"^      ([A-Za-z0-9_-]+):\s*$")
# (workflow, stripped line) -> why a Blacksmith label there may stay ungated.
UNGATED_BLACKSMITH_ALLOWED = {
    ("cla.yml", "runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"): (
        "scripts/ci/validate-cla-policy.rb pins this runner from the trusted base; "
        "the job signs manaflow-ai's CLA ledger and has nothing to do in a fork"
    ),
    ("reload-build.yml", "macOS runner label to build on. Blacksmith (blacksmith-6vcpu-macos-26),"): (
        "description text of the runner input, not a value"
    ),
}
# (workflow, dispatch input) -> why its Blacksmith default and choices may be
# read before the fork branch.
UNTRANSLATED_DISPATCH_INPUTS: dict[tuple[str, str], str] = {}
LOCAL_WORKFLOW_CALL = re.compile(
    r"uses:\s+\./\.github/workflows/([A-Za-z0-9_.-]+\.ya?ml)"
)

# A fork pull request into manaflow-ai runs with repository_owner ==
# 'manaflow-ai', so the owner branches above do not catch it. Before any
# repository variable or pool picker output can pick a runner, it must take
# this branch to a Blacksmith or GitHub-hosted label, because the
# MACOS_RUNNER_* variables, and any pool pr_runner_pool.py may learn later,
# may name owned self-hosted Macs. The branch either names a label or keeps
# the picker's choice only when it is a Blacksmith label (the picker already
# limits forks to ephemeral pools; this restates that where the runner is
# picked). Comparing full_name instead of reading head.repo.fork also covers a
# deleted head repository (head.repo is null).
FORK_PULL_REQUEST_CLAUSE = re.compile(
    r"github\.event_name == 'pull_request'"
    r" && github\.event\.pull_request\.head\.repo\.full_name != github\.repository"
    r" && (?:'(?:blacksmith-\d+vcpu-macos-\d+|macos-\d+)'"
    r"|\(startsWith\((?P<picked>[A-Za-z0-9_.]+), 'blacksmith-'\) && (?P=picked)"
    r" \|\| 'blacksmith-\d+vcpu-macos-\d+'\))"
)
# Values that can resolve to an owned self-hosted macOS label. A variable
# counts on any line (env mirrors such as CMUX_PRODUCT_RUNNER must agree with
# runs-on); a matrix pool or the pull request pool picker's output only where
# it picks the runner.
OWNED_MACOS_VARIABLE = re.compile(r"vars\.MACOS_RUNNER_\w+")
OWNED_MACOS_SELECTOR = re.compile(
    r"vars\.MACOS_RUNNER_\w+|matrix\.pr_runner|inputs\.pr_runner|needs\.changes\.outputs\.macos_pr_runner"
)
# (workflow, stripped line) -> why a MACOS_RUNNER_* read there picks no runner.
FORK_GATE_EXEMPT = {
    ("ci.yml", "DEFAULT_RUNNER: ${{ vars.MACOS_RUNNER_PR }}"): (
        "pr_runner_pool.py's input: it compares the lane with its default and "
        "ignores it for a fork head, and every runs-on reading its output takes "
        "the fork branch first"
    ),
}


def pull_request_workflows() -> list[Path]:
    result: list[Path] = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        text = path.read_text(encoding="utf-8")
        if re.search(r"(?m)^  pull_request:\s*(?:$|\[|\{)", text):
            result.append(path)
    return result


def fork_pull_request_gate_error(line: str) -> str | None:
    """Why a fork PR into manaflow-ai could reach an owned macOS label, if it can."""
    selector = OWNED_MACOS_SELECTOR.search(line)
    if not selector:
        return None
    gate = FORK_PULL_REQUEST_CLAUSE.search(line)
    if not gate:
        return "has no fork pull-request branch"
    if gate.start() > selector.start():
        return f"checks {selector.group(0)} before the fork pull-request branch"
    return None


def fork_exercised_workflows() -> list[Path]:
    """PR workflows plus every local reusable workflow reachable from them."""
    pending = list(pull_request_workflows())
    seen: set[Path] = set()
    while pending:
        path = pending.pop()
        if path in seen:
            continue
        seen.add(path)
        text = path.read_text(encoding="utf-8")
        for name in LOCAL_WORKFLOW_CALL.findall(text):
            called = WORKFLOWS / name
            if called.is_file() and called not in seen:
                pending.append(called)
    return sorted(seen)


def pull_request_selects(line: str, family: str) -> bool:
    """True when `github.event_name == 'pull_request'` selects a hosted label."""
    return bool(
        re.search(
            r"github\.event_name == 'pull_request' && '" + family + r"-[^']+'",
            line,
        )
    )


def _gated_expression(expression: str, explicit_input_first: bool = False) -> bool:
    """True when a `${{ }}` body picks a GitHub-hosted label first outside manaflow-ai.

    With `explicit_input_first`, a leading `inputs.X ||` is allowed: an input
    someone set explicitly wins, and its default is checked on its own line.
    """
    body = expression.strip()
    if body.startswith("startsWith("):
        body = body[len("startsWith("):]
    if explicit_input_first:
        body = re.sub(r"^(?:inputs\.[A-Za-z0-9_-]+ \|\| )+", "", body)
    return body.startswith(FORK_BRANCHES)


def ungated_blacksmith_labels(name: str, text: str) -> list[str]:
    """Blacksmith labels a zero-configuration run outside manaflow-ai could select.

    A label is fine when every `${{ }}` holding it starts with the owner fork
    branch, when it sits in a job whose `if:` is the owner check, when it is a
    matrix row whose `hosted_runner` a fork branch picks instead, or when it is a
    dispatch input's default or choice and every `runs-on:` reading that input
    starts with the fork branch.
    """
    lines = text.splitlines()
    owner_only_jobs: set[str] = set()
    job = None
    for raw in lines:
        header = JOB_HEADER.match(raw)
        if header:
            job = header.group(1)
        elif job and raw.strip() == OWNER_ONLY_JOB_IF and raw.startswith("    if:"):
            owner_only_jobs.add(job)

    def input_is_translated(input_name: str) -> bool:
        read = re.compile(rf"inputs\.{re.escape(input_name)}\b")
        for raw in lines:
            if not re.match(r"^\s*runs-on:", raw):
                continue
            for expression in EXPRESSION.findall(raw):
                if read.search(expression) and not _gated_expression(expression):
                    return False
        return True

    matrix_branch = FORK_MACOS_MATRIX_BRANCH in text
    errors: list[str] = []
    job = None
    current_input = None
    in_options = False
    for number, raw in enumerate(lines, start=1):
        stripped = raw.strip()
        header = JOB_HEADER.match(raw)
        if header:
            job = header.group(1)
        input_header = INPUT_HEADER.match(raw)
        if input_header:
            current_input = input_header.group(1)
        if stripped.startswith("options:"):
            in_options = True
            continue
        if in_options and not stripped.startswith("- "):
            in_options = False
        if stripped.startswith("#") or not BLACKSMITH_LABEL.search(raw):
            continue
        if job in owner_only_jobs or (name, stripped) in UNGATED_BLACKSMITH_ALLOWED:
            continue
        if matrix_branch and re.search(r'"hosted_runner":\s*"macos-[^"]+"', raw):
            continue
        label = BLACKSMITH_LABEL.search(raw).group(0)
        dispatch_value = (in_options and stripped == f"- {label}") or stripped == f"default: {label}"
        if dispatch_value and current_input and (
            input_is_translated(current_input)
            or (name, current_input) in UNTRANSLATED_DISPATCH_INPUTS
        ):
            continue
        expressions = [e for e in EXPRESSION.findall(raw) if BLACKSMITH_LABEL.search(e)]
        if expressions and all(_gated_expression(e, explicit_input_first=True) for e in expressions):
            # A label outside every expression (e.g. `group: blacksmith-...-${{ }}`)
            # is still selectable.
            if not BLACKSMITH_LABEL.search(EXPRESSION.sub("", raw)):
                continue
        errors.append(
            f"{name}:{number}: {label} is selectable outside manaflow-ai, where no "
            f"Blacksmith runner exists; start the expression with the owner fork branch, "
            f"e.g. ${{{{ {FORK_LINUX_BRANCH} || ... }}}}"
        )
    return errors


class ForkRunnerRoutingTests(unittest.TestCase):
    def test_pull_request_branch_must_select_the_hosted_label(self) -> None:
        selected = (
            "runs-on: ${{ github.event_name == 'pull_request' && 'ubuntu-latest'"
            " || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"
        )
        inverted = (
            "runs-on: ${{ github.event_name == 'pull_request'"
            " && 'blacksmith-6vcpu-macos-15' || 'macos-15' }}"
        )
        inverted_linux = (
            "runs-on: ${{ github.event_name == 'pull_request'"
            " && 'blacksmith-4vcpu-ubuntu-2404' || 'ubuntu-24.04' }}"
        )
        self.assertTrue(pull_request_selects(selected, "ubuntu"))
        self.assertFalse(pull_request_selects(inverted, "macos"))
        self.assertFalse(pull_request_selects(inverted_linux, "ubuntu"))

    def test_fork_pull_request_gate_must_precede_every_owned_selector(self) -> None:
        clause = (
            "github.event_name == 'pull_request'"
            " && github.event.pull_request.head.repo.full_name != github.repository"
        )
        gated = (
            "runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || ("
            + clause
            + " && 'blacksmith-6vcpu-macos-15' || vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15') }}"
        )
        ungated = (
            "runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26'"
            " || (vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15') }}"
        )
        late = (
            "runs-on: ${{ vars.MACOS_RUNNER_PR || "
            + clause
            + " && 'blacksmith-6vcpu-macos-15' || 'blacksmith-6vcpu-macos-15' }}"
        )
        # head.repo.fork is false-y when the head repository was deleted.
        null_unsafe = (
            "runs-on: ${{ github.event.pull_request.head.repo.fork && 'blacksmith-6vcpu-macos-15'"
            " || matrix.pr_runner }}"
        )
        # The fork branch must pick a hosted label, not another variable.
        to_variable = (
            "runs-on: ${{ " + clause + " && vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15' }}"
        )
        # The picker's choice may stand for a fork only when it is Blacksmith.
        picked = (
            "runs-on: ${{ " + clause + " && (startsWith(inputs.pr_runner, 'blacksmith-')"
            " && inputs.pr_runner || 'blacksmith-6vcpu-macos-15')"
            " || github.event_name == 'pull_request' && (inputs.pr_runner || vars.MACOS_RUNNER_PR"
            " || 'blacksmith-6vcpu-macos-15') }}"
        )
        picked_unchecked = (
            "runs-on: ${{ " + clause + " && (inputs.pr_runner || 'blacksmith-6vcpu-macos-15')"
            " || vars.MACOS_RUNNER_PR }}"
        )
        picked_mismatch = (
            "runs-on: ${{ " + clause + " && (startsWith(inputs.pr_runner, 'blacksmith-')"
            " && vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-15') || vars.MACOS_RUNNER_PR }}"
        )
        picker_first = (
            "runs-on: ${{ needs.changes.outputs.macos_pr_runner || "
            + clause
            + " && 'blacksmith-6vcpu-macos-15' || 'blacksmith-6vcpu-macos-15' }}"
        )
        self.assertIsNone(fork_pull_request_gate_error(picked))
        self.assertIsNotNone(fork_pull_request_gate_error(picked_unchecked))
        self.assertIsNotNone(fork_pull_request_gate_error(picked_mismatch))
        self.assertIsNotNone(fork_pull_request_gate_error(picker_first))
        self.assertIsNone(fork_pull_request_gate_error(gated))
        self.assertIsNone(fork_pull_request_gate_error("runs-on: macos-15"))
        self.assertIsNotNone(fork_pull_request_gate_error(ungated))
        self.assertIsNotNone(fork_pull_request_gate_error(late))
        self.assertIsNotNone(fork_pull_request_gate_error(null_unsafe))
        self.assertIsNotNone(fork_pull_request_gate_error(to_variable))

    def test_fork_pull_requests_into_manaflow_ai_never_reach_an_owned_macos_label(self) -> None:
        """MACOS_RUNNER_* may name self-hosted Macs; fork PR code must not run there."""
        checked = 0
        failures = []
        for path in fork_exercised_workflows():
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                if line.lstrip().startswith("#"):
                    continue
                if not (
                    OWNED_MACOS_VARIABLE.search(line)
                    or ("runs-on:" in line and OWNED_MACOS_SELECTOR.search(line))
                ):
                    continue
                # A selector split across lines would hide the gate from
                # this line-based check.
                if "${{" in line and "}}" not in line:
                    failures.append(f"{path.name}:{number} spans lines; keep runner expressions on one line")
                    continue
                if (path.name, line.strip()) in FORK_GATE_EXEMPT:
                    continue
                checked += 1
                error = fork_pull_request_gate_error(line)
                if error:
                    failures.append(f"{path.name}:{number} {error}: {line.strip()}")
        self.assertEqual(failures, [])
        self.assertGreater(checked, 0)

    def test_pull_request_xcode_pin_follows_the_same_repository_lane(self) -> None:
        """A fork PR leaves MACOS_RUNNER_PR, so it must leave its Xcode pin too.

        select-ci-xcode.sh fails on a pinned Xcode the image does not carry, so a
        fork PR routed to the macOS 15 default while still reading
        CMUX_CI_XCODE_APP_PR would fail at Xcode selection.
        """
        same_repository = "github.event.pull_request.head.repo.full_name == github.repository"
        checked = 0
        failures = []
        for path in fork_exercised_workflows():
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                if line.lstrip().startswith("#") or not re.search(r"vars\.CMUX_(?:CI|CI_HELPER)_XCODE_APP_PR\b", line):
                    continue
                checked += 1
                if same_repository not in line:
                    failures.append(f"{path.name}:{number}: {line.strip()}")
        self.assertEqual(failures, [])
        self.assertGreater(checked, 0)

    def test_pull_request_graph_is_nonempty_and_includes_reusable_workflows(self) -> None:
        roots = pull_request_workflows()
        graph = fork_exercised_workflows()
        self.assertTrue(roots)
        self.assertGreater(len(graph), len(roots))

    def test_fork_macos_branches_use_macos_26_unless_the_job_needs_macos_15(self) -> None:
        workflows = Path(__file__).resolve().parents[1] / ".github" / "workflows"
        wrong = []
        for path in sorted(workflows.glob("*.yml")):
            job = None
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
                if match:
                    job = match.group(1)
                if FORK_MACOS_15_BRANCH in line and (path.name, job) not in MACOS_15_FORK_JOBS:
                    wrong.append(f"{path.name}:{number} ({job})")
        self.assertEqual(wrong, [], "fork branches compile on macos-26 so they can reuse main's caches")

    def test_every_fork_exercised_runner_has_a_hosted_path(self) -> None:
        """No fork PR may queue forever on organization-only capacity."""
        saw_linux = 0
        saw_macos = 0

        for path in fork_exercised_workflows():
            text = path.read_text(encoding="utf-8")
            # Rows are YAML (`hosted_runner: macos-15`) or JSON literals in a
            # matrix `include` expression (`"hosted_runner": "macos-15"`).
            hosted_rows = re.findall(r"(?m)^\s+hosted_runner:\s*(\S+)\s*$", text)
            hosted_rows += re.findall(r'"hosted_runner":\s*"([^"]*)"', text)
            matrix_hosted = bool(hosted_rows) and set(hosted_rows) <= HOSTED_MACOS_LABELS
            for number, line in enumerate(text.splitlines(), start=1):
                if "runs-on:" not in line:
                    continue

                # A few trust-boundary workflows already choose GitHub-hosted
                # capacity specifically for pull_request and use the repository
                # pool for push/main. That is equivalent to the owner branch,
                # but only when the hosted label is the value the pull_request
                # condition selects, not a label appearing later on the line.
                pull_request_linux = pull_request_selects(line, "ubuntu")
                pull_request_macos = pull_request_selects(line, "macos")
                hosted_linux = FORK_LINUX_BRANCH in line or pull_request_linux
                hosted_macos = (
                    FORK_MACOS_BRANCH in line
                    or FORK_MACOS_15_BRANCH in line
                    or pull_request_macos
                    or (matrix_hosted and FORK_MACOS_MATRIX_BRANCH in line)
                )

                with self.subTest(workflow=path.name, line=number):
                    if "vars.LINUX_RUNNER" in line:
                        saw_linux += 1
                        self.assertTrue(
                            hosted_linux,
                            f"{path.name}:{number} has no GitHub-hosted Linux fork branch",
                        )
                    if "vars.MACOS_RUNNER" in line:
                        saw_macos += 1
                        self.assertTrue(
                            hosted_macos,
                            f"{path.name}:{number} has no GitHub-hosted macOS fork branch",
                        )
                    if "blacksmith-" in line:
                        self.assertTrue(
                            hosted_linux or hosted_macos,
                            f"{path.name}:{number} can queue forever in a fork: {line.strip()}",
                        )
                    if re.search(r"\b(?:warp|depot|tart)-", line):
                        self.assertTrue(
                            hosted_linux or hosted_macos,
                            f"{path.name}:{number} can route a fork onto non-GitHub capacity",
                        )

        self.assertGreater(saw_linux, 0)
        self.assertGreater(saw_macos, 0)

    def test_no_workflow_falls_back_to_blacksmith_outside_manaflow_ai(self) -> None:
        """Scheduled, dispatched and push-only workflows need a fork branch too.

        A fork running its own CI has no Blacksmith installation and no runner
        variables, so an ungated fallback sits queued forever and holds its
        concurrency group.
        """
        errors: list[str] = []
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            errors.extend(ungated_blacksmith_labels(path.name, path.read_text(encoding="utf-8")))
        self.assertEqual(errors, [], "\n" + "\n".join(errors))

    def test_ungated_blacksmith_fallbacks_are_rejected(self) -> None:
        text = (
            "on:\n"
            "  workflow_dispatch:\n"
            "    inputs:\n"
            "      runner:\n"
            "        default: blacksmith-6vcpu-macos-26\n"
            "        type: choice\n"
            "        options:\n"
            "          - blacksmith-6vcpu-macos-26\n"
            "jobs:\n"
            "  a:\n"
            "    runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}\n"
            "  b:\n"
            "    runs-on: blacksmith-6vcpu-macos-15\n"
            "  c:\n"
            "    strategy:\n"
            "      matrix:\n"
            "        include:\n"
            "          - runner: blacksmith-6vcpu-macos-26\n"
            "  d:\n"
            "    runs-on: ${{ inputs.runner || " + FORK_MACOS_BRANCH + " || 'blacksmith-6vcpu-macos-26' }}\n"
        )
        # a, b, c, and the dispatch default and option that d reads before
        # the fork branch. d itself passes: an explicitly chosen input wins.
        self.assertEqual(len(ungated_blacksmith_labels("x.yml", text)), 5)

    def test_owner_gated_blacksmith_fallbacks_pass(self) -> None:
        text = (
            "on:\n"
            "  workflow_dispatch:\n"
            "    inputs:\n"
            "      runner:\n"
            "        default: blacksmith-6vcpu-macos-26\n"
            "        type: choice\n"
            "        options:\n"
            "          - blacksmith-6vcpu-macos-26\n"
            "concurrency:\n"
            "  group: x-${{ " + FORK_MACOS_BRANCH + " || inputs.runner }}\n"
            "jobs:\n"
            "  a:\n"
            "    runs-on: ${{ " + FORK_LINUX_BRANCH + " || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}\n"
            "  b:\n"
            "    runs-on: ${{ " + FORK_MACOS_BRANCH + " || inputs.runner || 'blacksmith-6vcpu-macos-26' }}\n"
            "    steps:\n"
            "      - if: ${{ startsWith(" + FORK_MACOS_BRANCH + " || 'blacksmith-6vcpu-macos-26', 'tart-') }}\n"
            "        run: ./scripts/blacksmith-bounded-command.sh\n"
            "  c:\n"
            "    " + OWNER_ONLY_JOB_IF + "\n"
            "    runs-on: blacksmith-32vcpu-ubuntu-2404\n"
        )
        self.assertEqual(ungated_blacksmith_labels("x.yml", text), [])


if __name__ == "__main__":
    unittest.main()
