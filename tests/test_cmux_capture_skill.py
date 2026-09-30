#!/usr/bin/env python3
"""Tie the cmux-capture skill to the code it describes.

The reference page documents flags, response fields, recording states and
error codes. Each of those lives in Swift, and a doc that drifts from it sends
an agent after a field that no longer exists. These checks read both sides and
compare them; they need no build and no running app.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
REFERENCE = ROOT / "skills" / "cmux-capture" / "references" / "commands.md"
SKILL = ROOT / "skills" / "cmux-capture" / "SKILL.md"
CLAUDE_SKILL = ROOT / ".claude" / "skills" / "cmux-capture"
RECORD_CLI = ROOT / "CLI" / "CMUXCLI+Record.swift"
SHOT_CLI = ROOT / "CLI" / "CMUXCLI+Screenshot.swift"
TASK_HELP = ROOT / "CLI" / "CMUXCLI+TaskHelp.swift"
SESSION = ROOT / "Sources" / "WindowRecordingSession.swift"
SHOT_METHOD = ROOT / "Sources" / "TerminalController+WindowScreenshotMethod.swift"
RECORD_METHOD = ROOT / "Sources" / "TerminalController+WindowRecording.swift"
FOUNDATION = ROOT / "Packages" / "macOS" / "CmuxFoundation" / "Sources" / "CmuxFoundation"
SHOT_REQUEST = FOUNDATION / "WindowCapture" / "WindowScreenshotRequest.swift"
RECORD_REQUEST = FOUNDATION / "WindowRecording" / "WindowRecordingRequest.swift"
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-skill-contract.yml"

# Every Swift file these checks read. The workflow has to run them when one of
# these changes, or a doc claim outlives the code it describes.
WATCHED = (
    RECORD_CLI,
    SHOT_CLI,
    TASK_HELP,
    SESSION,
    SHOT_METHOD,
    RECORD_METHOD,
    SHOT_REQUEST,
    RECORD_REQUEST,
)

FLAG = re.compile(r"--[a-z][a-z-]*")
SECTION = re.compile(r"^## (.+)$", re.MULTILINE)
CONSTANT = re.compile(
    r"public static let (?P<name>\w+)(?:\s*:\s*\w+)?\s*="
    r"\s*(?P<value>[\d_]+(?:\.\d+)?(?:\s*\.\.\.\s*[\d_]+(?:\.\d+)?)?)"
)


def constants(path: Path) -> dict[str, str]:
    """Every `public static let name = <number or range>` in one file."""
    return {
        match.group("name"): match.group("value")
        for match in CONSTANT.finditer(path.read_text(encoding="utf-8"))
    }


def number(text: str) -> float:
    return float(text.replace("_", "").strip())


def bounds(text: str) -> tuple[float, float]:
    lower, _, upper = text.partition("...")
    return number(lower), number(upper)


def spellings(value: float) -> tuple[str, ...]:
    """How prose may write one limit: 120 and 120.0 are the same bound."""
    if value == int(value):
        return (str(int(value)), f"{int(value)}.0")
    return (f"{value:g}",)


def quotes(text: str, value: float) -> bool:
    """Whether `text` states this number, not a longer one containing it."""
    return any(
        re.search(rf"(?<![\d.]){re.escape(form)}(?![\d.])", text)
        for form in spellings(value)
    )


def reference_text() -> str:
    return REFERENCE.read_text(encoding="utf-8")


def section(name: str, text: str) -> str:
    """The body of one `## name` section."""
    matches = list(SECTION.finditer(text))
    for index, match in enumerate(matches):
        if match.group(1) != name:
            continue
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        return text[match.end():end]
    raise AssertionError(f"{REFERENCE.name} has no '## {name}' section")


def fenced_block(body: str) -> str:
    start = body.index("```") + 3
    return body[start:body.index("```", start)]


def backticked(body: str) -> set[str]:
    return set(re.findall(r"`([^`]+)`", body))


class CaptureSkillTests(unittest.TestCase):
    def test_documented_flags_exist_in_the_cli_help(self) -> None:
        text = reference_text()
        for name, cli in (("Screenshot", SHOT_CLI), ("Recording", RECORD_CLI)):
            documented = set(FLAG.findall(fenced_block(section(name, text))))
            help_text = cli.read_text(encoding="utf-8")
            missing = sorted(flag for flag in documented if flag not in help_text)
            self.assertEqual([], missing, f"{name}: flags documented but not in {cli.name}")

    def test_limits_table_names_only_real_flags(self) -> None:
        text = reference_text()
        both = SHOT_CLI.read_text(encoding="utf-8") + RECORD_CLI.read_text(encoding="utf-8")
        documented = set(FLAG.findall(section("Limits", text)))
        missing = sorted(flag for flag in documented if flag not in both)
        self.assertEqual([], missing, "limits table names flags no command takes")

    def test_documented_recording_states_match_the_enum(self) -> None:
        source = SESSION.read_text(encoding="utf-8")
        body = source[source.index("enum State: String"):]
        cases = set(re.findall(r"^\s*case ([a-z]+)$", body[:body.index("}")], re.MULTILINE))
        row = [
            line for line in section("Recording", reference_text()).splitlines()
            if line.startswith("| `id`, `state` |")
        ]
        self.assertEqual(1, len(row), "the status table lost its state row")
        documented = backticked(row[0]) - {"id", "state"}
        self.assertEqual(cases, documented, "documented states differ from WindowRecordingStatus.State")

    def test_documented_screenshot_formats_match_the_enum(self) -> None:
        body = SHOT_REQUEST.read_text(encoding="utf-8")
        body = body[body.index("public enum Format: String"):]
        cases = set(re.findall(r"^\s*case ([a-z]+)$", body[:body.index("/// Extensions")], re.MULTILINE))
        row = [
            line for line in section("Screenshot", reference_text()).splitlines()
            if line.startswith("| `format` |")
        ]
        self.assertEqual(1, len(row), "the screenshot table lost its format row")
        # The row also names the file extension a jpeg gets, which is not a
        # format value, so only the values before the semicolon are compared.
        documented = backticked(row[0].split(";")[0]) - {"format"}
        self.assertEqual(cases, documented, "documented formats differ from WindowScreenshotRequest.Format")

    def test_documented_response_fields_are_emitted(self) -> None:
        text = reference_text()
        for name, source, extra in (
            ("Screenshot", SHOT_METHOD, set()),
            # `seconds` and `max_seconds` are written with a computed value, so
            # their keys are matched from the payload literal the same way.
            ("Recording", SESSION, set()),
        ):
            emitted = set(re.findall(r'payload\["([a-z_]+)"\]', source.read_text(encoding="utf-8")))
            emitted |= set(re.findall(r'^\s+"([a-z_]+)":', source.read_text(encoding="utf-8"), re.MULTILINE))
            emitted |= extra
            rows = [
                line for line in section(name, text).splitlines()
                if line.startswith("| `") and " | " in line
            ]
            documented: set[str] = set()
            for row in rows:
                documented |= backticked(row.split("|")[1])
            missing = sorted(field for field in documented if field not in emitted)
            self.assertEqual([], missing, f"{name}: fields documented but never put in the response")

    def test_documented_error_codes_are_returned(self) -> None:
        returned = set()
        for source, mapper in (
            (SHOT_METHOD, "nonisolated static func screenshotErrorCode"),
            (RECORD_METHOD, "nonisolated static func recordingErrorCode"),
        ):
            body = source.read_text(encoding="utf-8")
            returned |= set(re.findall(r'return "([a-z_]+)"', body[body.index(mapper):]))
            if 'code: "timeout"' in body:
                returned.add("timeout")
        rows = [
            line for line in section("Error codes", reference_text()).splitlines()
            if line.startswith("| `")
        ]
        documented = {row.split("|")[1].strip().strip("`") for row in rows}
        self.assertEqual(returned, documented, "documented socket error codes differ from implementation")

    def test_unknown_record_subcommand_is_documented_as_a_local_cli_error(self) -> None:
        reference = section("Error codes", reference_text())
        self.assertIn("unknown `cmux record` subcommand", reference)
        self.assertIn("`CLIError`", reference)

        source = RECORD_CLI.read_text(encoding="utf-8")
        unknown_case = source[source.index("default:", source.index("func runRecord")):]
        self.assertIn("throw CLIError", unknown_case)
        self.assertIn("record: unknown subcommand", unknown_case)

    def test_top_level_help_advertises_capture_commands(self) -> None:
        source = TASK_HELP.read_text(encoding="utf-8")
        inspect_help = source[source.index("private var inspectCommandsHelp"):]
        inspect_help = inspect_help[:inspect_help.index("private var customizeCommandsHelp")]
        self.assertIn("Self.recordUsageLine", inspect_help)
        self.assertIn("Self.shotUsageLine", inspect_help)

        customize_help = source[source.index("private var customizeCommandsHelp"):]
        customize_help = customize_help[:customize_help.index("private var automationCommandsHelp")]
        self.assertIn("docs [settings|shortcuts|api|browser|capture|agents|dock|sidebars]", customize_help)

    def test_region_limits_match_the_constants(self) -> None:
        """The documented region bounds are the ones the code enforces."""
        record = constants(RECORD_REQUEST)
        # Joined, because a bound can land either side of a line wrap.
        region = " ".join(section("Region", reference_text()).split())
        minimum = number(record["minimumRegionExtent"])
        maximum = number(record["maximumRegionExtent"])
        self.assertIn(f"at least {minimum:g} points", region)
        self.assertTrue(
            quotes(region, maximum),
            f"the Region section does not state the {maximum:g} point ceiling",
        )

    def test_documented_limits_are_the_enforced_ones(self) -> None:
        """Every number in the Limits table comes out of a Swift constant.

        The drift this catches: `--max-width` is 64 to 4096, but a gif stops at
        `gifMaximumWidth`, and the table said 4096 for both. An agent reading
        the doc asked for a width the app refuses, and the two gif budgets that
        have no flag of their own were not written down at all.
        """
        record = constants(RECORD_REQUEST)
        shot = constants(SHOT_REQUEST)
        limits = " ".join(section("Limits", reference_text()).split())

        ranged = [
            (record, "allowedFramesPerSecond"),
            (record, "allowedSeconds"),
            (record, "allowedScale"),
            (record, "allowedMaximumWidth"),
            (shot, "allowedMaximumWidth"),
            (shot, "allowedScale"),
        ]
        single = [
            (record, "gifMaximumWidth"),
            (record, "gifMaximumFrames"),
            (record, "gifMaximumPixelsPerFrame"),
        ]

        for source, name in ranged:
            lower, upper = bounds(source[name])
            for value in (lower, upper):
                self.assertTrue(
                    quotes(limits, value),
                    f"{name} allows {value:g}, which the Limits section never states",
                )
        for source, name in single:
            value = number(source[name])
            self.assertTrue(
                quotes(limits, value),
                f"{name} is {value:g}, which the Limits section never states",
            )

    def test_both_requests_agree_on_the_region_bounds(self) -> None:
        """One documented region rule, so the two commands cannot diverge."""
        record = constants(RECORD_REQUEST)
        shot = constants(SHOT_REQUEST)
        for name in ("minimumRegionExtent", "maximumRegionExtent"):
            self.assertEqual(
                number(record[name]),
                number(shot[name]),
                f"{name} differs between shot and record; the doc states one",
            )

    def test_relative_links_and_their_anchors_resolve(self) -> None:
        """A link in either page points at a file, and at a heading that exists.

        The forward reference this catches: the skill linked
        `dogfood-scenarios.md#record-a-clip` while the heading was still in an
        unmerged branch, so the link landed on main pointing at nothing.
        """
        for page in (SKILL, REFERENCE):
            text = page.read_text(encoding="utf-8")
            for target in re.findall(r"\]\((?!https?:|mailto:)([^)]+)\)", text):
                path, _, fragment = target.partition("#")
                resolved = (page.parent / path).resolve() if path else page
                self.assertTrue(resolved.is_file(), f"{page.name} links to missing {target}")
                if not fragment:
                    continue
                headings = {
                    re.sub(r"[^a-z0-9]+", "-", line.lstrip("#").strip().lower()).strip("-")
                    for line in resolved.read_text(encoding="utf-8").splitlines()
                    if line.startswith("#")
                }
                self.assertIn(fragment, headings, f"{page.name}: no '{fragment}' in {path}")

    def test_the_workflow_runs_this_guard_when_its_sources_change(self) -> None:
        triggers = WORKFLOW.read_text(encoding="utf-8")
        missing = [
            str(path.relative_to(ROOT))
            for path in WATCHED
            if f'"{path.relative_to(ROOT)}"' not in triggers
        ]
        self.assertEqual([], missing, "sources this guard reads are missing from the triggers")

    def test_skill_points_at_its_reference(self) -> None:
        self.assertIn("references/commands.md", SKILL.read_text(encoding="utf-8"))

    def test_claude_discovers_the_canonical_capture_skill(self) -> None:
        self.assertTrue(CLAUDE_SKILL.is_symlink())
        self.assertEqual(SKILL.parent.resolve(), CLAUDE_SKILL.resolve())


if __name__ == "__main__":
    unittest.main()
