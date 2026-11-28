#!/usr/bin/env python3
"""Request a protected ASC snapshot and await its exact webhook run, never GitHub polling.

Only a metadata job checked out at a protected main SHA may execute this helper with
actions:write. The PR pairing job receives numeric run metadata, never that token.
The existing fleet controller holds each read until completion (maximum 300 seconds).
Renewals share one ten-minute deadline; any transport refusal ends the request.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = "manaflow-ai/cmux"
WORKFLOW = ".github/workflows/ios-asc-ops.yml"
SHA = re.compile(r"[0-9a-f]{40}")


class NoVerdict(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise NoVerdict("unexpected redirect from snapshot control plane")


def read_json(url, *, token="", body=None, timeout=30):
    headers = {"Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
        headers["X-GitHub-Api-Version"] = "2022-11-28"
    data = None if body is None else json.dumps(body).encode()
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers)
    # A dispatch is never retried: its acceptance can be ambiguous on a timeout.
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=timeout) as response:
        payload = response.read(1024 * 1024 + 1)
    if len(payload) > 1024 * 1024:
        raise NoVerdict("snapshot control-plane response exceeds bound")
    doc = json.loads(payload)
    if not isinstance(doc, dict):
        raise NoVerdict("snapshot control-plane response is not an object")
    return doc


def check_run(run, run_id, producer_sha, *, controller=False):
    if not isinstance(run, dict):
        raise NoVerdict("missing snapshot producer run")
    repository = run.get("repo") if controller else (run.get("repository") or {}).get("full_name")
    attempt = run.get("attempt") if controller else run.get("run_attempt")
    expected = {
        "id": run_id, "head_sha": producer_sha, "head_branch": "main",
        "event": "workflow_dispatch", "path": WORKFLOW,
    }
    if any(run.get(key) != value for key, value in expected.items()) or repository != REPO or attempt != 1:
        raise NoVerdict("snapshot producer run identity/attempt does not match the protected dispatch")


def wait_run(controller, run_id, producer_sha, *, read=read_json, clock=time.monotonic, seconds=600):
    parsed = urllib.parse.urlsplit(controller)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/"):
        raise NoVerdict("missing or invalid existing CMUX_FLEET_CONTROLLER route")
    deadline = clock() + seconds
    # Two server-held reads normally span the deadline. The small hard cap also
    # refuses a broken endpoint returning nonterminal snapshots immediately.
    for _ in range(3):
        remaining = deadline - clock()
        if remaining <= 0:
            break
        hold = min(300, remaining)
        url = f"{controller.rstrip('/')}/v1/github/runs/{run_id}?wait={hold:.3f}&attempt=1"
        doc = read(url, timeout=min(hold + 10, remaining))
        run = doc.get("run")
        if run is not None:
            check_run(run, run_id, producer_sha, controller=True)
        if doc.get("terminal"):
            if not doc.get("known") or run is None or run.get("status") != "completed" or run.get("conclusion") != "success":
                raise NoVerdict("snapshot producer did not complete successfully")
            return
        if doc.get("note") or doc.get("evicted_open"):
            raise NoVerdict("snapshot producer is unavailable from the existing controller route")
    raise NoVerdict("snapshot producer condition wait exhausted its ten-minute deadline")


def dispatch(head_sha, request_id, producer_sha, controller, token, *, read=read_json, waiter=wait_run):
    if not SHA.fullmatch(head_sha) or not SHA.fullmatch(producer_sha) or not re.fullmatch(r"[1-9][0-9]*:[1-9][0-9]*", request_id):
        raise NoVerdict("snapshot request requires full head/producer SHAs and run:attempt")
    if not token or not controller:
        raise NoVerdict("snapshot dispatch requires trusted write authority and existing controller route")
    api = f"https://api.github.com/repos/{REPO}"
    response = read(f"{api}/actions/workflows/ios-asc-ops.yml/dispatches", token=token, body={
        "ref": "main", "return_run_details": True,
        "inputs": {"op": "publication-snapshot", "head_sha": head_sha, "request_id": request_id},
    })
    run_id = response.get("workflow_run_id")
    if type(run_id) is not int or run_id <= 0:
        raise NoVerdict("dispatch returned no exact workflow_run_id; no run discovery is permitted")
    # One immutable identity read, not a status loop. If main moved after checkout,
    # fail closed instead of executing one revision and trusting another producer.
    run = read(f"{api}/actions/runs/{run_id}", token=token)
    check_run(run, run_id, producer_sha)
    waiter(controller, run_id, producer_sha)
    return {"producer_run": str(run_id), "producer_sha": producer_sha, "request_id": request_id}


def main():
    try:
        if os.environ.get("GITHUB_REPOSITORY") != REPO or os.environ.get("SNAPSHOT_TRUSTED") != "true":
            raise NoVerdict("fork/untrusted run has no snapshot dispatch authority")
        values = dispatch(os.environ.get("HEAD_SHA", ""), os.environ.get("REQUEST_ID", ""),
                          os.environ.get("PRODUCER_SHA", ""), os.environ.get("CMUX_FLEET_CONTROLLER", ""),
                          os.environ.get("GH_TOKEN", ""))
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write("".join(f"{key}={value}\n" for key, value in values.items()))
        return 0
    except (NoVerdict, OSError, ValueError, KeyError, urllib.error.URLError) as error:
        print(f"::error::Snapshot infrastructure/no verdict: {error}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
