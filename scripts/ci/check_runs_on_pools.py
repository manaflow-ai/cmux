#!/usr/bin/env python3
"""Fail when a same-repository Linux job picks its runner instead of naming the runner pool.

Linux CI is one persistent runner pool (cmuxterm-hq decisions/junctions.md, 2026-11-20, Leo: "let this thing run,
we can clean up at some later point, let our caches do work, install stuff properly"). A same-repository Linux job
says `'cmux-linux'`; a fork keeps its GitHub-hosted or one-job branch. Two kinds of hit:

- a literal `blacksmith-*-ubuntu-*` / `ubuntu-*` label outside a fork-only branch (on 2026-11-19 1,822 of 2,284
  queued jobs targeted labels no runner served);
- a picker: a runs-on that reads `vars.RUNNER_POOLS`, `vars.LINUX_RUNNER`, `vars.CI_CLOUD_OVERFLOW_SAVED` or
  `vars.CI_LINUX_GATE_OWNED_RUNNER`, unless it keeps its runner for a reason the pool cannot meet: the line says
  `# ephemeral-required` or `# github-hosted-required`, the job holds signing or release material (rule 7 of
  tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py: ephemeral runner), or the expression is a
  trusted-runner, nightly, macOS, Windows, Arm or placement-output route (KEEP below).

Allowed literals: inside an `||` alternative whose `&&` chain is fork-only, at that level or an enclosing one:
`github.repository_owner != 'manaflow-ai'` (a fork repository) or `head.repo.full_name != github.repository` /
`head.repo.fork` (a fork pull request). Everything else is a hit, unless EXCEPTIONS lists the job with its reason.

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

# (workflow file name, job id) -> why the job keeps a literal Linux label. Keep it small. Every pool but
# `provenance` is Blacksmith, so a job that must stay GitHub-hosted for a reason other than provenance keeps
# its hosted literal here.
_NIGHTLY_HOSTED = ("nightly job: never Blacksmith (CLAUDE.md, tests/test_ci_nightly_off_blacksmith.py); stays on "
                   "GitHub-hosted ubuntu-24.04, and RUNNER_POOLS has no hosted Linux pool but provenance")
EXCEPTIONS: dict[tuple[str, str], str] = {
    **{("nightly.yml", job): _NIGHTLY_HOSTED for job in (
        "publish-nightly", "publish-nightly-next-github", "keep-published-dsyms", "sentry-dsyms-nightly",
        "republish-nightly-deltas", "sign-release-notes", "publish-release-notes", "publish-nightly-reel")},
    ("nightly-tag-permission-probe.yml", "probe"): _NIGHTLY_HOSTED,
    # .github/language-boundaries.toml: a PR that changes this workflow fails the check unless Leo labels it
    # (the boundaries are his call), so its fallback label moves only in a PR he approves.
    ("language-boundaries.yml", "language-boundaries"): "language-boundaries.yml is Leo's to change",
    # The Linux nightly jobs that hold signing secrets (2e164b5e610c): rule 7 of
    # tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py needs an ephemeral runner, and the hosted
    # route is pinned by tests/test_ci_self_hosted_guard.sh's signer-route exceptions.
    **{key: _NIGHTLY_HOSTED + "; holds signing secrets (rule 7: ephemeral runner)" for key in (
        ("auto-resume-nightly-notarization.yml", "poll"), ("auto-resume-nightly-notarization.yml", "poll-outer"),
        ("auto-resume-nightly-notarization.yml", "poll-stapled"), ("auto-resume-nightly-notarization.yml", "publish"),
        ("ios-internal-nightly.yml", "previous-build"), ("nightly-next-train.yml", "drive"))},
    ("cmux-next-guards.yml", "signing-runner-variables"): "checks the runner variables, so it must not read one: "
                                                          "rule 7 of tests/test_ci_signing_keychain_is_deleted_"
                                                          "before_bundle_code.py pins its literal Blacksmith label",
    ("ci-cloud-overflow-probe.yml", "watch"): "github-hosted-required: it must run while Blacksmith starts nothing, "
                                              "to switch overflow on",
}

POOL_LABEL = "cmux-linux"
PICKER = re.compile(r"RUNNER_POOLS|LINUX_RUNNER|CI_CLOUD_OVERFLOW_SAVED|CI_LINUX_GATE_OWNED_RUNNER")
KEEP = re.compile(r"macos|windows|arm64|CI_TRUSTED_RUNNER|nightly|glaeda|CI_RELEASE_PIN_SLOT|DARWIN_CROSS|"
                  r"cmux-gcp-|matrix\.|inputs\.|needs\.|ubuntu-latest|provenance|promotion")
KEEP_MARK = re.compile(r"#.*\b(ephemeral-required|github-hosted-required)\b")
RUNS_ON_LINE = re.compile(r"^\s*runs-on:\s*(?P<value>[^#]*?)\s*(?P<comment>#.*)?$")
JOB_LINE = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(#.*)?$")
RELEASE_SECRET = re.compile(r"secrets(\.|\[\s*(format\(\s*)?\\?['\"])(APPLE_|ASC_API_|IOS_|SPARKLE_|NIGHTLY_SPARKLE_|"
                            r"CMUX_RELEASE_APP_|CONTENT_SIGNING_|CF_R2_|NIGHTLY_NEXT_R2_|HOMEBREW_TAP_TOKEN)", re.I)
RELEASE_ENV = re.compile(r"\b(release|release-next|content-signing|nightly-next-promote|release-surface-ack)\b")


def signing_job(job: dict) -> bool:
    """A job holding signing or release material keeps an ephemeral runner (rule 7)."""
    import json  # noqa: PLC0415

    return bool(RELEASE_SECRET.search(json.dumps(job))) or bool(
        RELEASE_ENV.search(json.dumps(job.get("environment") or "")))


def picker_jobs(path: Path, jobs: dict) -> set[str]:
    """Jobs whose runs-on line picks a Linux runner from a variable instead of naming the pool."""
    found: set[str] = set()
    job, in_jobs = None, False
    for line in path.read_text(encoding="utf-8").split("\n"):
        if line.startswith("jobs:"):
            in_jobs = True
            continue
        if in_jobs and (m := JOB_LINE.match(line)):
            job = m.group(1)
        m = RUNS_ON_LINE.match(line)
        if not m or job is None or not PICKER.search(m.group("value")):
            continue
        if KEEP_MARK.search(m.group("comment") or "") or KEEP.search(m.group("value")):
            continue
        if isinstance(jobs.get(job), dict) and signing_job(jobs[job]):
            continue
        found.add(job)
    return found


COMPARISON = re.compile(r"(?:==|!=)\s*$")
COMPARED = re.compile(r"^\s*(?:==|!=)")


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
                    and not literal_is_fork_only(body, m.start())):
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
        doc = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader) or {}
        jobs = doc.get("jobs") if isinstance(doc, dict) else None
        pickers = picker_jobs(path, jobs or {})
        for job_id, job in (jobs or {}).items():
            if not isinstance(job, dict) or (path.name, job_id) in EXCEPTIONS:
                continue
            labels = job_hits(job) + (["a runner picker"] if job_id in pickers else [])
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
        print(f"{name} {job_id}: runs-on uses {', '.join(labels)} outside a fork-only branch. Fix: name the "
              f"runner pool, `'{POOL_LABEL}'` (cmuxterm-hq decisions/junctions.md 2026-11-20: Linux CI is one "
              "persistent pool, no pickers), or add the job to EXCEPTIONS in scripts/ci/check_runs_on_pools.py "
              "with its reason")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
