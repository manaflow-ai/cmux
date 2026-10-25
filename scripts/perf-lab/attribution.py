#!/usr/bin/env python3
"""Culprit attribution: who and what a verified perf culprit belongs to, told once on GitHub.

After verify.py (task 017) marks a culprit sha `verified` (strict DIFFERENT, p <= 0.01, in the
regression direction), this maps the sha to:

- its pull request: a GitHub merge commit names it in its subject ("Merge pull request #N from");
  otherwise `GET repos/{repo}/commits/{sha}/pulls` lists the PR whose merge (or squash) made the sha;
- its author, the Co-authored-by trailers and the Agent-Session trailers (of the commit, and for a
  merge commit of every commit the merge brought in);
- the OWNERS.md areas its first-parent diff touches (the same rows and the same most-specific-row
  rule as the pre-push owner warning, scripts/cmux-next/guardrails.py).

Then it writes one comment per culprit with the verified magnitude and the issue link: on the PR,
or on the issue when no PR made the sha (a direct push; the author is the fallback). The comment
carries a marker, so a second run edits that comment or leaves it, never adds one. The issue is
assigned to the PR author, else to the GitHub account of the commit author.

Chromium does the same after a Pinpoint culprit (catapult `dashboard/dashboard/pinpoint/models/job.py`):
`_FormatAndPostBugCommentOnComplete` posts the culprit commit, its author and the measured difference
on the bug, and `_ComputePostOwnerSheriffCCList` makes the culprit's author the bug owner and CCs the
other people on the commit. cmux has no Gerrit reviewers; co-authors, agent sessions and OWNERS
areas take their place.

  python3 scripts/perf-lab/attribution.py --repo manaflow-ai/cmux --culprit verify-result.json [--dry-run]

Load it by file path; it needs only the standard library, `git` and (outside tests) `gh`.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Protocol

HERE = Path(__file__).resolve().parent
GUARDRAILS_PY = HERE.parent / "cmux-next" / "guardrails.py"
OWNERS_PATH = "plans/cmux-next/OWNERS.md"
MARKER = "<!-- perf-lab-culprit group={group} sha={sha} -->"
MARKER_RE = re.compile(r"^<!-- perf-lab-culprit group=(?P<group>\d+) sha=(?P<sha>[0-9a-f]{40}) -->")
MERGE_SUBJECT = re.compile(r"^Merge pull request #(?P<number>\d+) from ")
CO_AUTHOR_TRAILER = "Co-authored-by"
SESSION_TRAILER = "Agent-Session"
PERSON = re.compile(r"^(?P<name>.*?)\s*<(?P<email>[^<>]+)>$")
COMMENTS_PER_PAGE = 100
SHERIFF_DOC = "plans/cmux-next/perf-sheriff.md"


class AttributionError(RuntimeError):
    pass


# ---------------------------------------------------------------- input: the verified culprit


@dataclass(frozen=True)
class Magnitude:
    """verify.py's stored shift: C^ (base) against C (culprit), strict p, attempts per arm."""
    unit: str
    better: str
    base_p50: float
    head_p50: float
    base_p99: float
    head_p99: float
    p_value: float
    attempts: int

    @staticmethod
    def change_percent(base: float, head: float) -> float | None:
        return None if base == 0 else (head - base) / base * 100.0


@dataclass(frozen=True)
class Culprit:
    group_id: int
    sha: str
    story: str
    metric: str
    host_class: str
    verified: bool
    magnitude: Magnitude
    issue_number: int | None
    job_id: str | None = None

    @classmethod
    def from_json(cls, data: dict) -> Culprit:
        """The verification record verify.py stores on the alert group (task 017)."""
        try:
            base, head = data["base"], data["head"]
            magnitude = Magnitude(unit=data["unit"], better=data["better"],
                                  base_p50=float(base["p50"]), head_p50=float(head["p50"]),
                                  base_p99=float(base["p99"]), head_p99=float(head["p99"]),
                                  p_value=float(data["p_value"]), attempts=int(data["attempts"]))
            sha = str(data["culprit_sha"]).lower()
            culprit = cls(group_id=int(data["group_id"]), sha=sha, story=data["story"], metric=data["metric"],
                          host_class=data["host_class"], verified=data["state"] == "verified", magnitude=magnitude,
                          issue_number=None if data.get("issue_number") is None else int(data["issue_number"]),
                          job_id=None if data.get("job_id") is None else str(data["job_id"]))
        except (KeyError, TypeError, ValueError) as error:
            raise AttributionError(f"verification record is incomplete: {error!r}") from error
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise AttributionError(f"group {culprit.group_id}: culprit sha {sha!r} is not a full sha")
        return culprit


# ---------------------------------------------------------------- git facts


@dataclass(frozen=True)
class Person:
    name: str
    email: str

    @classmethod
    def parse(cls, text: str) -> Person | None:
        match = PERSON.match(text.strip())
        return None if match is None else cls(match.group("name"), match.group("email"))


@dataclass(frozen=True)
class CommitFacts:
    sha: str
    parents: tuple[str, ...]
    author: Person
    subject: str
    co_authors: tuple[Person, ...]
    sessions: tuple[str, ...]
    files: tuple[str, ...]


_FIELDS = "%H%x00%P%x00%an%x00%ae%x00%s%x00" \
          f"%(trailers:key={CO_AUTHOR_TRAILER},valueonly,unfold,separator=%x01)%x00" \
          f"%(trailers:key={SESSION_TRAILER},valueonly,unfold,separator=%x01)%x00%x02"


def _unique(items: Sequence, key: Callable = lambda item: item) -> tuple:
    seen, out = set(), []
    for item in items:
        if key(item) not in seen:
            seen.add(key(item))
            out.append(item)
    return tuple(out)


class Git:
    """Reads commit facts from one checkout. `run` is the subprocess seam."""

    def __init__(self, repo: Path, run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> None:
        self._repo = repo
        self._run = run

    def _git(self, *args: str) -> str:
        done = self._run(["git", "-C", str(self._repo), *args], capture_output=True, text=True)
        if done.returncode != 0:
            raise AttributionError(f"git {' '.join(args)}: {done.stderr.strip()}")
        return done.stdout

    def _records(self, *args: str) -> list[list[str]]:
        """(sha, parents, author name, author email, subject, co-author trailers, session trailers) per commit."""
        out = self._git("log", f"--format={_FIELDS}", *args)
        return [record.lstrip("\n").split("\x00")[:7] for record in out.split("\x02") if record.strip()]

    def commit_facts(self, sha: str) -> CommitFacts:
        records = self._records("--no-walk", sha)
        if len(records) != 1:
            raise AttributionError(f"{sha}: not one commit in {self._repo}")
        full, parents, name, email, subject, _, _ = records[0]
        parent_list = tuple(parents.split())
        if len(parent_list) > 1:  # a merge commit: the people of every commit it brought in, and of itself
            records = self._records(f"{parent_list[0]}..{full}")
        people: list[Person] = []
        sessions: list[str] = []
        for _, _, branch_name, branch_email, _, co_authors, session_values in records:
            people.append(Person(branch_name, branch_email))
            people += [person for value in co_authors.split("\x01") if (person := Person.parse(value))]
            sessions += [value.strip() for value in session_values.split("\x01") if value.strip()]
        co = [person for person in people if person.email.lower() != email.lower()]
        if parent_list:
            files = self._git("diff", "--name-only", "--no-renames", parent_list[0], full)
        else:
            files = self._git("diff-tree", "--root", "-r", "--name-only", "--no-commit-id", full)
        return CommitFacts(sha=full, parents=parent_list, author=Person(name, email), subject=subject,
                           co_authors=_unique(co, key=lambda person: person.email.lower()),
                           sessions=_unique(sessions), files=tuple(line for line in files.splitlines() if line))

    def show(self, ref: str, path: str) -> str:
        return self._git("show", f"{ref}:{path}")


# ---------------------------------------------------------------- OWNERS areas


def _load_guardrails():
    """guardrails.py owns the OWNERS.md parser and its glob rules; one copy of them in the repo."""
    name = "perf_lab_guardrails"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, GUARDRAILS_PY)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module  # its dataclasses resolve their module through sys.modules
        spec.loader.exec_module(module)
    return sys.modules[name]


@dataclass(frozen=True)
class OwnedArea:
    area: str
    owner: str
    doc: str
    files: tuple[str, ...]


def owned_areas(files: Sequence[str], owners_text: str) -> tuple[OwnedArea, ...]:
    """The OWNERS.md rows FILES fall in. A file belongs to its most specific matching row (owner_warnings' rule)."""
    guardrails = _load_guardrails()
    rows = guardrails.parse_owners(owners_text)
    hits: dict[int, list[str]] = {}
    for path in files:
        scored = [(max(guardrails.glob_specificity(g) for g in globs if guardrails.glob_match(path, g)), row)
                  for row, (_, globs, _, _) in enumerate(rows) if any(guardrails.glob_match(path, g) for g in globs)]
        if scored:
            best = max(score for score, _ in scored)
            for score, row in scored:
                if score == best:
                    hits.setdefault(row, []).append(path)
    return tuple(OwnedArea(area, owner, doc, tuple(hits[row]))
                 for row, (area, _, owner, doc) in enumerate(rows) if row in hits)


# ---------------------------------------------------------------- GitHub seam


class GitHub(Protocol):
    def get(self, path: str) -> object: ...
    def post(self, path: str, body: dict) -> object: ...
    def patch(self, path: str, body: dict) -> object: ...


class GhCli:
    """`gh api` single reads and writes (no polling, so glaeda-gh has nothing to serve here)."""

    def __init__(self, run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> None:
        self._run = run

    def _api(self, path: str, method: str, body: dict | None) -> object:
        command = ["gh", "api", "-X", method, path]
        if body is not None:
            command += ["--input", "-"]
        done = self._run(command, input=None if body is None else json.dumps(body), capture_output=True, text=True)
        if done.returncode != 0:
            raise AttributionError(f"gh api {method} {path}: {done.stderr.strip()}")
        return json.loads(done.stdout) if done.stdout.strip() else None

    def get(self, path: str) -> object:
        return self._api(path, "GET", None)

    def post(self, path: str, body: dict) -> object:
        return self._api(path, "POST", body)

    def patch(self, path: str, body: dict) -> object:
        return self._api(path, "PATCH", body)


# ---------------------------------------------------------------- attribution


@dataclass(frozen=True)
class PullRequest:
    number: int
    url: str
    author_login: str | None
    found_by: str  # "merge-commit" or "commits-pulls"


@dataclass(frozen=True)
class Attribution:
    culprit: Culprit
    commit: CommitFacts
    pull: PullRequest | None
    assignee: str | None
    areas: tuple[OwnedArea, ...] = field(default_factory=tuple)

    def to_json(self) -> dict:
        return asdict(self)


def _login(user: object) -> str | None:
    """A person's login, or None for a missing user or a bot (a bot cannot fix the regression)."""
    login = user.get("login") if isinstance(user, dict) else None
    return None if not login or login.endswith("[bot]") else login


def resolve_pull(facts: CommitFacts, github: GitHub, repo: str) -> PullRequest | None:
    """The PR whose merge made FACTS.sha. A GitHub merge commit names it; a squash or rebase merge needs the API."""
    match = MERGE_SUBJECT.match(facts.subject)
    if match and len(facts.parents) > 1:
        pull = github.get(f"repos/{repo}/pulls/{match.group('number')}")
        return PullRequest(int(pull["number"]), pull["html_url"], _login(pull.get("user")), "merge-commit")
    pulls = [pull for pull in github.get(f"repos/{repo}/commits/{facts.sha}/pulls") or [] if pull.get("merged_at")]
    # A commit can sit in several PRs (a stacked PR, a backport); the one that merged it into the branch has it as
    # its merge commit. Without such a PR the sha came in through a direct push.
    made = [pull for pull in pulls if pull.get("merge_commit_sha") == facts.sha]
    if not made:
        return None
    pull = made[0]
    return PullRequest(int(pull["number"]), pull["html_url"], _login(pull.get("user")), "commits-pulls")


def attribute(culprit: Culprit, *, git: Git, github: GitHub, repo: str, owners_text: str) -> Attribution:
    """Reads only. Refuses an unverified culprit or one without its issue: only verified groups get issues (3.5)."""
    if not culprit.verified:
        raise AttributionError(f"group {culprit.group_id}: culprit {culprit.sha[:10]} is unverified; "
                               "only a verified culprit is attributed")
    if culprit.issue_number is None:
        raise AttributionError(f"group {culprit.group_id}: the verified group has no issue yet")
    facts = git.commit_facts(culprit.sha)
    pull = resolve_pull(facts, github, repo)
    if pull is not None and pull.author_login is not None:
        assignee = pull.author_login
    else:
        assignee = _login((github.get(f"repos/{repo}/commits/{facts.sha}") or {}).get("author"))
    return Attribution(culprit=culprit, commit=facts, pull=pull, assignee=assignee,
                       areas=owned_areas(facts.files, owners_text))


# ---------------------------------------------------------------- the comment


def _number(value: float) -> str:
    return f"{value:.3g}" if abs(value) < 1000 else f"{value:.0f}"


def _change(base: float, head: float) -> str:
    percent = Magnitude.change_percent(base, head)
    return "n/a" if percent is None else f"{percent:+.1f} %"


def comment_body(attribution: Attribution, *, repo: str, server: str = "https://github.com") -> str:
    culprit, facts, magnitude = attribution.culprit, attribution.commit, attribution.culprit.magnitude
    unit = magnitude.unit
    commit_url = f"{server}/{repo}/commit/{facts.sha}"
    issue = f"#{culprit.issue_number}"
    lines = [
        MARKER.format(group=culprit.group_id, sha=culprit.sha),
        f"**Perf regression, verified culprit.** [`{facts.sha[:10]}`]({commit_url}) ({facts.subject}) makes "
        f"`{culprit.story}` / `{culprit.metric}` worse on `{culprit.host_class}` ({magnitude.better} is better).",
        "",
        "| | before (C^) | culprit (C) | change |",
        "|---|---|---|---|",
        f"| p50 | {_number(magnitude.base_p50)} {unit} | {_number(magnitude.head_p50)} {unit} | "
        f"{_change(magnitude.base_p50, magnitude.head_p50)} |",
        f"| p99 | {_number(magnitude.base_p99)} {unit} | {_number(magnitude.head_p99)} {unit} | "
        f"{_change(magnitude.base_p99, magnitude.head_p99)} |",
        "",
        f"Strict verification: DIFFERENT, p = {magnitude.p_value:.2g}, {magnitude.attempts} ABBA attempts per side"
        + (f", job {culprit.job_id}." if culprit.job_id else "."),
        f"Issue: {issue}" + (f", assigned to @{attribution.assignee}." if attribution.assignee else
                              ", no assignee found: the sheriff assigns it."),
    ]
    if attribution.pull is None:
        lines.append(f"No pull request merged this commit (direct push). Author: {facts.author.name}.")
    people = ", ".join(person.name for person in facts.co_authors)
    if people:
        lines.append(f"Co-authors: {people}.")
    if facts.sessions:
        lines.append("Agent sessions: " + ", ".join(f"[{index + 1}]({url})" for index, url in enumerate(facts.sessions))
                     + ".")
    for area in attribution.areas:
        lines.append(f"Owned area: {area.area} ({len(area.files)} files): owner {area.owner}. Read {area.doc}.")
    lines += ["", f"Turn the feature off first when the change is behind a perfPath feature, else fix forward "
                  f"({SHERIFF_DOC}). Do not edit budgets, thresholds or expectations to clear the alert."]
    return "\n".join(lines) + "\n"


@dataclass(frozen=True)
class Published:
    target: int  # the PR number, or the issue number when no PR made the culprit
    comment: str  # "created", "updated", "unchanged", or "dry-run"
    comment_url: str | None
    assigned: str | None


def _find_marked(github: GitHub, repo: str, number: int, marker: str) -> dict | None:
    page = 1
    while True:
        comments = github.get(f"repos/{repo}/issues/{number}/comments?per_page={COMMENTS_PER_PAGE}&page={page}") or []
        for comment in comments:
            if (comment.get("body") or "").startswith(marker):
                return comment
        if len(comments) < COMMENTS_PER_PAGE:
            return None
        page += 1


def publish(attribution: Attribution, *, github: GitHub, repo: str, dry_run: bool = False,
            server: str = "https://github.com") -> Published:
    """One comment per culprit (edited when its text changed), then the issue's assignee. Safe to run again."""
    culprit = attribution.culprit
    target = attribution.pull.number if attribution.pull is not None else culprit.issue_number
    marker = MARKER.format(group=culprit.group_id, sha=culprit.sha)
    body = comment_body(attribution, repo=repo, server=server)
    if dry_run:
        return Published(target, "dry-run", None, attribution.assignee)
    existing = _find_marked(github, repo, target, marker)
    if existing is None:
        made = github.post(f"repos/{repo}/issues/{target}/comments", {"body": body})
        outcome, url = "created", made.get("html_url")
    elif existing.get("body") == body:
        outcome, url = "unchanged", existing.get("html_url")
    else:
        github.patch(f"repos/{repo}/issues/comments/{existing['id']}", {"body": body})
        outcome, url = "updated", existing.get("html_url")
    if attribution.assignee is not None:
        github.post(f"repos/{repo}/issues/{culprit.issue_number}/assignees", {"assignees": [attribution.assignee]})
    return Published(target, outcome, url, attribution.assignee)


# ---------------------------------------------------------------- CLI


def main(argv: Sequence[str] | None = None, *, github: GitHub | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True, help="OWNER/NAME")
    parser.add_argument("--culprit", type=Path, required=True, help="verify.py's verification record (JSON)")
    parser.add_argument("--checkout", type=Path, default=Path.cwd(), help="a checkout that has the culprit sha")
    parser.add_argument("--owners-ref", default="HEAD", help=f"the ref whose {OWNERS_PATH} names the owners")
    parser.add_argument("--dry-run", action="store_true", help="read and print; write nothing on GitHub")
    args = parser.parse_args(argv)
    try:
        culprit = Culprit.from_json(json.loads(args.culprit.read_text()))
        git, github = Git(args.checkout), github or GhCli()
        attribution = attribute(culprit, git=git, github=github, repo=args.repo,
                                owners_text=git.show(args.owners_ref, OWNERS_PATH))
        published = publish(attribution, github=github, repo=args.repo, dry_run=args.dry_run)
    except (AttributionError, OSError, json.JSONDecodeError) as error:
        print(f"attribution: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"attribution": attribution.to_json(), "published": asdict(published)}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
