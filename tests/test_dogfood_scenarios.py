#!/usr/bin/env python3
"""Check dogfood tours and the step reference against the step decoder.

A tour is read at run time by cmuxUITests/DogfoodScenarioUITests.swift, so a
typo in one is only found after a CI run that takes tens of minutes. These
checks find it in a second, and they keep the reference table and the recording
options in the skill honest about what the decoder accepts.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "cmuxUITests/DogfoodScenarioUITests.swift"
REQUEST = ROOT / ("Packages/macOS/CmuxFoundation/Sources/CmuxFoundation"
                  "/WindowRecording/WindowRecordingRequest.swift")
REFERENCE = ROOT / "skills/cmux-testing/references/dogfood-scenarios.md"
SCENARIOS = sorted((ROOT / "dogfood/scenarios").glob("*.json"))


def swift_declaration_body(source: str, declaration: str) -> str:
    """The bracketed body of a Swift `let name: ... = [ ... ]` declaration."""
    match = re.search(re.escape(declaration) + r"\s*=\s*\[(.*?)\]", source, re.DOTALL)
    assert match, f"{declaration} is no longer declared the way this test reads it"
    return match.group(1)


def swift_string_set(source: str, declaration: str) -> set[str]:
    """The string literals of a Swift `let name: ... = [ ... ]` declaration."""
    return set(re.findall(r'"([^"]+)"', swift_declaration_body(source, declaration)))


class DecoderFacts:
    source = RUNNER.read_text()
    kinds = swift_string_set(source, "private static let kinds: Set<String>")
    # The option map is "tourName": "socket_name" pairs; the tour names are the
    # keys, which are the odd entries of the flattened literal list.
    record_option_pairs = re.findall(
        r'"([A-Za-z_]+)":\s*"([a-z_]+)"',
        swift_declaration_body(source, "private static let recordOptions: [String: String]"),
    )
    record_options = {tour for tour, _ in record_option_pairs}


class ReferenceTests(unittest.TestCase):
    def test_every_step_the_decoder_accepts_is_in_the_reference_table(self):
        text = REFERENCE.read_text()
        # A row names its step as `{"click": target}` and its aliases as bare
        # `doubleClick`, so both spellings count as documented.
        documented = set(re.findall(r'`\{"(\w+)"', text)) | set(re.findall(r"`(\w+)`", text))
        missing = DecoderFacts.kinds - documented
        self.assertEqual(missing, set(),
                         f"undocumented steps in {REFERENCE.name}: {sorted(missing)}")

    def test_the_reference_does_not_promise_a_step_the_decoder_refuses(self):
        table = [line for line in REFERENCE.read_text().splitlines() if line.startswith("| `{")]
        promised = {kind for line in table for kind in re.findall(r'`\{"(\w+)"', line)}
        unknown = promised - DecoderFacts.kinds
        self.assertEqual(unknown, set(), f"documented but not decoded: {sorted(unknown)}")

    def test_every_recording_option_is_documented(self):
        text = REFERENCE.read_text()
        for option in sorted(DecoderFacts.record_options):
            self.assertIn(f"`{option}`", text, f"{option} is accepted but not documented")

    def test_every_recording_option_names_a_parameter_the_app_reads(self):
        """The socket side of the map, which the reference cannot vouch for.

        A tour option is only useful if the name it is translated into is one
        `WindowRecordingRequest.make` looks up, and a typo there is silent: an
        unknown key is simply ignored, so the recording runs with the default
        and the tour passes while doing the wrong thing.
        """
        request = REQUEST.read_text()
        read = set(re.findall(r'params\["([a-z_]+)"\]', request))
        for tour, socket in sorted(DecoderFacts.record_option_pairs):
            self.assertIn(socket, read,
                          f"{tour} is sent as {socket!r}, which {REQUEST.name} never reads")


class ScenarioTests(unittest.TestCase):
    def test_there_are_scenarios_to_check(self):
        self.assertTrue(SCENARIOS, "dogfood/scenarios holds the reusable tours")

    def test_every_scenario_only_uses_steps_the_decoder_accepts(self):
        for path in SCENARIOS:
            with self.subTest(scenario=path.name):
                check_scenario(json.loads(path.read_text()))


def check_scenario(tour: object) -> None:
    steps = tour if isinstance(tour, list) else (tour or {}).get("steps")
    if not isinstance(steps, list) or not steps:
        raise AssertionError("a tour is a steps array or an object with a steps array")
    if isinstance(tour, dict):
        unknown = set(tour) - {"steps", "launch", "paths"}
        if unknown:
            raise AssertionError(f"unknown top level keys: {sorted(unknown)}")
        paths = tour.get("paths", [])
        if not isinstance(paths, list) or not all(
            isinstance(pattern, str) and pattern.strip() for pattern in paths
        ):
            raise AssertionError("paths is a list of non-empty path patterns")
    check_steps(steps, inside_record=False)


def check_steps(steps: list, inside_record: bool) -> None:
    for index, step in enumerate(steps, start=1):
        if not isinstance(step, dict):
            raise AssertionError(f"step {index} is not an object")
        kinds = DecoderFacts.kinds & set(step)
        if len(kinds) != 1:
            raise AssertionError(
                f"step {index} names {sorted(kinds) or 'no step'}; each step is one of "
                f"{', '.join(sorted(DecoderFacts.kinds))}"
            )
        kind = kinds.pop()
        if kind == "note" and not inside_record:
            raise AssertionError(
                f"step {index} captions a clip outside a record; a note belongs "
                "among a record's own steps"
            )
        if kind != "record":
            continue
        if inside_record:
            raise AssertionError(f"step {index} records inside a recording")
        options = set(step) - {"record", "steps"}
        unknown = options - DecoderFacts.record_options
        if unknown:
            raise AssertionError(
                f"step {index} passes unknown record options {sorted(unknown)}; "
                f"use {', '.join(sorted(DecoderFacts.record_options))}"
            )
        nested = step.get("steps")
        if not isinstance(nested, list) or not nested:
            raise AssertionError(f"step {index} records around no steps")
        check_steps(nested, inside_record=True)


if __name__ == "__main__":
    unittest.main()
