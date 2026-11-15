#!/usr/bin/env python3
"""The Cloud carrier's link steps reach a release build's unified log.

On a production nightly (2026-11-15, 08:28-08:35Z) a Cloud test linked 8 machines over the carrier and
`log show` found no `cloud.carrier` line: the app logged its token reads at `.info`, which release builds
neither persist nor show without `--info`, and nothing logged the connect, the socket ready or a failure's
reason. Now `carrier supervise` (cmux-tui `carrier/supervise.rs`) words each link step as one bounded
`{"log":…}` line with no credential, and the app writes it under subsystem `com.cmuxterm.app.next`,
category `cloud.carrier`, at notice or error, which release builds keep:

    log show --last 10m --predicate 'subsystem == "com.cmuxterm.app.next" AND category == "cloud.carrier"'

This check refuses the shapes that hide those lines again: another subsystem or category, an info, debug
or trace call on the carrier logger, a `#if DEBUG` in the carrier file, the supervisor's `log` lines no
longer forwarded, or the supervisor no longer writing them.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextCloud/Link/CloudCarrierResolver.swift"
SUPERVISE = ROOT / "cmux-tui/crates/cmux-tui/src/carrier/supervise.rs"
WIRE = ROOT / "cmux-tui/crates/cmux-tui/src/carrier/supervise_wire.rs"

SUBSYSTEM = "com.cmuxterm.app.next"
CATEGORY = "cloud.carrier"
DECLARATION = re.compile(
    r'static let (\w+) = Logger\(subsystem: "([^"]+)", category: "([^"]+)"\)'
)
# Levels release builds keep on disk and `log show` prints without --info or --debug.
KEPT = {"notice", "error", "fault", "critical", "warning", "log"}


def carrier_logger(source: str) -> str:
    """The name of the file's `cloud.carrier` logger; fails when it has none or another subsystem."""
    found = [(name, subsystem) for name, subsystem, category in DECLARATION.findall(source) if category == CATEGORY]
    if not found:
        raise AssertionError(f"{SWIFT.name} declares no Logger with category {CATEGORY!r}")
    ((name, subsystem),) = found
    if subsystem != SUBSYSTEM:
        raise AssertionError(f"the {CATEGORY} logger's subsystem is {subsystem!r}, not {SUBSYSTEM!r}")
    return name


def levels(source: str, name: str) -> list[tuple[int, str]]:
    """Each call on the logger `name`: its line number and level."""
    calls = re.compile(rf"\b(?:Self|CloudCarrierServe)\.{re.escape(name)}\.(\w+)\(")
    return [
        (source.count("\n", 0, match.start()) + 1, match.group(1))
        for match in calls.finditer(source)
    ]


class CloudCarrierOsLogTests(unittest.TestCase):
    def setUp(self) -> None:
        self.swift = SWIFT.read_text(encoding="utf-8")
        self.name = carrier_logger(self.swift)

    def test_every_carrier_log_call_is_at_a_level_release_builds_keep(self) -> None:
        calls = levels(self.swift, self.name)
        self.assertGreaterEqual(len(calls), 5, f"too few carrier log calls: {calls}")
        dropped = [(line, level) for line, level in calls if level not in KEPT]
        self.assertEqual(
            dropped,
            [],
            "these carrier log lines are not persisted in a release build (use notice or error): "
            + ", ".join(f"{SWIFT.name}:{line} .{level}" for line, level in dropped),
        )

    def test_no_carrier_log_call_is_compiled_out(self) -> None:
        lines = [n for n, text in enumerate(self.swift.splitlines(), 1) if text.strip().startswith("#if")]
        self.assertEqual(lines, [], f"{SWIFT.name} has #if blocks at lines {lines}: carrier logs never depend on the build")

    def test_the_supervisors_log_lines_are_forwarded_at_notice(self) -> None:
        forward = re.search(
            r'if let (\w+) = object\["log"\] as\? String \{\s*(?://[^\n]*\n\s*)*'
            + rf'Self\.{re.escape(self.name)}\.(\w+)\("[^\n]*\\\(String\(\1\.prefix\(\d+\)\), privacy: \.public\)',
            self.swift,
        )
        self.assertIsNotNone(forward, f"{SWIFT.name} does not write the supervisor's `log` lines to the {CATEGORY} logger")
        self.assertIn(forward.group(2), KEPT)

    def test_the_supervisor_writes_a_log_line_per_link_step(self) -> None:
        wire = WIRE.read_text(encoding="utf-8")
        supervise = SUPERVISE.read_text(encoding="utf-8")
        self.assertTrue("pub(crate) fn log_line(" in wire, f"{WIRE.name} has no log_line")
        self.assertTrue("(self.out)(wire::log_line(text))" in supervise, f"{SUPERVISE.name} writes no log line")
        for step in ("connect {waiter}", "socket ready for connect", "failed: {}", "started", "exited with code", "refused: {}"):
            self.assertTrue(step in supervise, f"{SUPERVISE.name} no longer logs the {step!r} step")

    def test_the_checker_refuses_an_info_line_and_another_category(self) -> None:
        info = 'static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.carrier")\nSelf.log.info("x")\n'
        self.assertEqual(levels(info, carrier_logger(info)), [(2, "info")])
        with self.assertRaises(AssertionError):
            carrier_logger('static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")')
        with self.assertRaises(AssertionError):
            carrier_logger('static let log = Logger(subsystem: "com.example", category: "cloud.carrier")')


if __name__ == "__main__":
    unittest.main()
