#!/usr/bin/env python3
"""No runner selection names a single-size Blacksmith label: every route reads the declared pools.

Leo, 2026-10-28: "What the f*** do we still have so many of these? ... Where the f*** are the generalized
solution to all these f***ing problems that these incessant f***ing pins?" On 2026-10-28 nightly.yml fell back to
a literal 'blacksmith-4vcpu-ubuntu-2404' after it stopped starting jobs, and a re-run cannot move a literal label.
475 runs-on lines in 185 workflows ended that way.

A job names the size it was measured at by reading that size's pool, `fromJSON(vars.RUNNER_POOLS).<pool>`
(.github/runners.json `pools` on main: linux_2, linux_4, linux_8, linux_16, linux_32, linux_arm64, macos_15,
macos_26, macos_26_large, macos_latest, windows, ...). scripts/ci/runner_pools.py moves a pool off a member that
starts nothing, so the job follows with no YAML edit.

Every value under a runner-selection key (runs-on, runs_on, os, labels, group, pool and any *runner* key: matrix
entries, reusable-workflow inputs and env mirrors feed runs-on too) is scanned. A quoted Blacksmith label is
allowed only where it is not a route:

- the fork pull request branch, `head.repo.full_name != github.repository [&& !contains(...)] && '<label>'` or
  `&& (...)`: a fork's pull_request run gets no repository variables, so fromJSON(vars.RUNNER_POOLS) cannot be
  read there;
- the owner branch, `github.repository_owner != 'manaflow-ai' && '<label>'`, which never runs in manaflow-ai;
- a membership list, `fromJSON('[...]')`, and a comparison or function argument (`== '<label>'`,
  `contains(x, '<label>')`): checks, not routes.

A bare (unquoted) Blacksmith label in a selection is always a pin. EXCEPTIONS names the few selections that keep a
literal on purpose, each with its reason; SELECTIONS_KEPT_LITERAL names whole selections kept the same way, and a job that holds signing or release
material (SIGNING_JOB) keeps its route under its own trust rules. Workflow-dispatch input defaults are dispatch
choices a person makes, and are not scanned. GitHub-hosted labels are the other half of the invariant and stay
with tests/test_ci_self_hosted_guard.sh, whose exact-line exceptions (the light-Linux jobs in .github/runners.json
`hosted_light_jobs` with their measured wall time, provenance publishing) are the only hosted routes.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

KEY = re.compile(r"^(runs-on|runs_on|os|labels|group|pool|[A-Za-z0-9_-]*runner[A-Za-z0-9_-]*)$", re.IGNORECASE)
LABEL = re.compile(r"blacksmith-\d+vcpu-[a-z0-9.-]+")
QUOTED = re.compile(r"'(blacksmith-\d+vcpu-[a-z0-9.-]+)'")
FORK = re.compile(r"head\.repo\.full_name\s*!=\s*github\.repository(?:\s*&&\s*!contains\([^()]*\([^()]*\)[^()]*\))?\s*&&\s*$")
OWNER = re.compile(r"github\.repository_owner\s*!=\s*'manaflow-ai'\s*&&\s*$")
LIST_OPEN = re.compile(r"fromJSON\('\[[^\]']*$")
COMPARED = re.compile(r"(?:[!=]=|,|\w\()\s*$")  # a comparison or a function argument, never a bare group
# The text before a literal that keeps it on purpose -> why. Nothing else may.
EXCEPTIONS = {
    re.compile(r"vars\.CI_TRUSTED_RUNNER\) && vars\.CI_TRUSTED_RUNNER \|\|\s*$"): (
        "runner trust policy: a trusted-token job (pull_request_target, comment events, CLA) takes CI_TRUSTED_RUNNER "
        "only from the allowlist written into its own expression, else one fixed ephemeral label. A RUNNER_POOLS "
        "read would let whoever writes that variable route the token; scripts/ci/validate-cla-policy.rb allows the "
        "CLA job's runs-on as one exact string"
    ),
}
# Whole selections that keep their literal on purpose -> why.
SELECTIONS_KEPT_LITERAL = {
    ("cmux-next-guards.yml", "jobs.signing-runner-variables.runs-on"): (
        "the job checks the runner variables themselves, so its own route must not read them: with a bad value it "
        "would queue on that value instead of going red"
    ),
}
# A job that holds signing or release material keeps its route under its own trust rules
# (tests/test_ci_release_sdk_lane.sh, tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py).
sys.path.insert(0, str(ROOT / "tests"))
from runs_on_labels import SIGNING_JOB, holds_signing_material  # noqa: E402
# A fork branch whose operand reads any repository variable, directly or through fromJSON.
VARS_READ = re.compile(r"\bvars\.")
FORK_READS_POOLS = re.compile(FORK.pattern.rstrip("$") + r"(?:fromJSON\()?vars\.")


def fork_operands(text: str) -> list[range]:
    """Spans of `<fork condition> && (...)`: a parenthesized operand only a fork pull request evaluates."""
    spans = []
    for match in re.finditer(FORK.pattern.rstrip("$"), text):
        start = match.end()
        if text[start:start + 1] != "(":
            continue
        depth = 0
        for end in range(start, len(text)):
            depth += {"(": 1, ")": -1}.get(text[end], 0)
            if depth == 0:
                spans.append(range(start, end + 1))
                break
    return spans


def pins_in(value: str) -> list[str]:
    """The single-size Blacksmith labels `value` routes to, outside the allowed positions."""
    text = value.strip()
    if not text.startswith("${{"):
        return LABEL.findall(text) if LABEL.fullmatch(text.strip("'\"")) else []
    found = []
    forks = fork_operands(text)
    for match in QUOTED.finditer(text):
        if any(match.start() in span for span in forks):
            continue
        before = text[: match.start()]
        if (FORK.search(before) or OWNER.search(before) or LIST_OPEN.search(before) or COMPARED.search(before)
                or any(allowed.search(before) for allowed in EXCEPTIONS)):
            continue
        found.append(match.group(1))
    return found


def selections(node, path=()):
    """(path, string) for every string under a runner-selection key, list items and nested matrices included."""
    if isinstance(node, dict):
        for key, child in node.items():
            here = path + (str(key),)
            # A job ID such as `runner` names a job, not a runner selection.
            if isinstance(key, str) and KEY.match(key) and "inputs" not in path[-2:-1] and path != ("jobs",):
                yield from strings(child, here)
            if key == "on":
                continue
            yield from selections(child, here)
    elif isinstance(node, list):
        for index, child in enumerate(node):
            yield from selections(child, path + (str(index),))


def strings(node, path):
    if isinstance(node, str):
        yield path, node
    elif isinstance(node, list):
        for index, child in enumerate(node):
            yield from strings(child, path + (str(index),))
    elif isinstance(node, dict):
        for key, child in node.items():
            yield from strings(child, path + (str(key),))


def violations(directory: Path = WORKFLOWS) -> list[str]:
    found = []
    for workflow in sorted(directory.glob("*.y*ml")):
        document = yaml.load(workflow.read_text(encoding="utf-8"), Loader=yaml.BaseLoader) or {}
        jobs = document.get("jobs", {})
        for path, value in selections(jobs, ("jobs",)):
            if (workflow.name, ".".join(path)) in SELECTIONS_KEPT_LITERAL:
                continue
            if holds_signing_material(jobs.get(path[1])):
                continue
            if FORK_READS_POOLS.search(value) or any(
                    VARS_READ.search(value[span.start:span.stop]) for span in fork_operands(value)):
                found.append(f"{workflow.name}: {'.'.join(path)} gives fork pull requests a repository variable, "
                             f"which a fork's run cannot read; keep that branch a quoted label")
            for label in pins_in(value):
                found.append(f"{workflow.name}: {'.'.join(path)} routes to the literal {label!r}; "
                             f"read its size's pool, fromJSON(vars.RUNNER_POOLS).<pool>, instead")
    return found


class NoSingleSizePins(unittest.TestCase):
    def test_no_workflow_routes_to_a_single_size_blacksmith_label(self) -> None:
        found = violations()
        self.assertEqual(found, [], "\n" + "\n".join(found))

    def test_the_scan_flags_each_kind_of_pin(self) -> None:
        for pin in (
            "${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}",
            "${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-16vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_8 }}",
            "${{ needs.pick.outputs.runner || 'blacksmith-6vcpu-macos-26' }}",
            "${{ contains(fromJSON('[\"blacksmith-4vcpu-ubuntu-2404\"]'), vars.X) && vars.X || 'blacksmith-4vcpu-ubuntu-2404' }}",
            "blacksmith-32vcpu-ubuntu-2404",
            # A bare group is a route, not a function argument.
            "${{ github.event_name == 'push' && ('blacksmith-4vcpu-ubuntu-2404') || fromJSON(vars.RUNNER_POOLS).linux }}",
        ):
            with self.subTest(pin=pin):
                self.assertTrue(pins_in(pin))

    def test_a_runner_like_job_id_is_not_a_selection(self) -> None:
        jobs = {"runner": {"runs-on": "${{ fromJSON(vars.RUNNER_POOLS).linux }}",
                           "steps": [{"run": "echo blacksmith-4vcpu-ubuntu-2404"}]}}
        self.assertEqual([path for path, _ in selections(jobs, ("jobs",))], [("jobs", "runner", "runs-on")])

    def test_every_exception_is_still_used(self) -> None:
        text = "\n".join(path.read_text(encoding="utf-8") for path in sorted(WORKFLOWS.glob("*.y*ml")))
        for allowed in EXCEPTIONS:
            with self.subTest(exception=allowed.pattern):
                self.assertRegex(text, allowed.pattern.replace(r"\s*$", "") + r"\s*'blacksmith-")

    def test_every_kept_selection_still_exists(self) -> None:
        for workflow, path in SELECTIONS_KEPT_LITERAL:
            with self.subTest(workflow=workflow, path=path):
                document = yaml.load((WORKFLOWS / workflow).read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
                found = dict((".".join(p), v) for p, v in selections(document["jobs"], ("jobs",)))
                self.assertIn(path, found)
                self.assertTrue(pins_in(found[path]), "the selection no longer keeps a literal; drop its exception")

    def test_signing_jobs_are_left_to_their_trust_rules(self) -> None:
        document = yaml.load((WORKFLOWS / "release.yml").read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        job = document["jobs"]["build-sign-notarize"]
        self.assertRegex(yaml.safe_dump(job), SIGNING_JOB)
        self.assertNotIn("RUNNER_POOLS", job["runs-on"])

    def test_the_trusted_selector_keeps_its_literal_and_nothing_else_does(self) -> None:
        trusted = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || contains(fromJSON('[\"ubuntu-24.04\","
                   "\"blacksmith-4vcpu-ubuntu-2404\"]'), vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || "
                   "'blacksmith-4vcpu-ubuntu-2404' }}")
        self.assertEqual(pins_in(trusted), [])
        self.assertTrue(pins_in("${{ vars.CI_TRUSTED_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"))

    def test_a_fork_branch_that_reads_a_variable_is_flagged(self) -> None:
        value = ("${{ github.event.pull_request.head.repo.full_name != github.repository && "
                 "!contains(fromJSON(inputs.owned_head_repos), github.event.pull_request.head.repo.full_name) && "
                 "fromJSON(vars.RUNNER_POOLS).linux_4 || fromJSON(vars.RUNNER_POOLS).linux }}")
        self.assertTrue(FORK_READS_POOLS.search(value))
        nested = ("${{ github.event.pull_request.head.repo.full_name != github.repository && (startsWith(inputs.pr_runner, "
                  "'blacksmith-') && inputs.pr_runner || fromJSON(vars.RUNNER_POOLS).macos_15) }}")
        self.assertTrue(any("fromJSON(vars." in nested[s.start:s.stop] for s in fork_operands(nested)))
        plain = ("${{ github.event.pull_request.head.repo.full_name != github.repository && "
                 "vars.LINUX_RUNNER || fromJSON(vars.RUNNER_POOLS).linux }}")
        self.assertTrue(FORK_READS_POOLS.search(plain))
        nested_plain = ("${{ github.event.pull_request.head.repo.full_name != github.repository && "
                        "(inputs.pr_runner || vars.MACOS_RUNNER_15) || fromJSON(vars.RUNNER_POOLS).macos_15 }}")
        self.assertTrue(any(VARS_READ.search(nested_plain[s.start:s.stop]) for s in fork_operands(nested_plain)))

    def test_the_scan_allows_the_fork_owner_list_and_comparison_positions(self) -> None:
        fork = ("github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != "
                "github.repository && 'blacksmith-4vcpu-ubuntu-2404'")
        for allowed in (
            "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || " + fork
            + " || fromJSON(vars.RUNNER_POOLS).linux_4 }}",
            "${{ contains(fromJSON('[\"blacksmith-4vcpu-ubuntu-2404\",\"blacksmith-16vcpu-ubuntu-2404\"]'), "
            "fromJSON(vars.RUNNER_POOLS).linux) && fromJSON(vars.RUNNER_POOLS).linux || fromJSON(vars.RUNNER_POOLS).linux_4 }}",
            "${{ vars.LINUX_RUNNER == 'blacksmith-32vcpu-ubuntu-2404' && fromJSON(vars.RUNNER_POOLS).linux_32 || fromJSON(vars.RUNNER_POOLS).linux_8 }}",
            "${{ matrix.runner }}",
            "${{ github.event.pull_request.head.repo.full_name != github.repository && (startsWith(inputs.pr_runner, "
            "'blacksmith-') && inputs.pr_runner || 'blacksmith-6vcpu-macos-15') || fromJSON(vars.RUNNER_POOLS).macos_15 }}",
        ):
            with self.subTest(allowed=allowed):
                self.assertEqual(pins_in(allowed), [])


if __name__ == "__main__":
    sys.exit(unittest.main())
