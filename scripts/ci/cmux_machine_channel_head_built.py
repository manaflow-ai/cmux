#!/usr/bin/env python3
"""Whether an earlier pr-router run already built this pull request head's machine channel pair.

`cmux_machine_channel_head_built.py HEAD_SHA [--exclude-run ID]` prints the newest other pr-router run (event
pull_request, this head SHA) whose machine-channel-cmux-tui-<target> artifacts are both there and unexpired, or
nothing. scripts/ci/cmux-machine-channel-pr-plan.sh then skips the build: PR_HEAD_FAST_LANE builds the head itself
(checkout_ref is the head SHA, never the merge ref), so a second build of the same SHA makes the same bytes, and
the merge's finder (cmux_machine_channel_pr_head.py find) takes any run of that head with both artifacts.

The same head is handed to land more than once: ready-to-land and full-ci are each a land handoff, a label
removed and added again is another, and land re-queues a head. 3 of 3 sampled repeat builds on 2026-11-26
17Z..20Z were the same head SHA (226e3e16, f5164426, ce9d5838), 17-22 min a leg each.

Any miss or error prints nothing and the plan builds as before. Env: GH_TOKEN (the route job's token, actions:
read), GITHUB_REPOSITORY.

Leo, 2026-11-23: "de facto, im asking for 99% fewer minutes of ci time, period."
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gh_http  # noqa: E402

TARGETS = ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")
ROUTER = "pr-router.yml"

Api = Callable[[str], object]


def github_api(repo: str, token: str) -> Api:
    def get(path: str) -> object:
        req = urllib.request.Request(
            f"https://api.github.com/repos/{repo}/{path}",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
        )
        try:
            # Asked again on a passing refusal (gh_http); a 401/404 or permission 403 raises at once.
            _, body, _ = gh_http.request(req, 20, raise_errors=True)
            return json.loads(body)
        except urllib.error.HTTPError as exc:
            body = exc.read(300).decode("utf-8", "replace").replace("\n", " ")
            raise RuntimeError(f"{path}: HTTP {exc.code}: {body}") from exc

    return get


def built(api: Api, head: str, prefix: str, exclude: int = 0) -> int | None:
    """The newest other pr-router run of this head with both machine channel artifacts, or None. One runs read,
    then one artifacts read a run, newest first, at most five runs."""
    want = {f"{prefix}cmux-tui-{t}" for t in TARGETS}
    runs = (api(f"actions/workflows/{ROUTER}/runs?head_sha={head}&event=pull_request&per_page=20") or {}).get(
        "workflow_runs", []
    )
    others = [r for r in runs if int(r.get("id", 0)) != exclude]
    for run in sorted(others, key=lambda r: r.get("id", 0), reverse=True)[:5]:
        names = {
            a.get("name")
            for a in (api(f"actions/runs/{run['id']}/artifacts?per_page=100") or {}).get("artifacts", [])
            if not a.get("expired")
        }
        if want <= names:
            return int(run["id"])
    return None


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("head")
    ap.add_argument("--exclude-run", type=int, default=0)
    ap.add_argument("--prefix", default="machine-channel-")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    args = ap.parse_args(argv)
    token = os.environ.get("GH_TOKEN", "")
    if not token or len(args.head) != 40:
        return 0
    try:
        run = built(github_api(args.repo, token), args.head, args.prefix, args.exclude_run)
    except Exception as exc:  # a miss builds, as before
        print(f"head-built: lookup failed: {exc}", file=sys.stderr)
        run = None
    if run:
        print(run)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
