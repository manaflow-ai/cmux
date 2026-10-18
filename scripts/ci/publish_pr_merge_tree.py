#!/usr/bin/env python3
"""Starts the cmux-tui tree publish for a feat-cmux-next pull request's merge tree.

cmux-next's same-tree checks (scripts/cmux-next/pin-cmux-tui.sh probe, on
feat-cmux-next) test the cmux-tui built from a pull request's merge commit. A
pull request that changes a cmux-tui tree input has a merge tree no push has
published, and its pull_request run cannot start one: its token can neither
create the cmux-tui-pin-<sha12> branch nor dispatch the artifacts workflow
(the 403 behind the "same-tree cmux-tui unavailable" reds). No GITHUB_TOKEN
can create a ref at a feat-cmux-next commit: GitHub asks for the workflows
permission (#19166). GitHub reads pull_request_target workflows only from the
default branch, so this runs from main (cmux-next-pr-merge-tree.yml), for
same-repository pull requests only, and pins with the FFI release App's token
(contents and workflows write), minted in that job's own environment.

It executes none of the pull request's code: it reads the merge commit from
the API and, unless an artifacts run for that commit already ran or runs,
points refs/heads/cmux-tui-pin-<sha12> at it. The App's ref is a push, which
starts cmux-tui-artifacts.yml there (push: "**"): the run the pull request's
author, who can push to this repository, could already start by hand
(pin-cmux-tui.sh --help). A pin that already existed gets a workflow_dispatch
with GITHUB_TOKEN instead (the App has no actions permission). The probe then
finds the run active and defers to its publish.

Usage: publish_pr_merge_tree.py PR_NUMBER HEAD_SHA
Environment: GH_TOKEN (actions: write), CMUX_PR_TREE_PIN_TOKEN (the App's
contents and workflows write token), GITHUB_REPOSITORY, GITHUB_API_URL (optional),
CMUX_PR_TREE_MERGE_WAIT_SECONDS (default 90), CMUX_PR_TREE_POLL_SECONDS (default 5).
Exit 0 when the publish is started, already under way, or not possible for a
reason that is not this script's (a conflict, a newer head); 1 on an API error.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

WORKFLOW = "cmux-tui-artifacts.yml"


class Api:
    def __init__(self, token: str) -> None:
        self.base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
        self.repo = os.environ["GITHUB_REPOSITORY"]
        self.token = token

    def call(self, method: str, path: str, body: dict | None = None) -> tuple[int, object]:
        request = urllib.request.Request(
            f"{self.base}/repos/{self.repo}/{path}",
            method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                text = response.read().decode()
                return response.status, json.loads(text) if text else None
        except urllib.error.HTTPError as error:
            text = error.read().decode()
            try:
                return error.code, json.loads(text) if text else None
            except json.JSONDecodeError:
                return error.code, text


def merge_commit(api: Api, pr: str, head: str) -> str | None:
    """The pull request's merge commit once GitHub has computed it, or None (conflict, newer head)."""
    deadline = time.monotonic() + float(os.environ.get("CMUX_PR_TREE_MERGE_WAIT_SECONDS", "90"))
    poll = float(os.environ.get("CMUX_PR_TREE_POLL_SECONDS", "5"))
    while True:
        status, data = api.call("GET", f"pulls/{pr}")
        if status != 200 or not isinstance(data, dict):
            raise RuntimeError(f"GET pulls/{pr}: HTTP {status}")
        if data["head"]["sha"] != head:
            print(f"#{pr} moved to {data['head']['sha'][:12]}; its own run publishes that head's merge tree")
            return None
        if data.get("mergeable") is False:
            print(f"#{pr} conflicts with its base: no merge tree to publish")
            return None
        if data.get("mergeable") is True and data.get("merge_commit_sha"):
            return data["merge_commit_sha"]
        if time.monotonic() >= deadline:
            raise RuntimeError(f"GitHub computed no merge commit for #{pr} in time")
        time.sleep(poll)


def artifacts_run_exists(api: Api, sha: str) -> bool:
    """An artifacts run for the commit that is queued, running or succeeded: it publishes the tree."""
    status, data = api.call("GET", f"actions/workflows/{WORKFLOW}/runs?head_sha={sha}&per_page=20")
    if status != 200 or not isinstance(data, dict):
        raise RuntimeError(f"GET {WORKFLOW} runs for {sha}: HTTP {status}")
    return any(run.get("status") != "completed" or run.get("conclusion") == "success" for run in data["workflow_runs"])


def pin(api: Api, sha: str) -> tuple[str, bool]:
    """Points refs/heads/cmux-tui-pin-<sha12> at the commit: (branch, created).

    An existing pin must already point there."""
    branch = f"cmux-tui-pin-{sha[:12]}"
    status, data = api.call("POST", "git/refs", {"ref": f"refs/heads/{branch}", "sha": sha})
    if status == 201:
        return branch, True
    status_get, current = api.call("GET", f"git/ref/heads/{branch}")
    if status_get == 200 and isinstance(current, dict) and current["object"]["sha"] == sha:
        return branch, False
    raise RuntimeError(f"could not point {branch} at {sha}: HTTP {status} {data}")


def main(argv: list[str]) -> int:
    if len(argv) != 3 or not argv[1].isdigit() or len(argv[2]) != 40:
        print("usage: publish_pr_merge_tree.py PR_NUMBER HEAD_SHA", file=sys.stderr)
        return 2
    pr, head = argv[1], argv[2]
    pin_token = os.environ.get("CMUX_PR_TREE_PIN_TOKEN", "")
    api = Api(os.environ["GH_TOKEN"])
    try:
        if not pin_token:
            raise RuntimeError("CMUX_PR_TREE_PIN_TOKEN is empty: the release App token was not minted")
        sha = merge_commit(api, pr, head)
        if sha is None:
            return 0
        if artifacts_run_exists(api, sha):
            print(f"an artifacts run for the merge commit {sha[:12]} already publishes its tree")
            return 0
        branch, created = pin(Api(pin_token), sha)
        if created:
            print(f"pinned {branch} at #{pr}'s merge commit {sha[:12]}; its push starts {WORKFLOW}")
            return 0
        status, data = api.call("POST", f"actions/workflows/{WORKFLOW}/dispatches", {"ref": branch})
        if status != 204:
            raise RuntimeError(f"dispatch {WORKFLOW} on {branch}: HTTP {status} {data}")
        print(f"dispatched {WORKFLOW} on {branch} for #{pr}'s merge commit {sha[:12]}")
        return 0
    except RuntimeError as error:
        print(f"::error title=cmux-tui merge tree not published::{error}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
