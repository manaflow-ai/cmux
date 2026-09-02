#!/usr/bin/env python3
"""Executable regression coverage for the cmux-browser skill contract.

The repository guard tokenizes the shell examples and, when available, runs
the real ``cmux browser --help`` command. These tests keep the guard honest by
proving that the historical unscoped forms fail validation while their
surface-scoped aliases pass. They do not depend on a live browser or expose
any user's browser state.
"""

from __future__ import annotations

import contextlib
import io
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


def test_old_unscoped_forms_are_rejected(validator: ModuleType) -> None:
    browser = "cmux browser "
    fixture = [
        browser + "tab list",
        browser + "url",
        browser + "snapshot -i",
        browser + "list",
        browser + "dialog accept",
        browser + "addinitscript script",
        browser + "addscript script",
        browser + "addstyle css",
        browser + "screencast start",
    ]
    examples = [
        validator.ShellExample(Path("stale-fixture.md"), line, text)
        for line, text in enumerate(fixture, start=1)
    ]
    commands, parse_errors = validator.browser_commands(examples)
    if parse_errors:
        raise AssertionError(f"fixture parser failed: {parse_errors}")
    errors = [error for command in commands for error in validator.validate_command(command)]
    if len(errors) != len(fixture):
        raise AssertionError(f"expected every stale form to fail, got {errors}")
    surface_errors = errors[:3] + errors[4:]
    if not all("explicit" in error and "surface" in error for error in surface_errors):
        raise AssertionError(f"surface omissions were not diagnosed: {errors}")
    if "unsupported browser verb 'list'" not in errors[3]:
        raise AssertionError(f"stale list verb was not diagnosed: {errors}")


def test_explicitly_global_verbs_are_allowed_without_surface(validator: ModuleType) -> None:
    fixture = [
        "cmux browser identify --json",
        "cmux browser devtools toggle",
        "cmux browser design-mode status",
        "cmux browser zoom in",
        "cmux browser history clear --force",
        "cmux browser react-grab toggle",
        "cmux browser open https://example.test",
        "cmux browser profiles list",
        "cmux browser import --non-interactive",
    ]
    examples = [
        validator.ShellExample(Path("global-fixture.md"), line, text)
        for line, text in enumerate(fixture, start=1)
    ]
    commands, parse_errors = validator.browser_commands(examples)
    if parse_errors:
        raise AssertionError(f"global fixture parser failed: {parse_errors}")
    errors = [error for command in commands for error in validator.validate_command(command)]
    if errors:
        raise AssertionError(f"explicitly global browser verbs were rejected: {errors}")


def test_scoped_aliases_are_accepted(validator: ModuleType) -> None:
    fixture = [
        "cmux browser --surface surface:1 get url",
        "cmux browser surface:1 get-url",
        "cmux browser surface:1 snapshot -i",
        "cmux browser --surface surface:1 tab list",
    ]
    examples = [
        validator.ShellExample(Path("scoped-fixture.md"), line, text)
        for line, text in enumerate(fixture, start=1)
    ]
    commands, parse_errors = validator.browser_commands(examples)
    if parse_errors:
        raise AssertionError(f"fixture parser failed: {parse_errors}")
    errors = [error for command in commands for error in validator.validate_command(command)]
    if errors:
        raise AssertionError(f"surface-scoped aliases were rejected: {errors}")


def test_nested_commands_are_checked(validator: ModuleType) -> None:
    browser = "cmux browser "
    fixture = [
        'URL="$(' + browser + 'url)"',
        'TABS="$(' + browser + 'tab list)"',
        'NESTED="$(printf "%s" "$(' + browser + 'snapshot -i)")"',
        'QUOTED="$(printf \'%s\' \'x\\\' "$(' + browser + 'url)")"',
    ]
    examples = [
        validator.ShellExample(Path("nested-fixture.md"), line, text)
        for line, text in enumerate(fixture, start=1)
    ]
    commands, parse_errors = validator.browser_commands(examples)
    if parse_errors:
        raise AssertionError(f"nested fixture parser failed: {parse_errors}")
    errors = [error for command in commands for error in validator.validate_command(command)]
    if len(errors) != 4 or not all("explicit" in error for error in errors):
        raise AssertionError(f"nested unscoped commands were not rejected: {errors}")


def test_literal_substitution_text_is_ignored(validator: ModuleType) -> None:
    browser = "cmux browser "
    fixture = [
        "MESSAGE='$(" + browser + "url)'",
        "MESSAGE=\\$(" + browser + "tab list)",
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
        browser + "goto https://example.test;" + browser + "--surface surface:1 get url",
        browser + "snapshot -i&&" + browser + "--surface surface:1 get title",
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
        raise AssertionError(f"adjacent operators allowed a later surface to scope an earlier command: {errors}")


def test_unterminated_substitutions_fail_closed(validator: ModuleType) -> None:
    browser = "cmux browser "
    fixture = [
        'URL="$(' + browser + 'url"',
        'URL=`' + browser + 'tab list',
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
    fixture = "````bash\ncmux browser --surface surface:1 get url\n```\n"
    fixture += "cmux browser --surface surface:1 snapshot --interactive\n````\n"
    blocks = list(validator._fenced_shell_blocks(Path("fence-fixture.md"), fixture))
    if len(blocks) != 1 or "snapshot --interactive" not in blocks[0][1]:
        raise AssertionError(f"longer fence was closed before its matching fence: {blocks}")


def test_templates_require_a_surface() -> None:
    templates = sorted((ROOT / "skills" / "cmux-browser" / "templates").glob("*.sh"))
    if not templates:
        raise AssertionError("cmux-browser template directory contains no shell templates")
    for template in templates:
        environment = dict(os.environ)
        environment.pop("CMUX_SURFACE_ID", None)
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
                f"{template} accepted a missing surface: "
                f"status={result.returncode} stderr={result.stderr!r}"
            )


def test_live_help_when_available(validator: ModuleType) -> None:
    cli = validator.resolve_cli(os.environ.get("CMUX_CLI_BIN"))
    if not cli:
        return
    help_text, error = validator.live_help(cli)
    if error or help_text is None:
        raise AssertionError(error or "cmux browser --help returned no output")
    errors = validator.validate_repository(ROOT, help_text=help_text)
    if errors:
        raise AssertionError("live help contract failed:\n- " + "\n- ".join(errors))


def test_cli_flags_are_mutually_exclusive(validator: ModuleType) -> None:
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        result = validator.main(["--no-cli", "--require-cli"])
    if result == 0 or "mutually exclusive" not in output.getvalue():
        raise AssertionError("--no-cli and --require-cli must not silently pass together")


def main() -> int:
    validator = load_validator()
    tests = [
        lambda: test_repository_contract(validator),
        lambda: test_old_unscoped_forms_are_rejected(validator),
        lambda: test_explicitly_global_verbs_are_allowed_without_surface(validator),
        lambda: test_scoped_aliases_are_accepted(validator),
        lambda: test_nested_commands_are_checked(validator),
        lambda: test_literal_substitution_text_is_ignored(validator),
        lambda: test_adjacent_shell_operators_do_not_cross_scope(validator),
        lambda: test_unterminated_substitutions_fail_closed(validator),
        lambda: test_longer_markdown_fences_are_not_closed_early(validator),
        test_templates_require_a_surface,
        lambda: test_live_help_when_available(validator),
        lambda: test_cli_flags_are_mutually_exclusive(validator),
    ]
    for test in tests:
        test()
    print(f"PASS: {len(tests)} cmux-browser skill contract tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
