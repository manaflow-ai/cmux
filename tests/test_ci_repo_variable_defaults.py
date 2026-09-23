#!/usr/bin/env python3
"""Unset repository variables must select the cheap path, not the expensive one.

Fork pull requests receive no repository variables, so every `vars.X` a
workflow reads can arrive empty. #13717 found CI silently running the full
macOS suite and missing every cache restore because three expressions had no
literal fallback. That fix edited the sites it found; nothing stopped the next
copy of the same expression from landing without one, and several did.

Two rules, both checked against the workflows themselves rather than a list of
known-good sites:

1. A `runs-on:` that reads a repository variable needs a literal runner label
   to fall back to. An empty `runs-on:` cannot schedule at all.
2. A variable that selects how much work to do, or where a cache lives, needs
   the repository's own value written next to it as a literal. The table below
   is the one hand-maintained part, and it names three variables, not the
   dozens of sites that read them.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# variable -> the literal the repository sets, which an unset read must use.
# Each is cheap: the compile-only suite over the full macOS suite, and the
# cache the repository actually populates over no cache at all.
CHEAP_DEFAULTS = {
    "CI_PULL_REQUEST_SUITE": "compile-only",
    "CI_CACHE_BACKEND": "r2",
    "CI_CACHE_R2_PUBLIC_URL": "https://ci-cache.cmux.com",
}

VARS_REFERENCE = re.compile(r"vars\.([A-Z0-9_]+)")
RUNS_ON = re.compile(r"^\s*runs-on:\s*(.+?)\s*$")

# The repository-side switch for metered macOS capacity. Unset is the cheap
# reading, so a fork pull request and a repository with no admin action both
# land on the free Blacksmith fallback.
PAID_OVERFLOW_GATE = "CI_PAID_MACOS_OVERFLOW"

# Runner variables that have held a WarpBuild label. Each selects a lane that
# runs on every push to main or in the merge queue, where nobody is watching a
# check name closely enough to notice the pool changed under it.
PAID_CAPABLE_RUNNER_VARS = (
    "MACOS_RUNNER_15",
    "MACOS_RUNNER_DISPLAY",
    "MACOS_RUNNER_DUAL_XCODE",
    "MACOS_RUNNER_26_RELEASE",
    "MACOS_RUNNER_26_NIGHTLY_BUILD",
)


def workflow_files() -> list[Path]:
    return sorted(WORKFLOWS.glob("*.y*ml"))


def follows_with_literal_default(text: str, end: int) -> bool:
    """True when `... || 'literal'` immediately follows the variable read."""
    return re.match(r"\s*\|\|\s*'[^']+'", text[end:]) is not None


def is_comparison(text: str, end: int) -> bool:
    """True for `vars.X == '...'`, where an empty value already compares false.

    A comparison is the cheap reading on its own: unset means the expensive
    branch is not selected, which is exactly the behavior this file wants.
    """
    return re.match(r"\s*\)?\s*(==|!=)", text[end:]) is not None


def default_chain_reaches_literal(text: str, end: int) -> bool:
    """True when a chain of `|| vars.Y || 'literal'` ends in a literal."""
    rest = text[end:]
    while True:
        chained = re.match(r"\s*\|\|\s*vars\.[A-Z0-9_]+", rest)
        if chained is None:
            return re.match(r"\s*\|\|\s*'[^']+'", rest) is not None
        rest = rest[chained.end():]


def check_runs_on(path: Path, errors: list[str]) -> None:
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        matched = RUNS_ON.match(line)
        if matched is None:
            continue
        expression = matched.group(1)
        reads = list(VARS_REFERENCE.finditer(expression))
        if not reads:
            continue
        if any(default_chain_reaches_literal(expression, read.end()) for read in reads):
            continue
        errors.append(
            f"{path.name}:{number}: runs-on reads "
            f"{', '.join(read.group(0) for read in reads)} with no literal runner "
            f"label to fall back to; a fork pull request gets an empty runs-on"
        )


def check_cheap_defaults(path: Path, errors: list[str]) -> None:
    text = path.read_text(encoding="utf-8")
    offset = 0
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.lstrip().startswith("#"):
            for read in VARS_REFERENCE.finditer(line):
                name = read.group(1)
                expected = CHEAP_DEFAULTS.get(name)
                if expected is None:
                    continue
                if is_comparison(line, read.end()):
                    continue
                if follows_with_literal_default(line, read.end()):
                    actual = re.match(r"\s*\|\|\s*'([^']+)'", line[read.end():]).group(1)
                    if actual != expected:
                        errors.append(
                            f"{path.name}:{number}: vars.{name} falls back to "
                            f"{actual!r}, but the repository sets {expected!r}"
                        )
                    continue
                errors.append(
                    f"{path.name}:{number}: vars.{name} has no literal default; "
                    f"a fork pull request reads it as empty. Write "
                    f"`vars.{name} || '{expected}'`"
                )
        offset += len(line) + 1


def check_paid_overflow_gate(path: Path, errors: list[str]) -> None:
    """Reading a paid-capable runner variable requires the repository's own flag.

    Rule 1 covers the variable being *unset*. This covers it being *set*, which
    is the case the repository actually got wrong: between 2026-09-19 and
    2026-09-23 these five variables pointed at WarpBuild, so main and the merge
    queue ran on metered capacity while pull requests ran free on Blacksmith.
    Nothing in the repository could see it, because a variable's value is not
    reviewable and every other guard here reads workflow text.

    The gate restores the polarity the rest of this file assumes: stopping spend
    is a pull request anyone with push access can merge, and starting it needs
    both an admin-set runner variable and CI_PAID_MACOS_OVERFLOW=1. Unset, the
    literal Blacksmith fallback wins, which is the cheap path.
    """
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if line.lstrip().startswith("#"):
            continue
        for name in PAID_CAPABLE_RUNNER_VARS:
            for read in re.finditer(rf"vars\.{name}\b", line):
                if line[: read.start()].endswith(f"{PAID_OVERFLOW_GATE} == '1' && "):
                    continue
                errors.append(
                    f"{path.name}:{number}: vars.{name} is read without the paid "
                    f"overflow gate. It can hold a metered WarpBuild label, so "
                    f"write `vars.{PAID_OVERFLOW_GATE} == '1' && vars.{name} || "
                    f"'<blacksmith label>'`"
                )


def main() -> int:
    errors: list[str] = []
    files = workflow_files()
    if not files:
        print(f"no workflows found under {WORKFLOWS}", file=sys.stderr)
        return 1
    for path in files:
        check_runs_on(path, errors)
        check_cheap_defaults(path, errors)
        check_paid_overflow_gate(path, errors)

    if errors:
        print("Repository variables that an unset value makes expensive:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print(
        f"PASS: repo variable defaults ({len(files)} workflows, "
        f"{len(CHEAP_DEFAULTS)} cheap-default variables)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
