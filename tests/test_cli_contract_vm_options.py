#!/usr/bin/env python3
"""Keep the cloud VM contract's option synopses complete (#15694).

This is a static documentation check, not execution of the Swift CLI. The
reference is the CLI's named help literals: their initial Usage forms and
Options declarations, not examples or incidental option mentions in prose.
The contract side reads only code spans in Command-table first cells. Built-CLI
help probes remain in test_cli_contract_help.py.
"""

from pathlib import Path
import re
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
TRANSFER = "CLI/CMUXCLI+VMTransfer.swift"
TUI = "CLI/CMUXCLI+VMTui.swift"
HELP = {
    "exec": (TUI, "vmExecUsage"),
    "run": (TRANSFER, "vmRunUsage"),
    "agent": (TRANSFER, "vmAgentUsage"),
    "push": (TRANSFER, "vmPushUsage"),
    "open": (TUI, "vmOpenUsage"),
}
COMMANDS = (*HELP, "upload")
OPTION = re.compile(r"--[a-z][a-z0-9-]*")
FIRST_CELL = re.compile(r"^\s*\|\s*((?:\\\||[^|])+?)\s*\|")
COMMAND = re.compile(r"^vm (exec|run|agent|push|upload|open)(?:\s|$)")


def help_options(source: str, member: str, command: str) -> set[str]:
    """Read the existing literal forms; an unreadable/moved help fails closed."""
    declaration = (
        rf'^\s*static\s+(?:var\s+{member}\s*:\s*String\s*\{{\s*'
        rf'|let\s+{member}(?:\s*:\s*String)?\s*=\s*)'
        r'"""(.*?)^\s*"""'
    )
    matches = re.findall(declaration, source, flags=re.MULTILINE | re.DOTALL)
    if len(matches) != 1:
        raise ValueError(f"{member}: expected one readable help literal, found {len(matches)}")
    help_text = textwrap.dedent(matches[0]).strip()
    usage = re.split(r"\n\s*\n", help_text, maxsplit=1)[0]
    forms = re.findall(
        rf"^\s*(?:Usage:\s*)?cmux vm {command}(?:\s+[^\n]*)?$",
        usage,
        flags=re.MULTILINE,
    )
    if not help_text.startswith("Usage:") or not forms:
        raise ValueError(f"{member}: missing Usage form for vm {command}")
    options = set(OPTION.findall("\n".join(forms)))
    in_options = False
    for line in help_text.splitlines():
        stripped = line.strip()
        if stripped == "Options:":
            in_options = True
        elif in_options and stripped.startswith("--"):
            # Two spaces separate the declaration from its description. In
            # particular, --sync's description mentions --cwd on vm agent.
            declaration = re.split(r"\s{2,}", stripped, maxsplit=1)[0]
            options.update(OPTION.findall(declaration))
        elif in_options and stripped and line == stripped:
            # Blank lines can separate declarations. Only the next top-level
            # section/prose ends Options, so formatting cannot hide flags.
            in_options = False
    if not options:
        raise ValueError(f"{member}: no options extracted for vm {command}")
    return options


def contract_options(document: str) -> dict[str, set[str]]:
    """Collect flags from command cells, sharing push options with its upload alias."""
    result: dict[str, set[str]] = {}
    in_commands = False
    for line in document.splitlines():
        cell_match = FIRST_CELL.match(line)
        if not cell_match:
            in_commands = False
            continue
        cell = cell_match.group(1).strip()
        if cell == "Command":
            in_commands = True
            continue
        if not in_commands:
            continue
        row: dict[str, set[str]] = {}
        for synopsis in re.findall(r"`([^`]+)`", cell):
            command_match = COMMAND.match(synopsis)
            if command_match:
                command = command_match.group(1)
                row.setdefault(command, set()).update(OPTION.findall(synopsis))
        # upload is an alias of push, but unrelated commands never donate flags.
        if "push" in row and "upload" in row:
            row["upload"].update(row["push"])
        for command, options in row.items():
            result.setdefault(command, set()).update(options)
    return result


def check_contract(document: str, sources: dict[str, str]) -> list[str]:
    """Report missing command rows or flags and help sources that cannot be read."""
    documented = contract_options(document)
    expected: dict[str, set[str]] = {}
    errors: list[str] = []
    for command, (path, member) in HELP.items():
        try:
            expected[command] = help_options(sources[path], member, command)
        except (KeyError, ValueError) as exc:
            errors.append(f"{path}: {exc}")
    if "push" in expected:
        expected["upload"] = expected["push"]
    for command in COMMANDS:
        if command not in documented:
            errors.append(f"docs/cli-contract.md: missing vm {command} Command-table row")
        elif command in expected:
            missing = expected[command] - documented[command]
            if missing:
                errors.append(
                    f"docs/cli-contract.md: vm {command} synopsis missing "
                    + ", ".join(sorted(missing))
                )
    return errors


FIXTURE_HELP = {
    "exec": "Usage:\n  cmux vm exec [--timeout <seconds>] <machine> -- <command...>",
    "run": (
        "Usage: cmux vm run [--sync] -- <command...>\n\nOptions:\n"
        "  --wait, --output      Accepted for compatibility.\n\n"
        "Examples:\n  cmux vm run -- sh --example-only"
    ),
    "agent": (
        "Usage: cmux vm agent --agent <claude|codex> "
        "[--wait [--output] [--timeout <seconds>]] -- <prompt...>"
    ),
    "push": (
        "Usage: cmux vm push <id> <local> [--exclude <pattern>]... [--no-default-excludes]\n"
        "       cmux vm push <id> <local> --watch [--interval <seconds>]\n"
        "       cmux vm push --secret <id> <local> [--mode <octal>]"
    ),
    "open": (
        "Usage: cmux vm open <target> [--focus|--no-focus]\n"
        "       cmux vm open <id> <port> [--print]"
    ),
}
FIXTURE_DOC = r"""| Command | Contract |
| --- | --- |
| `vm exec [--timeout <seconds>] <machine> -- <command...>` | Execute. |
| `vm run [--sync] [--wait] [--output] -- <command...>` | Run. |
| `vm agent --agent <claude\|codex> [--wait [--output] [--timeout <seconds>]] -- <prompt...>` | Agent. |
| `vm push <id> <local> [--exclude <pattern>]... [--no-default-excludes]`<br>`vm push <id> <local> --watch [--interval <seconds>]`<br>`vm push --secret <id> <local> [--mode <octal>]`, `vm upload` | Upload is the same command. |
| `vm open <target> [--focus\|--no-focus]` | Open a target. |
| `vm open <id> <port> [--print]` | Print a port URL. |
"""


def fixture_sources(help_texts: dict[str, str] | None = None) -> dict[str, str]:
    """Wrap synthetic help in the Swift declaration forms accepted by the parser."""
    sources = {TRANSFER: "", TUI: ""}
    for command, text in (help_texts or FIXTURE_HELP).items():
        path, member = HELP[command]
        # Cover both production declaration forms, without executing Swift.
        if command == "exec":
            block = f'static let {member} = """\n{text}\n"""\n'
        else:
            block = f'static var {member}: String {{\n"""\n{text}\n"""\n}}\n'
        sources[path] += block
    return sources


class VMOptionContractTests(unittest.TestCase):
    def test_repository_contract_covers_help_options(self):
        """Check the repository's actual contract against its current help literals."""
        sources = {path: (ROOT / path).read_text() for path, _ in HELP.values()}
        errors = check_contract((ROOT / "docs/cli-contract.md").read_text(), sources)
        self.assertEqual(errors, [], "\n".join(errors))

    def test_complete_synopses_aliases_nested_options_and_escaped_pipes(self):
        """Accept complete rows with aliases, nested flags, and either table spacing."""
        for document in (FIXTURE_DOC, FIXTURE_DOC.replace("| ", "|").replace(" |", "|")):
            with self.subTest(compact=document != FIXTURE_DOC):
                self.assertEqual(check_contract(document, fixture_sources()), [])

    def test_every_missing_option_is_reported(self):
        """Removing any documented flag must identify the affected command and flag."""
        for command, options in contract_options(FIXTURE_DOC).items():
            for option in options:
                with self.subTest(command=command, option=option):
                    document = FIXTURE_DOC.replace(option, "omitted")
                    errors = check_contract(document, fixture_sources())
                    self.assertIn(f"vm {command} synopsis missing {option}", "\n".join(errors))

    def test_new_usage_option_requires_documentation(self):
        """A new help flag must fail until it appears in the command synopsis."""
        helps = dict(FIXTURE_HELP)
        helps["exec"] = helps["exec"].replace("<machine>", "[--new-option] <machine>")
        self.assertIn("vm exec synopsis missing --new-option", "\n".join(
            check_contract(FIXTURE_DOC, fixture_sources(helps))))

    def test_blank_lines_do_not_hide_option_declarations(self):
        """Blank lines within Options must not hide later declarations from the check."""
        helps = dict(FIXTURE_HELP)
        helps["run"] = helps["run"].replace("Options:\n", "Options:\n\n")
        helps["run"] = helps["run"].replace(
            "  --wait, --output      Accepted for compatibility.",
            "  --wait               Wait for completion.\n\n"
            "  --output             Print output.",
        )
        sources = fixture_sources(helps)
        self.assertEqual(check_contract(FIXTURE_DOC, sources), [])
        document = FIXTURE_DOC.replace("[--wait] [--output]", "")
        self.assertIn("vm run synopsis missing --output, --wait", "\n".join(
            check_contract(document, sources)))

    def test_description_and_other_commands_do_not_supply_options(self):
        """Prose and another command's flags cannot fill a missing synopsis option."""
        document = FIXTURE_DOC.replace("[--timeout <seconds>] <machine>", "<machine>")
        document = document.replace("| Execute. |", "| Use `--timeout <seconds>`. |")
        self.assertIn("vm exec synopsis missing --timeout", "\n".join(
            check_contract(document, fixture_sources())))

    def test_missing_command_or_alias_fails(self):
        """Every checked command, including the upload alias, needs its own name."""
        for command in COMMANDS:
            with self.subTest(command=command):
                document = FIXTURE_DOC.replace(f"`vm {command}", f"`other {command}")
                self.assertIn(f"missing vm {command} Command-table row", "\n".join(
                    check_contract(document, fixture_sources())))

    def test_non_command_table_cannot_supply_rows(self):
        """Only a table headed Command supplies documented option coverage."""
        errors = check_contract(FIXTURE_DOC.replace("| Command |", "| Field |"), fixture_sources())
        self.assertEqual(len(errors), len(COMMANDS))

    def test_missing_duplicate_or_unreadable_help_fails(self):
        """Absent files and missing, duplicate, or dynamic help must fail closed."""
        for source in ("", fixture_sources()[TUI] * 2, 'static let vmExecUsage = dynamicHelp'):
            with self.subTest(source=source[:50]):
                sources = fixture_sources()
                sources[TUI] = source
                self.assertIn("vmExecUsage: expected one readable help literal", "\n".join(
                    check_contract(FIXTURE_DOC, sources)))
        sources = fixture_sources()
        del sources[TUI]
        self.assertTrue(check_contract(FIXTURE_DOC, sources))

    def test_empty_or_wrong_command_usage_fails(self):
        """Reject empty, flag-free, or wrong-command usage instead of passing vacuously."""
        for text in ("", "Usage: cmux vm exec <machine>", "Usage: cmux vm run --timeout 3"):
            with self.subTest(text=text):
                helps = dict(FIXTURE_HELP, exec=text)
                self.assertTrue(check_contract(FIXTURE_DOC, fixture_sources(helps)))

    def test_examples_and_option_descriptions_are_not_declarations(self):
        """Incidental flag mentions in examples and descriptions add no requirements."""
        helps = dict(FIXTURE_HELP)
        helps["run"] = helps["run"].replace(
            "Accepted for compatibility.", "Like `vm other --description-only`.")
        self.assertEqual(check_contract(FIXTURE_DOC, fixture_sources(helps)), [])


if __name__ == "__main__":
    unittest.main()
