#!/usr/bin/env python3
"""Fail when a workflow job's `runs-on` names a literal Linux runner label outside a fork-only branch.

Leo, 2026-11-19: "why are there even 20,000? What are the 20,000 [jobs] doing?" At 20:12Z
28,318 cmux jobs were queued, and 1,822 of the 2,284 jobs queued since 19:40Z targeted labels
no runner served, because their workflows hardcoded `blacksmith-*-ubuntu-*` / `ubuntu-*` labels.
A label in a repository variable can be moved in one `gh variable set`; a label in workflow text
needs a PR on every branch. So same-repository Linux jobs read their label from
`fromJSON(vars.RUNNER_POOLS).<key>` (linux, linux_2 .. linux_32, linux_arm64, promotion, provenance).

Allowed: a literal inside an `||` alternative whose `&&` chain is fork-only, at that level or an
enclosing one: `github.repository_owner != 'manaflow-ai'` (a fork repository, which has no
variables) or `head.repo.full_name != github.repository` / `head.repo.fork` (a fork pull request,
which gets no variables either). Everything else is a hit, unless EXCEPTIONS lists the job with
its reason.

Reads `runs-on` as a string, a list, or a mapping's labels, with `${{ matrix.KEY }}` expanded to
each value the matrix gives it (tests/workflow_jobs.py).

Usage: check_runs_on_pools.py [WORKFLOW_DIR_OR_FILE ...]   (default: .github/workflows)
       --count prints hits per file and always exits 0.
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT / "tests") not in sys.path:
    sys.path.append(str(ROOT / "tests"))

LINUX_LABEL = re.compile(r"^(?:blacksmith-[\w.-]*ubuntu[\w.-]*|ubuntu-[\w.-]+)$")
STRING = re.compile(r"'(?:[^']|'')*'")
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.S)
FORK_ONLY = re.compile(
    r"repository_owner\s*!=\s*'manaflow-ai'"
    r"|github\.repository\s*!=\s*'manaflow-ai/cmux'"
    r"|head\.repo\.full_name\s*!=\s*github\.repository"
    r"|github\.repository\s*!=\s*github\.event\.pull_request\.head\.repo\.full_name"
    r"|(?<!!)github\.event\.pull_request\.head\.repo\.fork(?!\s*(?:==\s*false|!=\s*true))"
)

# (workflow file name, job id) -> why the job keeps a literal Linux label. Keep it small. GitHub-hosted labels
# are never an exception: they start nothing in manaflow-ai (check_no_hosted_runs_on.py; Leo, 2026-11-21: "the ci
# must flow"), so the nightly's secret-holding Linux jobs take the one-job cmux-gcp-nightly-jit-x64 label.
EXCEPTIONS: dict[tuple[str, str], str] = {
    # .github/language-boundaries.toml: a PR that changes this workflow fails the check unless Leo labels it (the boundaries
    # are his call), so its fallback label moves only in a PR he approves.
    ("language-boundaries.yml", "language-boundaries"): "language-boundaries.yml is Leo's to change",
}

# A runs-on line frozen to the literal it resolved to (scripts/ci/one_linux_label.py freeze_line, 2026-11-24: "no
# runs-on line that reads a variable") keeps its reason in a comment: a credentialed, signing or write-token job on its
# ephemeral vendor label, a provenance job on GitHub-hosted Ubuntu. MARK names which comment admits which kind.
EPHEMERAL_MARK = re.compile(r"#.*\b(?:ephemeral-required|owned-pool-unfit|frozen-label):")
HOSTED_MARK = re.compile(r"#.*\bgithub-hosted-required:")
JOB_HEADER = re.compile(r"^  ([A-Za-z_][\w-]*):\s*(?:#.*)?$")
RUNS_ON_LINE = re.compile(r"^    runs-on:")


def marked_jobs(text: str, mark: re.Pattern[str]) -> set[str]:
    """Job ids whose `runs-on:` line carries MARK's comment."""
    found, job = set(), ""
    for line in text.splitlines():
        if header := JOB_HEADER.match(line):
            job = header.group(1)
        elif job and RUNS_ON_LINE.match(line) and mark.search(line):
            found.add(job)
    return found


COMPARISON = re.compile(r"(?:==|!=)\s*$")
COMPARED = re.compile(r"^\s*(?:==|!=)")


# The CI_TRUSTED_RUNNER selector's last term: a one-job Blacksmith VM. Its jobs hold write tokens or parse untrusted
# input (`# ephemeral-required`), so they never read RUNNER_POOLS, whose x64 pools lead with the persistent
# cmux-fleet-linux-x64 pool (#47803); tests/test_ci_fork_runner_routing.py pins the exact selector.
TRUSTED_FALLBACK = re.compile(r"vars\.CI_TRUSTED_RUNNER\)\s*&&\s*vars\.CI_TRUSTED_RUNNER\s*\|\|\s*$")
TRUSTED_FALLBACK_LABELS = ("blacksmith-2vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404")


def is_trusted_selector_fallback(body: str, start: int, value: str) -> bool:
    """`... vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || 'blacksmith-4vcpu-ubuntu-2404'`: the selector's
    ephemeral fallback, not a pool choice."""
    return value in TRUSTED_FALLBACK_LABELS and bool(TRUSTED_FALLBACK.search(_blank_strings(body[:start])))


def is_comparison_operand(body: str, start: int, end: int) -> bool:
    """`vars.X == 'ubuntu-24.04'` compares against a label; it does not pick one."""
    return bool(COMPARISON.search(_blank_strings(body[:start])) or COMPARED.match(body[end:]))


def _blank_strings(text: str) -> str:
    return STRING.sub(lambda m: "'" + " " * (len(m.group()) - 2) + "'", text)


def _depths(text: str) -> list[int]:
    """Paren depth at each character, strings blanked so a ( in a literal does not count."""
    plain, depth, out = _blank_strings(text), 0, []
    for ch in plain:
        if ch == ")":
            depth -= 1
        out.append(depth)
        if ch == "(":
            depth += 1
    return out


def _alternative(text: str, depths: list[int], pos: int, start: int, end: int, level: int) -> tuple[int, int]:
    """Bounds of the `||` alternative at `level` within [start, end) that holds `pos`."""
    plain = _blank_strings(text)
    cuts = [i for i in range(start, end - 1) if plain[i:i + 2] == "||" and depths[i] == level]
    lo, hi = start, end
    for cut in cuts:
        if cut < pos:
            lo = cut + 2
        elif hi == end:
            hi = cut
    return lo, hi


def literal_is_fork_only(expression: str, pos: int) -> bool:
    """Whether the string literal at `pos` sits in an alternative some enclosing level gates to forks."""
    depths = _depths(expression)
    plain = _blank_strings(expression)
    level = depths[pos]
    while True:
        # The group at `level` around pos: back to the unmatched (, forward to its ).
        start = 0
        for i in range(pos, -1, -1):
            if plain[i] == "(" and depths[i] == level - 1:
                start = i + 1
                break
        end = len(expression)
        for i in range(pos, len(expression)):
            if plain[i] == ")" and depths[i] == level - 1:
                end = i
                break
        lo, hi = _alternative(expression, depths, pos, start, end, level)
        own = "".join(ch if depths[lo + i] == level else " " for i, ch in enumerate(expression[lo:hi]))
        if FORK_ONLY.search(own):
            return True
        if level == 0:
            return False
        pos, level = start - 1, level - 1


def literal_labels(text: str) -> list[str]:
    """Literal Linux labels in one runs-on value that run outside a fork-only branch."""
    found = []
    spans = [(m.start(), m.end(), m.group(1)) for m in EXPRESSION.finditer(text)]
    outside, at = [], 0
    for start, end, body in spans:
        outside.append(text[at:start])
        at = end
        for m in STRING.finditer(body):
            value = m.group()[1:-1].replace("''", "'")
            if (LINUX_LABEL.match(value) and not is_comparison_operand(body, m.start(), m.end())
                    and not literal_is_fork_only(body, m.start())
                    and not is_trusted_selector_fallback(body, m.start(), value)):
                found.append(value)
    outside.append(text[at:])
    for chunk in outside:
        found += [word for word in re.split(r"[\s,\[\]\"']+", chunk) if LINUX_LABEL.match(word)]
    return found


def job_hits(job: dict) -> list[str]:
    import workflow_jobs  # noqa: PLC0415  (needs PyYAML; tests/ on sys.path)

    hits: list[str] = []
    for item in workflow_jobs.runs_on_items(job):
        if not isinstance(item, str):
            continue
        cells = workflow_jobs.expand_matrix(job, item.strip()) or [item]
        for cell in cells:
            for label in literal_labels(cell):
                if label not in hits:
                    hits.append(label)
    return hits


def workflow_files(args: list[str]) -> list[Path]:
    paths = [Path(a) for a in args] or [ROOT / ".github" / "workflows"]
    files: list[Path] = []
    for path in paths:
        files += sorted([*path.glob("*.yml"), *path.glob("*.yaml")]) if path.is_dir() else [path]
    return files


def hits(files: list[Path]) -> list[tuple[str, str, list[str]]]:
    import yaml  # noqa: PLC0415

    found = []
    for path in files:
        text = path.read_text(encoding="utf-8")
        doc = yaml.load(text, Loader=yaml.BaseLoader) or {}
        jobs = doc.get("jobs") if isinstance(doc, dict) else None
        marked = marked_jobs(text, EPHEMERAL_MARK) | marked_jobs(text, HOSTED_MARK)
        for job_id, job in (jobs or {}).items():
            if not isinstance(job, dict) or (path.name, job_id) in EXCEPTIONS:
                continue
            labels = [label for label in job_hits(job)
                      if not (job_id in marked and (label.startswith("blacksmith-") or job_id in marked_jobs(text, HOSTED_MARK)))]
            if labels:
                found.append((path.name, job_id, labels))
    return found


def main(argv: list[str]) -> int:
    count = "--count" in argv
    args = [a for a in argv if a != "--count"]
    found = hits(workflow_files(args))
    if count:
        per_file = Counter(name for name, _, _ in found)
        for name, n in sorted(per_file.items()):
            print(f"{n:4d} {name}")
        print(f"{len(found):4d} jobs in {len(per_file)} files")
        return 0
    for name, job_id, labels in found:
        print(f"{name} {job_id}: runs-on names {', '.join(labels)} outside a fork-only branch. Fix: read "
              "fromJSON(vars.RUNNER_POOLS).<linux|linux_2..linux_32|linux_arm64|promotion|provenance> "
              "(or add the job to EXCEPTIONS in scripts/ci/check_runs_on_pools.py with its reason)")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
