#!/usr/bin/env python3
"""Validate cmux-browser skill examples against the live CLI contract.

The guard is intentionally an executable docs check, not a grep for a handful
of strings. When a cmux binary is available it runs ``cmux browser --help`` and
checks the advertised grammar. It then tokenizes shell examples in the
canonical skill (and an optional cmux-cli skill) and requires a surface handle
for every existing-surface browser verb. This catches an old example such as
an unscoped tab-list invocation even if its wording or whitespace changes.

On Linux documentation-only CI there may be no macOS cmux binary. In that
case the structural command parser still runs; pass ``--require-cli`` when a
live help contract is required (for example, from the macOS CLI test lane).
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, Sequence


ROOT = Path(__file__).resolve().parent.parent

# Keep this set aligned with the public ``cmux browser --help`` surface. The
# validator deliberately rejects an unknown verb so a renamed/removed CLI verb
# cannot quietly remain in an installed skill.
SURFACE_REQUIRED_VERBS = frozenset(
    {
        "addinitscript",
        "addscript",
        "addstyle",
        "back",
        "click",
        "check",
        "cookies",
        "console",
        "dblclick",
        "dialog",
        "download",
        "errors",
        "eval",
        "fill",
        "find",
        "focus",
        "focus-webview",
        "focus_webview",
        "forward",
        "frame",
        "geolocation",
        "geo",
        "get",
        "get-url",
        "goto",
        "highlight",
        "hover",
        "input",
        "input_keyboard",
        "input_mouse",
        "input_touch",
        "is",
        "is-webview-focused",
        "is_webview_focused",
        "key",
        "keydown",
        "keyup",
        "navigate",
        "network",
        "offline",
        "press",
        "reload",
        "screenshot",
        "scroll",
        "scroll-into-view",
        "scrollinto",
        "scrollintoview",
        "select",
        "screencast",
        "snapshot",
        "state",
        "storage",
        "tab",
        "trace",
        "type",
        "uncheck",
        "url",
        "viewport",
        "wait",
    }
)

UNSCOPED_VERBS = frozenset(
    {
        "disable",
        "dev-tools",
        "devtools",
        "design-mode",
        "enable",
        "focus-mode",
        "history",
        "identify",
        "import",
        "new",
        "open",
        "open-split",
        "profile",
        "profiles",
        "react-grab",
        "reactgrab",
        "status",
        "zoom",
    }
)

KNOWN_VERBS = SURFACE_REQUIRED_VERBS | UNSCOPED_VERBS

SHELL_OPERATORS = frozenset(
    {
        ";",
        "|",
        "||",
        "&&",
        ">",
        ">>",
        "<",
        "(",
        ")",
        "{",
        "}",
    }
)

HELP_MARKERS = (
    "Usage: cmux browser [--surface <id|ref|index> | <surface>] <subcommand> [args]",
    "url|get-url",
    "snapshot [--interactive|-i]",
    "get <url|title|text|html|value|attr|count|box|styles>",
    "tab <new|list|switch|close|<index>>",
    "dialog <accept|dismiss>",
    "addinitscript|addscript",
    "addstyle",
    "screencast <start|stop>",
)


@dataclass(frozen=True)
class ShellExample:
    path: Path
    line: int
    text: str


@dataclass(frozen=True)
class BrowserCommand:
    path: Path
    line: int
    raw: str
    tokens: tuple[str, ...]


class ShellSyntaxError(ValueError):
    """A shell example cannot be parsed into complete command substitutions."""


def _fenced_shell_blocks(path: Path, text: str) -> Iterator[tuple[int, str]]:
    """Yield (start line, block text) for shell-language Markdown fences."""

    lines = text.splitlines()
    opening: tuple[str, int] | None = None
    body: list[str] = []
    for index, line in enumerate(lines, start=1):
        match = re.match(r"^\s*(`{3,}|~{3,})\s*([^\s`]*)", line)
        if opening is None:
            if match and match.group(2).lower() in {"bash", "sh", "shell", "zsh"}:
                opening = (match.group(1), index + 1)
                body = []
            continue

        fence_run = opening[0]
        stripped = line.strip()
        if (
            len(stripped) >= len(fence_run)
            and stripped
            and all(character == fence_run[0] for character in stripped)
        ):
            yield opening[1], "\n".join(body)
            opening = None
            body = []
            continue
        body.append(line)


def shell_examples(paths: Iterable[Path]) -> Iterator[ShellExample]:
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        if path.suffix == ".md":
            for start_line, block in _fenced_shell_blocks(path, text):
                for offset, line in enumerate(block.splitlines(), start=0):
                    yield ShellExample(path, start_line + offset, line)
        elif path.suffix == ".sh":
            for line_number, line in enumerate(text.splitlines(), start=1):
                yield ShellExample(path, line_number, line)


def _logical_examples(examples: Iterable[ShellExample]) -> Iterator[ShellExample]:
    pending: ShellExample | None = None
    for example in examples:
        line = example.text.rstrip()
        if pending is not None:
            joined = pending.text + line.lstrip()
            if joined.endswith("\\"):
                pending = ShellExample(pending.path, pending.line, joined[:-1] + " ")
            elif _has_unclosed_quote(joined):
                pending = ShellExample(pending.path, pending.line, joined + " ")
            else:
                yield ShellExample(pending.path, pending.line, joined)
                pending = None
            continue

        if line.endswith("\\"):
            pending = ShellExample(example.path, example.line, line[:-1] + " ")
        elif _has_unclosed_quote(line):
            pending = example
        else:
            yield example
    if pending is not None:
        yield pending


def _has_unclosed_quote(text: str) -> bool:
    """Return whether a shell logical line still has an open quote."""

    lexer = shlex.shlex(text, posix=True)
    lexer.whitespace_split = True
    lexer.commenters = "#"
    try:
        list(lexer)
    except ValueError as exc:
        return "No closing quotation" in str(exc)
    return False


def _split_alternatives(token: str) -> tuple[str, ...]:
    # Reference docs use compact notation such as ``back|forward|reload``.
    pieces = tuple(piece for piece in token.split("|") if piece)
    return pieces or (token,)


def _looks_like_surface(token: str) -> bool:
    normalized = token.strip().lower()
    if normalized in {"<surface>", "<surface-id>", "<surface-ref>", "$surface", "${surface}"}:
        return True
    if normalized.startswith(("surface:", "tab:")):
        return True
    if normalized.isdigit():
        return True
    if re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
        normalized,
    ):
        return True
    # Shell variables in examples should name the thing they carry. Accept
    # ${SURFACE:-...} too, while rejecting arbitrary variables as an implicit
    # target.
    return bool(re.fullmatch(r"\$\{?surface(?:[^}]*)\}?", normalized))


def _tokenize(line: str) -> list[str]:
    # Ask shlex to keep shell operators as standalone tokens so an adjacent
    # ``;``/``&&`` cannot make one browser invocation consume the next one.
    # Quoted operator characters remain part of their quoted argument.
    lexer = shlex.shlex(line, posix=True, punctuation_chars=";&|")
    lexer.whitespace_split = True
    lexer.commenters = "#"
    return list(lexer)


def _substitution_bodies(text: str) -> Iterator[str]:
    """Yield command bodies inside ``$(...)`` and backtick substitutions."""

    index = 0
    quote: str | None = None
    escaped = False
    while index < len(text):
        character = text[index]
        if escaped:
            escaped = False
            index += 1
            continue

        # A backslash is literal inside a single-quoted shell string, but
        # escapes the next character everywhere else.
        if character == "\\" and quote != "'":
            escaped = True
            index += 1
            continue

        if quote == "'":
            if character == "'":
                quote = None
            index += 1
            continue

        if quote is None and character in {"'", '"'}:
            quote = character
            index += 1
            continue

        # Command substitutions are active when unquoted or inside a
        # double-quoted string; single-quoted/escaped text is literal.
        if (quote is None or quote == '"') and text.startswith("$(", index):
            start = index + 2
            depth = 1
            nested_quote: str | None = None
            escaped = False
            cursor = start
            while cursor < len(text):
                character = text[cursor]
                if escaped:
                    escaped = False
                elif character == "\\" and nested_quote != "'":
                    escaped = True
                elif nested_quote:
                    if character == nested_quote:
                        nested_quote = None
                elif character in {"'", '"'}:
                    nested_quote = character
                elif text.startswith("$(", cursor):
                    depth += 1
                    cursor += 1
                elif character == ")":
                    depth -= 1
                    if depth == 0:
                        yield text[start:cursor]
                        index = cursor + 1
                        break
                cursor += 1
            else:
                raise ShellSyntaxError("unterminated $() command substitution")
            continue

        if (quote is None or quote == '"') and character == "`":
            start = index + 1
            cursor = start
            escaped = False
            while cursor < len(text):
                character = text[cursor]
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == "`":
                    yield text[start:cursor]
                    index = cursor + 1
                    break
                cursor += 1
            else:
                raise ShellSyntaxError("unterminated backtick command substitution")
            continue

        index += 1


def _nested_browser_commands(
    example: ShellExample,
    text: str,
    depth: int = 0,
) -> tuple[list[BrowserCommand], list[str]]:
    """Collect browser commands in a shell line and all nested substitutions."""

    # A malformed or adversarial example must not make the validator recurse
    # forever. Sixteen levels is far beyond any useful shell example while
    # still allowing nested command substitutions to be checked completely.
    if depth > 16:
        return [], [f"{example.path}:{example.line}: shell substitution nesting is too deep"]

    commands: list[BrowserCommand] = []
    errors: list[str] = []
    try:
        tokens = _tokenize(text)
    except ValueError as exc:
        errors.append(f"{example.path}:{example.line}: invalid nested shell syntax: {exc}")
        return commands, errors

    commands.extend(_commands_from_tokens(example, tokens, text))
    try:
        substitution_bodies = list(_substitution_bodies(text))
    except ShellSyntaxError as exc:
        errors.append(f"{example.path}:{example.line}: {exc}")
        return commands, errors

    for body in substitution_bodies:
        nested_commands, nested_errors = _nested_browser_commands(example, body, depth + 1)
        commands.extend(nested_commands)
        errors.extend(nested_errors)
    return commands, errors


def _commands_from_tokens(
    example: ShellExample,
    tokens: Sequence[str],
    raw: str,
) -> list[BrowserCommand]:
    commands: list[BrowserCommand] = []
    for index, token in enumerate(tokens):
        if token != "cmux":
            continue
        end = len(tokens)
        for cursor in range(index + 1, len(tokens)):
            if tokens[cursor] in SHELL_OPERATORS:
                end = cursor
                break
        browser_index = next(
            (cursor for cursor in range(index + 1, end) if tokens[cursor] == "browser"),
            None,
        )
        if browser_index is None:
            continue
        commands.append(
            BrowserCommand(
                example.path,
                example.line,
                raw,
                tuple(tokens[index:end]),
            )
        )
    return commands


def browser_commands(examples: Iterable[ShellExample]) -> tuple[list[BrowserCommand], list[str]]:
    commands: list[BrowserCommand] = []
    errors: list[str] = []
    seen: set[tuple[Path, int, tuple[str, ...]]] = set()
    for example in _logical_examples(examples):
        if not example.text.strip() or example.text.lstrip().startswith("#"):
            continue
        nested_commands, nested_errors = _nested_browser_commands(example, example.text)
        for command in nested_commands:
            key = (command.path, command.line, command.tokens)
            if key in seen:
                continue
            seen.add(key)
            commands.append(command)
        errors.extend(nested_errors)
    return commands, errors


def _surface_flag_value(after_browser: Sequence[str]) -> tuple[bool, list[str]]:
    has_surface = False
    remaining = list(after_browser)
    index = 0
    while index < len(remaining):
        token = remaining[index]
        if token == "--surface":
            has_surface = True
            if index + 1 >= len(remaining) or remaining[index + 1] in SHELL_OPERATORS:
                return has_surface, []
            del remaining[index : index + 2]
            continue
        if token.startswith("--surface="):
            has_surface = bool(token.split("=", 1)[1])
            del remaining[index]
            continue
        index += 1
    return has_surface, remaining


def _verb_candidates(after_browser: Sequence[str]) -> tuple[bool, tuple[str, ...], str | None]:
    has_surface, remaining = _surface_flag_value(after_browser)
    if not remaining:
        return has_surface, (), "missing subcommand"

    # Help is intentionally allowed without a target.
    if remaining[0] in {"--help", "-h"}:
        return has_surface, (), None

    positional_surface = _looks_like_surface(remaining[0])
    if positional_surface:
        has_surface = True
        remaining = remaining[1:]
    while remaining and remaining[0].startswith("--"):
        # A global display flag before the verb has no value in the current
        # docs. Skip it so the command parser remains tolerant of --json.
        remaining = remaining[1:]
    if not remaining:
        return has_surface, (), "missing subcommand"
    return has_surface, _split_alternatives(remaining[0]), None


def validate_command(command: BrowserCommand) -> list[str]:
    tokens = command.tokens
    browser_index = tokens.index("browser")
    after_browser = tokens[browser_index + 1 :]
    has_surface, verbs, parse_error = _verb_candidates(after_browser)
    if parse_error:
        return [f"{command.path}:{command.line}: {parse_error}: {command.raw.strip()}"]
    if not verbs:
        return []

    errors: list[str] = []
    for verb in verbs:
        normalized = verb.lower()
        if normalized not in KNOWN_VERBS:
            errors.append(
                f"{command.path}:{command.line}: unsupported browser verb {verb!r}; "
                f"refresh `cmux browser --help`: {command.raw.strip()}"
            )
            continue
        if normalized in SURFACE_REQUIRED_VERBS and not has_surface:
            errors.append(
                f"{command.path}:{command.line}: browser {verb!r} requires an explicit "
                f"surface handle (`--surface <surface>` or positional): {command.raw.strip()}"
            )
    return errors


def _skill_files(root: Path) -> list[Path]:
    paths: list[Path] = []
    for base in (root / "skills" / "cmux-browser", root / "skills" / "cmux-cli"):
        if not base.is_dir():
            continue
        paths.extend(sorted(path for path in base.rglob("*.md") if path.is_file()))
        paths.extend(sorted(path for path in base.rglob("*.sh") if path.is_file()))
    return paths


def _frontmatter_errors(path: Path) -> list[str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        return [f"{path}: unable to read frontmatter: {exc}"]
    if not lines or lines[0].strip() != "---":
        return [f"{path}: missing YAML frontmatter"]
    try:
        end = next(index for index, line in enumerate(lines[1:], start=1) if line.strip() == "---")
    except StopIteration:
        return [f"{path}: unterminated YAML frontmatter"]
    fields: dict[str, str] = {}
    for line in lines[1:end]:
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        fields[key.strip()] = value.strip().strip('"').strip("'")
    errors: list[str] = []
    for required in ("name", "description"):
        if not fields.get(required):
            errors.append(f"{path}: frontmatter requires {required}")
    return errors


def _mirror_errors(root: Path) -> list[str]:
    canonical = (root / "skills").resolve()
    errors: list[str] = []
    mirrors = {
        Path(".agents/skills"): canonical,
        Path(".claude/skills/cmux-browser"): canonical / "cmux-browser",
    }
    for relative, expected_target in mirrors.items():
        mirror = root / relative
        if not mirror.is_symlink():
            expected = "../skills" if relative == Path(".agents/skills") else "../../skills/cmux-browser"
            errors.append(f"{mirror}: discovery mirror must remain a symlink to {expected}")
            continue
        if mirror.resolve() != expected_target:
            errors.append(f"{mirror}: resolves to {mirror.resolve()}, expected {expected_target}")
    return errors


def _metadata_errors(root: Path) -> list[str]:
    skill = root / "skills" / "cmux-browser"
    errors = _frontmatter_errors(skill / "SKILL.md")
    metadata = skill / "agents" / "openai.yaml"
    try:
        text = metadata.read_text(encoding="utf-8")
    except OSError as exc:
        return errors + [f"{metadata}: unable to read: {exc}"]
    for marker in ("interface:", "default_prompt:", "--help", "surface"):
        if marker not in text:
            errors.append(f"{metadata}: registration metadata is missing {marker!r}")
    agents = skill / "AGENTS.md"
    if not agents.is_file():
        errors.append(f"{agents}: Codex agent instructions are missing")
    return errors


def _template_errors(root: Path) -> list[str]:
    template_root = root / "skills" / "cmux-browser" / "templates"
    errors: list[str] = []
    if not template_root.is_dir():
        return [f"{template_root}: template directory is missing"]
    templates = sorted(template_root.glob("*.sh"))
    if not templates:
        return [f"{template_root}: no shell templates found"]
    for path in templates:
        text = path.read_text(encoding="utf-8")
        if re.search(r"SURFACE\s*=\s*[\"']?\$\{[^}]*:-\s*surface:", text):
            errors.append(f"{path}: template must not guess a default surface")
    return errors


def validate_repository(root: Path, help_text: str | None = None) -> list[str]:
    errors = _metadata_errors(root) + _mirror_errors(root) + _template_errors(root)
    files = _skill_files(root)
    commands, parse_errors = browser_commands(shell_examples(files))
    errors.extend(parse_errors)
    for command in commands:
        errors.extend(validate_command(command))

    if help_text is not None:
        normalized = " ".join(help_text.split())
        for marker in HELP_MARKERS:
            if " ".join(marker.split()) not in normalized:
                errors.append(f"cmux browser --help: missing contract marker {marker!r}")
    return errors


def resolve_cli(explicit: str | None) -> str | None:
    candidates = [explicit, os.environ.get("CMUX_CLI_BIN"), os.environ.get("CMUX_CLI")]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return shutil.which("cmux")


def live_help(cli: str) -> tuple[str | None, str | None]:
    try:
        result = subprocess.run(
            [cli, "browser", "--help"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return None, f"unable to run {cli!r}: {exc}"
    output = f"{result.stdout}\n{result.stderr}".strip()
    if result.returncode != 0:
        return None, f"{cli!r} browser --help exited {result.returncode}: {output}"
    return output, None


def live_syntax_errors(cli: str) -> list[str]:
    """Check representative CLI forms reach the socket parser unambiguously."""

    valid_commands = (
        ("url", ["browser", "--surface", "surface:1", "url"]),
        ("get-url", ["browser", "--surface", "surface:1", "get-url"]),
        ("get url", ["browser", "--surface", "surface:1", "get", "url"]),
        ("tab list", ["browser", "--surface", "surface:1", "tab", "list"]),
        ("snapshot", ["browser", "--surface", "surface:1", "snapshot", "--interactive"]),
        ("click", ["browser", "--surface", "surface:1", "click", "e1"]),
        ("positional get", ["browser", "surface:1", "get", "title"]),
    )
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cmux-browser-skill-") as directory:
        socket_path = str(Path(directory) / "absent.sock")
        environment = dict(os.environ)
        for key in (
            "CMUX_SOCKET",
            "CMUX_SOCKET_PATH",
            "CMUX_SOCKET_PASSWORD",
            "CMUX_WORKSPACE_ID",
            "CMUX_SURFACE_ID",
            "CMUX_TAB_ID",
        ):
            environment.pop(key, None)
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        def run(arguments: Sequence[str]) -> str:
            try:
                result = subprocess.run(
                    [cli, "--socket", socket_path, *arguments],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=5,
                    env=environment,
                )
            except (OSError, subprocess.SubprocessError) as exc:
                errors.append(f"{' '.join(arguments)}: unable to execute: {exc}")
                return ""
            return f"{result.stdout}\n{result.stderr}".strip()

        parser_failure_markers = (
            "Unsupported browser subcommand",
            "browser requires a subcommand",
            "requires a surface handle",
            "Invalid surface handle",
        )
        for label, arguments in valid_commands:
            output = run(arguments)
            if any(marker in output for marker in parser_failure_markers):
                errors.append(
                    f"{label}: surface-scoped form was rejected before socket dispatch: {output!r}"
                )
    return errors


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root")
    parser.add_argument("--cmux-bin", help="cmux executable to use for live help")
    parser.add_argument("--require-cli", action="store_true", help="fail when no live cmux binary is available")
    parser.add_argument("--no-cli", action="store_true", help="skip live help even when cmux is on PATH")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if args.no_cli and args.require_cli:
        print("FAIL: --no-cli and --require-cli are mutually exclusive")
        return 2
    root = args.root.resolve()
    help_text: str | None = None
    cli_warning: str | None = None
    if not args.no_cli:
        cli = resolve_cli(args.cmux_bin)
        if cli:
            help_text, cli_warning = live_help(cli)
            if help_text is not None:
                cli_syntax_errors = live_syntax_errors(cli)
                if cli_syntax_errors:
                    print("FAIL: cmux-browser CLI syntax contract")
                    for error in cli_syntax_errors:
                        print(f"- {error}")
                    return 1
        elif args.require_cli:
            cli_warning = "no executable cmux binary found (set CMUX_CLI_BIN)"
    if cli_warning and args.require_cli:
        print(f"FAIL: {cli_warning}")
        return 1
    errors = validate_repository(root, help_text=help_text)
    if errors:
        print("FAIL: cmux-browser skill contract")
        for error in errors:
            print(f"- {error}")
        return 1
    if cli_warning:
        print(f"INFO: {cli_warning}; structural docs contract used")
    elif help_text is not None:
        print("PASS: cmux-browser skill and live cmux browser --help contract")
    else:
        print("PASS: cmux-browser skill structural contract (no live CLI requested)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
