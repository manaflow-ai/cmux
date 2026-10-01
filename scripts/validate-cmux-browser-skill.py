#!/usr/bin/env python3
"""Validate cmux-browser skill examples against the cmux CLI browser grammar.

The guard is an executable docs check, not a grep for a handful of strings.
It tokenizes every shell example in the skill and checks each `cmux browser`
invocation against the grammar of the Rust cmux CLI (cmux-tui):

* `cmux browser <tab_…|page> VERB …` drives a browser tab of the app
  (cli/app.rs parse_page); VERB must be one of PAGE_VERBS.
* `cmux browser <browser_…> VERB …` drives a daemon browser (cli/command.rs
  parse_browser); VERB must be one of DAEMON_VERBS. `cmux browser list` lists them.
* `cmux browser ACTION` runs one of the app's browser UI actions (UI_ACTIONS).

Every page or daemon verb needs an explicit target, so an example that relies
on whatever tab is focused fails, as does the retired `--surface`/`surface:N`
grammar. A shell variable in the target position is accepted as a target.
"""

from __future__ import annotations

import argparse
import re
import shlex
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, Sequence


ROOT = Path(__file__).resolve().parent.parent

# Verbs of `cmux browser <tab_…|page> VERB` (cmux-tui src/cli/app.rs parse_page).
PAGE_VERBS = frozenset(
    {
        "back", "check", "click", "eval", "fill", "focus", "forward", "goto", "hover",
        "navigate", "open", "press", "reload", "scroll", "scroll-into-view", "select",
        "snapshot", "state", "text", "title", "type", "uncheck", "url", "value",
    }
)

# Verbs of `cmux browser <browser_…> VERB` (cmux-tui src/cli/command.rs parse_browser).
DAEMON_VERBS = frozenset(
    {
        "activate", "attach", "back", "close", "forward", "key", "mouse",
        "navigate", "reload", "show", "text", "wheel",
    }
)

# `cmux browser ACTION`: the app's browser UI actions. They act on the focused
# browser and take no target (`cmux action list --noun browser`).
UI_ACTIONS = frozenset(
    {
        "delete-site-data", "import-data", "new-profile", "screenshot-page",
        "screenshot-section", "show-javascript-console", "split-down", "split-right",
        "toggle-design-mode", "toggle-developer-tools", "toggle-focus-mode",
        "toggle-react-grab", "zoom-in", "zoom-out",
    }
)

# Global options before the scope word that take a value.
GLOBAL_OPTIONS_WITH_VALUE = frozenset({"--socket", "--app-socket", "--session"})

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


def _is_variable(token: str) -> bool:
    return token.startswith("$")


def _is_tab_target(token: str) -> bool:
    lowered = token.lower()
    return lowered == "page" or lowered.startswith(("tab_", "<tab"))


def _is_browser_target(token: str) -> bool:
    lowered = token.lower()
    return lowered.startswith(("browser_", "<browser"))


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


def _scope_index(tokens: Sequence[str], start: int, end: int) -> int | None:
    """Index of the scope word after `cmux` and its global options."""

    cursor = start
    while cursor < end and tokens[cursor].startswith("-"):
        cursor += 2 if tokens[cursor] in GLOBAL_OPTIONS_WITH_VALUE else 1
    return cursor if cursor < end else None


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
        browser_index = _scope_index(tokens, index + 1, end)
        if browser_index is None or tokens[browser_index] != "browser":
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


def validate_command(command: BrowserCommand) -> list[str]:
    tokens = command.tokens
    scope = _scope_index(tokens, 1, len(tokens))
    after = [token for token in tokens[(scope or 0) + 1 :] if token not in SHELL_OPERATORS]
    where = f"{command.path}:{command.line}"
    raw = command.raw.strip()
    retired = [token for token in after if token == "--surface" or token.startswith(("--surface=", "surface:"))]
    if retired:
        return [f"{where}: `--surface`/`surface:N` targets were retired; pass a tab_… or browser_… id: {raw}"]
    if not after:
        return [f"{where}: missing browser target or action: {raw}"]
    first = after[0]
    if first in {"--help", "-h", "list"} or first in UI_ACTIONS:
        return []
    if first.lower() in PAGE_VERBS | DAEMON_VERBS:
        return [f"{where}: browser {first!r} needs an explicit tab_… or browser_… target: {raw}"]
    if _is_tab_target(first):
        allowed, kind = PAGE_VERBS, "app tab"
    elif _is_browser_target(first):
        allowed, kind = DAEMON_VERBS, "daemon browser"
    elif _is_variable(first):
        allowed, kind = PAGE_VERBS | DAEMON_VERBS, "browser"
    else:
        return [f"{where}: unknown browser target or action {first!r}; check `cmux browser --help`: {raw}"]
    verbs = [token for token in after[1:] if not token.startswith("-")][:1]
    if not verbs:
        return [f"{where}: missing {kind} verb: {raw}"]
    errors = []
    for verb in _split_alternatives(verbs[0]):
        if verb.lower() not in allowed:
            errors.append(f"{where}: unsupported {kind} verb {verb!r}; check `cmux browser --help`: {raw}")
    return errors


def _skill_files(root: Path) -> list[Path]:
    paths: list[Path] = []
    for base in (root / "skills" / "cmux-browser",):
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
    for marker in ("interface:", "default_prompt:", "--help", "tab_"):
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
        if re.search(r"TAB\s*=\s*[\"']?\$\{[^}]*:-\s*(?:page|tab_)", text):
            errors.append(f"{path}: template must not guess a default tab")
    return errors


def validate_repository(root: Path) -> list[str]:
    errors = _metadata_errors(root) + _mirror_errors(root) + _template_errors(root)
    files = _skill_files(root)
    commands, parse_errors = browser_commands(shell_examples(files))
    errors.extend(parse_errors)
    for command in commands:
        errors.extend(validate_command(command))

    return errors


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    errors = validate_repository(args.root.resolve())
    if errors:
        print("FAIL: cmux-browser skill contract")
        for error in errors:
            print(f"- {error}")
        return 1
    print("PASS: cmux-browser skill contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
