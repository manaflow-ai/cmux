#!/usr/bin/env python3
"""Stop manual CI dispatches superseded by an open pull-request run."""
from __future__ import annotations

import dataclasses
import json
import os
import sys
import urllib.parse
import urllib.request
from typing import Any, Mapping, Sequence


@dataclasses.dataclass(frozen=True)
class Decision:
    cancel: bool
    reason: str


def has_covering_ci_run(runs: Sequence[Mapping[str, Any]], sha: str) -> bool:
    """Whether a successful or active full-suite pull-request run covers this head."""
    return any(
        item.get("event") == "pull_request"
        and item.get("head_sha") == sha
        and item.get("full_suite") is True
        and (item.get("status") != "completed" or item.get("conclusion") == "success")
        for item in runs
    )


def decide(*, event: str, repository: str, ref_name: str, sha: str,
           pull_requests: Sequence[Mapping[str, Any]],
           normal_ci_runs: Sequence[Mapping[str, Any]] = ()) -> Decision:
    """Return the cancellation decision without network or environment access."""
    if event != "workflow_dispatch":
        return Decision(False, "not a manual dispatch")
    matching = [
        item for item in pull_requests
        if item.get("state", "open") == "open"
        and (item.get("head") or {}).get("repo", {}).get("full_name") == repository
        and (item.get("head") or {}).get("ref") == ref_name
    ]
    if not matching:
        return Decision(False, "no open pull request for this branch")
    if any((item.get("head") or {}).get("sha") == sha for item in matching):
        if has_covering_ci_run(normal_ci_runs, sha):
            return Decision(True, "pull request run covers this head")
        return Decision(False, "pull request head matches but its CI run is not present")
    return Decision(True, "branch moved past the pull request head")


class GitHub:
    def __init__(self, token: str, repository: str):
        self.repository = repository
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "cmux-manual-dispatch-guard",
        }

    def _request(self, path: str, method: str = "GET") -> Any:
        request = urllib.request.Request(
            "https://api.github.com" + path, headers=self.headers, method=method
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            if method == "POST":
                return None
            return json.load(response)

    def open_pull_requests(self, ref_name: str) -> list[Mapping[str, Any]]:
        owner = self.repository.split("/", 1)[0]
        query = urllib.parse.quote(f"{owner}:{ref_name}", safe="")
        return self._request(
            f"/repos/{self.repository}/pulls?state=open&head={query}&per_page=100"
        )

    def normal_ci_runs(self, sha: str) -> list[Mapping[str, Any]]:
        query = urllib.parse.urlencode(
            {"event": "pull_request", "head_sha": sha, "per_page": "100"}
        )
        body = self._request(
            f"/repos/{self.repository}/actions/workflows/ci.yml/runs?{query}"
        )
        runs = body.get("workflow_runs", []) if isinstance(body, Mapping) else []
        for run in runs:
            try:
                jobs = self._request(
                    f"/repos/{self.repository}/actions/runs/{run['id']}/jobs?per_page=100"
                )
                run["full_suite"] = any(
                    job.get("name") == "full-suite-coverage"
                    and job.get("conclusion") not in {"cancelled", "skipped"}
                    for job in jobs.get("jobs", [])
                ) if isinstance(jobs, Mapping) else False
            except (KeyError, OSError, ValueError, TypeError):
                run["full_suite"] = False
        return runs

    def cancel(self, run_id: str) -> None:
        self._request(f"/repos/{self.repository}/actions/runs/{run_id}/cancel", "POST")


def main(env: Mapping[str, str] | None = None, *, check_only: bool = False) -> int:
    env = os.environ if env is None else env
    expected_path = env.get("SOURCE_WORKFLOW_PATHS", ".github/workflows/ci.yml")
    if env.get("SOURCE_WORKFLOW_PATH", expected_path) != expected_path:
        print("manual dispatch guard: unexpected source workflow", file=sys.stderr)
        return 0
    event = env.get("SOURCE_EVENT_NAME", env.get("GITHUB_EVENT_NAME", ""))
    if event != "workflow_dispatch":
        return 0
    token = env.get("GH_TOKEN", "")
    repository = env.get("SOURCE_REPOSITORY", env.get("GITHUB_REPOSITORY", ""))
    if not token or not repository:
        print("::warning title=manual dispatch guard::missing GitHub token or repository", file=sys.stderr)
        return 0
    try:
        api = GitHub(token, repository)
        ref_name = env.get("SOURCE_REF_NAME", env.get("GITHUB_REF_NAME", ""))
        sha = env.get("SOURCE_SHA", env.get("GITHUB_SHA", ""))
        run_id = env.get("SOURCE_RUN_ID", env.get("GITHUB_RUN_ID", ""))
        pull_requests = api.open_pull_requests(ref_name)
        matching_sha = any(
            (item.get("head") or {}).get("sha") == sha
            and item.get("state", "open") == "open"
            and (item.get("head") or {}).get("repo", {}).get("full_name") == repository
            and (item.get("head") or {}).get("ref") == ref_name
        for item in pull_requests
        )
        normal_ci_runs = api.normal_ci_runs(sha) if matching_sha else []
        decision = decide(
            event=event,
            repository=repository,
            ref_name=ref_name,
            sha=sha,
            pull_requests=pull_requests,
            normal_ci_runs=normal_ci_runs,
        )
        print(f"manual dispatch: {decision.reason}", file=sys.stderr)
        if decision.cancel:
            if check_only:
                # Fail changes before any consumer can start expensive work.
                # The default-branch watcher cancels the run with its own token.
                return 1
            api.cancel(run_id)
    except Exception as error:  # noqa: BLE001 - fail open keeps CI available
        print(f"::warning title=manual dispatch guard::{error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(check_only="--check-only" in sys.argv[1:]))
