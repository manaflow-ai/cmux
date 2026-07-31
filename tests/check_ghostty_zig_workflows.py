#!/usr/bin/env python3
"""Require Ghostty initialization before workflow steps execute Zig consumers."""

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import bashlex
import yaml
from yaml.nodes import MappingNode, Node, ScalarNode, SequenceNode


CONSUMER_NAMES = (
    "scripts/install-zig-ci.sh",
    "scripts/build-ghostty-cli-helper.sh",
    "scripts/ghostty-zig-version.sh",
)
CHECKOUT_ACTION = "actions/checkout@"
SETUP_ZIG_ACTION = "mlugg/setup-zig@"
SETUP_ZIG_VERSION = "${{ steps.ghostty-zig-version.outputs.version }}"
TUI_WORKFLOW_NAMES = frozenset({"cmux-tui-build-package.yml", "cmux-tui.yml"})
SHELL_INTERPRETERS = {"bash", "sh", "zsh"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
QUOTED_HEREDOC = re.compile(r"(<<-?\s*)(['\"])([A-Za-z_][A-Za-z0-9_]*)(\2)")
BASH_CONDITIONAL = re.compile(r"\[\[.*?\]\]", re.DOTALL)
WRAPPER_OPTIONS_WITH_VALUES = {
    "command": frozenset(),
    "env": frozenset({"-C", "-S", "-u", "--chdir", "--split-string", "--unset"}),
    "exec": frozenset({"-a"}),
    "sudo": frozenset(
        {
            "-C",
            "-D",
            "-g",
            "-h",
            "-p",
            "-R",
            "-r",
            "-T",
            "-t",
            "-U",
            "-u",
            "--chdir",
            "--chroot",
            "--close-from",
            "--command-timeout",
            "--group",
            "--host",
            "--other-user",
            "--prompt",
            "--role",
            "--type",
            "--user",
        }
    ),
}


@dataclass(frozen=True)
class Step:
    line: int
    run_line: int | None
    name: str
    identifier: str | None
    uses: str | None
    run: str | None
    inputs: dict[str, str]


@dataclass(frozen=True)
class Job:
    name: str
    steps: tuple[Step, ...]


@dataclass(frozen=True)
class RunEvent:
    kind: str
    line: int
    consumer: str | None = None
    failure_propagates: bool = True


def _mapping_value(mapping: Node | None, key: str) -> Node | None:
    if not isinstance(mapping, MappingNode):
        return None
    for key_node, value_node in mapping.value:
        if isinstance(key_node, ScalarNode) and key_node.value == key:
            return value_node
    return None


def _scalar(mapping: Node | None, key: str) -> str | None:
    value = _mapping_value(mapping, key)
    return value.value if isinstance(value, ScalarNode) else None


def _scalar_mapping(mapping: Node | None) -> dict[str, str]:
    if not isinstance(mapping, MappingNode):
        return {}
    values: dict[str, str] = {}
    for key_node, value_node in mapping.value:
        if isinstance(key_node, ScalarNode) and isinstance(value_node, ScalarNode):
            values[key_node.value] = value_node.value
    return values


def _workflow_jobs(path: Path) -> tuple[list[Job], list[str]]:
    try:
        root = yaml.compose(path.read_text(encoding="utf-8"), Loader=yaml.SafeLoader)
    except yaml.YAMLError as error:
        return [], [f"{path.name}: invalid workflow YAML: {error}"]

    jobs_node = _mapping_value(root, "jobs")
    if jobs_node is None:
        return [], []
    if not isinstance(jobs_node, MappingNode):
        return [], [f"{path.name}: jobs must be a mapping"]

    jobs: list[Job] = []
    failures: list[str] = []
    for job_name_node, job_node in jobs_node.value:
        if not isinstance(job_name_node, ScalarNode):
            failures.append(f"{path.name}: job name must be a scalar")
            continue
        if not isinstance(job_node, MappingNode):
            continue

        steps_node = _mapping_value(job_node, "steps")
        if steps_node is None:
            continue
        if not isinstance(steps_node, SequenceNode):
            failures.append(
                f"{path.name}:{steps_node.start_mark.line + 1}: "
                f"{job_name_node.value} steps must be a sequence"
            )
            continue

        steps: list[Step] = []
        for step_node in steps_node.value:
            if not isinstance(step_node, MappingNode):
                failures.append(
                    f"{path.name}:{step_node.start_mark.line + 1}: "
                    f"{job_name_node.value} step must be a mapping"
                )
                continue
            run_node = _mapping_value(step_node, "run")
            run_line = None
            if isinstance(run_node, ScalarNode):
                run_line = run_node.start_mark.line + (
                    2 if run_node.style in {"|", ">"} else 1
                )
            steps.append(
                Step(
                    line=step_node.start_mark.line + 1,
                    run_line=run_line,
                    name=_scalar(step_node, "name") or "<unnamed step>",
                    identifier=_scalar(step_node, "id"),
                    uses=_scalar(step_node, "uses"),
                    run=_scalar(step_node, "run"),
                    inputs=_scalar_mapping(_mapping_value(step_node, "with")),
                )
            )
        jobs.append(Job(name=job_name_node.value, steps=tuple(steps)))
    return jobs, failures


def _normalize_heredocs(script: str) -> str:
    # bashlex 0.18 parses heredocs but retains quotes in the expected delimiter,
    # unlike Bash. Removing only those delimiter quotes preserves line numbers
    # and leaves heredoc bodies represented as data, not executable commands.
    return QUOTED_HEREDOC.sub(
        lambda match: (
            match.group(1)
            + match.group(3)
            + (" " * (len(match.group(2)) + len(match.group(4))))
        ),
        script,
    )


def _child_nodes(node: object) -> Iterator[object]:
    for value in vars(node).values():
        if hasattr(value, "kind"):
            yield value
        elif isinstance(value, list):
            yield from (item for item in value if hasattr(item, "kind"))


def _command_words(command: object) -> list[str]:
    return [
        part.word
        for part in getattr(command, "parts", ())
        if getattr(part, "kind", None) == "word"
    ]


def _skip_wrapper_options(
    words: list[str], index: int, options_with_values: frozenset[str],
) -> int:
    while index < len(words):
        option = words[index]
        if option == "--":
            return index + 1
        if not option.startswith("-") or option == "-":
            return index

        index += 1
        option_name, separator, _ = option.partition("=")
        if option_name in options_with_values and not separator and index < len(words):
            index += 1
    return index


def _executable_words(words: list[str]) -> list[str]:
    index = 0
    while index < len(words):
        wrapper = words[index]
        options_with_values = WRAPPER_OPTIONS_WITH_VALUES.get(wrapper)
        if options_with_values is None:
            break

        index += 1
        option_start = index
        index = _skip_wrapper_options(words, index, options_with_values)
        if wrapper == "command" and any(
            option in {"-v", "-V"} for option in words[option_start:index]
        ):
            return []
        if wrapper == "env":
            while index < len(words) and ASSIGNMENT.match(words[index]):
                index += 1

    return words[index:]


def _shell_command_or_script(words: list[str]) -> tuple[str, str] | None:
    index = 1
    while index < len(words):
        argument = words[index]
        if argument == "--":
            index += 1
            break
        if not argument.startswith("-") or argument == "-":
            break

        if argument in {"-o", "-O", "--init-file", "--rcfile"}:
            index += 2
        elif not argument.startswith("--") and "c" in argument[1:]:
            return ("command", words[index + 1]) if index + 1 < len(words) else None
        else:
            index += 1

    return ("script", words[index]) if index < len(words) else None


def _consumer_name(target: str | None) -> str | None:
    if target is None:
        return None
    normalized = target.removeprefix("./").rstrip("/")
    for consumer in CONSUMER_NAMES:
        if normalized == consumer or normalized.endswith(f"/{consumer}"):
            return consumer
    return None


def _command_name(target: str) -> str:
    return target.rsplit("/", 1)[-1]


def _is_ghostty_init(words: list[str]) -> bool:
    return (
        len(words) >= 4
        and _command_name(words[0]) == "git"
        and words[1:3] == ["submodule", "update"]
        and "--init" in words[3:]
        and "ghostty" in words[3:]
    )


def _replace_preserving_lines(match: re.Match[str]) -> str:
    replacement = "true"
    return replacement + "".join(
        "\n" if character == "\n" else " "
        for character in match.group(0)[len(replacement) :]
    )


def _normalize_bash_conditionals(script: str) -> str:
    # bashlex does not implement [[ ... ]]. Replace the conditional expression
    # with a same-line-count command so its path operands remain data while the
    # surrounding shell control flow stays parseable.
    return BASH_CONDITIONAL.sub(_replace_preserving_lines, script)


class _ExecutionAnalyzer:
    def __init__(self, script: str, step_line: int) -> None:
        self.script = script
        self.step_line = step_line
        self.events: list[RunEvent] = []
        self.parse_errors: list[str] = []
        self.functions: dict[str, object] = {}
        self.active_functions: set[str] = set()

    def analyze(
        self, roots: list[object], *, failure_propagates: bool = True,
    ) -> list[RunEvent]:
        for root in roots:
            self._execute(root, failure_propagates=failure_propagates)
        return self.events

    def _line(self, node: object) -> int:
        position = getattr(node, "pos", (0, 0))[0]
        return self.step_line + self.script.count("\n", 0, position)

    def _execute(self, node: object, *, failure_propagates: bool) -> None:
        kind = getattr(node, "kind", None)
        if kind == "function":
            name = getattr(getattr(node, "name", None), "word", None)
            body = getattr(node, "body", None)
            if name is not None and body is not None:
                self.functions[name] = body
            return
        if kind == "command":
            self._execute_command(node, failure_propagates=failure_propagates)
            return
        if kind == "list":
            self._execute_list(node, failure_propagates=failure_propagates)
            return
        if kind == "if":
            children = list(_child_nodes(node))
            for index, child in enumerate(children):
                child_propagates = failure_propagates and index > 1
                self._execute(child, failure_propagates=child_propagates)
            return
        for child in _child_nodes(node):
            self._execute(child, failure_propagates=failure_propagates)

    def _execute_list(self, node: object, *, failure_propagates: bool) -> None:
        parts = list(getattr(node, "parts", ()))
        for index, part in enumerate(parts):
            if getattr(part, "kind", None) == "operator":
                continue
            next_operator = (
                getattr(parts[index + 1], "op", None)
                if index + 1 < len(parts)
                else None
            )
            self._execute(
                part,
                failure_propagates=(
                    failure_propagates and next_operator not in {"&&", "||"}
                ),
            )

    def _execute_expansions(self, node: object, *, failure_propagates: bool,) -> None:
        kind = getattr(node, "kind", None)
        if kind == "commandsubstitution":
            for child in _child_nodes(node):
                self._execute(child, failure_propagates=failure_propagates)
            return
        if kind == "processsubstitution":
            for child in _child_nodes(node):
                self._execute(child, failure_propagates=False)
            return
        for child in _child_nodes(node):
            self._execute_expansions(
                child, failure_propagates=failure_propagates,
            )

    def _execute_command(self, command: object, *, failure_propagates: bool,) -> None:
        words = _executable_words(_command_words(command))
        expansion_propagates = failure_propagates and not words
        for part in getattr(command, "parts", ()):
            self._execute_expansions(
                part, failure_propagates=expansion_propagates,
            )

        if not words:
            return

        target = words[0]
        function_body = self.functions.get(target)
        if function_body is not None:
            if target not in self.active_functions:
                self.active_functions.add(target)
                self._execute(
                    function_body, failure_propagates=failure_propagates,
                )
                self.active_functions.remove(target)
            return

        line = self._line(command)
        if _is_ghostty_init(words):
            self.events.append(RunEvent(kind="init", line=line))

        if _command_name(target) in SHELL_INTERPRETERS:
            shell_target = _shell_command_or_script(words)
            if shell_target is None:
                return
            target_kind, target_value = shell_target
            if target_kind == "command":
                nested_events, parse_error = _run_events(
                    target_value, line, failure_propagates=failure_propagates,
                )
                self.events.extend(nested_events)
                if parse_error is not None:
                    self.parse_errors.append(
                        f"cannot parse shell -c command at line {line}: {parse_error}"
                    )
                return
            target = target_value
        elif target in {"source", "."}:
            target = words[1] if len(words) > 1 else ""

        consumer = _consumer_name(target)
        if consumer is not None:
            self.events.append(
                RunEvent(
                    kind="consumer",
                    line=line,
                    consumer=consumer,
                    failure_propagates=failure_propagates,
                )
            )


def _run_events(
    script: str, step_line: int, *, failure_propagates: bool = True,
) -> tuple[list[RunEvent], str | None]:
    if not any(name in script for name in CONSUMER_NAMES) and (
        "git submodule" not in script or "ghostty" not in script
    ):
        return [], None

    normalized = _normalize_bash_conditionals(_normalize_heredocs(script))
    try:
        roots = bashlex.parse(normalized)
    except (bashlex.errors.ParsingError, NotImplementedError) as error:
        return [], str(error)

    analyzer = _ExecutionAnalyzer(normalized, step_line)
    events = analyzer.analyze(roots, failure_propagates=failure_propagates)
    parse_error = "; ".join(analyzer.parse_errors) or None
    return events, parse_error


def _checkout_initializes_ghostty(step: Step) -> bool:
    return (
        step.uses is not None
        and step.uses.startswith(CHECKOUT_ACTION)
        and step.inputs.get("submodules", "").lower() in {"true", "recursive"}
    )


def _job_events(path: Path, job: Job,) -> tuple[list[tuple[int, RunEvent]], list[str]]:
    events: list[tuple[int, RunEvent]] = []
    failures: list[str] = []
    for step_index, step in enumerate(job.steps):
        if _checkout_initializes_ghostty(step):
            events.append((step_index, RunEvent(kind="init", line=step.line)))
        if step.run is None:
            continue
        run_events, parse_error = _run_events(step.run, step.run_line or step.line,)
        if parse_error is not None:
            failures.append(
                f"{path.name}:{step.run_line or step.line}: "
                f"{job.name} cannot parse relevant run "
                f"step {step.name!r}: {parse_error}"
            )
            continue
        events.extend((step_index, event) for event in run_events)
    return events, failures


def _setup_zig_failures(
    path: Path, job: Job, events: list[tuple[int, RunEvent]],
) -> tuple[list[str], bool]:
    setup_steps = [
        (index, step)
        for index, step in enumerate(job.steps)
        if step.uses is not None and step.uses.startswith(SETUP_ZIG_ACTION)
    ]
    if not setup_steps:
        return [], False

    failures: list[str] = []
    init_events = [(index, event) for index, event in events if event.kind == "init"]
    resolver_steps = [
        (index, step)
        for index, step in enumerate(job.steps)
        if step.identifier == "ghostty-zig-version"
    ]
    helper_events = [
        (index, event)
        for index, event in events
        if event.kind == "consumer"
        and event.consumer == "scripts/ghostty-zig-version.sh"
    ]

    def fail(message: str) -> None:
        failures.append(f"{path.name}: job {job.name}: {message}")

    if len(init_events) != 1:
        fail("expected exactly one Ghostty submodule initialization")
    if len(resolver_steps) != 1:
        fail("expected exactly one Ghostty Zig resolver step")
    if len(helper_events) != 1:
        fail("resolver must execute scripts/ghostty-zig-version.sh exactly once")
    if len(setup_steps) != 1:
        fail("expected exactly one setup-zig action")

    if len(resolver_steps) == 1 and len(helper_events) == 1:
        resolver_index, _ = resolver_steps[0]
        helper_index, helper_event = helper_events[0]
        if helper_index != resolver_index:
            fail("Ghostty Zig resolver step must execute the version helper")
        if not helper_event.failure_propagates:
            fail("Ghostty Zig resolver step must propagate version helper failures")

    if len(setup_steps) == 1:
        _, setup_step = setup_steps[0]
        if setup_step.inputs.get("version") != SETUP_ZIG_VERSION:
            fail("setup-zig must use the resolver output in its own step")

    if (
        len(init_events) == 1
        and len(resolver_steps) == 1
        and len(helper_events) == 1
        and len(setup_steps) == 1
    ):
        init_index, _ = init_events[0]
        resolver_index, _ = resolver_steps[0]
        helper_index, _ = helper_events[0]
        setup_index, _ = setup_steps[0]
        if not (
            init_index < resolver_index
            and resolver_index == helper_index
            and helper_index < setup_index
        ):
            fail("expected ordered Ghostty init -> resolver -> setup-zig wiring")

    return failures, True


def workflow_failures(
    workflow_dir: Path, *, require_setup_zig: bool = False,
) -> list[str]:
    failures: list[str] = []
    validated_setup_jobs = 0
    paths = sorted((*workflow_dir.glob("*.yml"), *workflow_dir.glob("*.yaml")))
    for path in paths:
        jobs, parse_failures = _workflow_jobs(path)
        failures.extend(parse_failures)
        for job in jobs:
            events, event_failures = _job_events(path, job)
            failures.extend(event_failures)

            initialized = False
            for _, event in events:
                if event.kind == "init":
                    initialized = True
                elif event.kind == "consumer" and not initialized:
                    failures.append(
                        f"{path.name}:{event.line}: {job.name} executes "
                        f"{event.consumer} before Ghostty submodule init"
                    )

            if path.name in TUI_WORKFLOW_NAMES:
                setup_failures, validated = _setup_zig_failures(path, job, events)
                failures.extend(setup_failures)
                validated_setup_jobs += int(validated)

    if require_setup_zig and validated_setup_jobs == 0:
        failures.append("No setup-zig jobs were validated")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("workflow_dir", type=Path)
    parser.add_argument("--require-setup-zig", action="store_true")
    arguments = parser.parse_args()

    failures = workflow_failures(
        arguments.workflow_dir, require_setup_zig=arguments.require_setup_zig,
    )
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
