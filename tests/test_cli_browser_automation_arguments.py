#!/usr/bin/env python3
"""Pure regressions for browser automation CLI argument admission."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def member(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise ValueError(f"unterminated member: {signature}")


def fixture_source() -> str:
    source = (ROOT / "CLI/cmux.swift").read_text()
    helpers = [
        member(source, "    func parseOption("),
        member(source, "    func browserCommandArguments("),
        member(source, "    func rejectBrowserCommandExtras("),
        member(source, "    func validateBrowserCommandArguments("),
    ]
    return """
import Foundation

struct Fixture {
""" + "\n".join(helpers) + r"""
    func run(
        _ values: [String],
        valueOptions: Set<String>,
        allowedFlags: Set<String>,
        maxPositionals: Int
    ) throws -> [String: Any] {
        try validateBrowserCommandArguments(
            values,
            valueOptions: valueOptions,
            allowedFlags: allowedFlags,
            commandName: "browser test"
        )
        var remaining = values
        for option in valueOptions.sorted() {
            let (_, next) = parseOption(remaining, name: option)
            remaining = next
        }
        let parsed = try browserCommandArguments(
            remaining,
            allowedFlags: allowedFlags,
            commandName: "browser test"
        )
        try rejectBrowserCommandExtras(
            parsed.positionals.dropFirst(maxPositionals),
            commandName: "browser test"
        )
        return [
            "positionals": parsed.positionals,
            "flags": parsed.flags.sorted(),
        ]
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let valueOptions = Set(args[0].split(separator: ",").map(String.init).filter { !$0.isEmpty })
let allowedFlags = Set(args[1].split(separator: ",").map(String.init).filter { !$0.isEmpty })
let maxPositionals = Int(args[2])!
let values = Array(args.dropFirst(3))
var outcome: [String: Any] = [:]
do {
    outcome = try Fixture().run(
        values,
        valueOptions: valueOptions,
        allowedFlags: allowedFlags,
        maxPositionals: maxPositionals
    )
} catch {
    outcome["error"] = String(describing: error)
}
let data = try JSONSerialization.data(withJSONObject: outcome, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
"""


class BrowserAutomationArgumentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.scratch = tempfile.TemporaryDirectory(prefix="browser-arguments-", dir=ROOT)
        cls.addClassCleanup(cls.scratch.cleanup)
        main = Path(cls.scratch.name, "main.swift")
        main.write_text(fixture_source())
        cls.binary = Path(cls.scratch.name, "fixture")
        compiled = subprocess.run([
            "swiftc", "-swift-version", "6", str(ROOT / "CLI/CLIError.swift"),
            str(main), "-o", str(cls.binary),
        ], capture_output=True, text=True, timeout=120)
        if compiled.returncode:
            raise RuntimeError(compiled.stderr)

    def run_parser(
        self,
        values: list[str],
        *,
        value_options: tuple[str, ...] = (),
        allowed_flags: tuple[str, ...] = (),
        max_positionals: int = 0,
    ) -> dict:
        result = subprocess.run(
            [
                str(self.binary),
                ",".join(value_options),
                ",".join(allowed_flags),
                str(max_positionals),
                *values,
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return json.loads(result.stdout)

    def test_unknown_flags_are_rejected(self) -> None:
        cases = (
            (["--selector", "#submit", "--typo"], ("--selector",), (), 0),
            (["Save", "--typo"], (), ("--exact",), 1),
            (["--force", "--typo"], (), ("--force", "--yes"), 1),
            (["--from", "chrome", "--typo"], ("--from",), (), 0),
        )
        for values, options, flags, maximum in cases:
            with self.subTest(values=values):
                outcome = self.run_parser(
                    values,
                    value_options=options,
                    allowed_flags=flags,
                    max_positionals=maximum,
                )
                self.assertIn("error", outcome)
                self.assertIn("--typo", outcome["error"])

    def test_missing_option_values_are_rejected(self) -> None:
        for values in (["--selector"], ["--selector", "--snapshot-after"], ["--selector="]):
            with self.subTest(values=values):
                outcome = self.run_parser(
                    values,
                    value_options=("--selector",),
                    allowed_flags=("--snapshot-after",),
                    max_positionals=1,
                )
                self.assertIn("error", outcome)
                self.assertIn("requires a value", outcome["error"])

    def test_extra_positionals_are_rejected(self) -> None:
        for values, maximum in (
            (["#ready", "unexpected"], 1),
            (["Enter", "unexpected"], 1),
            (["#country", "us", "extra"], 2),
        ):
            with self.subTest(values=values):
                outcome = self.run_parser(values, max_positionals=maximum)
                self.assertIn("error", outcome)
                self.assertIn("unexpected", outcome["error"])

    def test_terminator_preserves_literal_option_like_values(self) -> None:
        outcome = self.run_parser(
            ["--", "--snapshot-after"],
            allowed_flags=("--snapshot-after",),
            max_positionals=1,
        )
        self.assertNotIn("error", outcome)
        self.assertEqual(outcome["positionals"], ["--snapshot-after"])
        self.assertEqual(outcome["flags"], [])

    def test_documented_option_and_equals_forms_remain_valid(self) -> None:
        for values in (["--selector", "#submit"], ["--selector=#submit"]):
            with self.subTest(values=values):
                outcome = self.run_parser(
                    values,
                    value_options=("--selector",),
                    max_positionals=0,
                )
                self.assertNotIn("error", outcome)


if __name__ == "__main__":
    unittest.main(verbosity=2)
