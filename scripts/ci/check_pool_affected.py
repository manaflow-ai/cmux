#!/usr/bin/env python3
"""Mark the check-pool commands a pull request cannot reach: run-checks-concurrently.sh --affected BASE.

A command whose inputs the change leaves as they were gives the base's verdict again; running it proves nothing
(Leo, 2026-11-18: "Don't test b******t that we know vacuously true"). Each command's inputs are the dependency
graph scripts/ci/guard_step_inputs.py reads for a ci-guards.yml step (the same rules: plain test invocations are
followed through their imports, the scripts they run and the data they name; anything it cannot read, a `$VAR`
argument, a pipe, a git read, makes the command whole-tree, so it always runs).

Reads run-checks-concurrently.sh's stdin (`[name]` lines, commands, comments) and writes it back with each
unreached command prefixed `@skip `. Every command runs (nothing is prefixed) when no base is given or readable,
when the change touches the selection itself (SELECTION_INPUTS) or more than guard_step_inputs.MAX_CHANGED paths.
A push to the base runs every command, so a command skipped here still has a verdict on the base.

    check_pool_affected.py --base REV [--head REV] < pool lines > marked lines
    check_pool_affected.py --whole < pool lines         # the whole-tree commands, one per line (WHOLE_BASELINE)
    check_pool_affected.py --verify [--match TEXT] < pool lines   # run declared commands traced; fail on an escape

A whole-tree command runs on every pull request. WHOLE_BASELINE lists the ones that do today; a command added to the
pool must name or declare its reads (`# guard-inputs:` in its source, guard_step_inputs.DECLARED) or be added there
(tests/test_check_pool_whole_baseline.py). --verify runs each command a declaration made selectable under the audit
hook tracer and fails on a file it opens or a folder it lists outside its inputs.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import guard_step_inputs as graph  # noqa: E402

SKIP = "@skip "
NAME_LINE = re.compile(r"\[[A-Za-z0-9_.-]+\]")
# A change to any of these changes which commands run or how: every command runs.
SELECTION_INPUTS = frozenset({
    ".github/workflows/cmux-next.yml",
    "scripts/ci/check_pool_affected.py",
    "scripts/ci/guard_step_inputs.py",
    "scripts/ci/run-checks-concurrently.sh",
    "scripts/ci/timeout.sh",
})


WHOLE_BASELINE = Path(__file__).resolve().parent / "check-pool-whole.txt"


def pool_commands(lines: list[str]) -> list[tuple[str, str]]:
    """(group, command) for each command line, in order."""
    group, found = "", []
    for line in lines:
        command = line.strip()
        if not command or command.startswith("#"):
            continue
        if NAME_LINE.fullmatch(command):
            group = command[1:-1]
            continue
        found.append((group, command))
    return found


def whole(tree: graph.Tree, lines: list[str]) -> list[tuple[str, str]]:
    """(command, why) for each command that reads the whole tree, so runs on every pull request."""
    out = []
    for _group, command in pool_commands(lines):
        why = graph.step_inputs(tree, command, None, frozenset()).whole
        if why:
            out.append((command, why))
    return out


def everything_reason(changed: list[str]) -> str:
    if len(changed) > graph.MAX_CHANGED:
        return f"{len(changed)} changed paths (over {graph.MAX_CHANGED})"
    touched = sorted(SELECTION_INPUTS.intersection(changed))
    if touched:
        return f"the change touches the selection itself ({', '.join(touched)})"
    return ""


def mark(lines: list[str], tree: graph.Tree, changed: list[str]) -> tuple[list[str], int, int]:
    """The lines with each unreached command prefixed SKIP; (lines, commands, skipped)."""
    frozen = frozenset(changed)
    out: list[str] = []
    commands = skipped = 0
    for line in lines:
        command = line.strip()
        if not command or command.startswith("#") or NAME_LINE.fullmatch(command):
            out.append(line)
            continue
        commands += 1
        inputs = graph.step_inputs(tree, command, None, frozen)
        if not inputs.whole and not any(inputs.reaches(path) for path in changed):
            skipped += 1
            out.append(SKIP + command)
        else:
            out.append(line)
    return out, commands, skipped


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--root", default=str(graph.ROOT))
    parser.add_argument("--whole", action="store_true", help="print the whole-tree commands, one per line")
    parser.add_argument("--verify", action="store_true", help="run each declared command traced; fail on an escape")
    parser.add_argument("--match", action="append", default=[], help="with --verify: only commands containing this")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args(argv)
    lines = sys.stdin.read().splitlines()
    if args.whole:
        for command, why in whole(graph.Tree(Path(args.root)), lines):
            print(f"{command}\t{why}")
        return 0
    if args.verify:
        tree = graph.Tree(Path(args.root))
        steps = [(command, command, None) for _g, command in pool_commands(lines)
                 if (not args.match or any(m in command for m in args.match))
                 and graph.step_inputs(tree, command, None, frozenset()).declared]
        return graph.verify(tree, steps, args.jobs, set())
    reason = "" if args.base else "no base"
    changed: list[str] = []
    if not reason:
        try:
            changed = graph.changed_paths(args.base, args.head, root=Path(args.root))
        except Exception as error:  # noqa: BLE001 - a base it cannot read runs everything
            reason = f"cannot diff against {args.base} ({error.__class__.__name__})"
    reason = reason or everything_reason(changed)
    if reason:
        print(f"check-pool affected: every command runs: {reason}", file=sys.stderr)
        sys.stdout.write("".join(line + "\n" for line in lines))
        return 0
    out, commands, skipped = mark(lines, graph.Tree(Path(args.root)), changed)
    print(f"check-pool affected: {len(changed)} changed paths; {commands - skipped} of {commands} commands run, "
          f"{skipped} skipped as their inputs are unchanged", file=sys.stderr)
    sys.stdout.write("".join(line + "\n" for line in out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
