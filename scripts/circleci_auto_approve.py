#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


GITHUB_API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
CIRCLECI_API = os.environ.get("CIRCLECI_API_URL", "https://circleci.com/api/v2")
UUID_RE = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
WORKFLOW_RE = re.compile(rf"/workflows/({UUID_RE})(?:[/?#]|$)")


@dataclass(frozen=True)
class Config:
  repository: str
  pr_head_repository: str
  pr_head_owner: str
  pr_head_owner_id: int
  pr_head_sha: str
  pr_author: str
  pr_author_id: int
  trusted_org: str
  trusted_users: dict[str, int]
  github_token: str
  circleci_token: str
  hold_job_name: str
  max_attempts: int
  poll_seconds: float
  dry_run: bool


def parse_trusted_users(value: str) -> dict[str, int]:
  trusted: dict[str, int] = {}
  for item in value.split(","):
    if not item.strip():
      continue
    try:
      login, user_id = item.strip().split(":", 1)
      trusted[login] = int(user_id)
    except ValueError as error:
      raise SystemExit(f"Invalid TRUSTED_GITHUB_USERS entry: {item!r}") from error
  return trusted


def load_config() -> Config:
  return Config(
    repository=require_env("GITHUB_REPOSITORY"),
    pr_head_repository=os.environ.get("PR_HEAD_REPOSITORY", require_env("GITHUB_REPOSITORY")),
    pr_head_owner=os.environ.get("PR_HEAD_OWNER", ""),
    pr_head_owner_id=int(os.environ.get("PR_HEAD_OWNER_ID", "0") or "0"),
    pr_head_sha=require_env("PR_HEAD_SHA"),
    pr_author=require_env("PR_AUTHOR"),
    pr_author_id=int(require_env("PR_AUTHOR_ID")),
    trusted_org=os.environ.get("TRUSTED_GITHUB_ORG", "manaflow-ai"),
    trusted_users=parse_trusted_users(os.environ.get("TRUSTED_GITHUB_USERS", "")),
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


def is_trusted_pr_source(config: Config) -> bool:
  validate_trusted_users(config)

  if not is_trusted_subject(config, config.pr_author, config.pr_author_id, "PR author"):
    return False

  if not config.pr_head_owner or config.pr_head_owner_id <= 0:
    print("PR head repository owner is unavailable; treating as untrusted")
    return False

  if config.pr_head_owner == config.pr_author and config.pr_head_owner_id == config.pr_author_id:
    return True

  return is_trusted_subject(
    config,
    config.pr_head_owner,
    config.pr_head_owner_id,
    "PR head repository owner",
  )


def is_trusted_subject(config: Config, login: str, user_id: int, label: str) -> bool:
  if config.trusted_users.get(login) == user_id:
    print(f"{label} {login} ({user_id}) is explicitly trusted")
    return True

  token = os.environ.get("GITHUB_ORG_READ_TOKEN", "")
  if not token:
    print(f"GITHUB_ORG_READ_TOKEN is not configured; cannot verify membership in {config.trusted_org}")
    return False
  url = f"{GITHUB_API}/orgs/{config.trusted_org}/members/{login}"
  try:
    request_json(url, token=token)
    print(f"{label} {login} is a member of {config.trusted_org}")
    return True
  except urllib.error.HTTPError as error:
    if error.code == 404:
      print(f"{label} {login} is not visible as a member of {config.trusted_org}")
      return False
    reason = getattr(error, "reason", None) or getattr(error, "msg", "")
    print(
      f"Org membership check for {label} {login} in {config.trusted_org} "
      f"failed with HTTP {error.code} {reason}; treating as untrusted"
    )
    return False
  except urllib.error.URLError as error:
    print(
      f"Org membership check for {label} {login} in {config.trusted_org} "
      f"failed with {error}; treating as untrusted"
    )
    return False


def validate_trusted_users(config: Config) -> None:
  for login, expected_id in config.trusted_users.items():
    url = f"{GITHUB_API}/users/{login}"
    try:
      payload = request_json(url, token=config.github_token)
    except urllib.error.HTTPError as error:
      raise SystemExit(f"Trusted GitHub user {login!r} could not be resolved") from error
    actual_id = payload.get("id")
    if actual_id != expected_id:
      raise SystemExit(f"Trusted GitHub user {login!r} resolved to {actual_id}, expected {expected_id}")


def check_runs(config: Config) -> list[dict[str, Any]]:
  checks: list[dict[str, Any]] = []
  page = 1
  while True:
    url = (
      f"{GITHUB_API}/repos/{config.repository}/commits/{config.pr_head_sha}/check-runs"
      f"?per_page=100&page={page}"
    )
    payload = request_json(url, token=config.github_token)
    items = payload.get("check_runs", [])
    checks.extend(items)
    if len(items) < 100:
      return checks
    page += 1


def circleci_workflow_id_from_check(check: dict[str, Any]) -> str | None:
  details_url = str(check.get("details_url") or "")
  match = WORKFLOW_RE.search(details_url)
  if not match:
    return None
  return match.group(1)


def find_circleci_workflow(config: Config) -> str | None:
  for check in check_runs(config):
    if not is_hold_check_name(str(check.get("name") or ""), config.hold_job_name):
      continue
    workflow_id = circleci_workflow_id_from_check(check)
    if workflow_id:
      return workflow_id
  return None


def is_hold_check_name(check_name: str, hold_job_name: str) -> bool:
  prefix = "ci/circleci: "
  if not check_name.startswith(prefix):
    return False
  circleci_name = check_name[len(prefix):]
  return circleci_name == hold_job_name or circleci_name.endswith(f"/{hold_job_name}")


def find_approval_request(config: Config, workflow_id: str) -> tuple[str | None, str] | None:
  page_token = ""
  while True:
    url = f"{CIRCLECI_API}/workflow/{workflow_id}/job"
    if page_token:
      url += f"?page-token={urllib.parse.quote(page_token)}"
    payload = request_json(url, token=config.circleci_token, token_header="Circle-Token")
    for job in payload.get("items", []):
      if job.get("name") != config.hold_job_name:
        continue
      if job.get("type") != "approval":
        continue
      status = str(job.get("status") or "")
      if status == "success":
        print(f"CircleCI approval job {config.hold_job_name} is already approved")
        return (None, status)
      approval_request_id = job.get("approval_request_id") or job.get("id")
      if not approval_request_id:
        raise SystemExit(f"Approval job {config.hold_job_name} has no approval_request_id")
      return (str(approval_request_id), status)
    page_token = str(payload.get("next_page_token") or "")
    if not page_token:
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
  if config.pr_head_repository == config.repository:
    print("Same-repository PR does not need CircleCI hold approval")
    return 0
  if not is_trusted_pr_source(config):
    print("Not approving CircleCI for untrusted PR source")
    return 0
  if not config.circleci_token and not config.dry_run:
    raise SystemExit("Missing CIRCLECI_TOKEN for trusted PR author")

  for attempt in range(1, config.max_attempts + 1):
    workflow_id = find_circleci_workflow(config)
    if workflow_id:
      approval = find_approval_request(config, workflow_id)
      if approval:
        approval_request_id, status = approval
        if approval_request_id:
          print(f"Found CircleCI approval job with status {status}")
          approve(config, workflow_id, approval_request_id)
        return 0
      print(f"CircleCI workflow {workflow_id} found, waiting for approval job")
    else:
      print(f"Waiting for CircleCI approval check ({attempt}/{config.max_attempts})")
    if attempt < config.max_attempts:
      time.sleep(config.poll_seconds)
      continue

  raise SystemExit(f"Timed out waiting for ci/circleci: */{config.hold_job_name}")


if __name__ == "__main__":
  sys.exit(run())
