#!/usr/bin/env python3
"""Evaluate CI checks for one pull request from a trusted workflow."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from collections.abc import Iterable, Mapping, Sequence
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import check_ci_status as contract  # noqa: E402
import detect_ci_change_areas as change_areas  # noqa: E402


CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
ACTIONS_APP_ID = 15368
APP_HOST_SHARDS = 6
MATRIX_PATTERN = re.compile(r"^app-host unit tests \((\d+)/(\d+)\)$")
CHECK_NAME_ALIASES = {"GhosttyKit release check": "ghosttykit-release-check"}
ADVISORY_CHECKS = {"ci-status", "ci-status-advisory", "ci-status-validator-canary"}
ROUTE_NAMES = contract.ROUTE_NAMES
PUBLISHED_CHECKS = ("ci-status-gate", "ci-status")
TRUSTED_REVIEWER_IDS = {
    38676809: "austinywang",
    67667005: "azooz2003-bit",
}
TRUSTED_REVIEWER_LOGINS = frozenset(TRUSTED_REVIEWER_IDS.values())
TRUSTED_REVIEWER_LOGIN_KEYS = frozenset(
    name.casefold() for name in TRUSTED_REVIEWER_LOGINS
)
REVIEW_STATES = frozenset(
    {"APPROVED", "CHANGES_REQUESTED", "DISMISSED", "COMMENTED", "PENDING"}
)
REVIEW_TIMESTAMP = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"
)
MAX_REVIEW_ID = 2**63 - 1
MAX_REVIEW_PAGES = 100


class GateError(RuntimeError):
    """Describe an input, API, or provenance error that must fail closed."""


class WorkflowDefinitionError(GateError):
    """The pull request changed CI policy without the required approval."""


def _is_sha(value: object) -> bool:
    return isinstance(value, str) and bool(re.fullmatch(r"[0-9a-f]{40}", value))


def _as_sha(value: object, label: str) -> str:
    if not _is_sha(value):
        raise GateError(f"{label} is not a full lowercase commit SHA")
    return str(value)


def parse_event(raw: str) -> Mapping[str, Any]:
    """Parse one GitHub event payload and reject non-object JSON."""

    try:
        event = json.loads(raw)
    except json.JSONDecodeError as error:
        raise GateError(f"event payload is not valid JSON: {error.msg}") from error
    if not isinstance(event, Mapping):
        raise GateError("event payload must be a JSON object")
    return event


def _page_rows(payload: object, key: str) -> list[Mapping[str, Any]]:
    """Flatten a regular or --slurp GitHub API response."""

    pages = payload if isinstance(payload, list) else [payload]
    rows: list[Mapping[str, Any]] = []
    for page in pages:
        if not isinstance(page, Mapping):
            raise GateError(f"GitHub API page for {key} is not an object")
        values = page.get(key)
        if not isinstance(values, list):
            raise GateError(f"GitHub API page is missing {key}")
        if any(not isinstance(value, Mapping) for value in values):
            raise GateError(f"GitHub API page for {key} contains a malformed row")
        rows.extend(values)
    return rows


def _array_rows(payload: object, label: str) -> list[Mapping[str, Any]]:
    """Flatten a regular or --slurp response whose pages are arrays."""

    if not isinstance(payload, list):
        raise GateError(f"GitHub API response for {label} is not an array")
    if not payload:
        return []
    pages: list[object]
    if all(isinstance(value, Mapping) for value in payload):
        pages = [payload]
    else:
        pages = payload
    if len(pages) > MAX_REVIEW_PAGES:
        raise GateError(f"GitHub API returned too many {label} pages")
    rows: list[Mapping[str, Any]] = []
    for page in pages:
        if not isinstance(page, list):
            raise GateError(f"GitHub API page for {label} is not an array")
        if len(page) > 100:
            raise GateError(f"GitHub API page for {label} is too large")
        if any(not isinstance(value, Mapping) for value in page):
            raise GateError(f"GitHub API page for {label} contains a malformed row")
        rows.extend(page)
    return rows


class GitHubAPI:
    """Small wrapper around the runner's authenticated gh client."""

    def __init__(self, repository: str, token: str | None = None) -> None:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise GateError("GITHUB_REPOSITORY is malformed")
        self.repository = repository
        self.token = token or os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")

    def get(self, endpoint: str, *, paginate: bool = False) -> object:
        """Fetch JSON without invoking a shell or exposing the token."""

        args = ["gh", "api", endpoint, "--header", "Accept: application/vnd.github+json"]
        if paginate:
            args.extend(["--paginate", "--slurp"])
        environment = os.environ.copy()
        if self.token:
            environment["GH_TOKEN"] = self.token
        try:
            result = subprocess.run(
                args,
                check=False,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GateError(f"GitHub API request failed: {error}") from error
        if result.returncode != 0:
            detail = result.stderr.strip().splitlines()[-1:] or ["unknown API error"]
            raise GateError(f"GitHub API request failed: {detail[0]}")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise GateError("GitHub API returned invalid JSON") from error

    def write(self, method: str, endpoint: str, payload: Mapping[str, Any]) -> object:
        """Send one narrow Checks API write using the trusted workflow token."""

        if method not in {"POST", "PATCH"}:
            raise GateError("unsupported GitHub API write method")
        args = [
            "gh",
            "api",
            endpoint,
            "--method",
            method,
            "--header",
            "Accept: application/vnd.github+json",
            "--input",
            "-",
        ]
        environment = os.environ.copy()
        if self.token:
            environment["GH_TOKEN"] = self.token
        try:
            result = subprocess.run(
                args,
                check=False,
                env=environment,
                input=json.dumps(payload, separators=(",", ":")),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GateError(f"GitHub API write failed: {error}") from error
        if result.returncode != 0:
            detail = result.stderr.strip().splitlines()[-1:] or ["unknown API error"]
            raise GateError(f"GitHub API write failed: {detail[0]}")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise GateError("GitHub API write returned invalid JSON") from error

    def publish_check(
        self,
        name: str,
        head_sha: str,
        conclusion: str,
        summary: str,
    ) -> None:
        """Create or update one Actions check run on the exact PR head."""

        if name not in PUBLISHED_CHECKS:
            raise GateError("unsupported published check name")
        head_sha = _as_sha(head_sha, "published check head SHA")
        if conclusion not in {"success", "failure"}:
            raise GateError("published check conclusion is malformed")
        if not isinstance(summary, str) or not summary:
            raise GateError("published check summary is malformed")
        payload = self.get(
            f"repos/{self.repository}/commits/{head_sha}/check-runs?check_name={name}&per_page=100",
            paginate=True,
        )
        rows = _page_rows(payload, "check_runs")
        candidates = [
            row
            for row in rows
            if row.get("name") == name
            and row.get("head_sha") == head_sha
            and isinstance(row.get("app"), Mapping)
            and row["app"].get("id") == ACTIONS_APP_ID
            and isinstance(row.get("id"), int)
            and not isinstance(row.get("id"), bool)
        ]
        latest = max(candidates, key=lambda row: row["id"]) if candidates else None
        endpoint = (
            f"repos/{self.repository}/check-runs/{latest['id']}"
            if latest is not None
            else f"repos/{self.repository}/check-runs"
        )
        method = "PATCH" if latest is not None else "POST"
        response = self.write(
            method,
            endpoint,
            {
                "name": name,
                "head_sha": head_sha,
                "status": "completed",
                "conclusion": conclusion,
                "external_id": f"cmux-{name}-{head_sha}",
                "output": {"title": name, "summary": summary},
            },
        )
        if not isinstance(response, Mapping):
            raise GateError("GitHub returned a malformed published check")
        if response.get("name") != name or response.get("head_sha") != head_sha:
            raise GateError("published check does not target the exact PR head")
        app = response.get("app")
        if not isinstance(app, Mapping) or app.get("id") != ACTIONS_APP_ID:
            raise GateError("published check was created by an unexpected app")


def _workflow_blob_sha(api: GitHubAPI, revision: str) -> str:
    """Return the immutable blob SHA for the CI workflow at one revision."""

    revision = _as_sha(revision, "workflow revision")
    payload = api.get(
        f"repos/{api.repository}/contents/{CI_WORKFLOW_PATH}?ref={revision}"
    )
    if not isinstance(payload, Mapping):
        raise GateError("GitHub returned a malformed CI workflow definition")
    if payload.get("type") != "file" or payload.get("path") != CI_WORKFLOW_PATH:
        raise GateError("GitHub returned a non-file CI workflow definition")
    return _as_sha(payload.get("sha"), "CI workflow blob SHA")


def _review_order(review: Mapping[str, Any]) -> tuple[dt.datetime, int]:
    """Build a deterministic order for one trusted review decision."""

    review_id = review.get("id")
    if not isinstance(review_id, int) or isinstance(review_id, bool):
        raise GateError("trusted review ID is malformed")
    if review_id <= 0 or review_id > MAX_REVIEW_ID:
        raise GateError("trusted review ID is malformed")
    submitted_at = review.get("submitted_at")
    if not isinstance(submitted_at, str) or not REVIEW_TIMESTAMP.fullmatch(submitted_at):
        raise GateError("trusted review timestamp is malformed")
    try:
        timestamp = dt.datetime.fromisoformat(submitted_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise GateError("trusted review timestamp is malformed") from error
    if timestamp.tzinfo is None:
        raise GateError("trusted review timestamp is malformed")
    return timestamp, review_id


def _trusted_reviewer_id(review: Mapping[str, Any]) -> int | None:
    """Identify a trusted human reviewer, rejecting ambiguous identities."""

    user = review.get("user")
    if not isinstance(user, Mapping):
        return None
    user_id = user.get("id")
    login = user.get("login")
    trusted_by_login = isinstance(login, str) and login.casefold() in TRUSTED_REVIEWER_LOGIN_KEYS
    if not isinstance(user_id, int) or isinstance(user_id, bool):
        if trusted_by_login:
            raise GateError("trusted reviewer identity is missing an account ID")
        return None
    expected_login = TRUSTED_REVIEWER_IDS.get(user_id)
    if expected_login is None:
        return None
    if not isinstance(login, str) or login.casefold() != expected_login.casefold():
        raise GateError("trusted reviewer identity does not match its account ID")
    if user.get("type") != "User":
        raise GateError("trusted reviewer is not a human account")
    return user_id


def _review_rows(payload: object) -> list[Mapping[str, Any]]:
    """Read review pages returned by ``gh api --paginate --slurp``."""

    return _array_rows(payload, "pull-request reviews")


def has_trusted_workflow_review(
    reviews: Iterable[Mapping[str, Any]],
    pull: Mapping[str, Any],
    head_sha: str,
) -> bool:
    """Return whether Austin or Aziz approved the exact workflow revision."""

    head_sha = _as_sha(head_sha, "head SHA")
    author = pull.get("user")
    author_id = author.get("id") if isinstance(author, Mapping) else None
    author_login = author.get("login") if isinstance(author, Mapping) else None
    latest: dict[int, tuple[tuple[dt.datetime, int], Mapping[str, Any]]] = {}
    seen_review_ids: set[int] = set()

    for review in reviews:
        if not isinstance(review, Mapping):
            raise GateError("pull-request review entry is malformed")
        raw_id = review.get("id")
        user = review.get("user")
        user_id = user.get("id") if isinstance(user, Mapping) else None
        login = user.get("login") if isinstance(user, Mapping) else None
        trusted_hint = (
            isinstance(user_id, int)
            and not isinstance(user_id, bool)
            and user_id in TRUSTED_REVIEWER_IDS
        ) or (
            isinstance(login, str)
            and login.casefold() in TRUSTED_REVIEWER_LOGIN_KEYS
        )
        if not isinstance(raw_id, int) or isinstance(raw_id, bool) or raw_id <= 0:
            if trusted_hint:
                raise GateError("trusted review ID is malformed")
            continue
        if raw_id > MAX_REVIEW_ID:
            raise GateError("pull-request review ID is malformed")
        if raw_id in seen_review_ids:
            raise GateError("pull-request review pagination repeated an entry")
        seen_review_ids.add(raw_id)

        reviewer_id = _trusted_reviewer_id(review)
        if reviewer_id is None:
            continue
        state = review.get("state")
        if not isinstance(state, str) or state not in REVIEW_STATES:
            raise GateError("trusted review state is malformed")
        if state in {"COMMENTED", "PENDING"}:
            continue
        order = _review_order(review)
        # A dismissed approval is not an approval, even if GitHub leaves the
        # original state in the response while dismissal metadata propagates.
        effective_state = "DISMISSED" if review.get("dismissed_at") is not None else state
        if effective_state == "APPROVED":
            commit_id = review.get("commit_id")
            _as_sha(commit_id, "trusted review commit SHA")
        previous = latest.get(reviewer_id)
        if previous is None or order > previous[0]:
            latest[reviewer_id] = (order, {**review, "state": effective_state})

    for _reviewer_id, (_order, review) in latest.items():
        if review.get("state") != "APPROVED":
            continue
        if review.get("commit_id") != head_sha:
            continue
        if review.get("dismissed_at") is not None:
            continue
        reviewed_user = review.get("user")
        reviewed_id = reviewed_user.get("id") if isinstance(reviewed_user, Mapping) else None
        reviewed_login = reviewed_user.get("login") if isinstance(reviewed_user, Mapping) else None
        if reviewed_id == author_id or (
            isinstance(reviewed_login, str)
            and isinstance(author_login, str)
            and reviewed_login.casefold() == author_login.casefold()
        ):
            continue
        return True
    return False


def verify_ci_workflow_revision(
    api: GitHubAPI,
    pull: Mapping[str, Any],
    head_sha: str,
) -> None:
    """Require trusted approval when the PR changes the CI workflow bytes."""

    base = pull.get("base")
    base_sha = _as_sha(
        base.get("sha") if isinstance(base, Mapping) else None,
        "pull request base SHA",
    )
    head_sha = _as_sha(head_sha, "pull request head SHA")
    base_blob = _workflow_blob_sha(api, base_sha)
    head_blob = _workflow_blob_sha(api, head_sha)
    if base_blob == head_blob:
        return

    number = pull.get("number")
    if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
        raise GateError("pull request number is malformed")
    reviews = _review_rows(
        api.get(
            f"repos/{api.repository}/pulls/{number}/reviews?per_page=100",
            paginate=True,
        )
    )
    if has_trusted_workflow_review(reviews, pull, head_sha):
        print(
            "CI workflow definition changed, exact-head trusted review verified.",
            file=sys.stderr,
        )
        return
    raise WorkflowDefinitionError(
        "CI workflow definition differs from the base revision; "
        "an exact-head approval from Austin or Aziz is required"
    )


def _single_pr_number(rows: object, source: str) -> int:
    """Return one well-formed PR number, rejecting missing or ambiguous rows."""

    if not isinstance(rows, list):
        raise GateError(f"{source} pull request association is malformed")
    if not rows:
        raise GateError(f"{source} is not associated with a pull request")
    if len(rows) > 1:
        raise GateError(f"{source} is associated with multiple pull requests")
    return _pr_number(rows[0], source)


def _pr_number(row: object, source: str) -> int:
    """Read one positive PR number from a validated association row."""

    if not isinstance(row, Mapping):
        raise GateError(f"{source} pull request association is malformed")
    number = row.get("number")
    if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
        raise GateError(f"{source} pull request number is malformed")
    return number


def _validate_commit_pull(
    row: Mapping[str, Any], repository: str, head_sha: str
) -> int:
    """Validate one commit-to-PR association before using its number."""

    if row.get("state") != "open":
        raise GateError("commit is not associated with an open pull request")
    base = row.get("base")
    if not isinstance(base, Mapping) or base.get("ref") != "main":
        raise GateError("commit pull request base is not main")
    base_repo = base.get("repo")
    if not isinstance(base_repo, Mapping) or base_repo.get("full_name") != repository:
        raise GateError("commit pull request targets a different repository")
    head = row.get("head")
    row_head = _as_sha(
        head.get("sha") if isinstance(head, Mapping) else None,
        "commit pull request head SHA",
    )
    if row_head != head_sha:
        raise GateError("commit pull request head does not match the workflow run")
    return _pr_number(row, "commit")


def _event_target(
    api: GitHubAPI, event_name: str, event: Mapping[str, Any]
) -> tuple[Mapping[str, Any], str, int, int | None]:
    """Resolve and validate the live pull request and optional CI run ID."""

    workflow_run_id: int | None = None
    if event_name in {"pull_request_target", "pull_request_review"}:
        pull = event.get("pull_request")
        number = event.get("number") if event_name == "pull_request_target" else None
        if number is None and isinstance(pull, Mapping):
            number = pull.get("number")
        if not isinstance(pull, Mapping) or not isinstance(number, int) or isinstance(number, bool):
            raise GateError(f"{event_name} payload is missing pull request data")
        event_head_data = pull.get("head")
        event_head = _as_sha(
            event_head_data.get("sha") if isinstance(event_head_data, Mapping) else None,
            "event head SHA",
        )
        pr_number = number
    elif event_name == "workflow_run":
        run_event = event.get("workflow_run")
        if not isinstance(run_event, Mapping):
            raise GateError("workflow_run payload is missing workflow data")
        raw_id = run_event.get("id")
        if not isinstance(raw_id, int) or isinstance(raw_id, bool):
            raise GateError("workflow_run payload is missing a numeric run ID")
        workflow_run_id = raw_id
        event_head = _as_sha(run_event.get("head_sha"), "workflow run head SHA")
        run = api.get(f"repos/{api.repository}/actions/runs/{raw_id}")
        if not isinstance(run, Mapping):
            raise GateError("workflow run API response is not an object")
        pull_requests = run.get("pull_requests")
        if not isinstance(pull_requests, list):
            raise GateError("workflow run API response is missing pull requests")
        if pull_requests:
            pr_number = _single_pr_number(pull_requests, "workflow run")
        else:
            pull_payload = api.get(
                f"repos/{api.repository}/commits/{event_head}/pulls?per_page=100",
                paginate=True,
            )
            commit_rows = _array_rows(pull_payload, "commit pull requests")
            if len(commit_rows) != 1:
                raise GateError(
                    "commit must resolve to exactly one pull request"
                )
            pr_number = _validate_commit_pull(
                commit_rows[0], api.repository, event_head
            )
    else:
        raise GateError(f"unsupported event {event_name or 'unknown'}")

    pull = api.get(f"repos/{api.repository}/pulls/{pr_number}")
    if not isinstance(pull, Mapping):
        raise GateError("pull request API response is not an object")
    if pull.get("state") != "open":
        raise GateError("pull request is not open")
    base = pull.get("base")
    head = pull.get("head")
    if not isinstance(base, Mapping) or not isinstance(head, Mapping):
        raise GateError("pull request is missing base or head data")
    if base.get("ref") != "main":
        raise GateError("pull request base is not main")
    base_repo = base.get("repo")
    if not isinstance(base_repo, Mapping) or base_repo.get("full_name") != api.repository:
        raise GateError("pull request targets a different repository")
    live_head = _as_sha(head.get("sha"), "live pull request head SHA")
    if live_head != event_head:
        raise GateError("pull request head changed after the event; wait for a new run")
    return pull, live_head, pr_number, workflow_run_id


def _select_ci_run(
    api: GitHubAPI,
    pull: Mapping[str, Any],
    head_sha: str,
    workflow_run_id: int | None,
) -> Mapping[str, Any]:
    """Select one completed CI workflow run for exactly this PR head."""

    if workflow_run_id is not None:
        candidate = api.get(f"repos/{api.repository}/actions/runs/{workflow_run_id}")
        candidates = [candidate] if isinstance(candidate, Mapping) else []
    else:
        payload = api.get(
            f"repos/{api.repository}/actions/runs?event=pull_request&head_sha={head_sha}&per_page=100"
        )
        candidates = []
        if isinstance(payload, Mapping) and isinstance(payload.get("workflow_runs"), list):
            candidates = [item for item in payload["workflow_runs"] if isinstance(item, Mapping)]

    valid: list[Mapping[str, Any]] = []
    pr_number = pull.get("number")
    for run in candidates:
        if run.get("path") != CI_WORKFLOW_PATH or run.get("event") != "pull_request":
            continue
        if run.get("head_sha") != head_sha:
            continue
        pull_requests = run.get("pull_requests")
        if isinstance(pull_requests, list):
            if pull_requests and not any(
                isinstance(item, Mapping) and item.get("number") == pr_number
                for item in pull_requests
            ):
                continue
        elif pull_requests is not None:
            raise GateError("CI workflow run pull request association is malformed")
        valid.append(run)
    if not valid:
        raise GateError("no CI workflow run exists for this exact pull request head")
    def run_key(run: Mapping[str, Any]) -> tuple[str, int]:
        raw_id = run.get("id")
        if not isinstance(raw_id, int) or isinstance(raw_id, bool):
            return (str(run.get("created_at", "")), 0)
        return (str(run.get("created_at", "")), raw_id)

    selected = max(valid, key=run_key)
    if not isinstance(selected.get("id"), int) or isinstance(selected.get("id"), bool):
        raise GateError("CI workflow run has no numeric ID")
    if selected.get("status") != "completed":
        raise GateError("CI workflow is still running; gate will rerun on completion")
    return selected


def _check_run_id(url: object) -> int | None:
    if not isinstance(url, str):
        return None
    match = re.search(r"/check-runs/(\d+)$", url)
    return int(match.group(1)) if match else None


def _run_check_ids(jobs: Sequence[Mapping[str, Any]], head_sha: str) -> set[int]:
    ids: set[int] = set()
    for job in jobs:
        if job.get("head_sha") != head_sha:
            raise GateError(f"CI job {job.get('name', '<unnamed>')} has a stale head SHA")
        check_id = _check_run_id(job.get("check_run_url"))
        if check_id is None:
            raise GateError(f"CI job {job.get('name', '<unnamed>')} has no check-run ID")
        ids.add(check_id)
    if not ids:
        raise GateError("CI workflow has no check runs")
    return ids


def _check_result(check: Mapping[str, Any]) -> str:
    status = check.get("status")
    if status != "completed":
        return status if isinstance(status, str) else "missing"
    conclusion = check.get("conclusion")
    return conclusion if isinstance(conclusion, str) else "missing"


def _job_id(display_name: object) -> str | None:
    if not isinstance(display_name, str):
        return None
    alias = CHECK_NAME_ALIASES.get(display_name)
    if alias:
        return alias
    if display_name in contract.PHASE_CONTRACTS["aggregate"][0] + contract.AGGREGATE_ROUTE_JOBS:
        return display_name
    return "app-host-unit-tests" if MATRIX_PATTERN.fullmatch(display_name) else None


def _matrix_status(matrix: Mapping[int, str]) -> str:
    expected = set(range(1, APP_HOST_SHARDS + 1))
    if set(matrix) != expected:
        return "missing"
    results = [matrix[index] for index in sorted(matrix)]
    if all(result == "success" for result in results):
        return "success"
    if all(result == "skipped" for result in results):
        return "skipped"
    if any(result not in {"success", "skipped"} for result in results):
        return next(result for result in results if result not in {"success", "skipped"})
    return "mixed"


def normalize_check_runs(
    check_runs: Iterable[Mapping[str, Any]],
    *,
    head_sha: str,
    expected_check_ids: set[int] | None = None,
) -> tuple[dict[str, str], list[str]]:
    """Map exact trusted Actions checks to the validator's job IDs."""

    _as_sha(head_sha, "head SHA")
    latest: dict[str, Mapping[str, Any]] = {}
    matrix: dict[int, Mapping[str, Any]] = {}
    unknown: list[str] = []
    for check in check_runs:
        if not isinstance(check, Mapping) or check.get("head_sha") != head_sha:
            continue
        app = check.get("app")
        if not isinstance(app, Mapping) or app.get("id") != ACTIONS_APP_ID:
            continue
        check_id = check.get("id")
        if not isinstance(check_id, int):
            continue
        if expected_check_ids is not None and check_id not in expected_check_ids:
            continue
        name = check.get("name")
        if not isinstance(name, str):
            continue
        match = MATRIX_PATTERN.fullmatch(name)
        if match:
            shard, denominator = (int(match.group(1)), int(match.group(2)))
            if denominator != APP_HOST_SHARDS:
                unknown.append(name)
                continue
            current = matrix.get(shard)
            current_id = current.get("id") if current is not None else None
            if current is None or not isinstance(current_id, int) or check_id > current_id:
                matrix[shard] = check
            continue
        job_id = _job_id(name)
        if job_id is None:
            if name not in ADVISORY_CHECKS:
                unknown.append(name)
            continue
        current = latest.get(job_id)
        current_id = current.get("id") if current is not None else None
        if current is None or not isinstance(current_id, int) or check_id > current_id:
            latest[job_id] = check

    statuses = {
        job: _check_result(latest[job]) if job in latest else "missing"
        for job in contract.PHASE_CONTRACTS["aggregate"][0] + contract.AGGREGATE_ROUTE_JOBS
    }
    statuses["app-host-unit-tests"] = _matrix_status(
        {index: _check_result(check) for index, check in matrix.items()}
    )
    return statuses, sorted(set(unknown))


def build_needs(
    check_runs: Iterable[Mapping[str, Any]],
    changed_files: Iterable[str],
    *,
    head_sha: str,
    expected_check_ids: set[int] | None = None,
) -> tuple[dict[str, dict[str, Any]], list[str]]:
    """Build the validator input using routes derived from live PR files."""

    statuses, unknown = normalize_check_runs(
        check_runs,
        head_sha=head_sha,
        expected_check_ids=expected_check_ids,
    )
    areas = change_areas.classify_files(changed_files)
    outputs = {
        "macos": "true" if areas.macos else "false",
        "web": "true" if areas.web else "false",
        "go": "true" if areas.go else "false",
        "agent_session_web": "true" if areas.agent_session_web else "false",
    }
    needs: dict[str, dict[str, Any]] = {
        job: {"result": result} for job, result in statuses.items()
    }
    needs["changes"] = {"result": statuses["changes"], "outputs": outputs}
    return needs, unknown


def validate_snapshot(
    check_runs: Iterable[Mapping[str, Any]],
    changed_files: Iterable[str],
    *,
    head_sha: str,
    expected_check_ids: set[int] | None = None,
) -> list[str]:
    """Return all fail-closed violations for one exact PR snapshot."""

    needs, unknown = build_needs(
        check_runs,
        changed_files,
        head_sha=head_sha,
        expected_check_ids=expected_check_ids,
    )
    failures = [f"{name}: unexpected CI job" for name in unknown]
    failures.extend(contract.validate_needs(needs, phase="aggregate"))
    return failures


def _pr_files(api: GitHubAPI, number: int, expected_count: object) -> list[str]:
    if (
        not isinstance(expected_count, int)
        or isinstance(expected_count, bool)
        or expected_count < 0
    ):
        raise GateError("pull request file count is malformed")
    payload = api.get(
        f"repos/{api.repository}/pulls/{number}/files?per_page=100", paginate=True
    )
    rows = _array_rows(payload, "pull-request files")
    files: list[str] = []
    for row in rows:
        filename = row.get("filename")
        if not isinstance(filename, str) or not filename:
            raise GateError("GitHub returned a pull request file without a filename")
        files.append(filename)
    if len(files) != expected_count:
        raise GateError("GitHub returned an incomplete pull request file list")
    return files


def _publish_gate_checks(
    api: GitHubAPI,
    head_sha: str,
    conclusion: str,
    summary: str,
) -> None:
    """Publish both the new and legacy contexts for one exact head."""

    for name in PUBLISHED_CHECKS:
        api.publish_check(name, head_sha, conclusion, summary)


def _run_gate(
    api: GitHubAPI,
    event_name: str,
    event: Mapping[str, Any],
    *,
    publish: bool = False,
) -> int:
    """Evaluate one event and optionally publish head-targeted check runs."""

    pull, head_sha, number, workflow_run_id = _event_target(api, event_name, event)
    print(f"CI status gate for PR #{number}, head {head_sha}")
    result = 1
    try:
        verify_ci_workflow_revision(api, pull, head_sha)
        ci_run = _select_ci_run(api, pull, head_sha, workflow_run_id)
        jobs_payload = api.get(
            f"repos/{api.repository}/actions/runs/{ci_run['id']}/jobs?per_page=100",
            paginate=True,
        )
        jobs = _page_rows(jobs_payload, "jobs")
        run_check_ids = _run_check_ids(jobs, head_sha)
        checks_payload = api.get(
            f"repos/{api.repository}/commits/{head_sha}/check-runs?per_page=100",
            paginate=True,
        )
        checks = _page_rows(checks_payload, "check_runs")
        files = _pr_files(api, number, pull.get("changed_files"))
        failures = validate_snapshot(
            checks,
            files,
            head_sha=head_sha,
            expected_check_ids=run_check_ids,
        )
    except WorkflowDefinitionError as error:
        failures = [str(error)]
    except GateError as error:
        failures = [f"gate input error: {error}"]

    if failures:
        print("CI status gate failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        summary = "CI status validation failed. See the base-owned gate log for details."
    else:
        result = 0
        print("CI status gate passed.")
        summary = "CI checks passed for the exact pull request head."

    if publish:
        try:
            _publish_gate_checks(
                api,
                head_sha,
                "success" if result == 0 else "failure",
                summary,
            )
        except GateError as error:
            print(f"CI status check publication failed: {error}", file=sys.stderr)
            return 2
    return result


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--event-file",
        type=Path,
        default=Path(os.environ.get("GITHUB_EVENT_PATH", "")) if os.environ.get("GITHUB_EVENT_PATH") else None,
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.event_file is None:
        print("CI status gate input error: GITHUB_EVENT_PATH is missing", file=sys.stderr)
        return 2
    try:
        event = parse_event(args.event_file.read_text(encoding="utf-8"))
        repository = os.environ.get("GITHUB_REPOSITORY", "")
        api = GitHubAPI(repository)
        return _run_gate(
            api,
            os.environ.get("GITHUB_EVENT_NAME", ""),
            event,
            publish=True,
        )
    except (GateError, OSError) as error:
        print(f"CI status gate input error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
