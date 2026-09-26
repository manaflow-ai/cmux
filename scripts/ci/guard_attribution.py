#!/usr/bin/env python3
"""Name the change behind a red guard, show the failing assertion, and say how to fix it.

Guards never block a merge. "CI fast guards" (ci-fast-guards.yml) runs on every
pull request and every push to main, and "CI repository variables"
(ci-repo-variables.yml) checks the live repository variables every 15 minutes.
When one goes red, this makes the failure actionable instead of just red.
ci-guard-attribution.yml runs it on each completed run of either workflow,
under GITHUB_TOKEN, with no polling:

  analyze   read-only. It reads the run's failed job log and parses each failed
            guard step with its failing tests and assertion messages.
            On main it also finds the first commit that fails each step: it
            walks back through earlier main runs to the newest one where the
            step passed, then runs only that step (run_ci_guards.py --step
            --root, seconds each) on every first-parent commit in between.
            It maps that commit to its pull request, author and merger.
            For the mechanical guard classes it applies the fix to main's
            head, reruns the step, and keeps the diff when the step then passes.
            For the repository-variable check it diffs the variable values
            printed in the red run's log against the last green run's.
  report    write. On main: one comment on the culprit PR (the failing step,
            the assertion, the likely fix, @author and @merger), and one
            tracking issue per red workflow, labeled guard-red-main. The
            issue is updated in place and closed when the workflow is green
            on main again. On a PR: one comment, edited in place on every
            push, which says when a step is red on main too, so it is not the
            PR's fault. With an App token, a verified fix for main becomes a
            pull request.
  fix       for agents and people. It runs the fast guards locally (or reads
            a saved log), applies the mechanical fixes to the working tree,
            and reruns the failing steps.

Mechanical fixes (FIXERS):
  - a vars.*RUNNER* variable the runner label report does not list. A runs-on
    label goes into both CMUX_CI_RUNNER_VARIABLES lists. A runner name list
    goes into NON_LABEL_RUNNER_VARIABLES in tests/test_runner_label_policy.py.
  - ci-repo-variables.yml's runner variable list drifting from
    ci-health-report.yml's
  - an unregistered test: validate_test_execution_registry.py --write
Any other failure gets its assertion message, which in these tests usually
names the fix, and a command that reproduces it.

The ci-dash alert names the culprit without reading GitHub: the report job's
name is the headline ("culprit: CI fast guards red since #N by @a, merged by
@m"), and job names reach ci-dash through the build controller's webhook feed.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Iterable, Mapping
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FAST_WORKFLOW = "CI fast guards"
FAST_WORKFLOW_FILE = "ci-fast-guards.yml"
VARS_WORKFLOW = "CI repository variables"
VARS_WORKFLOW_FILE = "ci-repo-variables.yml"
KINDS = {FAST_WORKFLOW: "fast-guards", VARS_WORKFLOW: "repo-variables"}
ISSUE_LABEL = "guard-red-main"
ISSUE_TITLES = {
    "fast-guards": "CI fast guards is red on main",
    "repo-variables": "CI repository variables is red",
}
ISSUE_MARKER = "<!-- cmux-guard-breakage kind={kind} -->"
DATA_PREFIX = "<!-- cmux-guard-data "
PR_MARKER = "<!-- cmux-fast-guards-pr -->"
CULPRIT_MARKER = "<!-- cmux-guard-culprit pr={pr} steps={digest} -->"
# Earlier main runs read, newest first, before a step's baseline is given up on.
MAX_BASELINE_RUNS = 12
# Commits a step is bisected over. A longer range names no culprit.
MAX_BISECT_COMMITS = 40
# Commits run one by one; a longer range is halved instead.
MAX_LINEAR_COMMITS = 8
# One run of a few guard steps (seconds normally). Budget + 3 probes stays under the 20 min job.
PROBE_TIMEOUT_S = 150
# analyze stops bisecting after this long so the report still posts (job timeout 20 min).
BISECT_BUDGET_S = 7 * 60
MAX_RENDERED_STEPS = 10
MAX_COMMENT_CHARS = 60000
MAX_MESSAGE_LINES = 14
MAX_MESSAGE_CHARS = 1500
MAX_TESTS_PER_STEP = 4
RED = {"failure", "timed_out", "startup_failure"}

TIMESTAMP = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ?")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# run_ci_guards.py's line for a failed step, then its output in a group.
FAIL_LINE = re.compile(r"^\s*FAIL\s+[\d.]+s\s+(?P<label>.+?): (?P<step>.+?)\s*$")
GROUP_START = ("##[group]", "::group::")
GROUP_END = ("##[endgroup]", "::endgroup::")
UNITTEST_HEADER = re.compile(r"^(?:FAIL|ERROR): (?P<name>\w+) \((?P<where>[^)]*)\)(?P<extra>.*)$")
ERROR_LINE = re.compile(r"^[A-Za-z_][\w.]*(?:Error|Exception|Failure)\b(?::|$)")
SEPARATOR = re.compile(r"^(?:={20,}|-{20,})$")
PLAIN_FAIL = re.compile(r"^(?:FAIL|ERROR|error|fail(?:ed|ure)?)\s*:\s*(?P<text>.+)$")
PR_SUBJECT = re.compile(r"\(#(\d+)\)\s*$")


# ---------------------------------------------------------------- log parsing


@dataclasses.dataclass
class TestFailure:
    test: str
    message: str


@dataclasses.dataclass
class StepFailure:
    step: str
    label: str
    tests: list[TestFailure]
    excerpt: str


def clean_lines(text: str) -> list[str]:
    return [TIMESTAMP.sub("", ANSI.sub("", line)).rstrip("\r") for line in text.splitlines()]


def clip(text: str, lines: int = MAX_MESSAGE_LINES, chars: int = MAX_MESSAGE_CHARS) -> str:
    kept = text.strip("\n").splitlines()
    out = "\n".join(kept[:lines])
    if len(kept) > lines:
        out += f"\n... ({len(kept) - lines} more lines)"
    return out if len(out) <= chars else out[:chars] + " ..."


def parse_unittest(body: list[str]) -> list[TestFailure]:
    """unittest's FAIL/ERROR blocks: the test and its exception message.
    Lines that start with FAIL: or error: but are not unittest headers are
    taken as failures too (several guards print their own)."""
    failures: list[TestFailure] = []
    i = 0
    while i < len(body):
        line = body[i]
        header = UNITTEST_HEADER.match(line)
        if header:
            where = header["where"].split(".")
            owner = where[-2] if len(where) >= 2 and where[-1] == header["name"] else where[-1]
            test = f"{owner}.{header['name']}{header['extra'].rstrip()}"
            j, message = i + 1, []
            while j < len(body) and not SEPARATOR.match(body[j]):
                j += 1
            j += 1  # the dashes under the header
            while j < len(body) and not ERROR_LINE.match(body[j]) and not SEPARATOR.match(body[j]):
                j += 1
            while j < len(body) and not SEPARATOR.match(body[j]) and not UNITTEST_HEADER.match(body[j]):
                message.append(body[j])
                j += 1
            while message and not message[-1].strip():
                message.pop()
            failures.append(TestFailure(test, clip("\n".join(message)) or "(no message)"))
            i = j
            continue
        plain = PLAIN_FAIL.match(line.strip())
        if plain and not line.strip().startswith(("FAILED (", "error: Process")):
            failures.append(TestFailure("", clip(plain["text"])))
        i += 1
    seen, unique = set(), []
    for failure in failures:
        key = (failure.test, failure.message)
        if key not in seen:
            seen.add(key)
            unique.append(failure)
    return unique


def parse_guard_log(text: str) -> list[StepFailure]:
    """Failed steps in a run_ci_guards.py log (the CI job log or local output)."""
    lines = clean_lines(text)
    steps: dict[str, StepFailure] = {}
    i = 0
    while i < len(lines):
        fail = FAIL_LINE.match(lines[i])
        if not fail:
            i += 1
            continue
        body: list[str] = []
        j = i + 1
        if j < len(lines) and lines[j].startswith(GROUP_START):
            j += 1
            while j < len(lines) and not lines[j].startswith(GROUP_END):
                body.append(lines[j])
                j += 1
        tests = parse_unittest(body)
        tail = [line for line in body if line.strip()][-12:]
        steps.setdefault(fail["step"], StepFailure(fail["step"], fail["label"], tests, clip("\n".join(tail))))
        i = j + 1
    return list(steps.values())


def failed_steps_summary(text: str) -> set[str] | None:
    """Step names from the `failed:` summary line, or None when the log has none."""
    for line in reversed(clean_lines(text)):
        if line.startswith("failed: "):
            return {part.split(": ", 1)[1].strip() for part in line[len("failed: "):].split("; ") if ": " in part}
    steps = {step.step for step in parse_guard_log(text)}
    return steps or None


# ---------------------------------------------------------------- repository variables


def parse_step_env(text: str, command: str = "check_repo_variables.py") -> dict[str, str]:
    """The env block GitHub prints at the top of the step that runs `command`.
    A multi-line value continues on lines without a timestamp."""
    raw = text.splitlines()
    env: dict[str, str] = {}
    in_step = in_env = False
    key = None
    for line in raw:
        stamped = bool(TIMESTAMP.match(line))
        content = TIMESTAMP.sub("", ANSI.sub("", line)).rstrip("\r")
        if content.startswith("##[group]Run ") and command in content:
            in_step, in_env, key = True, False, None
            continue
        if not in_step:
            continue
        if content.startswith("##[endgroup]"):
            break
        if stamped and content == "env:":
            in_env = True
            continue
        if not in_env:
            continue
        match = re.match(r"^  ([A-Za-z_][A-Za-z0-9_]*): ?(.*)$", content) if stamped else None
        if match:
            key = match[1]
            env[key] = match[2]
        elif key is not None and not stamped:
            env[key] += "\n" + content
    return env


def variable_values(env: Mapping[str, str]) -> dict[str, str]:
    """Each repository variable the check was handed, by name."""
    values = {k: v for k, v in env.items() if k in ("CI_OWNED_POOL_SLOTS", "CMUX_CI_XCODE_APP_PR")}
    for line in env.get("CMUX_CI_RUNNER_VARIABLES", "").splitlines():
        name, sep, value = line.strip().partition("=")
        if sep and re.fullmatch(r"[A-Z0-9_]+", name):
            values[name] = value
    return values


def error_annotations(text: str) -> list[str]:
    return [line[len("##[error]"):].strip() for line in clean_lines(text)
            if line.startswith("##[error]") and "Process completed with exit code" not in line]


def variable_changes(red: Mapping[str, str], green: Mapping[str, str]) -> list[dict[str, str | None]]:
    return [{"name": name, "old": green.get(name), "new": red.get(name)}
            for name in sorted(set(red) | set(green)) if red.get(name) != green.get(name)]


# ---------------------------------------------------------------- trees and fixers


class Tree:
    """Files of one checkout (editable) or one commit (read only, never run)."""

    def __init__(self, root: Path, rev: str | None = None):
        self.root, self.rev = root, rev

    def read(self, path: str) -> str | None:
        if self.rev is None:
            target = self.root / path
            return target.read_text(encoding="utf-8") if target.is_file() and not target.is_symlink() else None
        out = subprocess.run(["git", "-C", str(self.root), "show", f"{self.rev}:{path}"],
                             capture_output=True, text=True)
        return out.stdout if out.returncode == 0 else None

    def workflows(self) -> dict[str, str]:
        if self.rev is None:
            return {p.name: p.read_text(encoding="utf-8") for p in sorted((self.root / ".github/workflows").glob("*.y*ml"))}
        names = subprocess.run(["git", "-C", str(self.root), "ls-tree", "--name-only", self.rev, ".github/workflows/"],
                               capture_output=True, text=True).stdout.split()
        return {Path(n).name: self.read(n) or "" for n in names if n.endswith((".yml", ".yaml"))}

    def write(self, path: str, text: str) -> None:
        if self.rev is not None:
            raise RuntimeError("a commit tree is read only")
        target = (self.root / path).resolve()
        if self.root.resolve() not in target.parents:
            raise RuntimeError(f"{path} is outside the checkout")
        target.write_text(text, encoding="utf-8")


@dataclasses.dataclass
class Fix:
    hint: str
    # Edits the checkout; returns the paths it changed.
    edit: Callable[[Tree], list[str]] | None = None
    # A command that fixes it, run in the checkout (trusted trees only).
    command: str | None = None


HEALTH_REPORT = ".github/workflows/ci-health-report.yml"
REPO_VARIABLES = ".github/workflows/ci-repo-variables.yml"
LABEL_POLICY_TEST = "tests/test_runner_label_policy.py"
RUNNER_BLOCK_LINE = re.compile(r"^(\s+)([A-Z0-9_]+)=\$\{\{ vars\.[^\n]*$")
NON_LABEL_SET = re.compile(r"^NON_LABEL_RUNNER_VARIABLES = \{([^}]*)\}", re.M)


def runs_on_label(tree: Tree, name: str) -> bool:
    """A variable read on a runs-on: line picks a runner label."""
    pattern = re.compile(rf"runs-on:[^\n]*vars\.{re.escape(name)}\b|vars\[['\"]{re.escape(name)}['\"]\]")
    return any(pattern.search(text) for text in tree.workflows().values())


def add_block_line(text: str, name: str) -> str:
    """Add NAME=${{ vars.NAME }} to the CMUX_CI_RUNNER_VARIABLES block, sorted."""
    lines = text.splitlines(keepends=True)
    start = next((i for i, l in enumerate(lines) if l.strip() == "CMUX_CI_RUNNER_VARIABLES: |"), None)
    if start is None:
        raise RuntimeError("no CMUX_CI_RUNNER_VARIABLES block")
    end = start + 1
    while end < len(lines) and RUNNER_BLOCK_LINE.match(lines[end].rstrip("\n")):
        end += 1
    block = lines[start + 1:end]
    if not block:
        raise RuntimeError("empty CMUX_CI_RUNNER_VARIABLES block")
    indent = RUNNER_BLOCK_LINE.match(block[0].rstrip("\n"))[1]
    if any(RUNNER_BLOCK_LINE.match(l.rstrip("\n"))[2] == name for l in block):
        return text
    block.append(f"{indent}{name}=${{{{ vars.{name} }}}}\n")
    block.sort(key=lambda l: RUNNER_BLOCK_LINE.match(l.rstrip("\n"))[2])
    return "".join(lines[:start + 1] + block + lines[end:])


def runner_block(text: str) -> list[str]:
    return re.findall(r"^\s+([A-Z0-9_]+=\$\{\{ vars\.[^\n]*)$", text, re.M)


def fix_runner_variable_report(failure: TestFailure, tree: Tree) -> Fix | None:
    """test_runner_label_policy: a workflow reads vars.X*RUNNER* the report does not list."""
    if "CMUX_CI_RUNNER_VARIABLES in" not in failure.message:
        return None
    names = sorted({n for n in re.findall(r"'([A-Z][A-Z0-9_]*)'", failure.message) if "RUNNER" in n})
    if not names:
        return None
    labels = [n for n in names if runs_on_label(tree, n)]
    lists = [n for n in names if n not in labels]
    policy = tree.read(LABEL_POLICY_TEST) or ""
    exemptable = bool(NON_LABEL_SET.search(policy))
    hints = []
    if labels:
        hints.append(
            ", ".join(f"`{n}`" for n in labels) + " picks a `runs-on:` label: add "
            + ", ".join(f"`{n}=${{{{ vars.{n} }}}}`" for n in labels)
            + " to `CMUX_CI_RUNNER_VARIABLES` in both `ci-health-report.yml` and `ci-repo-variables.yml` "
              "(the two lists must stay equal)."
        )
    if lists:
        where = "`NON_LABEL_RUNNER_VARIABLES` in `tests/test_runner_label_policy.py`" if exemptable else \
            "the test's exemptions in `tests/test_runner_label_policy.py`"
        hints.append(
            ", ".join(f"`{n}`" for n in lists) + " is read by no `runs-on:`, so it holds runner names, not a "
            f"label, and reporting it would only flag the names as drift: add it to {where}."
        )

    def edit(target: Tree) -> list[str]:
        changed = []
        if labels:
            for path in (HEALTH_REPORT, REPO_VARIABLES):
                text = target.read(path)
                if text is None:
                    continue
                new = text
                for name in labels:
                    new = add_block_line(new, name)
                if new != text:
                    target.write(path, new)
                    changed.append(path)
        if lists:
            text = target.read(LABEL_POLICY_TEST) or ""
            match = NON_LABEL_SET.search(text)
            if match:
                current = set(re.findall(r"\"([A-Z0-9_]+)\"", match[1]))
                wanted = sorted(current | set(lists))
                new = text[:match.start()] + "NON_LABEL_RUNNER_VARIABLES = {" + \
                    ", ".join(f'"{n}"' for n in wanted) + "}" + text[match.end():]
                if new != text:
                    target.write(LABEL_POLICY_TEST, new)
                    changed.append(LABEL_POLICY_TEST)
        return changed

    return Fix(" ".join(hints), edit if (labels or exemptable) else None)


def fix_runner_variable_lists_equal(failure: TestFailure, tree: Tree) -> Fix | None:
    """test_ci_check_repo_variables: ci-repo-variables.yml must hand the check the report's runner list."""
    if "test_same_runner_variables_as_the_health_report" not in failure.test:
        return None

    def edit(target: Tree) -> list[str]:
        report, mine = target.read(HEALTH_REPORT), target.read(REPO_VARIABLES)
        if report is None or mine is None:
            return []
        new = mine
        for line in runner_block(report):
            new = add_block_line(new, line.split("=", 1)[0])
        if new == mine:
            return []
        target.write(REPO_VARIABLES, new)
        return [REPO_VARIABLES]

    return Fix("`ci-repo-variables.yml` must hand the check the same runner variables as `ci-health-report.yml`: "
               "copy the missing `NAME=${{ vars.NAME }}` lines into its `CMUX_CI_RUNNER_VARIABLES`.", edit)


def fix_test_registry(failure: TestFailure, tree: Tree) -> Fix | None:
    if "validate_test_execution_registry.py --write" not in failure.message:
        return None
    command = "python3 scripts/ci/validate_test_execution_registry.py --write"
    return Fix(f"Run `{command}`, which registers the new test in `tests/test-execution.toml`, and commit "
               "the result.", command=command)


FIXERS: tuple[Callable[[TestFailure, Tree], Fix | None], ...] = (
    fix_runner_variable_report,
    fix_runner_variable_lists_equal,
    fix_test_registry,
)


def fixes_for(step: StepFailure, tree: Tree) -> list[Fix]:
    found = []
    for failure in step.tests or [TestFailure("", step.excerpt)]:
        for fixer in FIXERS:
            fix = fixer(failure, tree)
            if fix:
                found.append(fix)
                break
    return found


# ---------------------------------------------------------------- steps and commands


def step_commands(tree: Tree) -> dict[str, str]:
    """Guard step name -> its one-line `run:` command in ci-guards.yml."""
    text = tree.read(".github/workflows/ci-guards.yml") or ""
    commands, name = {}, None
    for line in text.splitlines():
        named = re.match(r"^\s+- name: (.+?)\s*$", line)
        if named:
            name = named[1].strip("'\"")
            continue
        run = re.match(r"^\s+run: (.+?)\s*$", line)
        if run and name and run[1] not in ("|", ">"):
            commands.setdefault(name, run[1])
    return commands


def reproduce(step: str) -> str:
    return f"scripts/ci/guards-local.sh --step {shlex.quote(step)}"


def git(root: Path, *args: str, check: bool = True) -> str:
    out = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
    if check and out.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {out.stderr.strip()[:300]}")
    return out.stdout.strip()


def run_steps(runner_root: Path, tree_root: Path, steps: Iterable[str]) -> dict[str, bool | None]:
    """Run only these guard steps in tree_root with the runner from runner_root.
    None: that checkout has no such step (it predates the test)."""
    steps = sorted(set(steps))
    with tempfile.TemporaryDirectory(prefix="guard-steps-") as temp:
        results = Path(temp) / "results.json"
        args = [str(runner_root / "scripts/ci/guards-local.sh"), "--root", str(tree_root), "--results", str(results),
                "--jobs", "4"]
        for step in steps:
            args += ["--step", step]
        # Guard steps get no GitHub token: they never need one.
        env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
        env["CMUX_GUARDS_BASE_SHA"] = git(tree_root, "rev-parse", "HEAD~1", check=False)
        try:
            out = subprocess.run(args, capture_output=True, text=True, env=env, timeout=PROBE_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            return {step: None for step in steps}
        # Exit 3: no such step there. Exit 2 or no results: that checkout's plan
        # cannot be run by this runner. Either way the commit says nothing.
        found = json.loads(results.read_text()) if out.returncode != 3 and results.exists() else {}
    return {step: found.get(step) for step in steps}


# ---------------------------------------------------------------- GitHub


class GitHub:
    def __init__(self, repo: str, token: str, api: str = "https://api.github.com"):
        self.repo, self.token, self.api = repo, token, api.rstrip("/")
        self.calls = 0

    def request(self, method: str, path: str, body: object = None, text: bool = False) -> object:
        url = path if path.startswith("https://") else f"{self.api}/{path.lstrip('/')}"
        data = json.dumps(body).encode() if body is not None else None
        for attempt in range(2):
            req = urllib.request.Request(url, data=data, method=method)
            # Not sent on the redirect: job logs redirect to signed blob storage.
            req.add_unredirected_header("Authorization", f"Bearer {self.token}")
            req.add_header("Accept", "application/vnd.github+json")
            req.add_header("X-GitHub-Api-Version", "2022-11-28")
            if data is not None:
                req.add_header("Content-Type", "application/json")
            self.calls += 1
            try:
                with urllib.request.urlopen(req, timeout=60) as response:
                    raw = response.read()
            except urllib.error.HTTPError as error:
                # Only a read is retried: a POST that answered 502 may have landed.
                if error.code >= 500 and attempt == 0 and method == "GET":
                    continue
                detail = error.read().decode("utf-8", "replace")[:300]
                raise RuntimeError(f"{method} {path}: HTTP {error.code} {detail}") from error
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                if attempt == 0 and method == "GET":
                    continue
                raise RuntimeError(f"{method} {path}: {error}") from error
            if text:
                return raw.decode("utf-8", "replace")
            return json.loads(raw) if raw else None
        raise RuntimeError(f"{method} {path}: retries exhausted")

    def get(self, path: str) -> object:
        return self.request("GET", path)

    def run(self, run_id: int) -> dict:
        return self.get(f"repos/{self.repo}/actions/runs/{run_id}")  # type: ignore[return-value]

    def failed_log(self, run_id: int) -> str:
        jobs = self.get(f"repos/{self.repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=20")
        texts = []
        for job in (jobs or {}).get("jobs", []):  # type: ignore[union-attr]
            if job.get("conclusion") in RED:
                texts.append(self.request("GET", f"repos/{self.repo}/actions/jobs/{job['id']}/logs", text=True))
        return "\n".join(str(t) for t in texts)

    def job_log(self, run_id: int) -> str:
        jobs = self.get(f"repos/{self.repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=20")
        job = ((jobs or {}).get("jobs") or [None])[0]  # type: ignore[union-attr]
        return str(self.request("GET", f"repos/{self.repo}/actions/jobs/{job['id']}/logs", text=True)) if job else ""

    def main_runs(self, workflow_file: str, extra: str = "", status: str = "completed") -> list[dict]:
        # `status` takes a conclusion too (success, failure); there is no `conclusion` parameter.
        body = self.get(f"repos/{self.repo}/actions/workflows/{workflow_file}/runs"
                        f"?branch=main&status={status}&per_page=50{extra}")
        return list((body or {}).get("workflow_runs", []))  # type: ignore[union-attr]

    def pull(self, number: int) -> dict:
        return self.get(f"repos/{self.repo}/pulls/{number}")  # type: ignore[return-value]

    def commit_pulls(self, sha: str) -> list[dict]:
        return list(self.get(f"repos/{self.repo}/commits/{sha}/pulls") or [])  # type: ignore[arg-type]

    def open_issues(self) -> list[dict]:
        return list(self.get(f"repos/{self.repo}/issues?labels={ISSUE_LABEL}&state=open&per_page=20") or [])  # type: ignore[arg-type]

    def comments(self, number: int) -> list[dict]:
        found: list[dict] = []
        for page in range(1, 4):
            batch = list(self.get(f"repos/{self.repo}/issues/{number}/comments?per_page=100&page={page}") or [])  # type: ignore[arg-type]
            found += batch
            if len(batch) < 100:
                break
        return found


def tracking_issue(issues: Iterable[Mapping], kind: str) -> Mapping | None:
    marker = ISSUE_MARKER.format(kind=kind)
    return next((i for i in issues if marker in str(i.get("body") or "") and "pull_request" not in i), None)


def issue_data(issue: Mapping | None) -> dict:
    body = str((issue or {}).get("body") or "")
    start = body.find(DATA_PREFIX)
    if start < 0:
        return {}
    end = body.find(" -->", start)
    try:
        return json.loads(body[start + len(DATA_PREFIX):end])
    except ValueError:
        return {}


# ---------------------------------------------------------------- analysis


def pr_for_commit(gh: GitHub | None, root: Path, sha: str) -> dict:
    """The merged pull request behind a main commit: number, title, author, merger."""
    subject = git(root, "log", "-1", "--format=%s", sha, check=False)
    match = PR_SUBJECT.search(subject)
    number = int(match[1]) if match else None
    info: dict = {"sha": sha, "subject": subject, "pr": number}
    if gh is None:
        return info
    try:
        if number is None:
            pulls = [p for p in gh.commit_pulls(sha) if p.get("merged_at")]
            number = pulls[0]["number"] if pulls else None
            info["pr"] = number
        if number is not None:
            pull = gh.pull(number)
            info.update(title=pull.get("title"), url=pull.get("html_url"),
                        author=(pull.get("user") or {}).get("login"),
                        merger=(pull.get("merged_by") or {}).get("login"))
    except RuntimeError as error:
        info["lookup_error"] = str(error)[:200]
    return info


def first_parent_range(root: Path, base: str | None, head: str) -> tuple[list[str], bool]:
    """Main's commits after base up to head, oldest first, and whether base is known to pass.
    With no base, the newest MAX_BISECT_COMMITS commits."""
    if base:
        return git(root, "rev-list", "--first-parent", "--reverse", f"{base}..{head}").split(), True
    shas = git(root, "rev-list", "--first-parent", f"--max-count={MAX_BISECT_COMMITS}", head).split()
    return list(reversed(shas)), False


def is_ancestor(root: Path, older: str, newer: str) -> bool:
    return subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor", older, newer]).returncode == 0


def baselines(runs: list[dict], gh: GitHub | None, root: Path, red_sha: str, steps: set[str]) -> dict[str, str | None]:
    """For each step, the newest earlier main commit whose fast guard run passed it."""
    found: dict[str, str | None] = {step: None for step in steps}
    if gh is None:
        return found
    runs = [r for r in runs if r.get("conclusion") in RED | {"success"} and is_ancestor(root, r["head_sha"], red_sha)]
    runs.sort(key=lambda r: int(git(root, "rev-list", "--count", f"{r['head_sha']}..{red_sha}")))
    pending = set(steps)
    for run in runs[:MAX_BASELINE_RUNS]:
        if not pending:
            break
        if run["conclusion"] == "success":
            failed: set[str] = set()
        else:
            failed = failed_steps_summary(gh.failed_log(run["id"])) or set(pending)
        for step in list(pending):
            if step not in failed:
                found[step] = run["head_sha"]
                pending.discard(step)
    return found


Probe = Callable[[str, set[str]], Mapping[str, "bool | None"]]


def first_failing(commits: list[str], steps: set[str], probe: Probe, base_passes: bool,
                  deadline: float | None = None) -> dict[str, dict]:
    """The first commit that fails each step. commits is oldest first, and the
    commit before it passed every step when base_passes. Up to
    MAX_LINEAR_COMMITS commits are each run in order; a longer range is
    halved (which assumes the step stays red once broken). Past the deadline
    the remaining steps are left unattributed."""
    verdicts: dict[str, dict] = {}
    if len(commits) == 1 and base_passes:
        return {step: {"sha": commits[0], "method": "the only commit since the step last passed on main"}
                for step in steps}
    pending = set(steps)

    def late() -> bool:
        return deadline is not None and time.monotonic() > deadline

    if len(commits) <= MAX_LINEAR_COMMITS:
        for index, sha in enumerate(commits):
            if not pending or late():
                break
            for step, ok in probe(sha, set(pending)).items():
                if ok is False:
                    pending.discard(step)
                    if index == 0 and not base_passes:
                        verdicts[step] = {"sha": None, "method": f"it fails on the oldest of the {len(commits)} "
                                                                 "commits checked; the break is older"}
                    else:
                        verdicts[step] = {"sha": sha, "method": f"the step was run on each of {len(commits)} commits "
                                                                 "since it last passed on main; this is the first to fail it"}
    else:
        for step in list(pending):
            low, high = 0, len(commits) - 1  # commits[high] fails
            unknown = None
            while low < high and not late():
                middle = (low + high) // 2
                result = probe(commits[middle], {step}).get(step)
                if result is None:  # timed out or unplannable: never read as a pass
                    unknown = commits[middle]
                    break
                if result is False:
                    high = middle
                else:
                    low = middle + 1
            if unknown:
                pending.discard(step)
                verdicts[step] = {"sha": None, "method": f"bisecting {len(commits)} commits stopped: the step "
                                                         f"could not be run at {unknown[:10]}"}
                continue
            if low < high:
                continue  # out of time
            pending.discard(step)
            verdicts[step] = {"sha": commits[low], "method": f"bisected {len(commits)} commits since the step last "
                                                             "passed on main; this is the first to fail it"}
    for step in pending:
        why = "ran out of time bisecting" if late() else \
            "none failed the step when rerun alone (flaky, or it depends on the rest of the run)"
        verdicts[step] = {"sha": None, "method": f"{len(commits)} commits since it last passed; {why}"}
    return verdicts


def bisect(runner_root: Path, root: Path, ranges: Mapping[tuple[str, ...], tuple[set[str], bool]]) -> dict[str, dict]:
    """first_failing over each range, running only the steps in a scratch worktree."""
    verdicts: dict[str, dict] = {}
    with tempfile.TemporaryDirectory(prefix="guard-bisect-") as temp:
        scratch = Path(temp) / "tree"
        git(root, "worktree", "add", "--quiet", "--detach", str(scratch), "HEAD")

        def probe(sha: str, steps: set[str]) -> Mapping[str, bool | None]:
            git(scratch, "checkout", "--quiet", "--force", "--detach", sha)
            git(scratch, "clean", "-fdxq")
            return run_steps(runner_root, scratch, steps)

        try:
            deadline = time.monotonic() + BISECT_BUDGET_S
            for commits, (steps, base_passes) in ranges.items():
                if not commits:
                    continue
                try:
                    verdicts.update(first_failing(list(commits), steps, probe, base_passes, deadline))
                except (RuntimeError, OSError, ValueError) as error:
                    for step in steps:
                        verdicts[step] = {"sha": None, "method": f"bisect failed: {str(error)[:200]}"}
        finally:
            git(root, "worktree", "remove", "--force", str(scratch), check=False)
    return verdicts


def verified_fixes(runner_root: Path, root: Path, head: str, failures: list[StepFailure]) -> tuple[dict, dict]:
    """Hints per step, and one patch: every step's mechanical fixes applied
    together to a checkout of main's head, verified when the steps then pass."""
    probe = Tree(root, head)
    fixes = {f.step: fixes_for(f, probe) for f in failures}
    per_step: dict[str, dict] = {step: {"hints": [f.hint for f in found if f.hint]} for step, found in fixes.items()}
    combined: dict = {}
    if not failures:
        return per_step, combined
    with tempfile.TemporaryDirectory(prefix="guard-fix-") as temp:
        scratch = Path(temp) / "tree"
        git(root, "worktree", "add", "--quiet", "--detach", str(scratch), head)
        try:
            before = run_steps(runner_root, scratch, fixes)
            red = [step for step, ok in before.items() if ok is False]
            for step, ok in before.items():
                if ok is True:
                    per_step[step]["passing_on_head"] = True
            tree = Tree(scratch)
            for step in red:
                for fix in fixes[step]:
                    if fix.edit:
                        fix.edit(tree)
                    if fix.command:
                        subprocess.run(["bash", "-c", fix.command], cwd=scratch, capture_output=True, text=True,
                                       timeout=PROBE_TIMEOUT_S)
            patch = git(scratch, "diff")
            if patch:
                after = run_steps(runner_root, scratch, red)
                combined = {"patch": patch + "\n", "head": head, "steps": red,
                            "verified": all(after.get(step) is True for step in red)}
        except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
            combined = {"error": str(error)[:300]}
        finally:
            git(root, "worktree", "remove", "--force", str(scratch), check=False)
    return per_step, combined


def green_since(runs: list[dict], root: Path, since: str | None, red_sha: str) -> bool:
    """A green main run after `since` and before the red commit: an earlier breakage was fixed in between."""
    if not since:
        return False
    return any(r.get("conclusion") == "success" and r.get("head_sha") and r["head_sha"] != since
               and is_ancestor(root, since, r["head_sha"]) and is_ancestor(root, r["head_sha"], red_sha)
               for r in runs)


def analyze_fast_main(gh: GitHub | None, run: Mapping, root: Path, log: str, head: str,
                      baseline: str | None = None) -> dict:
    red_sha = run["head_sha"]
    report: dict = {"kind": "fast-guards", "workflow": FAST_WORKFLOW, "branch": "main", "sha": red_sha,
                    "run_url": run.get("html_url"), "run_created_at": run.get("created_at")}
    issue = tracking_issue(gh.open_issues(), "fast-guards") if gh else None
    if run.get("conclusion") == "success":
        report["state"] = "green" if issue else "noop"
        return report
    report["state"] = "red"
    failures = parse_guard_log(log)
    data = issue_data(issue)
    runs = [r for r in gh.main_runs(FAST_WORKFLOW_FILE, "&event=push")
            if r.get("id") != run.get("id") and r.get("head_sha") != red_sha] if gh else []
    known = data.get("steps", {})
    if known and green_since(runs, root, data.get("sha"), red_sha):
        # A green run the report missed (a dropped pending run): this is a new breakage.
        known = {}
        report["reset"] = True
    commands = step_commands(Tree(root, red_sha))
    new = [f for f in failures if f.step not in known]
    ranges: dict[tuple[str, ...], tuple[set[str], bool]] = {}
    if new:
        found = {s.step: baseline for s in new} if baseline else \
            baselines(runs, gh, root, red_sha, {s.step for s in new})
        for step in new:
            commits, base_passes = first_parent_range(root, found[step.step], red_sha)
            ranges.setdefault(tuple(commits), (set(), base_passes))[0].add(step.step)
    verdicts = bisect(ROOT, root, ranges) if ranges else {}
    hints, combined = verified_fixes(ROOT, root, head, new) if new else ({}, {})
    report["fix"] = combined
    steps = []
    for failure in failures:
        entry = dataclasses.asdict(failure)
        entry["command"] = commands.get(failure.step)
        entry["reproduce"] = reproduce(failure.step)
        if failure.step in known:
            entry["culprit"] = known[failure.step].get("culprit")
            entry["fix"] = known[failure.step].get("fix") or {}
            entry["known"] = True
        else:
            verdict = verdicts.get(failure.step, {})
            culprit = pr_for_commit(gh, root, verdict["sha"]) if verdict.get("sha") else {}
            culprit["method"] = verdict.get("method")
            entry["culprit"] = culprit
            entry["fix"] = hints.get(failure.step, {})
        steps.append(entry)
    report["steps"] = steps
    return report


def analyze_vars_main(gh: GitHub | None, run: Mapping, root: Path, log: str, green_log: str | None,
                      green_run: Mapping | None) -> dict:
    report: dict = {"kind": "repo-variables", "workflow": VARS_WORKFLOW, "branch": "main", "sha": run.get("head_sha"),
                    "run_url": run.get("html_url"), "run_created_at": run.get("created_at"), "event": run.get("event")}
    if run.get("conclusion") == "success":
        report["state"] = "green" if gh is None or tracking_issue(gh.open_issues(), "repo-variables") else "noop"
        return report
    report["state"] = "red"
    report["errors"] = error_annotations(log)
    red_values = variable_values(parse_step_env(log))
    green_values = variable_values(parse_step_env(green_log)) if green_log else {}
    report["changes"] = variable_changes(red_values, green_values) if green_log else []
    report["green_run_url"] = (green_run or {}).get("html_url")
    report["green_at"] = (green_run or {}).get("created_at")
    if run.get("event") == "push" and run.get("head_sha") and not report["changes"]:
        # The check's own code changed with the push.
        report["culprit"] = pr_for_commit(gh, root, str(run["head_sha"]))
    return report


def analyze_pr(gh: GitHub | None, run: Mapping, root: Path, log: str) -> dict:
    report: dict = {"kind": "fast-guards", "workflow": FAST_WORKFLOW, "branch": "pr", "sha": run.get("head_sha"),
                    "run_url": run.get("html_url"), "state": "green" if run.get("conclusion") == "success" else "red"}
    report["pr"] = pr_number(gh, run)
    if report["state"] == "green":
        # Nothing to update unless this PR already has a red guard comment.
        if not report["pr"] or (gh and not any(PR_MARKER in str(c.get("body") or "") for c in gh.comments(report["pr"]))):
            report["state"] = "noop"
        return report
    failures = parse_guard_log(log)
    issue = tracking_issue(gh.open_issues(), "fast-guards") if gh else None
    red_on_main = issue_data(issue)
    # The PR's files are read as data (git show) to shape the hint; nothing from the PR runs here.
    fetched = subprocess.run(["git", "-C", str(root), "cat-file", "-e", f"{run['head_sha']}^{{commit}}"],
                             capture_output=True).returncode == 0
    tree = Tree(root, run["head_sha"]) if fetched else Tree(root)
    commands = step_commands(Tree(root))
    steps = []
    for failure in failures:
        entry = dataclasses.asdict(failure)
        entry["command"] = commands.get(failure.step)
        entry["reproduce"] = reproduce(failure.step)
        # Hints only: a PR's code is never run with this job's token.
        entry["fix"] = {"hints": [f.hint for f in fixes_for(failure, tree) if f.hint]}
        main_step = (red_on_main.get("steps") or {}).get(failure.step)
        if main_step:
            entry["red_on_main"] = {"culprit": main_step.get("culprit"), "issue": (issue or {}).get("number")}
        steps.append(entry)
    report["steps"] = steps
    return report


def pr_number(gh: GitHub | None, run: Mapping) -> int | None:
    repo = (gh.repo if gh else os.environ.get("GITHUB_REPOSITORY", "")).lower()
    for pull in run.get("pull_requests") or []:
        # The list can hold a fork's own PRs with the same head; only this repository's count.
        base_url = str(((pull.get("base") or {}).get("repo") or {}).get("url", "")).lower()
        if base_url.endswith(f"/repos/{repo}"):
            return int(pull["number"])
    if gh is None:
        return None
    head_repo = (run.get("head_repository") or {}).get("full_name") or ""
    owner = head_repo.split("/")[0]
    body = gh.get(f"repos/{gh.repo}/pulls?state=open&head={owner}:{run.get('head_branch')}&per_page=5")
    for pull in body or []:  # type: ignore[union-attr]
        if (pull.get("head") or {}).get("sha") == run.get("head_sha"):
            return int(pull["number"])
    return None


# ---------------------------------------------------------------- rendering


def code(text: object, limit: int = 160) -> str:
    """Inline code from log text: no backticks or newlines to break out of it."""
    flat = " ".join(str(text).replace("`", "'").split())
    return f"`{flat[:limit] + ('...' if len(flat) > limit else '')}`"


def fence(text: str, lang: str = "") -> str:
    """A code fence longer than any backtick run in the text, so log text cannot break out."""
    longest = max((len(m) for m in re.findall(r"`+", text)), default=0)
    ticks = "`" * max(3, longest + 1)
    return f"{ticks}{lang}\n{text.rstrip()}\n{ticks}"


def short(sha: str | None) -> str:
    return (sha or "")[:10]


def who(culprit: Mapping | None) -> str:
    if not culprit or not culprit.get("pr"):
        return "an unattributed change"
    text = f"#{culprit['pr']}"
    if culprit.get("author"):
        text += f" by @{culprit['author']}"
    if culprit.get("merger") and culprit.get("merger") != culprit.get("author"):
        text += f", merged by @{culprit['merger']}"
    elif culprit.get("merger"):
        text += " (self-merged)"
    return text


def render_step(step: Mapping, heading: str = "###") -> list[str]:
    out = [f"{heading} {code(step['step'])}"]
    if step.get("command"):
        out.append(f"Test: {code(step['command'])}")
    tests = step.get("tests") or []
    for test in tests[:MAX_TESTS_PER_STEP]:
        if test.get("test"):
            out.append(f"- {code(test['test'])}")
        out.append(fence(test["message"]))
    if len(tests) > MAX_TESTS_PER_STEP:
        out.append(f"... and {len(tests) - MAX_TESTS_PER_STEP} more failing tests in the run log.")
    if not tests and step.get("excerpt"):
        out.append(fence(step["excerpt"]))
    fix = step.get("fix") or {}
    hints = fix.get("hints") or []
    if fix.get("passing_on_head"):
        out.append("**Fix:** already passing on main's head; nothing to do.")
    elif hints:
        out.append("**Fix:** " + " ".join(hints))
    else:
        out.append("**Fix:** the assertion above names what the guard expects; change the tree to match it.")
    out.append(f"Reproduce in seconds, no build: {code(step['reproduce'], 300)}")
    return out


def render_patch(fix: Mapping) -> list[str]:
    if not fix.get("patch"):
        return []
    state = f"verified: the steps pass with it on main at `{short(fix.get('head'))}`" if fix.get("verified") \
        else "not verified: the steps still fail with it"
    return [f"<details><summary>Patch ({state})</summary>\n\n{fence(fix['patch'], 'diff')}\n\n</details>"]


def cap(text: str) -> str:
    """GitHub refuses a comment or issue body over 65536 characters."""
    return text if len(text) <= MAX_COMMENT_CHARS else text[:MAX_COMMENT_CHARS] + "\n\n... (cut; see the run log)\n"


def render_steps(steps: list[Mapping]) -> list[str]:
    out: list[str] = []
    for step in steps[:MAX_RENDERED_STEPS]:
        out += [""] + render_step(step)
    if len(steps) > MAX_RENDERED_STEPS:
        out.append(f"\n... and {len(steps) - MAX_RENDERED_STEPS} more failed steps in the run log.")
    return out


def render_culprit_comment(report: Mapping, pr: int, steps: list[Mapping], issue: int | None, fix_pr: str | None) -> str:
    culprit = steps[0]["culprit"]
    digest = hashlib.sha1("|".join(sorted(s["step"] for s in steps)).encode()).hexdigest()[:12]
    names = ", ".join(code(s["step"]) for s in steps)
    out = [CULPRIT_MARKER.format(pr=pr, digest=digest),
           f"**This PR broke `{report['workflow']}` on main.** Every open PR's guard check is red on {names} "
           "until it is fixed forward.",
           f"How this was found: {culprit.get('method') or 'bisected on main'}. Merge commit `{short(culprit.get('sha'))}`; "
           f"main run: {report.get('run_url')}."]
    out += render_steps(steps)
    out.append("")
    fix = report.get("fix") or {}
    if fix_pr:
        out.append(f"Fix PR (opened automatically, verified on main's head): {fix_pr}")
    elif fix.get("patch") and set(fix.get("steps") or []) & {s["step"] for s in steps}:
        out += render_patch(fix)
        out.append("Agents: `python3 scripts/ci/guard_attribution.py fix` applies it in a checkout of main.")
    mentions = " ".join(dict.fromkeys(f"@{u}" for u in (culprit.get("author"), culprit.get("merger")) if u))
    tail = f"Tracking: #{issue}. " if issue else ""
    out.append(f"{tail}{mentions}".strip())
    return cap("\n".join(out) + "\n")


def render_issue(report: Mapping, steps_state: Mapping[str, Mapping], fix_prs: Mapping[str, str]) -> str:
    kind = report["kind"]
    out = [ISSUE_MARKER.format(kind=kind)]
    if kind == "repo-variables":
        out.append(f"`{VARS_WORKFLOW}` failed at {report.get('run_url')} ({report.get('run_created_at')}). A repository "
                   "variable holds a value CI's readers ignore or refuse.")
        errors = report.get("errors") or []
        if errors:
            out.append("### What the check says")
            out += [f"- {e}" for e in errors]
        changes = report.get("changes") or []
        if changes:
            out.append(f"### Changed since the last green run ({report.get('green_run_url')}, {report.get('green_at')})")
            out.append("| Variable | Last green | Now |\n| --- | --- | --- |")
            for change in changes:
                out.append(f"| `{change['name']}` | `{change.get('old') or '(unset)'}` | `{change.get('new') or '(unset)'}` |")
            restore = [c for c in changes if any(c["name"] in e for e in errors) or not errors]
            if restore:
                out.append("### Likely fix: restore the last green value, or set a valid one")
                out.append(fence("\n".join(
                    f"gh variable set {c['name']} --repo manaflow-ai/cmux --body {shlex.quote(c.get('old') or '')}"
                    if c.get("old") is not None else f"gh variable delete {c['name']} --repo manaflow-ai/cmux"
                    for c in restore), "bash"))
        elif report.get("green_run_url"):
            out.append("No variable the check reads changed since the last green run "
                       f"({report.get('green_run_url')}); the check's own code or its readers changed.")
        if report.get("culprit", {}).get("pr"):
            out.append(f"The run was the push of {who(report['culprit'])}.")
    else:
        out.append(f"`{FAST_WORKFLOW}` is red on main since {report.get('run_url')} (`{short(report.get('sha'))}`). "
                   "Every open PR's guard check fails on these steps until main is fixed forward; merging stays open.")
        out.append("| Step | Since | Fix PR |\n| --- | --- | --- |")
        for step, state in sorted(steps_state.items()):
            out.append(f"| {code(step)} | {who(state.get('culprit'))} | {fix_prs.get(step, '')} |")
        out += render_steps(report.get("steps") or [])
        out += render_patch(report.get("fix") or {})
    out.append("")
    out.append("Opened and closed by `scripts/ci/guard_attribution.py` (ci-guard-attribution.yml); it closes when "
               "the workflow is green on main again.")
    slim = {name: {"culprit": {k: v for k, v in (state.get("culprit") or {}).items()
                               if k in ("sha", "pr", "author", "merger", "method")},
                   "fix": {"hints": [h[:500] for h in ((state.get("fix") or {}).get("hints") or [])[:3]]},
                   "fix_pr": state.get("fix_pr")}
            for name, state in list(steps_state.items())[:40]}
    data = {"kind": kind, "sha": report.get("sha"), "steps": slim,
            "run_url": report.get("run_url")}
    marker = DATA_PREFIX + json.dumps(data, separators=(",", ":")).replace("-->", "--\\u003e") + " -->"
    return cap("\n".join(out) + "\n") + marker + "\n"


def render_pr_comment(report: Mapping) -> str:
    out = [PR_MARKER]
    if report["state"] == "green":
        out.append(f"`{FAST_WORKFLOW}` passes on `{short(report.get('sha'))}` ({report.get('run_url')}).")
        return "\n".join(out) + "\n"
    steps = report.get("steps") or []
    out.append(f"**`{FAST_WORKFLOW}` failed** on `{short(report.get('sha'))}` ({report.get('run_url')}). "
               "It does not block the merge; a red guard merged into main breaks it for every open PR.")
    for step in steps[:MAX_RENDERED_STEPS]:
        out.append("")
        main = step.get("red_on_main")
        if main:
            out.append(f"### {code(step['step'])} (red on main too, not this PR)")
            issue = f" (#{main['issue']})" if main.get("issue") else ""
            out.append(f"Main has failed this step since {who(main.get('culprit'))}{issue}. Merge main again once "
                       "the fix lands there.")
            continue
        out += render_step(step)
    if len(steps) > MAX_RENDERED_STEPS:
        out.append(f"\n... and {len(steps) - MAX_RENDERED_STEPS} more failed steps in the run log.")
    if not steps:
        out.append("The log named no failed step; see the run.")
    out.append("")
    out.append("Agents: `python3 scripts/ci/guard_attribution.py fix` applies the mechanical fixes locally. "
               "This comment is updated in place on each push.")
    return cap("\n".join(out) + "\n")


def headline(report: Mapping) -> str:
    """The report job's name, which reaches ci-dash through the webhook feed."""
    if report.get("branch") != "main" or report.get("state") != "red":
        return "report"
    if report["kind"] == "repo-variables":
        names = [c["name"] for c in report.get("changes") or []]
        tail = ("changed " + ", ".join(names[:3])) if names else "no variable changed"
        return f"culprit: {VARS_WORKFLOW} red, {tail}"[:200]
    culprits = [s["culprit"] for s in report.get("steps") or [] if (s.get("culprit") or {}).get("pr")]
    if not culprits:
        return f"culprit: {FAST_WORKFLOW} red, unattributed"
    names = list(dict.fromkeys(who(c) for c in culprits))
    return f"culprit: {FAST_WORKFLOW} red since " + "; ".join(names[:2])


# ---------------------------------------------------------------- reporting


class Writer:
    """GitHub writes, or a transcript of them for --dry-run."""

    def __init__(self, gh: GitHub | None, dry_run: bool):
        self.gh, self.dry_run = gh, dry_run
        self.log: list[str] = []

    def call(self, method: str, path: str, body: Mapping) -> dict:
        if self.dry_run or self.gh is None:
            text = body.get("body") or json.dumps(body)
            self.log.append(f"--- would {method} {path}\n{text}")
            return {"number": 0, "html_url": f"(dry run: {path})"}
        return self.gh.request(method, path, dict(body))  # type: ignore[return-value]


def upsert_comment(writer: Writer, repo: str, number: int, marker: str, body: str,
                   existing: list[dict] | None) -> None:
    current = next((c for c in existing or [] if marker in str(c.get("body") or "")), None)
    if current is None:
        writer.call("POST", f"repos/{repo}/issues/{number}/comments", {"body": body})
    elif str(current.get("body") or "").strip() != body.strip():
        writer.call("PATCH", f"repos/{repo}/issues/comments/{current['id']}", {"body": body})


def report_main(writer: Writer, gh: GitHub | None, repo: str, report: Mapping, fix_prs: Mapping[str, str]) -> None:
    kind = report["kind"]
    issues = gh.open_issues() if gh else []
    issue = tracking_issue(issues, kind)
    if report["state"] == "green":
        if issue:
            writer.call("POST", f"repos/{repo}/issues/{issue['number']}/comments",
                        {"body": f"`{report['workflow']}` is green on main again at `{short(report.get('sha'))}` "
                                 f"({report.get('run_url')}). Closing."})
            writer.call("PATCH", f"repos/{repo}/issues/{issue['number']}", {"state": "closed", "state_reason": "completed"})
        return
    previous = {} if report.get("reset") else issue_data(issue)
    steps_state: dict[str, dict] = {}
    for step in report.get("steps") or []:
        steps_state[step["step"]] = {"culprit": step.get("culprit"),
                                     "fix": {"hints": (step.get("fix") or {}).get("hints") or []},
                                     "fix_pr": fix_prs.get(step["step"]) or
                                     (previous.get("steps", {}).get(step["step"]) or {}).get("fix_pr")}
    body = render_issue(report, steps_state, {k: v["fix_pr"] for k, v in steps_state.items() if v.get("fix_pr")})
    new_steps = [s for s in report.get("steps") or [] if not s.get("known")]
    if issue is None:
        created = writer.call("POST", f"repos/{repo}/issues",
                              {"title": ISSUE_TITLES[kind], "body": body, "labels": [ISSUE_LABEL]})
        number = created.get("number")
    else:
        number = issue["number"]
        if str(issue.get("body") or "").strip() != body.strip():
            writer.call("PATCH", f"repos/{repo}/issues/{number}", {"body": body})
        if new_steps and kind == "fast-guards":
            writer.call("POST", f"repos/{repo}/issues/{number}/comments",
                        {"body": "Newly red on main: " + ", ".join(f"{code(s['step'])} ({who(s.get('culprit'))})"
                                                                  for s in new_steps)})
    by_pr: dict[int, list[Mapping]] = {}
    for step in new_steps:
        pr = (step.get("culprit") or {}).get("pr")
        if pr:
            by_pr.setdefault(int(pr), []).append(step)
    for pr, steps in by_pr.items():
        fix_pr = next((fix_prs.get(s["step"]) for s in steps if fix_prs.get(s["step"])), None)
        comment = render_culprit_comment(report, pr, steps, number or None, fix_pr)
        marker = comment.splitlines()[0]
        upsert_comment(writer, repo, pr, marker, comment, gh.comments(pr) if gh else [])


def report_pr(writer: Writer, gh: GitHub | None, repo: str, report: Mapping) -> None:
    pr = report.get("pr")
    if not pr:
        return
    existing = gh.comments(int(pr)) if gh else []
    current = next((c for c in existing if PR_MARKER in str(c.get("body") or "")), None)
    if report["state"] == "green" and current is None:
        return  # never red on this PR: nothing to say
    upsert_comment(writer, repo, int(pr), PR_MARKER, render_pr_comment(report), existing)


# ---------------------------------------------------------------- commands


def load_run(gh: GitHub | None, run_id: int | None) -> dict:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if run_id is None and event_path and Path(event_path).is_file():
        event = json.loads(Path(event_path).read_text())
        if event.get("workflow_run"):
            return event["workflow_run"]
    if run_id is None or gh is None:
        raise SystemExit("no workflow_run event: pass --run-id (and a token) or --sha with --log")
    return gh.run(run_id)


def client(args: argparse.Namespace) -> GitHub | None:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if getattr(args, "offline", False) or not token:
        return None
    return GitHub(args.repo, token)


def command_analyze(args: argparse.Namespace) -> int:
    gh = client(args)
    root = Path(args.root).resolve()
    if args.sha:
        run = {"id": None, "head_sha": git(root, "rev-parse", args.sha), "conclusion": args.conclusion,
               "name": args.workflow, "event": args.event, "html_url": args.run_url or "(local replay)",
               "head_branch": "main" if args.event != "pull_request" else args.branch,
               "pull_requests": [{"number": args.pr}] if args.pr else []}
    else:
        run = load_run(gh, args.run_id)
    name, event = run.get("name"), run.get("event")
    log = Path(args.log).read_text(errors="replace") if args.log else ""
    head = git(root, "rev-parse", args.head or "HEAD")
    if run.get("conclusion") not in RED | {"success"}:
        report: dict = {"state": "skipped", "reason": f"conclusion {run.get('conclusion')}"}
    elif event == "pull_request":
        if run.get("conclusion") != "success" and not log and gh:
            log = gh.failed_log(int(run["id"]))
        report = analyze_pr(gh, run, root, log)
    elif name == VARS_WORKFLOW:
        green_log, green_run = None, None
        if run.get("conclusion") != "success":
            if not log and gh:
                log = gh.job_log(int(run["id"]))
            if args.green_log:
                green_log = Path(args.green_log).read_text(errors="replace")
            elif gh:
                greens = [r for r in gh.main_runs(VARS_WORKFLOW_FILE, status="success")
                          if r.get("id") != run.get("id")]
                if greens:
                    green_run = greens[0]
                    green_log = gh.job_log(int(green_run["id"]))
        report = analyze_vars_main(gh, run, root, log, green_log, green_run)
    elif run.get("head_branch") == "main" and event in ("push", "workflow_dispatch"):
        if run.get("conclusion") != "success" and not log and gh:
            log = gh.failed_log(int(run["id"]))
        report = analyze_fast_main(gh, run, root, log, head, baseline=args.baseline)
    else:
        report = {"state": "skipped", "reason": f"{name} on {event} {run.get('head_branch')}"}
    report.setdefault("workflow", name)
    report["headline"] = headline(report)
    report["api_calls"] = gh.calls if gh else 0
    text = json.dumps(report, indent=2) + "\n"
    if args.out:
        Path(args.out).write_text(text)
    else:
        sys.stdout.write(text)
    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a") as handle:
            handle.write(f"headline={' '.join(report['headline'].split())}\n")
            handle.write(f"state={report.get('state')}\n")
            handle.write(f"has_patch={'true' if fix_patch(report) else 'false'}\n")
    return 0


def fix_patch(report: Mapping) -> str:
    """The verified fix for main, when there is one."""
    fix = report.get("fix") or {}
    if report.get("branch") != "main" or report.get("state") != "red" or not fix.get("verified"):
        return ""
    return str(fix.get("patch") or "")


def command_report(args: argparse.Namespace) -> int:
    report = json.loads(Path(args.report).read_text())
    if report.get("state") not in ("red", "green"):
        print(f"nothing to report: {report.get('reason') or report.get('state')}")
        return 0
    gh = client(args)
    writer = Writer(gh, args.dry_run)
    fix_prs: dict[str, str] = {}
    if args.fix_pr:
        for step in (report.get("fix") or {}).get("steps") or []:
            fix_prs[step] = args.fix_pr
    if report.get("branch") == "pr":
        report_pr(writer, gh, args.repo, report)
    else:
        report_main(writer, gh, args.repo, report, fix_prs)
    for entry in writer.log:
        print(entry)
    print(f"api calls: {gh.calls if gh else 0}")
    return 0


def command_patch(args: argparse.Namespace) -> int:
    """Write the verified fix patch and a PR title/body for the fix-PR step."""
    report = json.loads(Path(args.report).read_text())
    patch = fix_patch(report)
    if not patch:
        return 1
    Path(args.patch_out).write_text(patch)
    fixed = set(report["fix"].get("steps") or [])
    steps = [s for s in report["steps"] if s["step"] in fixed]
    culprits = list(dict.fromkeys(who(s.get("culprit")) for s in steps))
    title = f"ci: fix {FAST_WORKFLOW} on main after {culprits[0].split(' ')[0]}" if culprits else \
        f"ci: fix {FAST_WORKFLOW} on main"
    body = [f"`{FAST_WORKFLOW}` is red on main since {', '.join(culprits)} ({report.get('run_url')}).", ""]
    for step in steps:
        body.append(f"- {code(step['step'])}: " + " ".join(step["fix"].get("hints") or []))
    body += ["", f"Opened by `scripts/ci/guard_attribution.py`. The failing steps pass with this patch on main at "
                 f"`{short(report['fix'].get('head'))}`; nothing else was run. Review, then merge."]
    Path(args.body_out).write_text(json.dumps({"title": title, "body": "\n".join(body) + "\n"}))
    return 0


def command_fix(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    if args.log:
        log = Path(args.log).read_text(errors="replace")
    else:
        run = subprocess.run([str(ROOT / "scripts/ci/guards-local.sh"), "--root", str(root), "--no-stamp"],
                             capture_output=True, text=True)
        log = run.stdout + run.stderr
        if run.returncode == 0:
            print("cmux fast guards pass; nothing to fix.")
            return 0
    failures = parse_guard_log(log)
    if not failures:
        print("no failed guard step in the log", file=sys.stderr)
        return 2
    tree = Tree(root)
    for failure in failures:
        print(f"FAIL {failure.step}")
        for test in failure.tests[:MAX_TESTS_PER_STEP]:
            print(f"  {test.test or '(step output)'}: {test.message.splitlines()[0] if test.message else ''}")
        fixes = fixes_for(failure, tree)
        if not fixes:
            print("  no mechanical fix; the assertion names what to change")
        for fix in fixes:
            print(f"  fix: {fix.hint}")
            if args.dry_run:
                continue
            if fix.edit:
                for path in fix.edit(tree):
                    print(f"  edited {path}")
            if fix.command:
                print(f"  running {fix.command}")
                subprocess.run(["bash", "-c", fix.command], cwd=root)
    if args.dry_run:
        return 1
    results = run_steps(ROOT, root, [f.step for f in failures])
    for step, ok in results.items():
        print(f"{'pass' if ok else 'FAIL'}: {step}")
    return 0 if all(results.values()) else 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    sub = parser.add_subparsers(dest="command", required=True)

    analyze = sub.add_parser("analyze", help="read-only: parse, attribute and verify fixes; writes a report")
    analyze.add_argument("--run-id", type=int, help="the completed run (default: the workflow_run event)")
    analyze.add_argument("--root", default=str(ROOT), help="a checkout of main with history")
    analyze.add_argument("--head", help="main's head to verify fixes on (default HEAD)")
    analyze.add_argument("--out")
    analyze.add_argument("--log", help="use this log instead of fetching the run's")
    analyze.add_argument("--green-log", help="repository variables: the last green run's log")
    analyze.add_argument("--baseline", help="skip the run history: the step last passed at this commit")
    analyze.add_argument("--offline", action="store_true", help="no GitHub calls")
    # A replay without a GitHub run: --sha with --log (and --baseline).
    analyze.add_argument("--sha")
    analyze.add_argument("--conclusion", default="failure")
    analyze.add_argument("--workflow", default=FAST_WORKFLOW)
    analyze.add_argument("--event", default="push")
    analyze.add_argument("--branch", default="main")
    analyze.add_argument("--pr", type=int)
    analyze.add_argument("--run-url")
    analyze.set_defaults(func=command_analyze)

    report = sub.add_parser("report", help="write: comments, the tracking issue")
    report.add_argument("--report", required=True)
    report.add_argument("--fix-pr", help="URL of the fix PR opened for this report")
    report.add_argument("--dry-run", action="store_true", help="print the writes instead of making them")
    report.add_argument("--offline", action="store_true")
    report.set_defaults(func=command_report)

    patch = sub.add_parser("patch", help="the verified fix as a patch and a PR title/body (exit 1: none)")
    patch.add_argument("--report", required=True)
    patch.add_argument("--patch-out", required=True)
    patch.add_argument("--body-out", required=True)
    patch.set_defaults(func=command_patch)

    fix = sub.add_parser("fix", help="apply the mechanical guard fixes to a checkout and rerun the failing steps")
    fix.add_argument("--root", default=os.getcwd())
    fix.add_argument("--log", help="a saved guard log (CI job log or guards-local.sh output)")
    fix.add_argument("--dry-run", action="store_true", help="print the fixes without applying them")
    fix.set_defaults(func=command_fix)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
