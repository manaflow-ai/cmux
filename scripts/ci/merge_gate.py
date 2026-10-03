#!/usr/bin/env python3
"""Evaluate and publish the merge-gate check for a pull request.

The decision function is deliberately pure. ``evaluate_gate`` accepts the JSON
already returned by GitHub and never opens a repository or executes pull request
content.  The small API client below only reads GitHub metadata and writes the
check run and one diagnostic comment.
"""
from __future__ import annotations

import dataclasses
import datetime as _dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Mapping, Sequence
from typing import Any

API = "https://api.github.com"
MARKER = "merge-override:"
BOT_MARKER = "<!-- merge-gate -->"
_SUCCESS = {"success"}
_WRITE_PERMISSIONS = {"admin", "maintain", "write", "push"}
_RUN_LINK = re.compile(r"https?://github\.com/[^/\s]+/[^/\s]+/actions/runs/(\d+)")
_NOT_ON_MAIN = re.compile(r"\bnot\s+on\s+main\b", re.I)
_BOILERPLATE = {
    "lgtm", "looks good", "safe to merge", "merge override", "approved",
    "tests pass", "ship it", "fine", "ok", "okay", "good to go",
}


@dataclasses.dataclass(frozen=True)
class Decision:
    passed: bool
    reason: str
    failing_checks: tuple[str, ...] = ()
    override_comment: Mapping[str, Any] | None = None

    @property
    def conclusion(self) -> str:
        return "success" if self.passed else "failure"


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _time(value: Any) -> _dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return _dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _latest_time(comment: Mapping[str, Any]) -> _dt.datetime | None:
    values = [_time(comment.get("created_at")), _time(comment.get("updated_at"))]
    values = [item for item in values if item is not None]
    return max(values) if values else None


def _normalise(value: str) -> str:
    return " ".join(value.lower().split())


def _required_checks(data: Mapping[str, Any]) -> tuple[str, ...]:
    value = data.get("required_checks")
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes)):
        rules = data.get("rules") or data.get("required_rules")
        found: list[str] = []
        if isinstance(rules, Sequence) and not isinstance(rules, (str, bytes)):
            for rule in rules:
                if not isinstance(rule, Mapping) or rule.get("type") != "required_status_checks":
                    continue
                params = rule.get("parameters")
                checks = params.get("required_status_checks") if isinstance(params, Mapping) else None
                if isinstance(checks, Sequence) and not isinstance(checks, (str, bytes)):
                    for item in checks:
                        if isinstance(item, Mapping) and isinstance(item.get("context"), str):
                            found.append(item["context"])
        value = found
    names_list = [str(item) for item in value if isinstance(item, str) and item]
    # ci-status is the aggregate this gate protects, even while the ruleset is
    # being rolled out and the API response has not caught up.
    if "ci-status" not in names_list:
        names_list.append("ci-status")
    return tuple(dict.fromkeys(names_list))


def _check_state(name: str, runs: Sequence[Any], statuses: Sequence[Any], head_sha: str) -> str | None:
    candidates: list[tuple[str, str]] = []
    for item in runs:
        if not isinstance(item, Mapping) or item.get("name") != name:
            continue
        item_sha = item.get("head_sha") or item.get("sha")
        if item_sha and head_sha and item_sha != head_sha:
            continue
        conclusion = item.get("conclusion")
        if isinstance(conclusion, str):
            when = item.get("completed_at") or item.get("started_at") or item.get("updated_at") or ""
            candidates.append((str(when), conclusion.lower()))
    for item in statuses:
        if not isinstance(item, Mapping) or item.get("context") != name:
            continue
        state = item.get("state")
        if isinstance(state, str):
            when = item.get("updated_at") or ""
            candidates.append((str(when), state.lower()))
    return max(candidates, key=lambda pair: pair[0])[1] if candidates else None


def _author_can_override(comment: Mapping[str, Any], trusted: set[str]) -> bool:
    user = comment.get("user") or comment.get("author") or {}
    login = user.get("login") if isinstance(user, Mapping) else None
    if isinstance(login, str) and login in trusted:
        return True
    if isinstance(login, str) and login.endswith("[bot]"):
        return False
    permission = comment.get("author_permission") or comment.get("permission")
    if isinstance(permission, str):
        # The collaborator permission endpoint is authoritative. Do not fall
        # back to author_association when it explicitly says read/none.
        return permission.lower() in _WRITE_PERMISSIONS
    permissions = user.get("permissions") if isinstance(user, Mapping) else None
    if isinstance(permissions, Mapping) and "push" in permissions:
        return permissions.get("push") is True
    association = comment.get("author_association")
    return isinstance(association, str) and association.upper() in {"OWNER", "MEMBER", "COLLABORATOR"}


def _rationale(body: str) -> str:
    parts = body.split(MARKER, 1)
    return parts[1].strip() if len(parts) == 2 else ""


def _has_real_sentence(rationale: str) -> bool:
    words = re.findall(r"[A-Za-z0-9][A-Za-z0-9'_-]*", rationale)
    if len(words) < 8 or not re.search(r"[.!?]", rationale):
        return False
    normal = _normalise(rationale).rstrip(".!?")
    return normal not in _BOILERPLATE and not any(normal == phrase for phrase in _BOILERPLATE)


def _main_failure(run: Mapping[str, Any], check: str, repository: str) -> bool:
    if run.get("head_branch") != "main" and run.get("ref") != "refs/heads/main":
        return False
    repo = run.get("head_repository")
    if isinstance(repo, Mapping) and repo.get("full_name") not in (None, repository):
        return False
    entries: list[Any] = []
    for key in ("check_runs", "jobs", "checks"):
        value = run.get(key)
        if isinstance(value, Sequence) and not isinstance(value, (str, bytes)):
            entries.extend(value)
    for item in entries:
        if not isinstance(item, Mapping):
            continue
        name = item.get("name") or item.get("context")
        conclusion = item.get("conclusion") or item.get("state")
        if name == check and isinstance(conclusion, str) and conclusion.lower() == "failure":
            return True
    return False


def _linked_main_failure(rationale: str, check: str, main_runs: Sequence[Any], repository: str) -> bool:
    for raw_id in _RUN_LINK.findall(rationale):
        for run in main_runs:
            if not isinstance(run, Mapping) or str(run.get("id")) != raw_id:
                continue
            if _main_failure(run, check, repository):
                return True
    return False


def evaluate_gate(data: Mapping[str, Any]) -> Decision:
    """Return the merge-gate decision from GitHub JSON fixtures only."""
    head_sha = _text(data.get("head_sha"))
    runs = data.get("check_runs") or data.get("checks") or []
    statuses = data.get("statuses") or []
    if not isinstance(runs, Sequence) or isinstance(runs, (str, bytes)):
        runs = []
    if not isinstance(statuses, Sequence) or isinstance(statuses, (str, bytes)):
        statuses = []
    if _check_state("ci-status", runs, statuses, head_sha) == "success":
        return Decision(True, "ci-status passed on the current pull-request head")

    required = _required_checks(data)
    failing = tuple(name for name in required if _check_state(name, runs, statuses, head_sha) != "success")
    if not failing:
        failing = ("ci-status",)

    push_time = _time(data.get("head_pushed_at") or data.get("head_commit_timestamp"))
    comments = data.get("comments") or []
    if not isinstance(comments, Sequence) or isinstance(comments, (str, bytes)):
        comments = []
    trusted = {str(item) for item in (data.get("trusted_logins") or []) if isinstance(item, str)}
    main_runs = data.get("main_runs") or []
    if not isinstance(main_runs, Sequence) or isinstance(main_runs, (str, bytes)):
        main_runs = []
    prior_rationales: set[str] = set()
    candidates: list[Mapping[str, Any]] = []
    for comment in comments:
        if not isinstance(comment, Mapping):
            continue
        body = _text(comment.get("body"))
        if MARKER not in body:
            continue
        rationale = _rationale(body)
        normal = _normalise(rationale)
        comment_time = _latest_time(comment)
        if normal:
            prior_rationales.add(normal)
        if push_time and (comment_time is None or comment_time <= push_time):
            continue
        if not _author_can_override(comment, trusted) or not _has_real_sentence(rationale):
            continue
        if not all(
            (re.search(rf"(?im)(?<![A-Za-z0-9_-]){re.escape(check)}(?![A-Za-z0-9_-])", rationale) is not None)
            and (_NOT_ON_MAIN.search(rationale) or _linked_main_failure(rationale, check, main_runs, _text(data.get("repository"))))
            for check in failing
        ):
            continue
        candidates.append(comment)
    if candidates:
        candidates.sort(key=lambda item: _latest_time(item) or _dt.datetime.min.replace(tzinfo=_dt.timezone.utc), reverse=True)
        for comment in candidates:
            rationale = _normalise(_rationale(_text(comment.get("body"))))
            # A duplicate rationale is never a fresh justification, even when
            # the old copy was posted on an earlier head.
            occurrences = sum(1 for item in comments if isinstance(item, Mapping) and _normalise(_rationale(_text(item.get("body")))) == rationale)
            if occurrences == 1:
                return Decision(True, "merge override accepted", failing, comment)

    missing = ", ".join(failing)
    return Decision(
        False,
        f"merge-gate: ci-status is not successful on {head_sha or 'the current head'}. "
        f"A fresh merge-override: comment from a write-access collaborator is required for: {missing}. "
        "For every check, name it and link a main run that fails the same check or write 'not on main', then add a real sentence explaining why it is safe.",
        failing,
    )


class GitHub:
    def __init__(self, repository: str, token: str):
        self.repository = repository
        self.token = token
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-merge-gate",
        }

    def request(self, path: str, method: str = "GET", body: Mapping[str, Any] | None = None) -> Any:
        payload = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(API + path, headers=self.headers, method=method, data=payload)
        if body is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return json.loads(raw.decode()) if raw else None
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            raise RuntimeError(f"GitHub API {method} {path} failed: {error}") from error

    def paged(self, path: str) -> list[Mapping[str, Any]]:
        result: list[Mapping[str, Any]] = []
        page = 1
        while page <= 10:
            separator = "&" if "?" in path else "?"
            payload = self.request(f"{path}{separator}per_page=100&page={page}")
            if not isinstance(payload, list):
                break
            result.extend(item for item in payload if isinstance(item, Mapping))
            if len(payload) < 100:
                break
            page += 1
        return result


def _run_id_links(comments: Sequence[Any]) -> set[str]:
    return {run_id for c in comments if isinstance(c, Mapping) for run_id in _RUN_LINK.findall(_text(c.get("body")))}


def run() -> int:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    event = json.load(open(event_path, encoding="utf-8")) if event_path else {}
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not repo or not token:
        print("merge-gate: missing repository or token", file=sys.stderr)
        return 1
    pr_number = None
    if isinstance(event.get("pull_request"), Mapping):
        pr_number = event["pull_request"].get("number")
    if event.get("issue", {}).get("pull_request"):
        pr_number = event.get("issue", {}).get("number")
    source = event.get("workflow_run") or event.get("check_suite") or {}
    pulls = source.get("pull_requests") if isinstance(source, Mapping) else None
    if not pr_number and isinstance(pulls, Sequence) and pulls:
        pr_number = pulls[0].get("number") if isinstance(pulls[0], Mapping) else None
    # Some check_suite and workflow_run payloads omit pull_requests. Resolve
    # the immutable head through GitHub instead of silently skipping CI events.
    source_sha = source.get("head_sha") if isinstance(source, Mapping) else None
    if not pr_number and isinstance(source_sha, str):
        try:
            source_pulls = GitHub(repo, token).request(
                f"/repos/{repo}/commits/{urllib.parse.quote(source_sha, safe='')}/pulls"
            )
            if isinstance(source_pulls, Sequence) and source_pulls:
                first = source_pulls[0]
                pr_number = first.get("number") if isinstance(first, Mapping) else None
        except RuntimeError:
            pass
    if not pr_number:
        print("merge-gate: event has no pull request", file=sys.stderr)
        return 0
    gh = GitHub(repo, token)
    pr = gh.request(f"/repos/{repo}/pulls/{int(pr_number)}")
    head = pr.get("head") if isinstance(pr, Mapping) else {}
    sha = head.get("sha") if isinstance(head, Mapping) else None
    if not isinstance(sha, str):
        print("merge-gate: pull request has no head SHA", file=sys.stderr)
        return 1
    commit = gh.request(f"/repos/{repo}/commits/{sha}")
    commit_info = commit.get("commit") if isinstance(commit, Mapping) else {}
    author_info = commit_info.get("committer") if isinstance(commit_info, Mapping) else {}
    pushed = author_info.get("date") if isinstance(author_info, Mapping) else None
    # A commit timestamp is only a fallback. The synchronize event is the
    # server's record of when this exact head was pushed to the pull request.
    try:
        events = gh.paged(f"/repos/{repo}/issues/{int(pr_number)}/events")
        sync_times = [
            event.get("created_at")
            for event in events
            if isinstance(event, Mapping)
            and event.get("event") == "synchronize"
            and event.get("commit_id") == sha
            and isinstance(event.get("created_at"), str)
        ]
        if sync_times:
            pushed = max(sync_times)
    except RuntimeError:
        pass
    check_payload = gh.request(f"/repos/{repo}/commits/{sha}/check-runs?per_page=100")
    status_payload = gh.request(f"/repos/{repo}/commits/{sha}/status?per_page=100")
    rules = gh.request(f"/repos/{repo}/rules/branches/main")
    required = _required_checks({"rules": rules})
    comments = gh.paged(f"/repos/{repo}/issues/{int(pr_number)}/comments")
    # Resolve collaborator permissions as data. A failed lookup simply leaves
    # that author ineligible for an override; it cannot weaken the gate.
    for comment in comments:
        user = comment.get("user") or {}
        login = user.get("login") if isinstance(user, Mapping) else None
        if isinstance(login, str):
            try:
                permission = gh.request(f"/repos/{repo}/collaborators/{urllib.parse.quote(login, safe='')}/permission")
                if isinstance(permission, Mapping):
                    comment["author_permission"] = permission.get("permission")
                else:
                    comment["author_permission"] = "unknown"
            except RuntimeError:
                # Do not fall back to author_association after an API error:
                # the gate must prove write access before accepting an override.
                comment["author_permission"] = "unknown"
    main_runs: list[Mapping[str, Any]] = []
    for run_id in _run_id_links(comments):
        try:
            item = gh.request(f"/repos/{repo}/actions/runs/{run_id}")
            jobs = gh.request(f"/repos/{repo}/actions/runs/{run_id}/jobs?per_page=100")
            checks = None
            run_sha = item.get("head_sha") if isinstance(item, Mapping) else None
            if isinstance(run_sha, str) and run_sha:
                checks = gh.request(f"/repos/{repo}/commits/{run_sha}/check-runs?per_page=100")
            if isinstance(item, Mapping):
                item = dict(item)
                item["jobs"] = jobs.get("jobs", []) if isinstance(jobs, Mapping) else []
                item["check_runs"] = checks.get("check_runs", []) if isinstance(checks, Mapping) else []
                main_runs.append(item)
        except RuntimeError:
            continue
    decision = evaluate_gate({
        "repository": repo, "head_sha": sha, "head_pushed_at": pushed,
        "required_checks": required, "check_runs": check_payload.get("check_runs", []) if isinstance(check_payload, Mapping) else [],
        "statuses": status_payload.get("statuses", []) if isinstance(status_payload, Mapping) else [],
        "comments": comments, "main_runs": main_runs,
        "trusted_logins": [item for item in os.environ.get("MERGE_GATE_TRUSTED_LOGINS", "").split(",") if item],
    })
    summary = decision.reason
    gh.request(f"/repos/{repo}/check-runs", "POST", {
        "name": "merge-gate", "head_sha": sha, "status": "completed",
        "conclusion": decision.conclusion,
        "output": {"title": "Merge gate", "summary": summary},
    })
    if not decision.passed:
        body = f"{BOT_MARKER}\n{decision.reason}"
        ours = [c for c in comments if BOT_MARKER in _text(c.get("body")) and c.get("id")]
        if ours:
            gh.request(f"/repos/{repo}/issues/comments/{ours[0]['id']}", "PATCH", {"body": body})
        else:
            gh.request(f"/repos/{repo}/issues/{int(pr_number)}/comments", "POST", {"body": body})
    print(("PASS" if decision.passed else "FAIL") + f": {decision.reason}")
    return 0 if decision.passed else 1


if __name__ == "__main__":
    raise SystemExit(run())
