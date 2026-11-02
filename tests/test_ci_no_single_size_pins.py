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

- the fork pull request branch, `head.repo.full_name != github.repository [&& !contains(...)] && '<label>'`:
  a fork's pull_request run gets no repository variables, so fromJSON(vars.RUNNER_POOLS) cannot be read there;
- the owner branch, `github.repository_owner != 'manaflow-ai' && '<label>'`, which never runs in manaflow-ai;
- a membership list, `fromJSON('[...]')`, and a comparison or function argument (`== '<label>'`,
  `contains(x, '<label>')`): checks, not routes.

A bare (unquoted) Blacksmith label in a selection is always a pin. Workflow-dispatch input defaults are dispatch
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
COMPARED = re.compile(r"(?:[!=]=|,|\()\s*$")


def pins_in(value: str) -> list[str]:
    """The single-size Blacksmith labels `value` routes to, outside the allowed positions."""
    text = value.strip()
    if not text.startswith("${{"):
        return LABEL.findall(text) if LABEL.fullmatch(text.strip("'\"")) else []
    found = []
    for match in QUOTED.finditer(text):
        before = text[: match.start()]
        if FORK.search(before) or OWNER.search(before) or LIST_OPEN.search(before) or COMPARED.search(before):
            continue
        found.append(match.group(1))
    return found


def selections(node, path=()):
    """(path, string) for every string under a runner-selection key, list items and nested matrices included."""
    if isinstance(node, dict):
        for key, child in node.items():
            here = path + (str(key),)
            if isinstance(key, str) and KEY.match(key) and "inputs" not in path[-2:-1]:
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
        for path, value in selections(document.get("jobs", {}), ("jobs",)):
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
        ):
            with self.subTest(pin=pin):
                self.assertTrue(pins_in(pin))

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
        ):
            with self.subTest(allowed=allowed):
                self.assertEqual(pins_in(allowed), [])


if __name__ == "__main__":
    sys.exit(unittest.main())
