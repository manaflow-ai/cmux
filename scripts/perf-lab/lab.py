#!/usr/bin/env python3
"""The perf lab's command line: a thin dispatcher over command modules.

    python3 -I scripts/perf-lab/lab.py --help
    python3 -I scripts/perf-lab/lab.py COMMAND [--help | ARGS]

A command module is a sibling `*.py` file with three top-level names:

    LAB_COMMANDS = {"name": "one-line help", ...}         # a literal dict
    def add_arguments(command, parser): ...                # adds the command's arguments to its parser
    def run(command, args) -> int: ...                     # runs it; the return value is the exit code

lab.py reads every LAB_COMMANDS literal with `ast` and imports only the module of the command it runs, so a later
task adds a command by adding a module, never by editing this file. Stdlib only; modules load by file path, so it
runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import ast
import importlib.util
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REGISTRY = "LAB_COMMANDS"
COMMAND_NAME = re.compile(r"^[a-z][a-z0-9-]*$")


class LabError(RuntimeError):
    pass


def declared_commands(path: Path) -> dict[str, str]:
    """The module's LAB_COMMANDS literal ({} without one); raises LabError on a malformed one."""
    text = path.read_text(encoding="utf-8")
    if REGISTRY not in text:
        return {}
    for node in ast.parse(text, filename=str(path)).body:
        targets = node.targets if isinstance(node, ast.Assign) else [node.target] if isinstance(node, ast.AnnAssign) else []
        if not any(isinstance(target, ast.Name) and target.id == REGISTRY for target in targets):
            continue
        try:
            commands = ast.literal_eval(node.value)
        except (ValueError, TypeError, SyntaxError):
            raise LabError(f"{path.name}: {REGISTRY} is not a literal") from None
        if not isinstance(commands, dict) or not all(
                isinstance(name, str) and COMMAND_NAME.match(name) and isinstance(help_text, str)
                for name, help_text in commands.items()):
            raise LabError(f"{path.name}: {REGISTRY} must map command names ({COMMAND_NAME.pattern}) to help text")
        return commands
    return {}


def discover(directory: Path = HERE) -> dict[str, tuple[Path, str]]:
    """Command name -> (module path, help) for every command module in `directory`; a name declared twice is an error."""
    commands: dict[str, tuple[Path, str]] = {}
    for path in sorted(directory.glob("*.py")):
        if path.name == Path(__file__).name:
            continue
        for name, text in declared_commands(path).items():
            if name in commands:
                raise LabError(f"command {name} is declared by both {commands[name][0].name} and {path.name}")
            commands[name] = (path, text)
    return commands


def load(path: Path):
    """The command module at `path`, imported once per process as perf_lab_<stem>."""
    name = f"perf_lab_{path.stem}"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None:
        raise LabError(f"no module at {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    for attribute in ("add_arguments", "run"):
        if not callable(getattr(module, attribute, None)):
            raise LabError(f"{path.name} declares {REGISTRY} but has no {attribute}(command, ...)")
    return module


def main(argv: list[str] | None = None, *, directory: Path = HERE) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    try:
        commands = discover(directory)
    except (LabError, OSError, SyntaxError) as error:
        print(f"lab.py: {error}", file=sys.stderr)
        return 2
    parser = argparse.ArgumentParser(prog="lab.py", description="The cmux perf lab.")
    subparsers = parser.add_subparsers(dest="command", metavar="COMMAND", required=True)
    chosen = argv[0] if argv and not argv[0].startswith("-") else None
    module = None
    for name, (path, text) in sorted(commands.items()):
        command_parser = subparsers.add_parser(name, help=text, description=text)
        if name == chosen:
            try:
                module = load(path)
            except LabError as error:
                print(f"lab.py: {error}", file=sys.stderr)
                return 2
            module.add_arguments(name, command_parser)
    args = parser.parse_args(argv)
    return int(module.run(args.command, args))


if __name__ == "__main__":
    sys.exit(main())
