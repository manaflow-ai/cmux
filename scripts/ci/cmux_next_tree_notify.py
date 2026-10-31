#!/usr/bin/env python3
"""Start the cmux-next tree jobs that waited for a cmux-tui tree.

cmux-next's path routing probes the same-tree cmux-tui once
(pin-cmux-tui.sh probe). When the tree is not published yet, it uploads a
marker artifact named `cmux-next-tree-wait-<key>` (marker.json: the commit to
test, the commit to report on, the tree tiers, the origin event) and skips the
tree jobs. No runner waits.

The cmux-tui artifacts workflow runs this when it publishes <key> (--state
ready) or ends without publishing it (--state failed). For each current marker
it dispatches cmux-next.yml in same-tree mode, which runs only the daemon tests
and scheme compile on that commit, or reports the failure. An unpublished PR
tree is skipped: its failed marker is retained for a later trusted publication,
without dispatching a red check or creating a cmux-tui-pin-* ref.

--state failed is checked against the tree's completion.json on R2 first.
publish-cmux-tui-tree.py writes it last and only once, so it is the record
that the tree is published: a run cancelled after (or while another run)
published the key reports ready, not the run's conclusion (#23517).

Usage: cmux_next_tree_notify.py --repo OWNER/NAME --key KEY --state ready|failed
       [--reason TEXT]
Needs GH_TOKEN with actions: write (dispatch, delete markers), contents: read
and pull-requests: read. Exits 0 when the API fails: a notify problem must not
turn a good publication red; it prints a ::warning:: instead.
"""

from __future__ import annotations

import argparse
import http.client
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import zipfile
from typing import Callable, Protocol

SHA = re.compile(r"^[0-9a-f]{40}$")
REF = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
TIERS = ("daemon", "scheme")
# A marker's tip_suite -> the tiers it may carry and the dispatch input that names its same-tree run
# (`cmux-next tip daemon suite · <sha>`, `cmux-next base tier · <sha>`).
TIP_SUITES = {"daemon": {"daemon"}, "base": {"daemon", "scheme"}}
TIP_SUITE_INPUTS = {"daemon": "tip_daemon_suite", "base": "base_tier"}
MAX_MARKERS = 50
WORKFLOW = "cmux-next.yml"
TREE_BASE = "https://files.cmux.com/cmux-tui/tree"


class Api(Protocol):
    def get(self, path: str): ...
    def download(self, url: str) -> bytes: ...
    def post(self, path: str, body: dict) -> int: ...
    def delete(self, path: str) -> int: ...


class GitHub:
    def __init__(self, token: str, api_url: str = "https://api.github.com"):
        self.token = token
        self.api_url = api_url.rstrip("/")

    def _request(self, method: str, url: str, body: dict | None = None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        # Unredirected: an artifact download redirects to blob storage, which
        # must not receive the token.
        request.add_unredirected_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def get(self, path: str):
        status, payload = self._request("GET", f"{self.api_url}/{path}")
        if status != 200:
            raise RuntimeError(f"GET {path}: HTTP {status}")
        return json.loads(payload)

    def download(self, url: str) -> bytes:
        status, payload = self._request("GET", url)
        if status != 200:
            raise RuntimeError(f"download {url}: HTTP {status}")
        return payload

    def post(self, path: str, body: dict) -> int:
        return self._request("POST", f"{self.api_url}/{path}", body)[0]

    def delete(self, path: str) -> int:
        return self._request("DELETE", f"{self.api_url}/{path}")[0]


def fetch_completion(key: str) -> object | None:
    """The tree's published completion.json, or None when it is absent or unreadable."""
    # The query string bypasses a cached 404 at the CDN edge.
    url = f"{TREE_BASE}/{key}/completion.json?notify={int(time.time())}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url), timeout=30) as response:
            return json.loads(response.read())
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
        return None


def completion_attests(completion: object, key: str) -> bool:
    """The checks the artifacts workflow makes of a completion.json: its key and a binaries object."""
    return (isinstance(completion, dict) and completion.get("key") == key
            and isinstance(completion.get("binaries"), dict))


def read_marker(api: Api, artifact: dict, key: str) -> dict | None:
    """The validated marker, or None when it is not one this script wrote."""
    try:
        with zipfile.ZipFile(io.BytesIO(api.download(artifact["archive_download_url"]))) as archive:
            marker = json.loads(archive.read("marker.json"))
    except (KeyError, ValueError, zipfile.BadZipFile, RuntimeError, OSError):
        return None
    if not isinstance(marker, dict) or marker.get("key") != key:
        return None
    if not all(SHA.match(str(marker.get(field, ""))) for field in ("sha", "status_sha")):
        return None
    tiers = marker.get("tiers")
    if not isinstance(tiers, list) or not tiers or any(tier not in TIERS for tier in tiers):
        return None
    dev_daily = marker.get("dev_daily", False)
    if dev_daily:
        if marker.get("dev_daily_sha") != marker.get("sha"):
            return None
        if marker.get("branch") != "feat-cmux-next":
            return None
    elif dev_daily is not False:
        return None
    # The tip daemon suite (cmux-next.yml tip_daemon_suite): a dispatch on feat-cmux-next of the daemon
    # tier only, which tests its exact commit whatever the tip is by then. The base tier
    # (cmux-next.yml base_tier, cmux-next-base-tier-kick.yml) likewise, with the daemon and scheme tiers.
    tip_suite = marker.get("tip_suite")
    if tip_suite is not None and (not isinstance(tip_suite, str) or tip_suite not in TIP_SUITES
                                  or marker.get("origin") != "dispatch" or dev_daily
                                  or marker.get("branch") != "feat-cmux-next"
                                  or marker.get("ref_kind", "heads") != "heads"
                                  or not set(tiers) <= TIP_SUITES[tip_suite]):
        return None
    if marker.get("origin") in ("push", "dispatch"):
        if dev_daily and marker.get("origin") != "push":
            return None
        # A dispatch may run on a tag; a push marker names a branch.
        if marker.get("ref_kind", "heads") not in (("heads", "tags") if marker["origin"] == "dispatch" else ("heads",)):
            return None
        return marker if REF.match(str(marker.get("branch", ""))) else None
    if marker.get("origin") == "pull_request":
        if not re.fullmatch(r"[0-9]{1,9}", str(marker.get("pr", ""))):
            return None
        if not REF.match(str(marker.get("base_ref", ""))):
            return None
        return marker
    return None


def dispatch_refs(marker: dict, repo: str) -> list[str]:
    """Where cmux-next.yml runs: the push's branch; a pull request's head
    branch (its checks then show on the pull request) and then its base.
    A dispatch on a branch runs there again, like a push."""
    if marker["origin"] in ("push", "dispatch"):
        return [marker["branch"]]
    refs = []
    head_ref = str(marker.get("head_ref", ""))
    if marker.get("head_repo") == repo and REF.match(head_ref):
        refs.append(head_ref)
    refs.append(marker["base_ref"])
    return refs


def is_current(api: Api, repo: str, marker: dict) -> bool:
    if marker["origin"] in ("push", "dispatch"):
        # A scheduled DEV build owns an immutable SHA. Its tree may finish
        # after feat-cmux-next advances, so the branch pointer is not an
        # admission signal for this marker. same-tree mode checks out the
        # recorded SHA and the publisher's source gate verifies it again.
        if marker.get("dev_daily"):
            return True
        # Likewise the tip daemon suite and the base tier: each is the base's verdict for that commit, and in a
        # landing burst the tip always moves before its tree publishes (2026-10-30: no base daemon-test
        # verdict for hours, so no pull request's daemon-test red could be compared with the base).
        if marker.get("tip_suite"):
            return True
        # A tag has no head to move on (and is not a branch to look up).
        if marker.get("ref_kind") == "tags":
            return True
        head = api.get(f"repos/{repo}/git/ref/heads/{marker['branch']}")
        return head.get("object", {}).get("sha") == marker["sha"]
    pull = api.get(f"repos/{repo}/pulls/{marker['pr']}")
    return pull.get("state") == "open" and pull.get("head", {}).get("sha") == marker["status_sha"]


def notify(api: Api, *, repo: str, key: str, state: str, reason: str,
           log: Callable[[str], None] = print,
           fetch_completion: Callable[[str], object | None] = fetch_completion) -> int:
    """Dispatches same-tree runs for the markers of <key>; returns how many."""
    if state == "failed" and completion_attests(fetch_completion(key), key):
        log(f"tree {key}: its completion.json is published, so the tree is ready whatever the "
            f"reporting run's conclusion; starting the tree jobs (ready)")
        state = "ready"
        reason = f"tree {key} is published ({TREE_BASE}/{key}/completion.json)"
    listing = api.get(f"repos/{repo}/actions/artifacts?name=cmux-next-tree-wait-{key}&per_page=100")
    artifacts = [artifact for artifact in listing.get("artifacts", []) if not artifact.get("expired")]
    dispatched = 0
    for artifact in artifacts[:MAX_MARKERS]:
        run_id = artifact.get("workflow_run", {}).get("id")
        marker = read_marker(api, artifact, key)
        if marker is None:
            log(f"marker {artifact.get('id')} (run {run_id}) is not a valid tree marker; ignored")
            continue
        try:
            current = is_current(api, repo, marker)
        except RuntimeError as error:
            log(f"::warning::run {run_id}: could not check whether it is current: {error}")
            continue
        if not current:
            log(f"run {run_id} ({marker['origin']} {marker['status_sha'][:12]}) was superseded; nothing to start")
            api.delete(f"repos/{repo}/actions/artifacts/{artifact['id']}")
            continue
        if marker["origin"] == "pull_request" and state == "failed":
            log(f"::notice title=same-tree cmux-tui skipped::run {run_id} ({marker['status_sha'][:12]}): "
                f"tree {key} is unavailable; no pin ref is created. Re-run after a trusted publication.")
            continue
        inputs = {
            "same_tree_sha": marker["sha"],
            "same_tree_status_sha": marker["status_sha"],
            "same_tree_tiers": ",".join(marker["tiers"]),
            "same_tree_state": state,
            "same_tree_reason": reason[:900],
            "same_tree_origin": marker["origin"],
            "same_tree_origin_run": str(run_id or ""),
        }
        if marker.get("dev_daily"):
            inputs.update(dev_daily="true", dev_daily_sha=marker["dev_daily_sha"])
        if marker.get("tip_suite"):
            # Names the run `cmux-next tip daemon suite · <sha>` or `cmux-next base tier · <sha>`, which
            # the dispatchers and base_red_excuse.py look up.
            inputs[TIP_SUITE_INPUTS[marker["tip_suite"]]] = "true"
        for ref in dispatch_refs(marker, repo):
            status = api.post(f"repos/{repo}/actions/workflows/{WORKFLOW}/dispatches", {"ref": ref, "inputs": inputs})
            if status == 204:
                dispatched += 1
                log(f"run {run_id}: dispatched {WORKFLOW} same-tree mode ({state}) on {ref} "
                    f"for {marker['sha'][:12]}, tiers {inputs['same_tree_tiers']}")
                if state == "ready":
                    api.delete(f"repos/{repo}/actions/artifacts/{artifact['id']}")
                break
            log(f"run {run_id}: dispatch on {ref} refused (HTTP {status})")
        else:
            log(f"::warning::run {run_id}: no ref accepted the same-tree dispatch; its tree jobs did not start")
    log(f"tree {key}: {len(artifacts)} marker(s), {dispatched} same-tree run(s) started ({state})")
    return dispatched


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--state", choices=("ready", "failed"), required=True)
    parser.add_argument("--reason", default="")
    args = parser.parse_args(argv)
    if not SHA.match(args.key):
        print(f"::warning::not a tree key: {args.key!r}")
        return 0
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        print("::warning::no GH_TOKEN; cannot start the deferred cmux-next tree jobs")
        return 0
    api = GitHub(token, os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    try:
        notify(api, repo=args.repo, key=args.key, state=args.state, reason=args.reason)
    except (RuntimeError, OSError, ValueError) as error:
        print(f"::warning::could not start the deferred cmux-next tree jobs for tree {args.key}: {error}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
