#!/usr/bin/env python3
"""Whether an earlier pr-router run already built this pull request head's machine channel pair.

`cmux_machine_channel_head_built.py HEAD_SHA [--exclude-run ID] [--key KEY --branch REF]` prints the newest other
pr-router run (event pull_request, this head SHA) whose machine-channel-cmux-tui-<target> artifacts are both there and
unexpired, or nothing. With --key and --branch, a miss on this SHA then reads the branch's earlier heads: a run of one
whose v2 tree key (cmux_tui_tree_key.py) is KEY built the same cmux-tui inputs, so it is taken too. scripts/ci/cmux-machine-channel-pr-plan.sh then skips the build: PR_HEAD_FAST_LANE builds the head itself
(checkout_ref is the head SHA, never the merge ref), so a second build of the same SHA makes the same bytes, and
the merge's finder (cmux_machine_channel_pr_head.py find) takes any run of that head with both artifacts.

The same head is handed to land more than once: ready-to-land and full-ci are each a land handoff, a label
removed and added again is another, and land re-queues a head. 3 of 3 sampled repeat builds on 2026-11-26
17Z..20Z were the same head SHA (226e3e16, f5164426, ce9d5838), 17-22 min a leg each.

A base merge (update-branch, the land queue's own) makes a new head SHA. When the base moved nothing the key reads,
that head's tree key is its earlier head's, yet the SHA lookup missed and both legs built again: the two PR head
build jobs were 58.8k runner-min in 24 h on 2026-11-26 (aarch64 30.2k, x86_64 28.6k), the fattest job pair in cmux
CI. The earlier-head read is at most ARTIFACT_READS artifact lists and KEY_READS keys (each a depth-1 fetch).

Any miss or error prints nothing and the plan builds as before. Env: GH_TOKEN (the route job's token, actions:
read), GITHUB_REPOSITORY.

Leo, 2026-11-23: "de facto, im asking for 99% fewer minutes of ci time, period."
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gh_http  # noqa: E402

TARGETS = ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")
ROUTER = "pr-router.yml"
ROOT = Path(__file__).resolve().parents[2]
SHA = re.compile(r"^[0-9a-f]{40}$")
ARTIFACT_READS = 6
KEY_READS = 3

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


def has_both(api: Api, run_id: int, prefix: str) -> bool:
    want = {f"{prefix}cmux-tui-{t}" for t in TARGETS}
    names = {
        a.get("name")
        for a in (api(f"actions/runs/{run_id}/artifacts?per_page=100") or {}).get("artifacts", [])
        if not a.get("expired")
    }
    return want <= names


def tree_key(rev: str) -> str:
    """REV's v2 tree key, fetching REV at depth 1 first when the checkout is shallow (the route job's), or ''."""
    try:
        shallow = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "--is-shallow-repository"],
            check=False, capture_output=True, text=True, timeout=30,
        ).stdout.strip() == "true"
        subprocess.run(
            ["git", "-C", str(ROOT), "fetch", "--no-tags", *(["--depth=1"] if shallow else []), "origin", rev],
            check=False, capture_output=True, timeout=30,
        )
        out = subprocess.run(
            [sys.executable, "-I", str(ROOT / "scripts/ci/cmux_tui_tree_key.py"), "--version", "v2", rev],
            check=False, capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    key = out.stdout.strip() if out.returncode == 0 else ""
    return key if SHA.match(key) else ""


def built(api: Api, head: str, prefix: str, exclude: int = 0, key: str = "", branch: str = "",
          key_of: Callable[[str], str] = tree_key) -> int | None:
    """The newest other pr-router run of this head with both machine channel artifacts, else (KEY and BRANCH given)
    the newest run of an earlier head of BRANCH with both whose v2 tree key is KEY, or None. One runs read, then one
    artifacts read a run, newest first, at most five runs; the earlier heads cost one more runs read."""
    runs = (api(f"actions/workflows/{ROUTER}/runs?head_sha={head}&event=pull_request&per_page=20") or {}).get(
        "workflow_runs", []
    )
    others = [r for r in runs if int(r.get("id", 0)) != exclude]
    for run in sorted(others, key=lambda r: r.get("id", 0), reverse=True)[:5]:
        if has_both(api, int(run["id"]), prefix):
            return int(run["id"])
    if not SHA.match(key or "") or not branch:
        return None
    q = urllib.parse.quote(branch, safe="")
    earlier = (api(f"actions/workflows/{ROUTER}/runs?branch={q}&event=pull_request&per_page=30") or {}).get(
        "workflow_runs", []
    )
    artifact_reads, keyed = 0, {}
    for run in sorted(earlier, key=lambda r: r.get("id", 0), reverse=True):
        sha = run.get("head_sha") or ""
        if int(run.get("id", 0)) == exclude or sha == head or not SHA.match(sha) or keyed.get(sha) is False:
            continue
        if artifact_reads >= ARTIFACT_READS:
            break
        artifact_reads += 1
        if not has_both(api, int(run["id"]), prefix):
            continue
        if sha not in keyed:
            if len(keyed) >= KEY_READS:
                break
            keyed[sha] = key_of(sha) == key
        if keyed[sha]:
            print(f"head-built: run {run['id']} built earlier head {sha}, tree key {key}", file=sys.stderr)
            return int(run["id"])
    return None


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("head")
    ap.add_argument("--exclude-run", type=int, default=0)
    ap.add_argument("--prefix", default="machine-channel-")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    ap.add_argument("--key", default="", help="this head's v2 tree key: an earlier head with it counts")
    ap.add_argument("--branch", default="", help="the head's branch, whose earlier heads are read with --key")
    args = ap.parse_args(argv)
    token = os.environ.get("GH_TOKEN", "")
    if not token or len(args.head) != 40:
        return 0
    try:
        run = built(github_api(args.repo, token), args.head, args.prefix, args.exclude_run, args.key, args.branch)
    except Exception as exc:  # a miss builds, as before
        print(f"head-built: lookup failed: {exc}", file=sys.stderr)
        run = None
    if run:
        print(run)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
