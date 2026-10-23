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

Then it cancels the artifacts runs still queued or running for this pull
request's older merge commits (cancel_superseded_pins): each push pins a new
merge commit on a new ref, so the artifacts workflow cannot group them, and 21
of 29 pin runs on 2026-10-20/21 were cancelled by hand. It cancels only a
cmux-tui-pin-<sha12> push run whose commit is GitHub's merge commit ("Merge
<head> into <base>", parents [base, head]) of an older head that GitHub lists
under this pull request and no other (a stacked pull request may share it),
and whose cmux-tui tree or ghostty-next gitlink differs from the new merge
commit's (so its tree key differs: a same-key run may own the publication the
new pin waits for), and none of whose publish jobs has started and whose tree
preflight is not running (PUBLISH_JOBS). Anything it cannot tell, and every API
failure, keeps the run; the cancel never changes the exit status.

Usage: publish_pr_merge_tree.py PR_NUMBER HEAD_SHA
Environment: GH_TOKEN (actions: write), CMUX_PR_TREE_PIN_TOKEN (the App's
contents and workflows write token), GITHUB_REPOSITORY, GITHUB_API_URL (optional),
CMUX_PR_TREE_MERGE_WAIT_SECONDS (default 90), CMUX_PR_TREE_POLL_SECONDS (default 5).
Exit 0 when the publish is started, already under way, or not possible for a
reason that is not this script's (a conflict, a newer head); 1 on an API error.
"""

from __future__ import annotations

import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

WORKFLOW = "cmux-tui-artifacts.yml"
PIN_PREFIX = "cmux-tui-pin-"
# The run states a cancel can still save runner time on; one list call each.
ACTIVE_STATUSES = ("queued", "in_progress", "waiting", "pending")
# At most this many older pins are examined (three reads each) per publish.
MAX_SUPERSEDED_CANDIDATES = 10
MERGE_SUBJECT = re.compile(r"Merge ([0-9a-f]{40}) into ([0-9a-f]{40})")
# The tree key's input list (cmux_tui_tree_key.py on feat-cmux-next), read at
# the new merge commit. Its top-level tree and gitlink inputs are whole root
# entries, so a root tree that differs in one of them has another key.
TREE_INPUTS = "scripts/cmux-next/cmux-tui-tree-inputs.txt"
# Inputs of the v1 key only (cmux_tui_tree_key.py V1_ONLY_INPUTS): the v2 key a
# run claims leaves them out, so a difference there does not tell keys apart.
V1_ONLY_INPUTS = frozenset({("gitlink", "ghostty")})
# cmux-tui-artifacts.yml never cancels a started run, so no write-once upload stops halfway: a run is
# kept once one of these jobs started (a cancel mid-publish leaves a prefix without its manifest or
# completion, and the next run of that key or commit fails on it), and while its tree preflight runs
# (it may hold the tree claim another run deferred to).
PUBLISH_JOBS = ("publish", "mark the published tree")
PREFLIGHT_JOB = "cmux-tui tree preflight"


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


def _get(api: Api, path: str) -> object:
    status, data = api.call("GET", path)
    if status != 200:
        raise RuntimeError(f"GET {path}: HTTP {status}")
    return data


def _commit(api: Api, sha: str) -> tuple[list[str], str, str]:
    """(parent shas, subject, root tree sha) of a commit."""
    data = _get(api, f"commits/{sha}")
    if not isinstance(data, dict):
        raise RuntimeError(f"GET commits/{sha}: not an object")
    parents = [str((parent or {}).get("sha", "")) for parent in data.get("parents") or []]
    commit = data.get("commit") or {}
    subject = str(commit.get("message") or "").partition("\n")[0].strip()
    return parents, subject, str((commit.get("tree") or {}).get("sha", ""))


def _root_entries(api: Api, tree: str) -> dict[str, str]:
    data = _get(api, f"git/trees/{tree}")
    if not isinstance(data, dict) or not isinstance(data.get("tree"), list):
        raise RuntimeError(f"GET git/trees/{tree}: not a tree")
    return {str(entry.get("path")): str(entry.get("sha")) for entry in data["tree"]}


def _whole_root_inputs(api: Api, merge: str) -> list[str]:
    """The tree key inputs at the merge commit that are whole root entries."""
    data = _get(api, f"contents/{TREE_INPUTS}?ref={merge}")
    if not isinstance(data, dict) or data.get("encoding") != "base64":
        raise RuntimeError(f"GET contents/{TREE_INPUTS}: not a base64 file")
    names = []
    for line in base64.b64decode(str(data.get("content", ""))).decode().splitlines():
        fields = line.split()
        if len(fields) == 2 and not line.lstrip().startswith("#") and fields[0] in ("tree", "gitlink") \
                and "/" not in fields[1] and (fields[0], fields[1]) not in V1_ONLY_INPUTS:
            names.append(fields[1])
    if not names:
        raise RuntimeError(f"{TREE_INPUTS} at {merge[:12]} lists no root tree or gitlink input")
    return names


def _superseded_verdict(api: Api, pr: str, head: str, run: dict, new_entries: dict[str, str],
                        whole: list[str]) -> tuple[bool, str]:
    sha = str(run.get("head_sha", ""))
    parents, subject, tree = _commit(api, sha)
    if len(parents) != 2 or subject != f"Merge {parents[1]} into {parents[0]}":
        return False, "its pin is not a pull request merge commit"
    if parents[1] == head:
        return False, f"it merges the current head {head[:12]}"
    pulls = _get(api, f"commits/{parents[1]}/pulls?per_page=100")
    if not isinstance(pulls, list):
        raise RuntimeError(f"GET commits/{parents[1][:12]}/pulls: not a list")
    numbers = {str((pull or {}).get("number")) for pull in pulls}
    if pr not in numbers:
        return False, f"GitHub lists no #{pr} for its head {parents[1][:12]}"
    if numbers != {pr}:
        # A stacked pull request shares the commit: the pin may be its own.
        others = ", ".join(f"#{number}" for number in sorted(numbers - {pr}))
        return False, f"its head {parents[1][:12]} is in {others} too"
    old_entries = _root_entries(api, tree)
    differing = [name for name in whole if old_entries.get(name) != new_entries.get(name)]
    if not differing:
        return False, "its cmux-tui tree key may be the new merge's own"
    busy = _publishing(api, run["id"])
    if busy:
        return False, busy
    return True, f"#{pr}'s older head {parents[1][:12]} ({', '.join(differing)} differ)"


def _publishing(api: Api, run_id: object) -> str:
    """Why the run must finish instead of being cancelled, or "" when nothing it started can stop halfway."""
    data = _get(api, f"actions/runs/{run_id}/jobs?per_page=100")
    if not isinstance(data, dict) or not isinstance(data.get("jobs"), list):
        raise RuntimeError(f"GET actions/runs/{run_id}/jobs: not a job list")
    for job in data["jobs"]:
        name, status = str(job.get("name", "")), job.get("status")
        if name == PREFLIGHT_JOB and status == "in_progress":
            return "its tree preflight is running (it may hold the tree claim)"
        if name.startswith(PUBLISH_JOBS) and (status == "in_progress" or
                                              (status == "completed" and job.get("conclusion") != "skipped")):
            return f"its {name!r} job started (write-once uploads)"
    return ""


def cancel_superseded_pins(api: Api, pr: str, head: str, merge: str) -> list[str]:
    """Cancels the artifacts runs of this pull request's older pins; returns what it cancelled.

    Every failure before a cancel keeps every run."""
    try:
        runs: dict[int, dict] = {}
        for status in ACTIVE_STATUSES:
            data = _get(api, f"actions/workflows/{WORKFLOW}/runs?event=push&status={status}&per_page=100")
            if not isinstance(data, dict) or not isinstance(data.get("workflow_runs"), list):
                raise RuntimeError(f"the {status} {WORKFLOW} runs are not a list")
            for run in data["workflow_runs"]:
                runs[int(run["id"])] = run
        candidates = []
        for run_id, run in sorted(runs.items()):
            sha = str(run.get("head_sha", ""))
            subject = str((run.get("head_commit") or {}).get("message") or "").partition("\n")[0].strip()
            match = MERGE_SUBJECT.fullmatch(subject)
            if (run.get("event") == "push" and run.get("head_branch") == f"{PIN_PREFIX}{sha[:12]}"
                    and len(sha) == 40 and sha != merge and match and match.group(1) != head):
                candidates.append(run)
        if not candidates:
            print(f"no older #{pr} pin run to cancel")
            return []
        if len(candidates) > MAX_SUPERSEDED_CANDIDATES:
            print(f"{len(candidates)} pin runs look superseded; examining the newest {MAX_SUPERSEDED_CANDIDATES}")
            candidates = candidates[-MAX_SUPERSEDED_CANDIDATES:]
        whole = _whole_root_inputs(api, merge)
        new_entries = _root_entries(api, _commit(api, merge)[2])
    except Exception as error:  # noqa: BLE001 - any doubt keeps every run; the publish already happened
        print(f"::warning title=superseded pins kept::cancelled nothing: {error!r}")
        return []
    cancelled = []
    for run in candidates:
        run_id, branch = run["id"], run["head_branch"]
        try:
            stale, reason = _superseded_verdict(api, pr, head, run, new_entries, whole)
        except Exception as error:  # noqa: BLE001 - a run it cannot attribute is kept
            stale, reason = False, f"could not tell ({error!r})"
        if not stale:
            print(f"kept run {run_id} on {branch}: {reason}")
            continue
        try:
            status, data = api.call("POST", f"actions/runs/{run_id}/cancel")
        except Exception as error:  # noqa: BLE001 - a failed cancel is a warning, not a failed publish
            status, data = 0, repr(error)
        if status != 202:
            print(f"::warning title=superseded pin not cancelled::run {run_id} on {branch}: HTTP {status} {data}")
            continue
        print(f"cancelled run {run_id} on {branch}: {reason}")
        cancelled.append(str(run_id))
    return cancelled


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
        else:
            branch, created = pin(Api(pin_token), sha)
            if created:
                print(f"pinned {branch} at #{pr}'s merge commit {sha[:12]}; its push starts {WORKFLOW}")
            else:
                status, data = api.call("POST", f"actions/workflows/{WORKFLOW}/dispatches", {"ref": branch})
                if status != 204:
                    raise RuntimeError(f"dispatch {WORKFLOW} on {branch}: HTTP {status} {data}")
                print(f"dispatched {WORKFLOW} on {branch} for #{pr}'s merge commit {sha[:12]}")
        cancel_superseded_pins(api, pr, head, sha)
        return 0
    except RuntimeError as error:
        print(f"::error title=cmux-tui merge tree not published::{error}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
