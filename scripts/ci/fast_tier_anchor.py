#!/usr/bin/env python3
"""Decide whether a feat-cmux-next push runs the fast tier, from the last FINISHED one.

A push's fast tier can end without a verdict: GitHub's job concurrency group
replaces a pending fast tier with the next push's, and the push head preflight
skips it on a push that is no longer the branch head. So the commits since the
previous push are not what still needs testing. What needs testing is
everything since the last push whose fast tier finished (success or failure,
never cancelled or skipped). On 2026-10-30 no run containing c5dd001a (#27931,
a generated SettingsSchema Swift file) finished the fast tier: runs
41012836913 and 41013125180 had it replaced while pending, and 41014687570
skipped it.

A push's fast tier that finishes uploads a marker artifact with a fixed name
(MARKER, the fast-tier job's last step). This script lists those markers (one
REST call; path_route already has `actions: read`), takes the newest one from a feat-cmux-next push
of this repository whose commit is an ancestor of this push, and routes the
diff from that commit to this push with the pull request router
(scripts/ci/cmux_next_route.py): the fast tier runs when that diff reaches a
Mac tier, as it does for a pull request.

Fail open: no token, an API or git error, no marker, or no marker on this
push's history prints why and runs the fast tier.

Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

from cmux_next_route import ROOT, outputs, route  # noqa: E402

BRANCH = "feat-cmux-next"
# The artifact a finished push fast tier uploads (.github/workflows/cmux-next.yml).
MARKER = "cmux-next-fast-tier-finished"
# Markers read, newest first. Artifacts last one day; at a push a minute the
# newest finished one is near the top.
MAX_MARKERS = 30
# Commits of the push's history fetched to find the marker's commit on it.
HISTORY_DEPTH = 3000
SHA = re.compile(r"[0-9a-f]{40}")

# Newest first: (head sha, run id) of finished push fast tiers.
Markers = Callable[[], list[tuple[str, int]]]


class Skip(Exception):
    """The anchor does not apply; the fast tier runs. The message says why."""


@dataclass
class Decision:
    fast_tier: bool
    reason: str
    anchor: str = ""
    changed: list[str] = field(default_factory=list)


class Git:
    def __init__(self, cwd: Path, remote: str = "origin") -> None:
        self.cwd = cwd
        self.remote = remote

    def run(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-c", "maintenance.auto=false", "-c", "gc.auto=0", *args],
            cwd=self.cwd, check=True, capture_output=True, text=True,
        ).stdout

    def succeeds(self, *args: str) -> bool:
        return subprocess.run(["git", *args], cwd=self.cwd, capture_output=True, text=True).returncode == 0

    def is_shallow(self) -> bool:
        return self.run("rev-parse", "--is-shallow-repository").strip() == "true"

    def deepen(self, head: str) -> None:
        """Commits only (no trees) of the push's history, in a shallow checkout."""
        if self.is_shallow():
            self.run("fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--filter=tree:0",
                     f"--deepen={HISTORY_DEPTH}", self.remote, head)

    def has_commit(self, oid: str) -> bool:
        return self.succeeds("cat-file", "-e", f"{oid}^{{commit}}")

    def is_ancestor(self, ancestor: str, descendant: str) -> bool:
        return self.succeeds("merge-base", "--is-ancestor", ancestor, descendant)

    def changed(self, base: str, head: str) -> list[str]:
        # Trees (not blobs) of the anchor, which a tree:0 history fetch left out.
        if not self.succeeds("cat-file", "-e", f"{base}^{{tree}}"):
            self.run("fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--filter=blob:none",
                     "--depth=1", self.remote, base)
        output = self.run("diff", "--no-renames", "--name-only", base, head)
        return sorted(line for line in output.splitlines() if line.strip())


def short(oid: str) -> str:
    return oid[:12]


def markers_from(artifacts: Iterable[dict], repository_id: Optional[int]) -> list[tuple[str, int]]:
    """(head sha, run id) of finished feat-cmux-next push fast tiers, newest first.

    Only this repository's own runs on feat-cmux-next count: a pull request
    run that uploads an artifact of the same name names its own branch, and a
    fork's names its own repository. Expired artifacts are kept: the marker is
    its name and run, not its contents.
    """
    found: list[tuple[str, str, int]] = []
    for artifact in artifacts:
        run = artifact.get("workflow_run") or {}
        sha = run.get("head_sha") or ""
        run_id = run.get("id")
        if artifact.get("name") != MARKER or run.get("head_branch") != BRANCH:
            continue
        if repository_id is not None and (run.get("repository_id") != repository_id
                                          or run.get("head_repository_id") != repository_id):
            continue
        if SHA.fullmatch(sha) and isinstance(run_id, int):
            found.append((artifact.get("created_at") or "", sha, run_id))
    found.sort(key=lambda item: item[0], reverse=True)
    return [(sha, run_id) for _, sha, run_id in found]


def decide(git: Git, head: str, markers: Markers, root: Path = ROOT) -> Decision:
    if not SHA.fullmatch(head):
        raise Skip(f"the head {head!r} is not a full sha")
    finished = markers()
    if not finished:
        raise Skip("no finished feat-cmux-next push fast tier on record")
    git.deepen(head)
    anchor: Optional[tuple[str, int]] = None
    for sha, run_id in finished:
        if git.has_commit(sha) and git.is_ancestor(sha, head):
            anchor = (sha, run_id)
            break
    if anchor is None:
        raise Skip(f"none of the {len(finished)} finished push fast tiers is on {short(head)}'s history")
    sha, run_id = anchor
    changed = git.changed(sha, head)
    if not changed:
        # The same tree finished already; a re-run asks again on purpose.
        return Decision(True, f"no change since the fast tier finished on {short(sha)} (run {run_id}): it runs again",
                        sha, changed)
    result = route(root, "pull_request", changed, set())
    # The push Mac job is gated by fast_tier, which can be false for a daemon
    # or app-host-only diff even when another Mac tier is needed.
    reach = outputs(result)["fast_tier"] == "true"
    listed = ", ".join(changed[:5]) + (f" and {len(changed) - 5} more" if len(changed) > 5 else "")
    verb = "reach a Mac tier: the fast tier runs" if reach else "reach no Mac tier: the fast tier skips"
    return Decision(reach, f"{len(changed)} files since the fast tier finished on {short(sha)} "
                           f"(run {run_id}) {verb} ({listed})", sha, changed)


def github_markers(repository: str, token: str) -> Markers:
    api = os.environ.get("GITHUB_API_URL") or "https://api.github.com"

    def call(url: str) -> dict:
        request = urllib.request.Request(url, headers={
            "Authorization": f"bearer {token}", "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)

    def lookup() -> list[tuple[str, int]]:
        # The runner names this repository's id; one REST call lists the markers.
        repository_id = os.environ.get("GITHUB_REPOSITORY_ID", "")
        if not repository_id.isdigit():
            raise Skip("GITHUB_REPOSITORY_ID is not set, so a marker's repository cannot be checked")
        artifacts = call(f"{api}/repos/{repository}/actions/artifacts?name={MARKER}&per_page={MAX_MARKERS}")
        return markers_from(artifacts.get("artifacts") or [], int(repository_id))

    return lookup


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--head", required=True, help="the pushed commit")
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
    parser.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    args = parser.parse_args(argv)

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    try:
        if not token or "/" not in args.repository:
            raise Skip("no token or repository to read the finished fast tiers with")
        decision = decide(Git(Path.cwd()), args.head, github_markers(args.repository, token))
    except Skip as skip:
        decision = Decision(True, f"the fast tier runs: {skip}")
    except Exception as error:  # noqa: BLE001 - any failure runs the fast tier
        detail = (getattr(error, "stderr", "") or "").strip()
        decision = Decision(True, f"the fast tier runs: the anchor lookup failed ({error} {detail})".strip())

    print(f"fast tier anchor: {decision.reason}")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write(f"fast_tier={'true' if decision.fast_tier else 'false'}\n")
            handle.write(f"fast_tier_anchor={decision.anchor}\n")
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write(f"**Push fast tier:** {decision.reason}\n\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
