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
    fixture = "```bash\n"
    fixture += browser + "tab list\n"
    fixture += browser + "url\n"
    fixture += browser + "snapshot -i\n"
    fixture += browser + "list\n"
    fixture += "```\n"
    examples = [
        validator.ShellExample(Path("stale-fixture.md"), line, text)
        for line, text in enumerate(fixture.splitlines(), start=1)
    ]
    commands, parse_errors = validator.browser_commands(examples)
    if parse_errors:
        raise AssertionError(f"fixture parser failed: {parse_errors}")
    errors = [error for command in commands for error in validator.validate_command(command)]
    if len(errors) != 4:
        raise AssertionError(f"expected all four stale forms to fail, got {errors}")
    if not all("explicit" in error and "surface" in error for error in errors[:3]):
        raise AssertionError(f"surface omissions were not diagnosed: {errors}")
    if "unsupported browser verb 'list'" not in errors[3]:
        raise AssertionError(f"stale list verb was not diagnosed: {errors}")


def test_scoped_aliases_are_accepted(validator: ModuleType) -> None:
    fixture = """
```bash
cmux browser --surface surface:1 get url
cmux browser surface:1 get-url
cmux browser surface:1 snapshot -i
cmux browser --surface surface:1 tab list
```
"""
    examples = [
        validator.ShellExample(Path("scoped-fixture.md"), line, text)
        for line, text in enumerate(fixture.splitlines(), start=1)
    ]
    commands, parse_errors = validator.browser_commands(examples)
    if parse_errors:
        raise AssertionError(f"fixture parser failed: {parse_errors}")
    errors = [error for command in commands for error in validator.validate_command(command)]
    if errors:
        raise AssertionError(f"surface-scoped aliases were rejected: {errors}")


def test_nested_commands_are_checked(validator: ModuleType) -> None:
    browser = "cmux browser "
    fixture = "```bash\n"
    fixture += 'URL="$(' + browser + 'url)"\n'
    fixture += 'TABS="$(' + browser + 'tab list)"\n'
    fixture += 'NESTED="$(printf "%s" "$(' + browser + 'snapshot -i)")"\n'
    fixture += "```\n"
    examples = [
        validator.ShellExample(Path("nested-fixture.md"), line, text)
        for line, text in enumerate(fixture.splitlines(), start=1)
    ]
    commands, parse_errors = validator.browser_commands(examples)
    if parse_errors:
        raise AssertionError(f"nested fixture parser failed: {parse_errors}")
    errors = [error for command in commands for error in validator.validate_command(command)]
    if len(errors) != 3 or not all("explicit" in error for error in errors):
        raise AssertionError(f"nested unscoped commands were not rejected: {errors}")


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
        lambda: test_scoped_aliases_are_accepted(validator),
        lambda: test_nested_commands_are_checked(validator),
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
