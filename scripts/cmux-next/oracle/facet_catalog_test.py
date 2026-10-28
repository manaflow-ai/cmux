#!/usr/bin/env python3
"""The App's facet catalog agrees with the snapshot schema (p15-oracle-030).

`OracleFacet` (Packages/macOS/CmuxNext/Sources/CmuxNextOracle/OracleFacet.swift) names the facets
`debug.oracle.snapshot` answers and the task that writes each provider; a facet with no provider
answers not-comparable with that task. The schema (schemas/oracle/snapshot-v1.schema.json) names the
same facets under `x-oracle-source.method == "debug.oracle.snapshot"` (plus `topology`, which a
provider also gives in the oracle's one cut) and the same tasks. This test keeps the two equal, so a
facet added to one side and not the other fails here, not in a diff run.

Run: python3 -I scripts/cmux-next/oracle/facet_catalog_test.py (stdlib unittest).
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SWIFT = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextOracle/OracleFacet.swift"
SCHEMA = ROOT / "schemas/oracle/snapshot-v1.schema.json"
# Facets the runner reads from another method, never from the app's oracle list (cli, mcp and reply: the step's receipt;
# tui: the frontend's PTY, driver_tui.py).
RUNNER_ONLY = {"daemon", "cli", "mcp", "reply", "tui"}


def swift_catalog(text: str) -> tuple[list[str], dict[str, str]]:
    """The enum's cases in declaration order and each case's task from the `task` switch."""
    body = text[text.index("enum OracleFacet"):]
    cases: list[str] = []
    for line in body[: body.index("public var task")].splitlines():
        match = re.match(r"\s*case\s+([a-zA-Z]+)\s*$", line)
        if match:
            cases.append(match.group(1))
    tasks: dict[str, str] = {}
    switch = body[body.index("public var task"):]
    for match in re.finditer(r'case\s+([^:]+):\s*"([^"]+)"', switch):
        for name in match.group(1).split(","):
            tasks[name.strip().lstrip(".")] = match.group(2)
    return cases, tasks


class FacetCatalogTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cases, cls.tasks = swift_catalog(SWIFT.read_text(encoding="utf-8"))
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        cls.facets = schema["properties"]["facets"]["properties"]

    def test_the_enum_has_the_schema_facets_in_schema_order(self) -> None:
        expected = [name for name in self.facets if name not in RUNNER_ONLY]
        self.assertEqual(self.cases, expected)

    def test_every_case_has_the_schema_task(self) -> None:
        self.assertEqual(set(self.tasks), set(self.cases), "every case needs exactly one task")
        for name in self.cases:
            with self.subTest(facet=name):
                self.assertEqual(self.tasks[name], self.facets[name]["x-oracle-source"]["task"])

    def test_app_facets_name_the_oracle_method(self) -> None:
        for name in self.cases:
            method = self.facets[name]["x-oracle-source"]["method"]
            if name == "topology":
                # The whole snapshot.get result; its provider (task 033) gives it in the oracle's cut too.
                self.assertEqual(method, "snapshot.get")
                continue
            with self.subTest(facet=name):
                self.assertEqual(method, "debug.oracle.snapshot")

    def test_the_parser_reads_a_multi_case_row(self) -> None:
        cases, tasks = swift_catalog(
            'public enum OracleFacet: String {\n    case a\n    case b\n'
            '    public var task: String {\n        switch self {\n'
            '        case .a, .b: "p15-oracle-001"\n        }\n    }\n}\n'
        )
        self.assertEqual(cases, ["a", "b"])
        self.assertEqual(tasks, {"a": "p15-oracle-001", "b": "p15-oracle-001"})


if __name__ == "__main__":
    unittest.main()
