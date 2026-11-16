#!/usr/bin/env python3
"""Linux runner labels come from one place: `.github/runners.json` `pools`.

Leo, 2026-11-16: "why do we have so many files that get affected each time anyways" and
"fewer sources of truth for individual things" (cmuxterm-hq#11721, row "Linux runner labels").
A routing change used to touch 32 to 169 workflow files (#26439, #30360, #30837, #30878, #32457)
because each file typed its Linux labels by hand.

A job's Linux route reads its size's pool, which scripts/ci/runner_pools.py keeps live in the
RUNNER_POOLS repository variable:

    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-4vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_4 }}

Two literals stay, because the places they run read no repository variables:

- the owner branch, `github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'` (or `-arm`):
  a copy of the repository on another account, where GitHub's own Ubuntu image is the only label;
- the fork pull request branch, `head.repo.full_name != github.repository && '<label>'`: it must be
  the first member of the pool the same expression reads last (runners.json is its source).
  `--fix` rewrites a fork label that disagrees, so a pool change is runners.json plus `--fix`,
  never a hand edit across files.

Every other Linux label typed in a workflow is refused, except where BASELINE (one line per file,
`<count> <path>`) still lists it. The baseline only shrinks: a file over its count fails, and
`--update-baseline` rewrites it after labels were removed. What is left in it is either a pinned
security selector (the CI_TRUSTED_RUNNER list that scripts/ci/validate-cla-policy.rb and
tests/test_ci_self_hosted_guard.sh check verbatim), a hosted-first light job, or a label list a
bounded selector compares against.

Usage:
    linux_runner_labels.py                    check (CI: ci-guards.yml, group ci)
    linux_runner_labels.py --count            files and lines with hand-typed Linux labels
    linux_runner_labels.py --fix              rewrite fork labels from runners.json
    linux_runner_labels.py --update-baseline  shrink the baseline to today's counts
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNNERS = ROOT / ".github" / "runners.json"
BASELINE = ROOT / "scripts" / "ci" / "linux-runner-labels-baseline.txt"
SCANNED = (".github/workflows", ".github/actions")

# A Linux runner label: Blacksmith Ubuntu sizes, GitHub-hosted Ubuntu, owned fleet Linux.
LABEL = re.compile(
    r"(?<![\w.-])(?:blacksmith-\d+vcpu-ubuntu-\d+(?:-arm)?|ubuntu-(?:latest|\d\d\.\d\d)(?:-arm)?"
    r"|cmux-fleet-linux-[a-z0-9-]+)(?![\w.-])"
)
OWNER_BRANCH = re.compile(r"github\.repository_owner != 'manaflow-ai' && 'ubuntu-24\.04(?:-arm)?'")
FORK_BRANCH = re.compile(
    r"(github\.event\.pull_request\.head\.repo\.full_name != github\.repository && )'([^']+)'"
)
POOL_READ = re.compile(r"fromJSON\(vars\.RUNNER_POOLS\)\.([a-z][a-z0-9_]*)")
LINUX_POOL = re.compile(r"^linux(?:_[a-z0-9]+)?$")


def pool_defaults(path: Path = RUNNERS) -> dict[str, str]:
    """Each pool's declared first member: the label a fork pull request takes for that pool."""
    pools = json.loads(path.read_text())["pools"]
    return {name: spec["members"][0] for name, spec in pools.items() if not name.startswith("$")}


def workflow_files(root: Path = ROOT) -> list[Path]:
    files: list[Path] = []
    for top in SCANNED:
        base = root / top
        if base.is_dir():
            files += [p for p in base.rglob("*") if p.suffix in (".yml", ".yaml") and p.is_file()]
    return sorted(files)


def code_part(line: str) -> str:
    """The line without a YAML comment: a whole-line comment is empty, a trailing one after `}}` is cut."""
    stripped = line.lstrip()
    if stripped.startswith("#"):
        return ""
    end = line.rfind("}}")
    cut = line.find(" #", end + 2 if end >= 0 else 0)
    return line if cut < 0 else line[:cut]


def fork_problem(code: str, defaults: dict[str, str]) -> tuple[str, str] | None:
    """(found, wanted) when a fork branch's label is not the first member of the pool the line reads last."""
    fork = FORK_BRANCH.search(code)
    if not fork or not LABEL.fullmatch(fork.group(2)):
        return None
    pools = [pool for pool in POOL_READ.findall(code) if LINUX_POOL.match(pool)]
    if not pools or pools[-1] not in defaults:
        return (fork.group(2), "")
    wanted = defaults[pools[-1]]
    return None if fork.group(2) == wanted else (fork.group(2), wanted)


def hand_typed(code: str, defaults: dict[str, str]) -> list[str]:
    """The Linux labels a line types by hand: everything but the owner branch and a fork branch that matches its pool."""
    if "runner.name" in code:
        # Comparisons against a runner's own name (the ephemeral-machine identity check), not a route.
        return []
    code = OWNER_BRANCH.sub("", code)
    fork = FORK_BRANCH.search(code)
    if fork and fork_problem(code, defaults) is None:
        code = code[: fork.start(2)] + code[fork.end(2):]
    return LABEL.findall(code)


def scan(root: Path = ROOT, defaults: dict[str, str] | None = None) -> dict[str, list[tuple[int, str]]]:
    defaults = pool_defaults(root / ".github" / "runners.json") if defaults is None else defaults
    found: dict[str, list[tuple[int, str]]] = {}
    for path in workflow_files(root):
        rel = path.relative_to(root).as_posix()
        for number, line in enumerate(path.read_text().splitlines(), 1):
            labels = hand_typed(code_part(line), defaults)
            if labels:
                found.setdefault(rel, []).extend((number, label) for label in labels)
    return found


def load_baseline(path: Path = BASELINE) -> dict[str, int]:
    counts: dict[str, int] = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if line.strip() and not line.startswith("#"):
                count, rel = line.split(maxsplit=1)
                counts[rel] = int(count)
    return counts


def write_baseline(found: dict[str, list[tuple[int, str]]], path: Path = BASELINE) -> None:
    header = (
        "# Linux runner labels still typed by hand, per workflow file (scripts/ci/linux_runner_labels.py).\n"
        "# Only shrinks: read the label from fromJSON(vars.RUNNER_POOLS).<pool> (.github/runners.json pools)\n"
        "# and run `python3 scripts/ci/linux_runner_labels.py --update-baseline`.\n"
    )
    body = "".join(f"{len(hits)} {rel}\n" for rel, hits in sorted(found.items()))
    path.write_text(header + body)


def fix(root: Path = ROOT) -> int:
    defaults = pool_defaults(root / ".github" / "runners.json")
    changed = 0
    for path in workflow_files(root):
        text = path.read_text()
        lines = text.splitlines(keepends=True)
        for i, line in enumerate(lines):
            problem = fork_problem(code_part(line), defaults)
            if problem and problem[1]:
                wanted = problem[1]
                lines[i] = FORK_BRANCH.sub(lambda m: f"{m.group(1)}'{wanted}'", line, count=1)
        new = "".join(lines)
        if new != text:
            path.write_text(new)
            changed += 1
    return changed


def check(root: Path = ROOT, baseline: dict[str, int] | None = None) -> list[str]:
    defaults = pool_defaults(root / ".github" / "runners.json")
    baseline = load_baseline(root / BASELINE.relative_to(ROOT)) if baseline is None else baseline
    problems: list[str] = []
    for path in workflow_files(root):
        rel = path.relative_to(root).as_posix()
        for number, line in enumerate(path.read_text().splitlines(), 1):
            problem = fork_problem(code_part(line), defaults)
            if problem and problem[1]:
                problems.append(
                    f"{rel}:{number}: fork branch names '{problem[0]}', but the pool this line reads starts with "
                    f"'{problem[1]}' (.github/runners.json pools); run python3 scripts/ci/linux_runner_labels.py --fix")
    for rel, hits in sorted(scan(root, defaults).items()):
        allowed = baseline.get(rel, 0)
        if len(hits) > allowed:
            where = ", ".join(f"line {n} '{label}'" for n, label in hits)
            problems.append(
                f"{rel}: {len(hits)} hand-typed Linux runner label(s), baseline allows {allowed} ({where}). "
                "Read the label from the pool instead: fromJSON(vars.RUNNER_POOLS).<pool> (.github/runners.json "
                "pools: linux, linux_2, linux_4, linux_8, linux_16, linux_32, linux_arm64, provenance)")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--count", action="store_true")
    mode.add_argument("--fix", action="store_true")
    mode.add_argument("--update-baseline", action="store_true")
    args = parser.parse_args(argv)
    if args.count:
        found = scan()
        for rel, hits in sorted(found.items()):
            print(f"{len(hits):4d} {rel}")
        print(f"{len(found)} files, {sum(len(h) for h in found.values())} hand-typed Linux runner labels")
        return 0
    if args.fix:
        print(f"rewrote fork labels in {fix()} files")
        return 0
    if args.update_baseline:
        found = scan()
        old = load_baseline()
        grown = [rel for rel, hits in found.items() if len(hits) > old.get(rel, 0)]
        if grown and BASELINE.exists():
            print("refusing to grow the baseline: " + ", ".join(grown), file=sys.stderr)
            return 1
        write_baseline(found)
        print(f"baseline: {len(found)} files")
        return 0
    problems = check()
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    print("Linux runner labels: every route reads .github/runners.json pools (or a baselined literal)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
