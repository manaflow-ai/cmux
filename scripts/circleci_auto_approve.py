#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any


GITHUB_API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
CIRCLECI_API = os.environ.get("CIRCLECI_API_URL", "https://circleci.com/api/v2")
WORKFLOW_RE = re.compile(r"/workflows/([0-9a-fA-F-]{36})(?:[/?#]|$)")


@dataclass(frozen=True)
class Config:
  repository: str
  pr_head_sha: str
  pr_author: str
  trusted_org: str
  trusted_users: set[str]
  github_token: str
  circleci_token: str
  hold_job_name: str
  max_attempts: int
  poll_seconds: float
  dry_run: bool


def split_csv(value: str) -> set[str]:
  return {item.strip() for item in value.split(",") if item.strip()}


def load_config() -> Config:
  return Config(
    repository=require_env("GITHUB_REPOSITORY"),
    pr_head_sha=require_env("PR_HEAD_SHA"),
    pr_author=require_env("PR_AUTHOR"),
    trusted_org=os.environ.get("TRUSTED_GITHUB_ORG", "manaflow-ai"),
    trusted_users=split_csv(os.environ.get("TRUSTED_GITHUB_USERS", "")),
    github_token=require_env("GITHUB_TOKEN"),
    circleci_token=os.environ.get("CIRCLECI_TOKEN", ""),
    hold_job_name=os.environ.get("CIRCLECI_HOLD_JOB_NAME", "hold-for-approval"),
    max_attempts=int(os.environ.get("CIRCLECI_APPROVAL_MAX_ATTEMPTS", "40")),
    poll_seconds=float(os.environ.get("CIRCLECI_APPROVAL_POLL_SECONDS", "15")),
    dry_run=os.environ.get("DRY_RUN", "").lower() in {"1", "true", "yes"},
  )


def require_env(name: str) -> str:
  value = os.environ.get(name, "")
  if not value:
    raise SystemExit(f"Missing required environment variable: {name}")
  return value


def request_json(url: str, *, token: str, token_header: str = "Authorization", method: str = "GET") -> Any:
  headers = {"Accept": "application/vnd.github+json"}
  if token_header == "Authorization":
    headers["Authorization"] = f"Bearer {token}"
  else:
    headers[token_header] = token

  request = urllib.request.Request(url, headers=headers, method=method)
  with urllib.request.urlopen(request, timeout=20) as response:
    data = response.read()
  if not data:
    return {}
  return json.loads(data.decode("utf-8"))


def is_org_member(config: Config) -> bool:
  if config.pr_author in config.trusted_users:
    print(f"{config.pr_author} is explicitly trusted")
    return True

  token = os.environ.get("GITHUB_ORG_READ_TOKEN") or config.github_token
  url = f"{GITHUB_API}/orgs/{config.trusted_org}/members/{config.pr_author}"
  try:
    request_json(url, token=token)
    print(f"{config.pr_author} is a member of {config.trusted_org}")
    return True
  except urllib.error.HTTPError as error:
    if error.code == 404:
      print(f"{config.pr_author} is not visible as a member of {config.trusted_org}")
      return False
    raise


def check_runs(config: Config) -> list[dict[str, Any]]:
  url = f"{GITHUB_API}/repos/{config.repository}/commits/{config.pr_head_sha}/check-runs?per_page=100"
  payload = request_json(url, token=config.github_token)
  return payload.get("check_runs", [])


def circleci_workflow_id_from_check(check: dict[str, Any]) -> str | None:
  details_url = str(check.get("details_url") or "")
  match = WORKFLOW_RE.search(details_url)
  if not match:
    return None
  return match.group(1)


def find_circleci_workflow(config: Config) -> str | None:
  expected_check_name = f"ci/circleci: {config.hold_job_name}"
  for check in check_runs(config):
    if check.get("name") != expected_check_name:
      continue
    workflow_id = circleci_workflow_id_from_check(check)
    if workflow_id:
      return workflow_id
  return None


def find_approval_request(config: Config, workflow_id: str) -> tuple[str, str] | None:
  url = f"{CIRCLECI_API}/workflow/{workflow_id}/job"
  payload = request_json(url, token=config.circleci_token, token_header="Circle-Token")
  for job in payload.get("items", []):
    if job.get("name") != config.hold_job_name:
      continue
    if job.get("type") != "approval":
      continue
    status = str(job.get("status") or "")
    if status == "success":
      print(f"CircleCI approval job {config.hold_job_name} is already approved")
      return None
    approval_request_id = job.get("approval_request_id") or job.get("id")
    if not approval_request_id:
      raise SystemExit(f"Approval job {config.hold_job_name} has no approval_request_id")
    return (str(approval_request_id), status)
  return None


def approve(config: Config, workflow_id: str, approval_request_id: str) -> None:
  url = f"{CIRCLECI_API}/workflow/{workflow_id}/approve/{approval_request_id}"
  if config.dry_run:
    print(f"DRY_RUN: would approve {config.hold_job_name} in workflow {workflow_id}")
    return
  request_json(url, token=config.circleci_token, token_header="Circle-Token", method="POST")
  print(f"Approved CircleCI job {config.hold_job_name} in workflow {workflow_id}")


def run() -> int:
  config = load_config()
  if not is_org_member(config):
    print("Not approving CircleCI for untrusted PR author")
    return 0
  if not config.circleci_token and not config.dry_run:
    raise SystemExit("Missing CIRCLECI_TOKEN for trusted PR author")

  for attempt in range(1, config.max_attempts + 1):
    workflow_id = find_circleci_workflow(config)
    if workflow_id:
      approval = find_approval_request(config, workflow_id)
      if approval:
        approval_request_id, status = approval
        print(f"Found CircleCI approval job with status {status}")
        approve(config, workflow_id, approval_request_id)
      return 0

    print(f"Waiting for CircleCI approval check ({attempt}/{config.max_attempts})")
    time.sleep(config.poll_seconds)

  raise SystemExit(f"Timed out waiting for ci/circleci: {config.hold_job_name}")


if __name__ == "__main__":
  sys.exit(run())
