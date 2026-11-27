#!/usr/bin/env python3
"""No .github/workflows file repeats a key inside one mapping.

GitHub rejects a workflow whose mapping repeats a key, and the run fails with zero jobs and no
log. localization-fill.yml carried a second job-level `env:` in two jobs (lines 51 and 178), so
the workflow never parsed until #59784; cmuxterm-hq's harness-watch.yml repeated `environment:`
the same way (hq#30852, handbook page workflow-repeats-a-key-runs-zero-jobs.md).

The check hooks PyYAML's mapping constructor, so it sees exactly the mappings the parser builds:
block scalars, anchors, aliases and flow maps (`env: {A: 1, A: 2}`) need no special cases. Keys
compare by their source text, as GitHub's parser compares them, so `on` and `true` stay distinct.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


def duplicate_keys(text: str) -> list[tuple[int, str]]:
    found: list[tuple[int, str]] = []

    class Loader(yaml.SafeLoader):
        pass

    def construct_mapping(loader: yaml.SafeLoader, node: yaml.MappingNode, deep: bool = False):
        seen: dict[str, int] = {}
        for key_node, _ in node.value:
            if not isinstance(key_node, yaml.ScalarNode):
                continue
            line = key_node.start_mark.line + 1
            if key_node.value in seen:
                found.append((line, f"{key_node.value!r} repeats line {seen[key_node.value]}"))
            else:
                seen[key_node.value] = line
        return loader.construct_mapping(node, deep=deep)

    Loader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping)
    yaml.load(text, Loader=Loader)  # noqa: S506 - SafeLoader subclass
    return sorted(found)


def workflow_findings(root: Path = ROOT) -> list[str]:
    failures = []
    for path in sorted((root / ".github" / "workflows").glob("*.y*ml")):
        for number, why in duplicate_keys(path.read_text()):
            failures.append(f"{path.relative_to(root)}:{number}: {why}")
    return failures


class WorkflowDuplicateKeys(unittest.TestCase):
    def test_no_workflow_repeats_a_key(self) -> None:
        failures = workflow_findings()
        self.assertEqual(failures, [], "\n".join(failures))

    def test_finds_the_localization_fill_shape(self) -> None:
        text = (
            "jobs:\n  fill:\n    env:\n      A: 1\n    steps:\n      - name: x\n        run: |\n"
            "          env: not a key\n      - name: y\n    env:\n      B: 2\n"
        )
        self.assertEqual([n for n, _ in duplicate_keys(text)], [10])

    def test_finds_a_repeat_inside_a_flow_map_and_a_list_item(self) -> None:
        text = "env: {A: 1, A: 2}\nsteps:\n  - name: a\n    name: b\n"
        self.assertEqual([n for n, _ in duplicate_keys(text)], [1, 4])

    def test_quoted_and_plain_spellings_are_one_key(self) -> None:
        self.assertEqual([n for n, _ in duplicate_keys("env: 1\n'env': 2\n")], [2])

    def test_siblings_list_items_anchors_and_scalars_are_separate(self) -> None:
        text = (
            "on:\n  push:\ntrue: 1\njobs:\n  a: &job\n    env:\n      X: 1\n  b: *job\n  c:\n    env:\n"
            "      X: 1\n    if: >-\n      x\n    steps:\n      - &s\n        name: p\n"
            "      - name: q\n        with: {name: q}\n"
        )
        self.assertEqual(duplicate_keys(text), [])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
