#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import sys
import urllib.error
from contextlib import contextmanager
from typing import Any
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "circleci_auto_approve.py"
WORKFLOW_ID = "11111111-1111-1111-1111-111111111111"
APPROVAL_ID = "22222222-2222-2222-2222-222222222222"


def load_module() -> Any:
  spec = importlib.util.spec_from_file_location("circleci_auto_approve", SCRIPT)
  assert spec and spec.loader
  module = importlib.util.module_from_spec(spec)
  sys.modules["circleci_auto_approve"] = module
  spec.loader.exec_module(module)
  return module


class FakeResponse:
  def __init__(self, payload: Any = None):
    self.payload = payload

  def __enter__(self) -> "FakeResponse":
    return self

  def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
    return None

  def read(self) -> bytes:
    if self.payload is None:
      return b""
    return json.dumps(self.payload).encode("utf-8")


def http_error(url: str, status: int) -> urllib.error.HTTPError:
  return urllib.error.HTTPError(url, status, "not found", hdrs=None, fp=None)


def request_headers(request: Any) -> dict[str, str]:
  return {name.lower(): value for name, value in request.header_items()}


def assert_github_auth(request: Any) -> None:
  assert request_headers(request).get("authorization") == "Bearer github-token"


def assert_circleci_auth(request: Any) -> None:
  assert request_headers(request).get("circle-token") == "circle-token"


@contextmanager
def env(**updates: str):
  old = os.environ.copy()
  for key in list(os.environ):
    if key.startswith(("GITHUB_", "CIRCLECI_", "PR_", "TRUSTED_", "DRY_RUN")):
      del os.environ[key]
  os.environ.update(updates)
  try:
    yield
  finally:
    os.environ.clear()
    os.environ.update(old)


def base_env(author: str) -> dict[str, str]:
  author_ids = {
    "lawrencecchen": "54008264",
    "austinywang": "38676809",
    "alice": "1111",
    "mallory": "2222",
  }
  return {
    "GITHUB_API_URL": "https://api.github.test",
    "CIRCLECI_API_URL": "https://circleci.test/api/v2",
    "GITHUB_REPOSITORY": "manaflow-ai/cmux",
    "PR_HEAD_REPOSITORY": "contributor/cmux",
    "PR_HEAD_OWNER": author,
    "PR_HEAD_OWNER_ID": author_ids[author],
    "PR_HEAD_SHA": "abc123",
    "PR_AUTHOR": author,
    "PR_AUTHOR_ID": author_ids[author],
    "TRUSTED_GITHUB_ORG": "manaflow-ai",
    "TRUSTED_GITHUB_USERS": "lawrencecchen:54008264,austinywang:38676809",
    "GITHUB_TOKEN": "github-token",
    "GITHUB_ORG_READ_TOKEN": "github-token",
    "CIRCLECI_TOKEN": "circle-token",
    "CIRCLECI_APPROVAL_MAX_ATTEMPTS": "1",
    "CIRCLECI_APPROVAL_POLL_SECONDS": "0",
  }


def fake_check_runs() -> dict[str, Any]:
  return {
    "check_runs": [
      {
        "name": "ci/circleci: ci-gated/hold-for-approval",
        "details_url": f"https://app.circleci.com/pipelines/circleci/example/workflows/{WORKFLOW_ID}",
      }
    ]
  }


def fake_check_runs_without_hold(count: int = 100) -> dict[str, Any]:
  return {
    "check_runs": [
      {
        "name": f"check-{index}",
        "details_url": f"https://example.test/check-{index}",
      }
      for index in range(count)
    ]
  }


def fake_workflow_jobs(status: str = "blocked") -> dict[str, Any]:
  return {
    "items": [
      {
        "name": "hold-for-approval",
        "type": "approval",
        "status": status,
        "approval_request_id": APPROVAL_ID,
      }
    ]
  }


def trusted_user_response(url: str) -> FakeResponse | None:
  if url.endswith("/users/lawrencecchen"):
    return FakeResponse({"login": "lawrencecchen", "id": 54008264})
  if url.endswith("/users/austinywang"):
    return FakeResponse({"login": "austinywang", "id": 38676809})
  return None


def test_allowlisted_user_approves_without_membership_lookup() -> None:
  calls: list[tuple[str, str]] = []

  def urlopen(request: Any, timeout: int = 20) -> FakeResponse:
    calls.append((request.get_method(), request.full_url))
    if request.full_url.startswith("https://api.github.test/"):
      assert_github_auth(request)
    if request.full_url.startswith("https://circleci.test/"):
      assert_circleci_auth(request)
    if response := trusted_user_response(request.full_url):
      return response
    if request.full_url.endswith("/check-runs?per_page=100&page=1"):
      return FakeResponse(fake_check_runs())
    if request.full_url.endswith(f"/workflow/{WORKFLOW_ID}/job"):
      return FakeResponse(fake_workflow_jobs())
    if request.full_url.endswith(f"/workflow/{WORKFLOW_ID}/approve/{APPROVAL_ID}"):
      return FakeResponse({})
    raise AssertionError(f"unexpected request: {request.full_url}")

  with env(**base_env("lawrencecchen")):
    module = load_module()
    with mock.patch.object(module.urllib.request, "urlopen", urlopen):
      assert module.run() == 0

  urls = [url for _, url in calls]
  assert not any("/orgs/manaflow-ai/members/lawrencecchen" in url for url in urls)
  assert any(url.endswith("/users/austinywang") for url in urls)
  assert any(method == "POST" and url == f"https://circleci.test/api/v2/workflow/{WORKFLOW_ID}/approve/{APPROVAL_ID}" for method, url in calls), calls


def test_visible_org_member_approves() -> None:
  calls: list[tuple[str, str]] = []

  def urlopen(request: Any, timeout: int = 20) -> FakeResponse:
    calls.append((request.get_method(), request.full_url))
    if request.full_url.startswith("https://api.github.test/"):
      assert_github_auth(request)
    if request.full_url.startswith("https://circleci.test/"):
      assert_circleci_auth(request)
    if response := trusted_user_response(request.full_url):
      return response
    if request.full_url.endswith("/orgs/manaflow-ai/members/alice"):
      return FakeResponse()
    if request.full_url.endswith("/check-runs?per_page=100&page=1"):
      return FakeResponse(fake_check_runs())
    if request.full_url.endswith(f"/workflow/{WORKFLOW_ID}/job"):
      return FakeResponse(fake_workflow_jobs())
    if request.full_url.endswith(f"/workflow/{WORKFLOW_ID}/approve/{APPROVAL_ID}"):
      return FakeResponse({})
    raise AssertionError(f"unexpected request: {request.full_url}")

  with env(**base_env("alice")):
    module = load_module()
    with mock.patch.object(module.urllib.request, "urlopen", urlopen):
      assert module.run() == 0

  assert any(method == "POST" and url == f"https://circleci.test/api/v2/workflow/{WORKFLOW_ID}/approve/{APPROVAL_ID}" for method, url in calls), calls


def test_non_member_does_not_call_circleci() -> None:
  calls: list[tuple[str, str]] = []

  def urlopen(request: Any, timeout: int = 20) -> FakeResponse:
    calls.append((request.get_method(), request.full_url))
    if request.full_url.startswith("https://api.github.test/"):
      assert_github_auth(request)
    if response := trusted_user_response(request.full_url):
      return response
    if request.full_url.endswith("/orgs/manaflow-ai/members/mallory"):
      raise http_error(request.full_url, 404)
    raise AssertionError(f"unexpected request: {request.full_url}")

  with env(**base_env("mallory")):
    module = load_module()
    with mock.patch.object(module.urllib.request, "urlopen", urlopen):
      assert module.run() == 0

  assert all("circleci.test" not in url for _, url in calls)


def test_missing_org_token_does_not_call_circleci_for_non_allowlisted_member() -> None:
  calls: list[tuple[str, str]] = []
  test_env = base_env("alice")
  del test_env["GITHUB_ORG_READ_TOKEN"]

  def urlopen(request: Any, timeout: int = 20) -> FakeResponse:
    calls.append((request.get_method(), request.full_url))
    if request.full_url.startswith("https://api.github.test/"):
      assert_github_auth(request)
    if response := trusted_user_response(request.full_url):
      return response
    raise AssertionError(f"unexpected request: {request.full_url}")

  with env(**test_env):
    module = load_module()
    with mock.patch.object(module.urllib.request, "urlopen", urlopen):
      assert module.run() == 0

  assert all("/orgs/manaflow-ai/members/alice" not in url for _, url in calls)
  assert all("circleci.test" not in url for _, url in calls)


def test_trusted_author_cannot_approve_untrusted_fork_owner() -> None:
  calls: list[tuple[str, str]] = []
  test_env = base_env("lawrencecchen")
  test_env["PR_HEAD_REPOSITORY"] = "mallory/cmux"
  test_env["PR_HEAD_OWNER"] = "mallory"
  test_env["PR_HEAD_OWNER_ID"] = "2222"

  def urlopen(request: Any, timeout: int = 20) -> FakeResponse:
    calls.append((request.get_method(), request.full_url))
    if request.full_url.startswith("https://api.github.test/"):
      assert_github_auth(request)
    if response := trusted_user_response(request.full_url):
      return response
    if request.full_url.endswith("/orgs/manaflow-ai/members/mallory"):
      raise http_error(request.full_url, 404)
    raise AssertionError(f"unexpected request: {request.full_url}")

  with env(**test_env):
    module = load_module()
    with mock.patch.object(module.urllib.request, "urlopen", urlopen):
      assert module.run() == 0

  urls = [url for _, url in calls]
  assert any(url.endswith("/orgs/manaflow-ai/members/mallory") for url in urls)
  assert all("circleci.test" not in url for url in urls)


def test_same_repository_pr_does_not_poll_circleci() -> None:
  calls: list[tuple[str, str]] = []
  test_env = base_env("lawrencecchen")
  test_env["PR_HEAD_REPOSITORY"] = "manaflow-ai/cmux"

  def urlopen(request: Any, timeout: int = 20) -> FakeResponse:
    calls.append((request.get_method(), request.full_url))
    raise AssertionError(f"unexpected request: {request.full_url}")

  with env(**test_env):
    module = load_module()
    with mock.patch.object(module.urllib.request, "urlopen", urlopen):
      assert module.run() == 0

  assert calls == []


def test_hold_check_name_accepts_legacy_and_workflow_prefixed_names() -> None:
  module = load_module()
  assert module.is_hold_check_name("ci/circleci: hold-for-approval", "hold-for-approval")
  assert module.is_hold_check_name("ci/circleci: ci-gated/hold-for-approval", "hold-for-approval")
  assert not module.is_hold_check_name("ci/circleci: macos-unit-tests", "hold-for-approval")


def test_membership_api_error_does_not_call_circleci() -> None:
  calls: list[tuple[str, str]] = []

  def urlopen(request: Any, timeout: int = 20) -> FakeResponse:
    calls.append((request.get_method(), request.full_url))
    if request.full_url.startswith("https://api.github.test/"):
      assert_github_auth(request)
    if response := trusted_user_response(request.full_url):
      return response
    if request.full_url.endswith("/orgs/manaflow-ai/members/alice"):
      raise http_error(request.full_url, 403)
    raise AssertionError(f"unexpected request: {request.full_url}")

  with env(**base_env("alice")):
    module = load_module()
    with mock.patch.object(module.urllib.request, "urlopen", urlopen):
      assert module.run() == 0

  assert all("circleci.test" not in url for _, url in calls)


def test_already_approved_does_not_post() -> None:
  calls: list[tuple[str, str]] = []

  def urlopen(request: Any, timeout: int = 20) -> FakeResponse:
    calls.append((request.get_method(), request.full_url))
    if request.full_url.startswith("https://api.github.test/"):
      assert_github_auth(request)
    if request.full_url.startswith("https://circleci.test/"):
      assert_circleci_auth(request)
    if response := trusted_user_response(request.full_url):
      return response
    if request.full_url.endswith("/check-runs?per_page=100&page=1"):
      return FakeResponse(fake_check_runs())
    if request.full_url.endswith(f"/workflow/{WORKFLOW_ID}/job"):
      return FakeResponse(fake_workflow_jobs(status="success"))
    raise AssertionError(f"unexpected request: {request.full_url}")

  with env(**base_env("lawrencecchen")):
    module = load_module()
    with mock.patch.object(module.urllib.request, "urlopen", urlopen):
      assert module.run() == 0

  assert not any(method == "POST" for method, _ in calls)


def test_dry_run_paginates_and_does_not_post() -> None:
  calls: list[tuple[str, str]] = []
  test_env = base_env("lawrencecchen")
  test_env["DRY_RUN"] = "1"

  def urlopen(request: Any, timeout: int = 20) -> FakeResponse:
    calls.append((request.get_method(), request.full_url))
    if request.full_url.startswith("https://api.github.test/"):
      assert_github_auth(request)
    if request.full_url.startswith("https://circleci.test/"):
      assert_circleci_auth(request)
    if response := trusted_user_response(request.full_url):
      return response
    if request.full_url.endswith("/check-runs?per_page=100&page=1"):
      return FakeResponse(fake_check_runs_without_hold())
    if request.full_url.endswith("/check-runs?per_page=100&page=2"):
      return FakeResponse(fake_check_runs())
    if request.full_url.endswith(f"/workflow/{WORKFLOW_ID}/job"):
      return FakeResponse(fake_workflow_jobs())
    raise AssertionError(f"unexpected request: {request.full_url}")

  with env(**test_env):
    module = load_module()
    with mock.patch.object(module.urllib.request, "urlopen", urlopen):
      assert module.run() == 0

  assert any(url.endswith("/check-runs?per_page=100&page=2") for _, url in calls)
  assert not any(method == "POST" for method, _ in calls)


def test_workflow_without_approval_job_keeps_polling() -> None:
  calls: list[tuple[str, str]] = []
  workflow_job_calls = 0
  test_env = base_env("lawrencecchen")
  test_env["CIRCLECI_APPROVAL_MAX_ATTEMPTS"] = "2"

  def urlopen(request: Any, timeout: int = 20) -> FakeResponse:
    nonlocal workflow_job_calls
    calls.append((request.get_method(), request.full_url))
    if request.full_url.startswith("https://api.github.test/"):
      assert_github_auth(request)
    if request.full_url.startswith("https://circleci.test/"):
      assert_circleci_auth(request)
    if response := trusted_user_response(request.full_url):
      return response
    if request.full_url.endswith("/check-runs?per_page=100&page=1"):
      return FakeResponse(fake_check_runs())
    if request.full_url.endswith(f"/workflow/{WORKFLOW_ID}/job"):
      workflow_job_calls += 1
      if workflow_job_calls == 1:
        return FakeResponse({"items": []})
      return FakeResponse(fake_workflow_jobs())
    if request.full_url.endswith(f"/workflow/{WORKFLOW_ID}/approve/{APPROVAL_ID}"):
      return FakeResponse({})
    raise AssertionError(f"unexpected request: {request.full_url}")

  with env(**test_env):
    module = load_module()
    with mock.patch.object(module.urllib.request, "urlopen", urlopen):
      assert module.run() == 0

  assert workflow_job_calls == 2
  assert any(method == "POST" and url == f"https://circleci.test/api/v2/workflow/{WORKFLOW_ID}/approve/{APPROVAL_ID}" for method, url in calls), calls


def test_unresolvable_allowlisted_login_fails_closed() -> None:
  calls: list[tuple[str, str]] = []
  test_env = base_env("lawrencecchen")
  test_env["TRUSTED_GITHUB_USERS"] = "lawrencecchen:54008264,austyinywang:38676809"

  def urlopen(request: Any, timeout: int = 20) -> FakeResponse:
    calls.append((request.get_method(), request.full_url))
    if request.full_url.startswith("https://api.github.test/"):
      assert_github_auth(request)
    if request.full_url.endswith("/users/lawrencecchen"):
      return FakeResponse({"login": "lawrencecchen", "id": 54008264})
    if request.full_url.endswith("/users/austyinywang"):
      raise http_error(request.full_url, 404)
    raise AssertionError(f"unexpected request: {request.full_url}")

  with env(**test_env):
    module = load_module()
    with mock.patch.object(module.urllib.request, "urlopen", urlopen):
      try:
        module.run()
      except SystemExit:
        pass
      else:
        raise AssertionError("expected SystemExit")

  assert all("circleci.test" not in url for _, url in calls)


def main() -> None:
  test_allowlisted_user_approves_without_membership_lookup()
  test_visible_org_member_approves()
  test_non_member_does_not_call_circleci()
  test_missing_org_token_does_not_call_circleci_for_non_allowlisted_member()
  test_trusted_author_cannot_approve_untrusted_fork_owner()
  test_same_repository_pr_does_not_poll_circleci()
  test_hold_check_name_accepts_legacy_and_workflow_prefixed_names()
  test_membership_api_error_does_not_call_circleci()
  test_already_approved_does_not_post()
  test_dry_run_paginates_and_does_not_post()
  test_workflow_without_approval_job_keeps_polling()
  test_unresolvable_allowlisted_login_fails_closed()
  print("PASS: CircleCI auto approval trusts only allowlisted users or org members")


if __name__ == "__main__":
  main()
