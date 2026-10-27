#!/usr/bin/env python3
"""Culprit attribution: who and what a verified perf culprit belongs to, told once on GitHub.

After verify.py (task 017) marks an alert group's culprit `verified` (strict DIFFERENT, p <= 0.01,
in the regression direction), this reads that group from the lab store: the group row
(culprit_sha, culprit_verified, issue_number, set by verify.py and alerts.py), the verify job's
Verification through `GroupRecorder.verification_of`, and the unit of the series the job measured.
Then it maps the culprit sha to:

- its pull request: a GitHub merge commit names it in its subject ("Merge pull request #N from");
  otherwise `GET repos/{repo}/commits/{sha}/pulls` lists the PR whose merge or squash made the sha,
  or the merged PR into the bisected branch that holds it (a rebase merge, where only the last
  rebased commit is the PR's merge commit);
- its author: the PR author; for a local merge with no PR (the big branch lands batches as
  "Merge cp/<task> into perf/chrome-parity") the author of the merged branch's newest commit;
  for a direct push the commit author;
- the Co-authored-by and Agent-Session trailers (of the commit, and for a merge commit of every
  commit the merge brought in);
- the OWNERS.md areas its first-parent diff touches (the same rows and the same most-specific-row
  rule as the pre-push owner warning, scripts/cmux-next/guardrails.py).

Then it writes one comment per culprit with the verified magnitude and the issue link: on the PR,
or on the issue when no PR made the sha. The comment carries a marker, so a second run edits that
comment or leaves it, never adds one. The issue is assigned to the author found above.

Chromium does the same after a Pinpoint culprit (catapult `dashboard/dashboard/pinpoint/models/job.py`):
`_FormatAndPostBugCommentOnComplete` posts the culprit commit, its author and the measured difference
on the bug, and `_ComputePostOwnerSheriffCCList` makes the culprit's author the bug owner and CCs the
other people on the commit. cmux has no Gerrit reviewers; co-authors, agent sessions and OWNERS
areas take their place.

GitHub reads of issue comments go through glaeda-gh (p12-perf-process.md 3.5), as alerts.py's do;
`gh api` makes the single PR and commit lookups and the writes, with alerts.py's backoff.

  python3 scripts/perf-lab/attribution.py --db lab.sqlite --group 7 [--branch perf/chrome-parity] [--dry-run]

Load it by file path; it needs only the standard library, `git`, verify.py next to it and (outside
tests) `gh` and `glaeda-gh`.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sqlite3
import subprocess
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Protocol

HERE = Path(__file__).resolve().parent
GUARDRAILS_PY = HERE.parent / "cmux-next" / "guardrails.py"
OWNERS_PATH = "plans/cmux-next/OWNERS.md"
DEFAULT_REPO = "manaflow-ai/cmux"
DEFAULT_BRANCH = "perf/chrome-parity"  # the big branch the lab bisects (p12-perf-process.md 1)
MARKER = "<!-- perf-lab-culprit group={group} sha={sha} -->"
MERGE_SUBJECT = re.compile(r"^Merge pull request #(?P<number>\d+) from ")
COMMENT_ID_IN_URL = re.compile(r"#issuecomment-(?P<id>\d+)$")
CO_AUTHOR_TRAILER = "Co-authored-by"
SESSION_TRAILER = "Agent-Session"
PERSON = re.compile(r"^(?P<name>.*?)\s*<(?P<email>[^<>]+)>$")
SHERIFF_DOC = "plans/cmux-next/perf-sheriff.md"


class AttributionError(RuntimeError):
    pass


def _load_sibling(module_name: str, filename: str):
    """Loads a perf-lab module by path once, under the name the other lab tools use for it."""
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module  # its dataclasses resolve their module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(module_name, None)
        raise
    return module


# ---------------------------------------------------------------- input: the verified culprit


@dataclass(frozen=True)
class Magnitude:
    """verify.py's Verification of the culprit: C^ (parent) against C (culprit) on one pinpoint host."""
    unit: str
    better: str
    parent_p50: float
    culprit_p50: float
    parent_p99: float
    culprit_p99: float
    p_value: float
    parent_attempts: int
    culprit_attempts: int
    host: str

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
    job_id: int

    @classmethod
    def from_records(cls, group: Mapping, job: Mapping, series: Mapping, verification: Mapping) -> Culprit:
        """One field each from the alert_groups row, the verify job row, its series row and its Verification."""
        try:
            params = json.loads(job["params_json"])
            magnitude = Magnitude(unit=series["unit"], better=params["better"],
                                  parent_p50=float(verification["parent_p50"]),
                                  culprit_p50=float(verification["culprit_p50"]),
                                  parent_p99=float(verification["parent_p99"]),
                                  culprit_p99=float(verification["culprit_p99"]),
                                  p_value=float(verification["p_value"]),
                                  parent_attempts=int(verification["parent_attempts"]),
                                  culprit_attempts=int(verification["culprit_attempts"]),
                                  host=str(verification["host"]))
            sha = str(group["culprit_sha"]).lower()
            culprit = cls(group_id=int(group["id"]), sha=sha, story=job["story"], metric=params["metric"],
                          host_class=job["host_class"],
                          verified=bool(group["culprit_verified"]) and verification["state"] == "verified",
                          magnitude=magnitude,
                          issue_number=None if group["issue_number"] is None else int(group["issue_number"]),
                          job_id=int(verification["job_id"]))
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise AttributionError(f"group {group['id']}: verification record is incomplete: {error!r}") from error
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise AttributionError(f"group {culprit.group_id}: culprit sha {sha!r} is not a full sha")
        if str(verification["culprit_sha"]).lower() != sha:
            raise AttributionError(f"group {culprit.group_id}: verify job {culprit.job_id} verified "
                                   f"{verification['culprit_sha']}, the group's culprit is {sha}")
        return culprit


def load_culprit(db: Path, group_id: int) -> Culprit:
    """The group's culprit and its newest Verification of that sha, read from the lab store; writes nothing."""
    if not db.is_file():
        raise AttributionError(f"{db}: no lab store there")
    verify = _load_sibling("perf_lab_verify", "verify.py")
    connection = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    recorder = verify.GroupRecorder(db, clock=lambda: datetime.now(timezone.utc))
    try:
        group = connection.execute("SELECT * FROM alert_groups WHERE id = ?", (group_id,)).fetchone()
        if group is None:
            raise AttributionError(f"no alert group {group_id}")
        if group["culprit_sha"] is None:
            raise AttributionError(f"group {group_id} has no culprit yet")
        sha = str(group["culprit_sha"]).lower()
        records = [record for record in recorder.verification_of(group_id)
                   if str(record["culprit_sha"]).lower() == sha]
        verified = [record for record in records if record["state"] == "verified"]
        if not records:
            raise AttributionError(f"group {group_id}: no finished verify job for culprit {sha[:10]}")
        verification = (verified or records)[-1]
        job = connection.execute("SELECT * FROM jobs WHERE id = ?", (verification["job_id"],)).fetchone()
        metric = json.loads(job["params_json"]).get("metric")
        series = connection.execute(
            """SELECT s.* FROM alerts a JOIN series s ON s.id = a.series_id
               WHERE a.group_id = ? AND s.story = ? AND s.metric = ? AND s.host_class = ? ORDER BY a.id LIMIT 1""",
            (group_id, job["story"], metric, job["host_class"])).fetchone()
        if series is None:
            raise AttributionError(f"group {group_id}: no alerted series {job['story']}/{metric} on "
                                   f"{job['host_class']}, the series verify job {job['id']} measured")
        return Culprit.from_records(group, job, series, verification)
    finally:
        recorder.close()
        connection.close()


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
    co_authors: tuple[Person, ...]  # everyone on the commit (a merge: on every commit it brought in) but `author`
    sessions: tuple[str, ...]
    files: tuple[str, ...]
    branch_head: str | None = None  # a merge commit: the newest non-merge commit it brought in
    branch_author: Person | None = None  # and that commit's author

    @property
    def is_merge(self) -> bool:
        return len(self.parents) > 1


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
        branch_head, branch_author = None, None
        if len(parent_list) > 1:  # a merge commit: the people of every commit it brought in, and of itself
            records = self._records(f"{parent_list[0]}..{full}")
            newest = next((record for record in records if len(record[1].split()) <= 1), None)
            if newest is not None:
                branch_head, branch_author = newest[0], Person(newest[2], newest[3])
        people: list[Person] = []
        sessions: list[str] = []
        for _, _, commit_name, commit_email, _, co_authors, session_values in records:
            people.append(Person(commit_name, commit_email))
            people += [person for value in co_authors.split("\x01") if (person := Person.parse(value))]
            sessions += [value.strip() for value in session_values.split("\x01") if value.strip()]
        co = [person for person in people if person.email.lower() != email.lower()]
        if parent_list:
            files = self._git("diff", "--name-only", "--no-renames", parent_list[0], full)
        else:
            files = self._git("diff-tree", "--root", "-r", "--name-only", "--no-commit-id", full)
        return CommitFacts(sha=full, parents=parent_list, author=Person(name, email), subject=subject,
                           co_authors=_unique(co, key=lambda person: person.email.lower()),
                           sessions=_unique(sessions), files=tuple(line for line in files.splitlines() if line),
                           branch_head=branch_head, branch_author=branch_author)

    def show(self, ref: str, path: str) -> str:
        return self._git("show", f"{ref}:{path}")


# ---------------------------------------------------------------- OWNERS areas


@dataclass(frozen=True)
class OwnedArea:
    area: str
    owner: str
    doc: str
    files: tuple[str, ...]


def owned_areas(files: Sequence[str], owners_text: str) -> tuple[OwnedArea, ...]:
    """The OWNERS.md rows FILES fall in. A file belongs to its most specific matching row (owner_warnings' rule).

    guardrails.py owns the OWNERS.md parser and its glob rules; one copy of them in the repo.
    """
    if "perf_lab_guardrails" not in sys.modules:
        spec = importlib.util.spec_from_file_location("perf_lab_guardrails", GUARDRAILS_PY)
        module = importlib.util.module_from_spec(spec)
        sys.modules["perf_lab_guardrails"] = module
        spec.loader.exec_module(module)
    guardrails = sys.modules["perf_lab_guardrails"]
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
    def pull(self, number: int) -> dict: ...
    def commit_pulls(self, sha: str) -> list[dict]: ...
    def commit(self, sha: str) -> dict: ...
    def issue_comments(self, number: int) -> list[dict]: ...  # each: id, body, html_url
    def create_comment(self, number: int, body: str) -> dict: ...
    def edit_comment(self, comment_id: int, body: str) -> dict: ...
    def add_assignee(self, number: int, login: str) -> None: ...


Runner = Callable[..., subprocess.CompletedProcess]


class GhCli:
    """Comments read through the glaeda-gh cache; single lookups and writes through `gh api`, with backoff.

    The backoff is alerts.py GhClient's: a rate-limited request is refused before GitHub acts on it,
    so every request retries a 429. A 5xx may have been applied, so only idempotent requests (reads,
    a comment edit, adding an assignee) retry it; a comment POST would risk a second comment.
    """

    RATE_LIMITED = re.compile(r"HTTP 429|rate limit", re.IGNORECASE)
    SERVER_ERROR = re.compile(r"HTTP 5\d\d")

    def __init__(self, repo: str, *, runner: Runner = subprocess.run, sleep: Callable[[float], None] = time.sleep,
                 attempts: int = 4, base_delay_s: float = 2.0) -> None:
        self._repo, self._run, self._sleep = repo, runner, sleep
        self._attempts, self._base_delay_s = attempts, base_delay_s

    def pull(self, number: int) -> dict:
        return self._api("GET", f"repos/{self._repo}/pulls/{number}", None, idempotent=True)

    def commit_pulls(self, sha: str) -> list[dict]:
        return self._api("GET", f"repos/{self._repo}/commits/{sha}/pulls", None, idempotent=True) or []

    def commit(self, sha: str) -> dict:
        return self._api("GET", f"repos/{self._repo}/commits/{sha}", None, idempotent=True) or {}

    def issue_comments(self, number: int) -> list[dict]:
        target = f"{self._repo}#{number}"
        try:
            done = self._run(["glaeda-gh", "status", "comment", target, "--json"], capture_output=True, text=True)
        except OSError as error:
            raise AttributionError(f"glaeda-gh: {error}; install it (glaeda-mini-setup), do not poll GitHub") from None
        if done.returncode == 3:
            raise AttributionError("glaeda-gh daemon is down; start it (see the github-ci-wait skill), "
                                   "do not poll GitHub")
        if done.returncode != 0:
            raise AttributionError(f"glaeda-gh status comment {target}: {done.stderr.strip()}")
        try:
            document = json.loads(done.stdout)
        except json.JSONDecodeError:
            raise AttributionError(f"glaeda-gh status comment {target}: output is not JSON") from None
        comments = document.get("comments") if isinstance(document, dict) else document
        if not isinstance(comments, list) or not all(isinstance(c, dict) for c in comments):
            raise AttributionError(f"glaeda-gh status comment {target}: no comments list")
        return [self._rest_comment(comment) for comment in comments]

    @staticmethod
    def _rest_comment(comment: dict) -> dict:
        """glaeda-gh's comment as the REST fields publish() uses; the REST id is in the comment URL's anchor."""
        url = comment.get("html_url") or comment.get("url")
        identifier = comment.get("id") if isinstance(comment.get("id"), int) else None
        if identifier is None and isinstance(url, str) and (match := COMMENT_ID_IN_URL.search(url)):
            identifier = int(match.group("id"))
        return {"id": identifier, "body": str(comment.get("body") or ""), "html_url": url}

    def create_comment(self, number: int, body: str) -> dict:
        return self._api("POST", f"repos/{self._repo}/issues/{number}/comments", {"body": body}, idempotent=False)

    def edit_comment(self, comment_id: int, body: str) -> dict:
        return self._api("PATCH", f"repos/{self._repo}/issues/comments/{comment_id}", {"body": body},
                         idempotent=True)

    def add_assignee(self, number: int, login: str) -> None:
        self._api("POST", f"repos/{self._repo}/issues/{number}/assignees", {"assignees": [login]}, idempotent=True)

    def _api(self, method: str, path: str, payload: Mapping[str, object] | None, *, idempotent: bool) -> object:
        command = ["gh", "api", "--method", method, path] + ([] if payload is None else ["--input", "-"])
        for attempt in range(self._attempts):
            try:
                done = self._run(command, input=None if payload is None else json.dumps(payload),
                                 capture_output=True, text=True)
            except OSError as error:
                raise AttributionError(f"gh api {method} {path}: {error}") from None
            if done.returncode == 0:
                return json.loads(done.stdout) if done.stdout.strip() else None
            retry = bool(self.RATE_LIMITED.search(done.stderr)) or (
                idempotent and bool(self.SERVER_ERROR.search(done.stderr)))
            if not retry or attempt == self._attempts - 1:
                raise AttributionError(f"gh api {method} {path}: {done.stderr.strip()}")
            self._sleep(self._base_delay_s * 2 ** attempt)
        raise AttributionError(f"gh api {method} {path}: no attempts")


# ---------------------------------------------------------------- attribution


@dataclass(frozen=True)
class PullRequest:
    number: int
    url: str
    author_login: str | None
    found_by: str  # "merge-commit", "merge-commit-sha" or "contains" (a rebase merge's earlier commit)


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


def _pull(pull: dict, found_by: str) -> PullRequest:
    return PullRequest(int(pull["number"]), pull["html_url"], _login(pull.get("user")), found_by)


def resolve_pull(facts: CommitFacts, github: GitHub, branch: str) -> PullRequest | None:
    """The PR that brought FACTS.sha into BRANCH, or None for a local merge or a direct push.

    A GitHub merge commit names its PR. Otherwise the PR whose merge or squash commit is the sha made it;
    failing that, the first PR merged into BRANCH that holds the sha (a rebase merge gives only its last
    commit the PR's merge_commit_sha). A PR that holds the sha but merged elsewhere (a stacked PR, a
    backport) did not bring it in.
    """
    match = MERGE_SUBJECT.match(facts.subject)
    if match and facts.is_merge:
        return _pull(github.pull(int(match.group("number"))), "merge-commit")
    merged = [pull for pull in github.commit_pulls(facts.sha) if pull.get("merged_at")]
    made = [pull for pull in merged if pull.get("merge_commit_sha") == facts.sha]
    if made:
        return _pull(made[0], "merge-commit-sha")
    into_branch = sorted((pull for pull in merged if (pull.get("base") or {}).get("ref") == branch),
                         key=lambda pull: pull["merged_at"])
    return _pull(into_branch[0], "contains") if into_branch else None


def attribute(culprit: Culprit, *, git: Git, github: GitHub, branch: str, owners_text: str) -> Attribution:
    """Reads only. Refuses an unverified culprit or one without its issue: only verified groups get issues (3.5)."""
    if not culprit.verified:
        raise AttributionError(f"group {culprit.group_id}: culprit {culprit.sha[:10]} is unverified; "
                               "only a verified culprit is attributed")
    if culprit.issue_number is None:
        raise AttributionError(f"group {culprit.group_id}: the verified group has no issue yet")
    facts = git.commit_facts(culprit.sha)
    pull = resolve_pull(facts, github, branch)
    if pull is not None and pull.author_login is not None:
        assignee = pull.author_login
    else:  # a local merge belongs to whoever wrote the merged branch, not to whoever ran the merge
        assignee = _login(github.commit(facts.branch_head or facts.sha).get("author"))
    return Attribution(culprit=culprit, commit=facts, pull=pull, assignee=assignee,
                       areas=owned_areas(facts.files, owners_text))


# ---------------------------------------------------------------- the comment


def _number(value: float) -> str:
    return f"{value:.3g}" if abs(value) < 1000 else f"{value:.0f}"


def _change(base: float, head: float) -> str:
    percent = Magnitude.change_percent(base, head)
    return "n/a" if percent is None else f"{percent:+.1f} %"


def _origin(attribution: Attribution) -> str | None:
    """The line that says where the culprit came from when no PR did."""
    facts = attribution.commit
    if attribution.pull is not None:
        return None
    if facts.branch_author is not None:
        return (f"No pull request: a local merge. Branch author: {facts.branch_author.name} "
                f"(newest commit `{facts.branch_head[:10]}`).")
    return f"No pull request merged this commit (direct push). Author: {facts.author.name}."


def comment_body(attribution: Attribution, *, repo: str, server: str = "https://github.com") -> str:
    culprit, facts, magnitude = attribution.culprit, attribution.commit, attribution.culprit.magnitude
    unit = magnitude.unit
    commit_url = f"{server}/{repo}/commit/{facts.sha}"
    lines = [
        MARKER.format(group=culprit.group_id, sha=culprit.sha),
        f"**Perf regression, verified culprit.** [`{facts.sha[:10]}`]({commit_url}) ({facts.subject}) makes "
        f"`{culprit.story}` / `{culprit.metric}` worse on `{culprit.host_class}` ({magnitude.better} is better).",
        "",
        "| | parent (C^) | culprit (C) | change |",
        "|---|---|---|---|",
        f"| p50 | {_number(magnitude.parent_p50)} {unit} | {_number(magnitude.culprit_p50)} {unit} | "
        f"{_change(magnitude.parent_p50, magnitude.culprit_p50)} |",
        f"| p99 | {_number(magnitude.parent_p99)} {unit} | {_number(magnitude.culprit_p99)} {unit} | "
        f"{_change(magnitude.parent_p99, magnitude.culprit_p99)} |",
        "",
        f"Strict verification: DIFFERENT, p = {magnitude.p_value:.2g}, {magnitude.parent_attempts} parent and "
        f"{magnitude.culprit_attempts} culprit attempts in ABBA order on {magnitude.host}, verify job {culprit.job_id}.",
        f"Issue: #{culprit.issue_number}" + (f", assigned to @{attribution.assignee}." if attribution.assignee else
                                             ", no assignee found: the sheriff assigns it."),
    ]
    origin = _origin(attribution)
    if origin:
        lines.append(origin)
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


def publish(attribution: Attribution, *, github: GitHub, repo: str, dry_run: bool = False,
            server: str = "https://github.com") -> Published:
    """One comment per culprit (edited when its text changed), then the issue's assignee. Safe to run again."""
    culprit = attribution.culprit
    target = attribution.pull.number if attribution.pull is not None else culprit.issue_number
    marker = MARKER.format(group=culprit.group_id, sha=culprit.sha)
    body = comment_body(attribution, repo=repo, server=server)
    if dry_run:
        return Published(target, "dry-run", None, attribution.assignee)
    existing = next((c for c in github.issue_comments(target) if c["body"].startswith(marker)), None)
    if existing is None:
        made = github.create_comment(target, body)
        outcome, url = "created", made.get("html_url")
    elif existing["body"] == body:
        outcome, url = "unchanged", existing.get("html_url")
    else:
        if existing.get("id") is None:
            raise AttributionError(f"#{target}: the marked comment {existing.get('html_url')} has no comment id")
        github.edit_comment(existing["id"], body)
        outcome, url = "updated", existing.get("html_url")
    if attribution.assignee is not None:
        github.add_assignee(culprit.issue_number, attribution.assignee)
    return Published(target, outcome, url, attribution.assignee)


# ---------------------------------------------------------------- CLI


def main(argv: Sequence[str] | None = None, *, github: GitHub | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--db", type=Path, required=True, help="the lab store (store.py)")
    parser.add_argument("--group", type=int, required=True, help="the alert group whose verified culprit to attribute")
    parser.add_argument("--repo", default=DEFAULT_REPO, help="OWNER/NAME")
    parser.add_argument("--branch", default=DEFAULT_BRANCH, help="the branch the lab bisected")
    parser.add_argument("--checkout", type=Path, default=Path.cwd(), help="a checkout that has the culprit sha")
    parser.add_argument("--owners-ref", default="HEAD", help=f"the ref whose {OWNERS_PATH} names the owners")
    parser.add_argument("--dry-run", action="store_true", help="read and print; write nothing on GitHub")
    args = parser.parse_args(argv)
    try:
        culprit = load_culprit(args.db, args.group)
        git, github = Git(args.checkout), github or GhCli(args.repo)
        attribution = attribute(culprit, git=git, github=github, branch=args.branch,
                                owners_text=git.show(args.owners_ref, OWNERS_PATH))
        published = publish(attribution, github=github, repo=args.repo, dry_run=args.dry_run)
    except (AttributionError, OSError, sqlite3.Error) as error:
        print(f"attribution: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"attribution": attribution.to_json(), "published": asdict(published)}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
