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

# Runner variables whose purpose is the paid overflow path, and the free label
# each must fall back to (the "Intended steady state" in docs/ci-runners.md).
# Each selects a lane that runs on every push to main or in the merge queue,
# where nobody is watching a check name closely enough to notice the pool
# changed under it. The fallback is pinned because a gate with the wrong
# literal moves the lane silently: the nightly builder once fell back to 6vcpu,
# half its intended 12.
#
# This is not a list of every runner variable, and adding one here is not a
# free safety improvement. The gate asks "may we spend money", so a variable
# that selects a free pool does not belong: gating it would mean repointing
# that pool -- at owned Mac hardware, say -- required turning the paid-overflow
# flag on. MACOS_RUNNER_26 is deliberately absent for that reason. What guards
# a variable outside this table is the value policy in runner_label_policy.py.
PAID_CAPABLE_RUNNER_VARS = {
    "MACOS_RUNNER_15": "blacksmith-6vcpu-macos-15",
    "MACOS_RUNNER_DISPLAY": "blacksmith-6vcpu-macos-15",
    "MACOS_RUNNER_DUAL_XCODE": "blacksmith-6vcpu-macos-15",
    "MACOS_RUNNER_26_LARGE": "blacksmith-12vcpu-macos-26",
}

# The gate as it must appear immediately before the read. The lookbehind keeps
# `inputs.CI_PAID_MACOS_OVERFLOW == '1' && ` from passing for the repository's
# own flag.
PAID_OVERFLOW_GATE_PREFIX = re.compile(
    rf"(?<![\w.])vars\.{PAID_OVERFLOW_GATE} == '1' && $"
)

# (workflow, env key) -> why this read of a paid-capable variable is not a
# runner selection and must NOT carry the gate.
#
# The gate answers "should this job run on metered capacity". A read that
# reports the variable's value is asking a different question, and gating it
# inverts the answer: with the gate unset, `vars.GATE == '1' && vars.NAME`
# evaluates to false, so the reporter would see an empty string and conclude
# the configuration is clean no matter what the variable actually holds. The
# one place that can see runner values would go blind exactly when it matters.
GATE_EXEMPT_REPORTING_READS = {
    ("ci-health-report.yml", "CMUX_CI_RUNNER_VARIABLES"):
        "reports each runner variable's value; gating would report empty",
}


def reporting_env_key(lines: list[str], number: int) -> str | None:
    """The env key whose block scalar contains line `number`, if any.

    Reads inside a `KEY: |` block are values being collected, not an
    expression selecting a runner.
    """
    indent = len(lines[number - 1]) - len(lines[number - 1].lstrip())
    for previous in range(number - 2, -1, -1):
        text = lines[previous]
        if not text.strip() or text.lstrip().startswith("#"):
            continue
        current = len(text) - len(text.lstrip())
        if current >= indent:
            continue
        matched = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*):\s*[|>]", text)
        return matched.group(1) if matched else None
    return None


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
    2026-09-23 every variable in the table above, plus the release lane's former variable, pointed at WarpBuild, so main and the merge
    queue ran on metered capacity while pull requests ran free on Blacksmith.
    Nothing in the repository could see it, because a variable's value is not
    reviewable and every other guard here reads workflow text.

    The gate restores the polarity the rest of this file assumes: stopping spend
    is a pull request anyone with push access can merge, and starting it needs
    both an admin-set runner variable and CI_PAID_MACOS_OVERFLOW=1. Unset, the
    literal Blacksmith fallback wins, which is the cheap path.
    """
    lines = path.read_text(encoding="utf-8").splitlines()
    for number, line in enumerate(lines, start=1):
        if line.lstrip().startswith("#"):
            continue
        for name, free_label in PAID_CAPABLE_RUNNER_VARS.items():
            for read in re.finditer(rf"vars\.{name}\b", line):
                if not PAID_OVERFLOW_GATE_PREFIX.search(line[: read.start()]):
                    key = reporting_env_key(lines, number)
                    if key is not None and (path.name, key) in GATE_EXEMPT_REPORTING_READS:
                        continue
                    errors.append(
                        f"{path.name}:{number}: vars.{name} is read without the "
                        f"paid overflow gate. It can hold a metered WarpBuild "
                        f"label, so write `vars.{PAID_OVERFLOW_GATE} == '1' && "
                        f"vars.{name} || '{free_label}'`"
                    )
                    continue
                fallback = re.match(r"\s*\|\|\s*'([^']+)'", line[read.end():])
                if fallback is None or fallback.group(1) != free_label:
                    actual = fallback.group(1) if fallback else "nothing"
                    errors.append(
                        f"{path.name}:{number}: gated vars.{name} falls back to "
                        f"{actual!r}, but its free steady state is {free_label!r}"
                    )


def self_test_gate_matcher(errors: list[str]) -> None:
    """The reporting exemption must not become a hole in the gate.

    An exemption that quietly widened would disable the check for the exact
    variables it exists to protect, and nothing else here would notice: the
    guard would keep printing PASS. These probes pin both directions.
    """
    import tempfile

    free = PAID_CAPABLE_RUNNER_VARS["MACOS_RUNNER_15"]
    probes = (
        ("other.yml",
         f"runs-on: ${{{{ vars.MACOS_RUNNER_15 || '{free}' }}}}", 1,
         "an ungated runs-on"),
        ("other.yml",
         f"runs-on: ${{{{ vars.{PAID_OVERFLOW_GATE} == '1' && vars.MACOS_RUNNER_15"
         f" || '{free}' }}}}",
         0, "a gated runs-on"),
        ("other.yml",
         "    env:\n      SOME_OTHER_KEY: |\n        A=${{ vars.MACOS_RUNNER_15 }}",
         1, "an ungated read under a non-exempt env key"),
        ("ci-health-report.yml",
         "    env:\n      CMUX_CI_RUNNER_VARIABLES: |\n        A=${{ vars.MACOS_RUNNER_15 }}",
         0, "the exempt reporting block"),
    )
    with tempfile.TemporaryDirectory() as directory:
        for filename, body, expected, description in probes:
            probe = Path(directory) / filename
            probe.write_text(body + "\n", encoding="utf-8")
            found: list[str] = []
            check_paid_overflow_gate(probe, found)
            if len(found) != expected:
                errors.append(
                    f"paid-overflow gate self-test: {description} produced "
                    f"{len(found)} error(s), expected {expected}"
                )


def main() -> int:
    errors: list[str] = []
    files = workflow_files()
    if not files:
        print(f"no workflows found under {WORKFLOWS}", file=sys.stderr)
        return 1
    self_test_gate_matcher(errors)
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
