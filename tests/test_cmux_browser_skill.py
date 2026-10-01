#!/usr/bin/env python3
"""Executable regression coverage for the cmux-browser skill contract.

The repository guard tokenizes the shell examples and checks every
``cmux browser`` invocation against the Rust CLI's grammar. These tests keep
the guard honest by proving that untargeted page verbs, the retired
``--surface``/``surface:N`` forms and unknown verbs fail validation while the
``tab_…``, ``page``, ``browser_…`` and UI-action forms pass. They do not depend
on a live browser or expose any user's browser state.
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
from pathlib import Path
from types import ModuleType


ROOT = Path(__file__).resolve().parent.parent
VALIDATOR_PATH = ROOT / "scripts" / "validate-cmux-browser-skill.py"


def load_validator() -> ModuleType:
    spec = importlib.util.spec_from_file_location("cmux_browser_skill_validator", VALIDATOR_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError(f"unable to load {VALIDATOR_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_repository_contract(validator: ModuleType) -> None:
    errors = validator.validate_repository(ROOT)
    if errors:
        raise AssertionError("repository contract failed:\n- " + "\n- ".join(errors))


def validate(validator: ModuleType, fixture: list[str]) -> list[str]:
    examples = [
        validator.ShellExample(Path("fixture.md"), line, text)
        for line, text in enumerate(fixture, start=1)
    ]
    commands, parse_errors = validator.browser_commands(examples)
    if parse_errors:
        raise AssertionError(f"fixture parser failed: {parse_errors}")
    return [error for command in commands for error in validator.validate_command(command)]


def test_untargeted_and_retired_forms_are_rejected(validator: ModuleType) -> None:
    untargeted = ["cmux browser snapshot --interactive", "cmux browser navigate https://x.test",
                  "cmux browser click e1", "cmux browser state"]
    errors = validate(validator, untargeted)
    if len(errors) != len(untargeted) or not all("explicit" in error for error in errors):
        raise AssertionError(f"untargeted page verbs were not diagnosed: {errors}")
    retired = ["cmux browser --surface surface:1 get url", "cmux browser surface:1 snapshot -i",
               "cmux browser --surface=surface:2 url"]
    errors = validate(validator, retired)
    if len(errors) != len(retired) or not all("retired" in error for error in errors):
        raise AssertionError(f"retired surface forms were not diagnosed: {errors}")


def test_unknown_verbs_and_targets_are_rejected(validator: ModuleType) -> None:
    fixture = [
        "cmux browser tab_01ab dialog accept",
        "cmux browser page get url",
        "cmux browser browser_01ab snapshot",
        "cmux browser identify --json",
        "cmux browser tab_01ab",
    ]
    errors = validate(validator, fixture)
    if len(errors) != len(fixture):
        raise AssertionError(f"expected every unknown form to fail, got {errors}")


def test_current_forms_are_accepted(validator: ModuleType) -> None:
    fixture = [
        "cmux browser --help",
        "cmux browser list",
        "cmux browser page state",
        'cmux browser "$TAB" snapshot --interactive --max-depth 4',
        "cmux browser tab_01ab fill '#q' hello",
        "cmux browser tab_01ab press Enter",
        "cmux browser page scroll '#list' --dy 300",
        "cmux --json browser tab_01ab eval 'document.title'",
        "cmux browser browser_01ab navigate --url https://x.test",
        "cmux browser browser_01ab key --key Enter",
        "cmux browser split-right",
        "cmux browser screenshot-page",
        "cmux --json tab create browser --url https://x.test",
        "cmux tab tab_01ab browser show",
    ]
    errors = validate(validator, fixture)
    if errors:
        raise AssertionError(f"current browser forms were rejected: {errors}")


def test_nested_commands_are_checked(validator: ModuleType) -> None:
    browser = "cmux browser "
    fixture = [
        'URL="$(' + browser + 'url)"',
        'SNAP="$(' + browser + 'snapshot -i)"',
        'NESTED="$(printf "%s" "$(' + browser + 'state)")"',
        'QUOTED="$(printf \'%s\' \'x\\\' "$(' + browser + 'url)")"',
    ]
    errors = validate(validator, fixture)
    if len(errors) != 4 or not all("explicit" in error for error in errors):
        raise AssertionError(f"nested untargeted commands were not rejected: {errors}")


def test_literal_substitution_text_is_ignored(validator: ModuleType) -> None:
    browser = "cmux browser "
    fixture = [
        "MESSAGE='$(" + browser + "url)'",
        "MESSAGE=\\$(" + browser + "state)",
    ]
    examples = [
        validator.ShellExample(Path("literal-substitution-fixture.md"), line, text)
        for line, text in enumerate(fixture, start=1)
    ]
    commands, parse_errors = validator.browser_commands(examples)
    if parse_errors or commands:
        raise AssertionError(
            f"literal/escaped substitution text was treated as executable: "
            f"commands={commands} errors={parse_errors}"
        )


def test_adjacent_shell_operators_do_not_cross_scope(validator: ModuleType) -> None:
    browser = "cmux browser "
    fixture = [
        browser + "goto https://example.test;" + browser + "tab_01ab state",
        browser + "snapshot -i&&" + browser + "page state",
    ]
    examples = [
        validator.ShellExample(Path("operator-fixture.md"), line, text)
        for line, text in enumerate(fixture, start=1)
    ]
    commands, parse_errors = validator.browser_commands(examples)
    if parse_errors:
        raise AssertionError(f"operator fixture parser failed: {parse_errors}")
    errors = [error for command in commands for error in validator.validate_command(command)]
    if len(errors) != 2 or not all("explicit" in error for error in errors):
        raise AssertionError(f"adjacent operators allowed a later target to scope an earlier command: {errors}")


def test_unterminated_substitutions_fail_closed(validator: ModuleType) -> None:
    browser = "cmux browser "
    fixture = [
        'URL="$(' + browser + 'url"',
        'URL=`' + browser + 'state',
    ]
    examples = [
        validator.ShellExample(Path("unterminated-fixture.md"), line, text)
        for line, text in enumerate(fixture, start=1)
    ]
    commands, parse_errors = validator.browser_commands(examples)
    if len(parse_errors) != 2 or commands:
        raise AssertionError(
            f"unterminated substitutions were not rejected: commands={commands} errors={parse_errors}"
        )


def test_longer_markdown_fences_are_not_closed_early(validator: ModuleType) -> None:
    fixture = "````bash\ncmux browser page state\n```\n"
    fixture += "cmux browser page snapshot --interactive\n````\n"
    blocks = list(validator._fenced_shell_blocks(Path("fence-fixture.md"), fixture))
    if len(blocks) != 1 or "snapshot --interactive" not in blocks[0][1]:
        raise AssertionError(f"longer fence was closed before its matching fence: {blocks}")


def test_templates_require_a_tab() -> None:
    templates = sorted((ROOT / "skills" / "cmux-browser" / "templates").glob("*.sh"))
    if not templates:
        raise AssertionError("cmux-browser template directory contains no shell templates")
    for template in templates:
        environment = dict(os.environ)
        environment.pop("CMUX_TAB_ID", None)
        result = subprocess.run(
            ["bash", str(template)],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
        if result.returncode != 2 or "Usage:" not in result.stderr:
            raise AssertionError(
                f"{template} accepted a missing tab: "
                f"status={result.returncode} stderr={result.stderr!r}"
            )


def main() -> int:
    validator = load_validator()
    tests = [
        lambda: test_repository_contract(validator),
        lambda: test_untargeted_and_retired_forms_are_rejected(validator),
        lambda: test_unknown_verbs_and_targets_are_rejected(validator),
        lambda: test_current_forms_are_accepted(validator),
        lambda: test_nested_commands_are_checked(validator),
        lambda: test_literal_substitution_text_is_ignored(validator),
        lambda: test_adjacent_shell_operators_do_not_cross_scope(validator),
        lambda: test_unterminated_substitutions_fail_closed(validator),
        lambda: test_longer_markdown_fences_are_not_closed_early(validator),
        test_templates_require_a_tab,
    ]
    for test in tests:
        test()
    print(f"PASS: {len(tests)} cmux-browser skill contract tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
