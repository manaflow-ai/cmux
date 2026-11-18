#!/usr/bin/env python3
"""Is this cmux-tui artifacts push superseded, so its run can skip its work?

On 2026-10-14 the owned Macs' side lane had ~285 queued jobs, and 37% of the
queued cmux-tui artifacts runs were already superseded: 61 cmux-tui-pin-* merge
trees whose pull request had a newer head, and 24 lane-branch pushes whose
branch had moved. Nobody needs their trees: a pull request's same-tree checks
use its newest head's merge tree, and a branch's newest push publishes its own.

The workflow's concurrency group cannot drop them. A run is admitted into its
group as soon as it is queued, so GitHub replaces only a newer pending run, and
cancel-in-progress would also stop runs that are uploading. So a run asks this
script when it gets a runner (tree-preflight, before it claims its tree key)
and again when its daemon tests get a Mac, and skips its builds and daemon
tests when the answer is yes. It never cancels anything.

Superseded means, for a push event only:
  - a lane branch (any ref but main, feat-cmux-next, next-batch/* and
    cmux-tui-pin-*) whose head is no longer SHA;
  - a cmux-tui-pin-* ref at GitHub's merge commit for a pull request
    ("Merge <head> into <base>", made by cmux-next-pr-merge-tree.yml) whose
    pull request is open with a different head now, and no pull request has
    that head any more;
  - such a pin whose pull request merged into feat-cmux-next at that head, and
    no open pull request has it: feat-cmux-next's push of the merge tests its own tree, and the pin's
    daemon tests held the side lane for hours after the merge (2026-10-21);
  - a push to any other branch (not a trunk ref, see TRUNK_REFS) whose head is
    no open pull request's head, unless its head commit asks for the daemon
    tests (Cmux-Daemon-Tests: run) or a cmux-next dispatch asked for it. On
    2026-10-26 cp/*, lane/* and perf/* branches started about 215 cmux-tui
    artifacts runs an hour, 93% of them at a head no open pull request had,
    while the workflow token's hourly budget ran out, and only those three
    families got this rule. On 2026-11-02 the other families (fix/*,
    rust-migration/*, test/*, scratch/*, dogfood-train/*, base-red/* and the
    like) built about 85% of the non-trunk build minutes, and a fifth of the
    branches that built had no pull request at all. A pull request's same-tree
    checks read its own head's publication only while that head is open; fleet
    builds request a missing tree themselves (cmux-tui-tree-request.yml), so a
    head nobody opened a pull request for has no reader.
main and next-batch/* runs gate latest/ and nightly-next promotion and are
never superseded here, nor is a dispatch, a pull request run,
or a pin of anything other than a pull request merge commit (pin-cmux-tui.sh,
next_batch.py). With --key, a run that another run of the key deferred to
(a cmux-tui-tree-deferred-<key> artifact, tree-owner-wait) is not superseded:
that run waits for its tree.

Every API failure answers no: the run then does its work as before.

A lane branch's head is read over git (`git ls-remote` on CMUX_TUI_REF_REMOTE,
which the workflow sets to the repository's clone URL), not the REST API: a
git ref read spends none of the installation's GITHUB_TOKEN budget, which ran
out every hour on 2026-10-26 with this workflow at about 260 runs an hour.
Whether a pull request has the head is read the same way (refs/pull/*/head), not
commits/{sha}/pulls. Without CMUX_TUI_REF_REMOTE the REST reads are used, as before. For every
non-trunk branch the head is read first, so a moved branch is superseded
without the pull request and dispatch lookups.

A feat-cmux-next push yields (tree-preflight only, --yield-superseded-tree true, the
TREE_YIELD_SUPERSEDED repository variable, on unless it is 0) when its tree key is neither
the current feat-cmux-next tip's key nor the key of a nightly cut: nightly-next's head or
a pending promotion (a nightly.yml run "Promote nightly-next to <sha>" not completed yet).
On 2026-11-18 109 feat-cmux-next runs from 06:00Z to 11:10Z built 27 keys on a vCPU-capped
Linux pool, 5 legs of 16 vCPU each, and only 8 keys were cut; a cut waited 9 to 84 min for
its tree behind builds nothing read. Only the first attempt yields: a re-run (attempt 2+,
which cmux-tui-tree-request.yml starts for a build that needs the tree) builds. A tree
already published, a key script that differs between the compared commits, and any read
failure keep the run. A yielded run claims no key and builds nothing, like any superseded
push, so it ends a minute after it starts and never reads as an active publisher; a reader
that still needs its tree requests it (pin-cmux-tui.sh wait_for_tree).

Usage: cmux_tui_superseded_push.py --event E --ref REF --sha SHA [--key KEY --run-id ID]
       [--yield-superseded-tree true|false]
Environment: GH_TOKEN (contents, pull-requests and actions read),
GITHUB_REPOSITORY, GITHUB_API_URL (default https://api.github.com).
Prints the reason and writes stale=true|false to $GITHUB_OUTPUT. Exits 0.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

PROTECTED = ("refs/heads/main", "refs/heads/feat-cmux-next")
FEAT = "refs/heads/feat-cmux-next"
NIGHTLY = "refs/heads/nightly-next"
PROMOTE_TITLE = re.compile(r"Promote nightly-next to ([0-9a-f]{40})")
# The key script whose definition two commits must share for their keys to compare.
KEY_SCRIPT = "scripts/ci/cmux_tui_tree_key.py"
PIN_PREFIX = "refs/heads/cmux-tui-pin-"
# Trunk and integration refs keep the plain moved-branch rule: nightly-next and
# release-next are promoted only to published feat-cmux-next trees, and a
# feat-cmux-next-* integration branch is a base other heads build on. Every
# other branch publishes nothing unless an open pull request has that head (or
# a cmux-next dispatch or the Cmux-Daemon-Tests trailer asks for it).
TRUNK_REFS = ("refs/heads/nightly-next", "refs/heads/release-next")
TRUNK_PREFIXES = ("refs/heads/feat-cmux-next-",)


def needs_open_pull_request(ref: str) -> bool:
    """Whether a push of REF publishes only a head an open pull request (or a dispatch) asked for."""
    return (ref.startswith("refs/heads/") and ref not in TRUNK_REFS
            and not ref.startswith(TRUNK_PREFIXES) and not ref.startswith(PIN_PREFIX))


class ApiError(Exception):
    pass


def api(path: str) -> tuple[int, object]:
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    repo = os.environ["GITHUB_REPOSITORY"]
    request = urllib.request.Request(
        f"{base}/repos/{repo}/{path}",
        headers={
            "Authorization": f"Bearer {os.environ.get('GH_TOKEN', '')}",
            "Accept": "application/vnd.github+json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, json.loads(response.read().decode() or "null")
    except urllib.error.HTTPError as error:
        return error.code, None
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise ApiError(f"GET {path}: {error}") from error


def ls_remote(remote: str, *patterns: str) -> str:
    command = ["git"]
    token = os.environ.get("GH_TOKEN", "")
    if token and remote.startswith("https://"):
        basic = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        command += ["-c", f"http.extraHeader=Authorization: Basic {basic}"]
    command += ["ls-remote", remote, *patterns]
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=30, check=True).stdout
    except (OSError, subprocess.SubprocessError) as error:
        raise ApiError(f"git ls-remote {' '.join(patterns)}: {type(error).__name__}") from error


def has_pull_request_head(sha: str) -> bool | None:
    """Whether some pull request's head ref (refs/pull/N/head, over git) is SHA; None without
    CMUX_TUI_REF_REMOTE. The refs stay after a pull request closes and include forks', so a
    closed or fork pull request at SHA also keeps the run: a lookup that can only keep extra
    runs, at no REST cost (it replaced commits/{sha}/pulls, ~200 calls an hour)."""
    remote = os.environ.get("CMUX_TUI_REF_REMOTE", "")
    if not remote:
        return None
    listed = ls_remote(remote, "refs/pull/*/head")
    return any(line.partition("\t")[0] == sha for line in listed.splitlines())


def branch_head(branch: str) -> str | None:
    """BRANCH's head sha, or None when the branch does not exist."""
    remote = os.environ.get("CMUX_TUI_REF_REMOTE", "")
    if remote:
        listed = ls_remote(remote, "--heads", f"refs/heads/{branch}")
        for line in listed.splitlines():
            head, _, name = line.partition("\t")
            if name == f"refs/heads/{branch}" and re.fullmatch(r"[0-9a-f]{40}", head):
                return head
        return None
    status, data = api(f"git/ref/heads/{urllib.parse.quote(branch)}")
    if status == 404:
        return None
    if status != 200 or not isinstance(data, dict):
        raise ApiError(f"GET git/ref/heads/{branch}: HTTP {status}")
    return data.get("object", {}).get("sha", "")


def lane_verdict(ref: str, sha: str) -> tuple[bool, str]:
    branch = ref.removeprefix("refs/heads/")
    head = branch_head(branch)
    if head is None:
        return False, f"{branch} no longer exists; keeping the run"
    if head == sha:
        return False, f"{sha[:12]} is still the head of {branch}"
    return True, f"{branch} moved to {head[:12]}; its newest push publishes that tree"


def asks_for_daemon_tests(sha: str) -> bool:
    """Whether the checked-out head commit carries the trailer Cmux-Daemon-Tests: run (daemon-policy's opt-in)."""
    try:
        value = subprocess.run(
            ["git", "log", "-1", "--format=%(trailers:key=Cmux-Daemon-Tests,valueonly)", sha],
            capture_output=True, text=True, timeout=20, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return "".join(value.split()).lower() == "run"


def unreviewed_verdict(ref: str, sha: str) -> tuple[bool, str] | None:
    """Superseded when no open pull request of this repository has SHA at its head; None asks lane_verdict."""
    if asks_for_daemon_tests(sha):
        return None
    has_pull = has_pull_request_head(sha)
    if has_pull:
        return None
    if has_pull is None:
        status, data = api(f"commits/{sha}/pulls?per_page=100")
        if status != 200 or not isinstance(data, list):
            raise ApiError(f"GET commits/{sha}/pulls: HTTP {status}")
        repo = os.environ["GITHUB_REPOSITORY"]
        if any(pr.get("state") == "open" and (pr.get("head") or {}).get("sha") == sha
               and ((pr.get("head") or {}).get("repo") or {}).get("full_name") == repo for pr in data):
            return None
    # A cmux-next dispatch on the branch (#22303) probes this exact commit's tree with no base fallback,
    # so a head some dispatch already asked about keeps its publisher.
    status, data = api(f"actions/workflows/cmux-next.yml/runs?head_sha={sha}&event=workflow_dispatch&per_page=1")
    if status != 200 or not isinstance(data, dict):
        raise ApiError(f"GET cmux-next.yml dispatches of {sha}: HTTP {status}")
    if data.get("total_count") or data.get("workflow_runs"):
        return None
    branch = ref.removeprefix("refs/heads/")
    return True, (f"no open pull request has {sha[:12]} ({branch}) at its head and no cmux-next dispatch "
                  "asked for it; a pull request's same-tree checks use its merge tree or the base tree. "
                  "To publish this tree anyway, add the trailer Cmux-Daemon-Tests: run, dispatch "
                  "cmux-tui-artifacts.yml on the branch, or dispatch cmux-next.yml before pushing")


def pin_verdict(sha: str) -> tuple[bool, str]:
    # Both jobs check out at depth 1, where git shows the pin commit without
    # parents (run 38608893139), so the parents and subject come from the API.
    status, data = api(f"commits/{sha}")
    if status != 200 or not isinstance(data, dict):
        raise ApiError(f"GET commits/{sha}: HTTP {status}")
    parents = [str((parent or {}).get("sha", "")) for parent in data.get("parents") or []]
    subject = str((data.get("commit") or {}).get("message") or "").partition("\n")[0].strip()
    if len(parents) != 2 or subject != f"Merge {parents[1]} into {parents[0]}":
        return False, "the pin is not a pull request merge commit; keeping the run"
    head = parents[1]
    status, data = api(f"commits/{head}/pulls?per_page=100")
    if status != 200 or not isinstance(data, list):
        raise ApiError(f"GET commits/{head}/pulls: HTTP {status}")
    repo = os.environ["GITHUB_REPOSITORY"]
    owners = [pr for pr in data if pr.get("head", {}).get("sha") == head]
    if any(pr.get("state") == "open" for pr in owners):
        return False, f"{head[:12]} is still a pull request head"
    merged = [pr for pr in owners if pr.get("merged_at") and (pr.get("base") or {}).get("ref") == "feat-cmux-next"
              and (pr.get("head", {}).get("repo") or {}).get("full_name") == repo]
    if merged:
        return True, f"#{merged[0].get('number')} merged at {head[:12]}; feat-cmux-next's push of it tests its own tree"
    if owners:
        return False, f"{head[:12]} is the head of a pull request closed without merging; keeping the run"
    moved = [pr for pr in data if pr.get("state") == "open"
             and (pr.get("head", {}).get("repo") or {}).get("full_name") == repo]
    if not moved:
        return False, f"no open pull request has {head[:12]}; keeping the run"
    pr = moved[0]
    return True, f"#{pr.get('number')} moved from {head[:12]} to {pr['head']['sha'][:12]}; its newer merge tree is pinned on its own"


def heads(remote: str, *refs: str) -> dict[str, str]:
    """REF -> head sha for each of REFS that exists, in one git ls-remote."""
    found = {}
    for line in ls_remote(remote, *refs).splitlines():
        head, _, name = line.partition("\t")
        if name in refs and re.fullmatch(r"[0-9a-f]{40}", head):
            found[name] = head
    return found


def pending_promotions() -> list[str]:
    """The commits of nightly.yml promotion runs on main that have not completed: the next cuts."""
    status, data = api("actions/workflows/nightly.yml/runs?event=workflow_dispatch&branch=main&per_page=30")
    if status != 200 or not isinstance(data, dict):
        raise ApiError(f"GET nightly.yml dispatch runs: HTTP {status}")
    found = []
    for run in data.get("workflow_runs") or []:
        match = PROMOTE_TITLE.fullmatch(str(run.get("display_title") or run.get("name") or ""))
        if match and run.get("status") != "completed":
            found.append(match.group(1))
    return found


def tree_key_of(sha: str) -> str:
    try:
        key = subprocess.run([sys.executable, KEY_SCRIPT, "--version", "v2", sha], capture_output=True, text=True,
                             timeout=60, check=True).stdout.strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise ApiError(f"tree key of {sha[:12]}: {type(error).__name__}") from error
    if not re.fullmatch(r"[0-9a-f]{40}", key):
        raise ApiError(f"tree key of {sha[:12]} is not 40-hex")
    return key


def tree_published(key: str) -> bool:
    """Whether tree KEY's completion manifest is on the CDN (publish-cmux-tui-tree.py writes it last)."""
    base = os.environ.get("CMUX_TUI_PIN_BASE", "https://files.cmux.com/cmux-tui").rstrip("/")
    try:
        result = subprocess.run(["curl", "--head", "--fail", "--silent", "--connect-timeout", "5", "--max-time", "15",
                                 "-o", "/dev/null", f"{base}/tree/{key}/completion.json?yield=1"], timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        raise ApiError(f"tree {key[:12]} publication: {type(error).__name__}") from error
    if result.returncode == 22:
        return False
    if result.returncode != 0:
        raise ApiError(f"tree {key[:12]} publication: curl exit {result.returncode}")
    return True


def fetch_commits(remote: str, shas: list[str]) -> None:
    command = ["git"]
    token = os.environ.get("GH_TOKEN", "")
    if token and remote.startswith("https://"):
        basic = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        command += ["-c", f"http.extraHeader=Authorization: Basic {basic}"]
    command += ["fetch", "-q", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head", "--depth=1", remote,
                *shas]
    try:
        subprocess.run(command, capture_output=True, timeout=45, check=True)
    except (OSError, subprocess.SubprocessError) as error:
        raise ApiError(f"git fetch of the compared commits: {type(error).__name__}") from error


def yield_verdict(sha: str) -> tuple[bool, str]:
    """Whether this feat-cmux-next push's unstarted tree build yields: its key is neither the tip's nor a cut's."""
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "1")
    if attempt not in ("", "1"):
        return False, f"attempt {attempt} is a re-run (cmux-tui-tree-request.yml asks for one); it builds"
    remote = os.environ.get("CMUX_TUI_REF_REMOTE", "")
    if not remote:
        return False, "no CMUX_TUI_REF_REMOTE to read the feat-cmux-next and nightly-next heads; keeping the run"
    found = heads(remote, FEAT, NIGHTLY)
    tip = found.get(FEAT, "")
    if not tip:
        raise ApiError("feat-cmux-next has no head")
    if tip == sha:
        return False, f"{sha[:12]} is the feat-cmux-next tip"
    cuts = {name: head for name, head in (("nightly-next", found.get(NIGHTLY, "")),) if head}
    for pending in pending_promotions():
        cuts.setdefault(f"pending promotion {pending[:12]}", pending)
    if sha in cuts.values():
        return False, f"{sha[:12]} is a nightly cut"
    key = tree_key_of(sha)
    if tree_published(key):
        return False, f"tree {key[:12]} is published; the run only writes this commit's manifest"
    compared = {"the feat-cmux-next tip": tip, **cuts}
    fetch_commits(remote, sorted(set(compared.values())))
    for what, other in compared.items():
        if subprocess.run(["git", "diff", "--quiet", sha, other, "--", KEY_SCRIPT], capture_output=True,
                          timeout=30).returncode != 0:
            return False, f"{what} ({other[:12]}) has another {KEY_SCRIPT}; keys do not compare, keeping the run"
        if tree_key_of(other) == key:
            return False, f"tree {key[:12]} is the key of {what} ({other[:12]})"
    names = ", ".join(f"{what} {other[:12]}" for what, other in compared.items())
    return True, (f"tree {key[:12]} is neither the feat-cmux-next tip's nor a nightly cut's ({names}); its unstarted "
                  "build yields to theirs. A build that needs this tree asks cmux-tui-tree-request.yml, whose re-run "
                  "builds it; TREE_YIELD_SUPERSEDED=0 turns the yield off")


def deferred_to(key: str, run_id: str) -> str:
    """A run of the key that deferred to this one, or ""."""
    status, data = api(f"actions/artifacts?name=cmux-tui-tree-deferred-{key}&per_page=100")
    if status != 200 or not isinstance(data, dict):
        raise ApiError(f"GET deferred artifacts of {key}: HTTP {status}")
    for artifact in data.get("artifacts", []):
        other = str((artifact.get("workflow_run") or {}).get("id", ""))
        if not artifact.get("expired") and other and other != run_id:
            return other
    return ""


def verdict(event: str, ref: str, sha: str, key: str, run_id: str,
            yield_superseded_tree: bool = False) -> tuple[bool, str]:
    if event != "push":
        return False, f"a {event} run is never superseded here"
    if ref == FEAT and yield_superseded_tree:
        return yield_verdict(sha)
    if ref in PROTECTED or ref.startswith("refs/heads/next-batch/"):
        return False, f"{ref} gates promotion; its runs are kept"
    if needs_open_pull_request(ref):
        # A moved branch is superseded whatever its pull requests say, so its
        # head (a free git read) goes first and the API lookups only follow
        # for a current head or a deleted branch.
        stale, reason = lane_verdict(ref, sha)
        if not stale:
            unreviewed = unreviewed_verdict(ref, sha)
            if unreviewed is not None:
                stale, reason = unreviewed
    else:
        stale, reason = pin_verdict(sha) if ref.startswith(PIN_PREFIX) else lane_verdict(ref, sha)
    if stale and key:
        waiting = deferred_to(key, run_id)
        if waiting:
            return False, f"{reason}, but run {waiting} deferred tree {key[:12]} to this run; keeping it"
    return stale, reason


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--event", required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--key", default="")
    parser.add_argument("--run-id", default="")
    parser.add_argument("--yield-superseded-tree", default="false",
                        help="true in tree-preflight unless TREE_YIELD_SUPERSEDED is 0")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[0-9a-f]{40}", args.sha) or (args.key and not re.fullmatch(r"[0-9a-f]{40}", args.key)):
        print("error: --sha and --key must be 40-hex", file=sys.stderr)
        return 2
    try:
        stale, reason = verdict(args.event, args.ref, args.sha, args.key, args.run_id,
                                args.yield_superseded_tree == "true")
    except (ApiError, KeyError) as error:
        stale, reason = False, f"could not tell ({error}); keeping the run"
        print(f"::warning title=superseded check::{reason}")
    if stale and args.ref == FEAT:
        print(f"::notice title=tree build yielded::{args.sha[:12]} yields: {reason}. This run skips its builds and daemon tests.")
    elif stale:
        print(f"::notice title=superseded push::{args.sha[:12]} is superseded: {reason}. This run skips its builds and daemon tests.")
    else:
        print(f"Not superseded: {reason}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"stale={'true' if stale else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
