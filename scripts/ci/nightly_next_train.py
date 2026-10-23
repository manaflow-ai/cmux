#!/usr/bin/env python3
"""The cmux NEXT nightly release train: cars, candidates and verdicts.

Design: leo-workspace workstreams/cmux-next-nightly-train.md (sections 1.1 to
1.5); the operator notes are in docs/ci/nightly-next-train.md.

  verdict --build B --verdict pass|fail|skipped --commit SHA --run-url URL --out FILE
      Write the durable canary verdict of one feed build (verdicts/<build>.json
      next to the cmux NEXT appcast in R2; nightly-next-verdict.yml uploads it).

  verdict-check --repo R --build B --verdict V --canary-run ID --out FILE
      The same document, for nightly-next-verdict.yml: the commit is read from
      the build's own nightly-next run, and `pass` needs canary run ID to be a
      scheduled nightly-next-canary.yml run of R whose `canary B` job passed.

  base [--feed URL] [--verdicts URL] [--good-build B]
      The last good nightly: the newest feed build whose durable verdict is
      `pass`. Prints {"build", "commit", "source"}; with no passing verdict yet
      the base is nightly-next's head ("source": "nightly-next").

  plan --tip SHA [--base-commit SHA] [--repo OWNER/REPO] [--out train.json]
      List the cars of base..tip: one car per squash-merged PR, one per direct
      push (before..after of the push event), and the cars a base train commit
      quarantined (they are still not in the base, so a fixed car rejoins on
      its own). Labels: `nightly-hold` keeps a car out, `nightly-retry` is
      recorded for the triage step.

  candidate --tip SHA --parent SHA --quarantine CAR[,CAR] --train train.json [--out FILE]
      Make a train commit: two parents (the current nightly-next head, then the
      tip), its tree the tip with the quarantined cars reverted. A revert that
      does not apply pulls in the later cars that touch the same files
      ("quarantined with ...").

  verify --commit SHA [--fetch]
      Recompute a train commit's tree from its second parent and its
      `Nightly-Train-Revert:` trailers and compare (promote guard G1').
      --fetch first fetches the commit, its parents and each revert with its
      parent (blobless; blobs load on demand), for a sparse guard checkout.

Run inside a checkout of manaflow-ai/cmux. `gh` is the GitHub client.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from typing import Callable, Iterable

SOURCE = "feat-cmux-next"
TARGET = "nightly-next"
FEED = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
VERDICTS = "https://files-next.cmux.com/nightly-next/next/verdicts"
TRAILER = "Nightly-Train: v1"
REVERT_TRAILER = "Nightly-Train-Revert:"
CAR_TRAILER = "Nightly-Train-Car:"
HOLD_LABEL = "nightly-hold"
RETRY_LABEL = "nightly-retry"
VERDICTS_ALLOWED = ("pass", "fail", "skipped")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
PR_SUBJECT = re.compile(r"\(#(\d+)\)\s*$")
MAX_ACTIVITY_PAGES = 20


class TrainError(Exception):
    pass


# ---------------------------------------------------------------- git / gh

def git(*args: str, input: str | None = None, check: bool = True, env: dict | None = None) -> str:
    proc = subprocess.run(
        ["git", *args], input=input, capture_output=True, text=True,
        env={**os.environ, **(env or {})},
    )
    if check and proc.returncode != 0:
        raise TrainError(f"git {' '.join(args)} failed ({proc.returncode}): {proc.stderr.strip()[:2000]}")
    return proc.stdout


def gh_api(path: str, paginate: bool = False) -> object:
    args = ["gh", "api", "-H", "Accept: application/vnd.github+json", path]
    if paginate:
        args[2:2] = ["--paginate", "--slurp"]
    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode != 0:
        raise TrainError(f"gh api {path} failed: {proc.stderr.strip()[:500]}")
    data = json.loads(proc.stdout or "null")
    if paginate and isinstance(data, list) and data and isinstance(data[0], list):
        return [item for page in data for item in page]
    return data


def http_get(url: str) -> bytes | None:
    """The body, or None on a 404 (a build with no verdict yet)."""
    request = urllib.request.Request(url, headers={"User-Agent": "cmux-nightly-next-train/1", "Cache-Control": "no-cache"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code in (403, 404):
            return None
        raise


# ---------------------------------------------------------------- verdicts

def verdict_document(build: str, verdict: str, commit: str, run_url: str, now: Callable[[], str] | None = None,
                     repo: str = "manaflow-ai/cmux") -> dict:
    if not build.isdigit():
        raise TrainError(f"build {build!r} is not a number")
    if verdict not in VERDICTS_ALLOWED:
        raise TrainError(f"verdict {verdict!r} is not one of {', '.join(VERDICTS_ALLOWED)}")
    if not SHA_RE.match(commit):
        raise TrainError(f"commit {commit!r} is not 40 lowercase hex characters")
    if not re.fullmatch(rf"https://github\.com/{re.escape(repo)}/actions/runs/\d+", run_url):
        raise TrainError(f"run url {run_url!r} is not a {repo} Actions run")
    stamp = (now or (lambda: _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")))()
    return {"schema": 1, "build": build, "verdict": verdict, "commit": commit, "canaryRun": run_url, "checkedAt": stamp}


CANARY_WORKFLOW = ".github/workflows/nightly-next-canary.yml"


def build_commit(api: Callable[..., object], repo: str, build: str) -> str | None:
    """The nightly-next commit of a build (nightly_next_fix_forward.build_commit)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import nightly_next_fix_forward as fix_forward  # noqa: PLC0415

    try:
        return fix_forward.build_commit(api, repo, build)
    except ValueError as error:
        raise TrainError(str(error)) from error


def checked_verdict(api: Callable[..., object], repo: str, build: str, verdict: str, canary_run: str,
                    now: Callable[[], str] | None = None) -> dict:
    """verdict_document() after checking the canary run and reading the commit."""
    if not canary_run.isdigit():
        raise TrainError(f"canary run {canary_run!r} is not a run id")
    if verdict not in VERDICTS_ALLOWED:
        raise TrainError(f"verdict {verdict!r} is not one of {', '.join(VERDICTS_ALLOWED)}")
    commit = build_commit(api, repo, build)
    if not commit:
        raise TrainError(f"build {build} has no nightly-next run in {repo}, so no commit")
    run = api(f"repos/{repo}/actions/runs/{canary_run}")
    if not isinstance(run, dict) or run.get("path") != CANARY_WORKFLOW or (run.get("repository") or {}).get("full_name") != repo:
        raise TrainError(f"run {canary_run} is not a {CANARY_WORKFLOW} run of {repo}")
    if verdict == "pass":
        if run.get("event") != "schedule":
            raise TrainError(f"a pass needs a scheduled canary run; run {canary_run} is a {run.get('event')} run")
        jobs = api(f"repos/{repo}/actions/runs/{canary_run}/jobs?filter=latest&per_page=100")
        names = [j for j in (jobs or {}).get("jobs", []) if j.get("name") == f"canary {build}"]  # type: ignore[union-attr]
        if not any(j.get("status") == "completed" and j.get("conclusion") == "success" for j in names):
            raise TrainError(f"run {canary_run} has no successful `canary {build}` job, so no pass")
        # The canary job also succeeds when it skipped (a build that predates
        # the canary); the run's own verdict job carries the real verdict in
        # its name (nightly-next-canary.yml job `verdict`).
        if not any(j.get("name") == f"verdict pass {build}" for j in (jobs or {}).get("jobs", [])):  # type: ignore[union-attr]
            raise TrainError(f"run {canary_run} recorded no pass for build {build}")
    return verdict_document(build, verdict, commit, f"https://github.com/{repo}/actions/runs/{canary_run}", now, repo)


FEED_ITEM = re.compile(r"<item>.*?</item>", re.S)
FEED_VERSION = re.compile(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>")


def feed_builds(feed_xml: str) -> list[str]:
    builds = []
    for item in FEED_ITEM.findall(feed_xml):
        version = FEED_VERSION.search(item)
        if version:
            builds.append(version.group(1))
    return sorted(set(builds), key=int, reverse=True)


def last_good(feed_xml: str, fetch: Callable[[str], bytes | None], verdicts_url: str = VERDICTS) -> dict | None:
    """The newest feed build whose verdict is pass: {"build", "commit"}."""
    for build in feed_builds(feed_xml):
        body = fetch(f"{verdicts_url}/{build}.json")
        if body is None:
            continue
        try:
            doc = json.loads(body)
        except ValueError:
            continue
        if doc.get("build") == build and doc.get("verdict") == "pass" and SHA_RE.match(str(doc.get("commit", ""))):
            return {"build": build, "commit": doc["commit"], "source": "verdict"}
    return None


# ---------------------------------------------------------------- train commits

@dataclass
class TrainCommit:
    sha: str
    parents: list[str]
    reverts: list[str]
    cars: list[str]


def parse_train_commit(sha: str, message: str, parents: list[str]) -> TrainCommit | None:
    lines = [line.strip() for line in message.splitlines()]
    if TRAILER not in lines:
        return None
    reverts = [line[len(REVERT_TRAILER):].strip() for line in lines if line.startswith(REVERT_TRAILER)]
    cars = [line[len(CAR_TRAILER):].strip() for line in lines if line.startswith(CAR_TRAILER)]
    for revert in reverts:
        if not SHA_RE.match(revert):
            raise TrainError(f"train commit {sha} has a bad revert trailer {revert!r}")
    return TrainCommit(sha=sha, parents=parents, reverts=reverts, cars=cars)


def read_train_commit(sha: str) -> TrainCommit | None:
    raw = git("cat-file", "commit", sha)
    header, _, message = raw.partition("\n\n")
    parents = [line.split()[1] for line in header.splitlines() if line.startswith("parent ")]
    return parse_train_commit(sha, message, parents)


def revert_onto(tree_commit: str, revert: str) -> tuple[str | None, list[str]]:
    """Revert `revert` (its change against its first parent) on top of
    `tree_commit`. Returns (new tree, []) or (None, conflicted paths)."""
    parent = git("rev-parse", f"{revert}^1").strip()
    proc = subprocess.run(
        ["git", "merge-tree", "--write-tree", "--name-only", "--no-messages",
         f"--merge-base={revert}", tree_commit, parent],
        capture_output=True, text=True,
    )
    lines = proc.stdout.splitlines()
    if proc.returncode == 0:
        return lines[0].strip(), []
    if proc.returncode == 1:
        return None, sorted({line.strip() for line in lines[1:] if line.strip()})
    raise TrainError(f"git merge-tree failed for the revert of {revert}: {proc.stderr.strip()[:500]}")


_SCRATCH_ENV = {
    "GIT_AUTHOR_NAME": "cmux nightly train", "GIT_AUTHOR_EMAIL": "nightly-train@cmux.invalid",
    "GIT_COMMITTER_NAME": "cmux nightly train", "GIT_COMMITTER_EMAIL": "nightly-train@cmux.invalid",
    "GIT_AUTHOR_DATE": "1700000000 +0000", "GIT_COMMITTER_DATE": "1700000000 +0000",
}


def apply_reverts(tip: str, reverts: Iterable[str]) -> tuple[str | None, str | None, list[str]]:
    """Revert each commit in order on top of tip. (tree, None, []) when all
    apply; (None, failing revert, conflicted paths) otherwise."""
    current = tip
    tree = git("rev-parse", f"{tip}^{{tree}}").strip()
    for revert in reverts:
        new_tree, conflicts = revert_onto(current, revert)
        if new_tree is None:
            return None, revert, conflicts
        tree = new_tree
        current = git("commit-tree", tree, "-p", current, "-m", f"scratch revert {revert}", env=_SCRATCH_ENV).strip()
    return tree, None, []


def fetch_for_verify(sha: str) -> None:
    """Fetch what verify needs into a shallow or sparse checkout: the
    commit's whole history without trees (the ancestor checks), trees and
    blobs on demand (the reverts)."""
    shallow = git("rev-parse", "--is-shallow-repository", check=False).strip() == "true"
    git("fetch", "--no-tags", "--quiet", "--filter=tree:0", *(["--unshallow"] if shallow else []), "origin", sha)


def verify_train_commit(sha: str) -> dict:
    if not SHA_RE.match(sha):
        return {"ok": False, "reason": f"{sha!r} is not 40 lowercase hex characters"}
    train = read_train_commit(sha)
    if train is None:
        return {"ok": False, "reason": f"{sha} has no `{TRAILER}` trailer"}
    if len(train.parents) != 2:
        return {"ok": False, "reason": f"train commit {sha} has {len(train.parents)} parents, not 2"}
    for revert in train.reverts:
        # A revert of a commit outside the tip's history would apply that
        # commit's change backwards: arbitrary code. Only the tip's own commits.
        if subprocess.run(["git", "merge-base", "--is-ancestor", revert, train.parents[1]], capture_output=True).returncode != 0:
            return {"ok": False, "reason": f"revert {revert} is not in the history of {train.parents[1]}"}
    tree, failed, _ = apply_reverts(train.parents[1], train.reverts)
    if tree is None:
        return {"ok": False, "reason": f"the revert of {failed} does not apply to {train.parents[1]}"}
    actual = git("rev-parse", f"{sha}^{{tree}}").strip()
    if tree != actual:
        return {"ok": False, "reason": f"the tree of {sha} ({actual}) is not {train.parents[1]} with its {len(train.reverts)} listed revert(s) ({tree})"}
    return {"ok": True, "reason": f"tree is {train.parents[1][:12]} minus {len(train.reverts)} revert(s)", "tip": train.parents[1], "reverts": train.reverts}


# ---------------------------------------------------------------- cars

@dataclass
class Car:
    id: str
    kind: str  # pr | push | commit | merge
    commits: list[str]  # oldest first
    owner: str = ""
    title: str = ""
    pr: int | None = None
    merger: str = ""
    labels: list[str] = field(default_factory=list)
    files: list[str] = field(default_factory=list)
    carried: bool = False

    @property
    def held(self) -> bool:
        return HOLD_LABEL in self.labels


def first_parent_range(base: str, tip: str) -> list[str]:
    out = git("rev-list", "--first-parent", "--reverse", f"{base}..{tip}")
    return [line for line in out.split() if line]


def commit_meta(sha: str) -> dict:
    out = git("show", "-s", "--format=%P%x00%an%x00%ae%x00%s", sha).rstrip("\n")
    parents, author, email, subject = out.split("\x00", 3)
    return {"parents": parents.split(), "author": author, "email": email, "subject": subject}


def changed_files(sha: str) -> list[str]:
    out = git("diff-tree", "--no-commit-id", "--name-only", "-r", "-m", "--first-parent", sha)
    return sorted({line for line in out.splitlines() if line})


def push_groups(api: Callable[..., object], repo: str, commits: list[str], boundary: str) -> dict[str, tuple[str, str]]:
    """commit -> (push id, push actor) from the repository activity of
    feat-cmux-next, for the commits of the range a push brought."""
    wanted = set(commits)
    position = {sha: index for index, sha in enumerate(commits)}
    found: dict[str, tuple[str, str]] = {}
    for page in range(1, MAX_ACTIVITY_PAGES + 1):
        try:
            events = api(f"repos/{repo}/activity?ref=refs/heads/{SOURCE}&per_page=100&page={page}")
        except TrainError:
            break
        if not events:
            break
        reached = False
        for event in events:
            after, before = event.get("after", ""), event.get("before", "")
            actor = (event.get("actor") or {}).get("login", "")
            if before == boundary:
                reached = True
            if after not in wanted:
                continue
            # The push brought the first-parent commits after `before` up to `after`.
            end = position[after]
            start = position[before] + 1 if before in position else 0
            if before not in position and before != boundary:
                start = end  # unknown lower bound: credit the tip only
            for sha in commits[start:end + 1]:
                found.setdefault(sha, (after, actor))
        if reached and len(found) >= len(wanted):
            break
        if len(events) < 100:
            break
    return found


MAX_PULL_PAGES = 10
MAX_PULL_LOOKUPS = 40


def merged_pulls(api: Callable[..., object], repo: str, numbers: set[int]) -> dict[int, dict]:
    """The closed PRs into feat-cmux-next, newest updated first, 100 a page,
    until every wanted number is seen: a day of cars costs a few calls, not
    one per PR (the plan runs on every tick, on the repository's token)."""
    found: dict[int, dict] = {}
    for page in range(1, MAX_PULL_PAGES + 1):
        if numbers <= found.keys():
            break
        try:
            pulls = api(f"repos/{repo}/pulls?state=closed&base={SOURCE}&sort=updated&direction=desc&per_page=100&page={page}")
        except TrainError:
            break
        if not isinstance(pulls, list):
            break
        for pull in pulls:
            if isinstance(pull, dict) and isinstance(pull.get("number"), int):
                found.setdefault(pull["number"], pull)
        if len(pulls) < 100:
            break
    return found


def pr_of(api: Callable[..., object], repo: str, sha: str, subject: str, known: dict[int, dict] | None = None,
          budget: list[int] | None = None) -> dict | None:
    match = PR_SUBJECT.search(subject)
    if not match:
        return None
    number = int(match.group(1))
    pull = (known or {}).get(number)
    if pull is None:
        if budget is not None:
            if budget[0] <= 0:
                return None
            budget[0] -= 1
        try:
            pull = api(f"repos/{repo}/pulls/{number}")
        except TrainError:
            return None
    if not isinstance(pull, dict) or pull.get("merge_commit_sha") != sha or not pull.get("merged_at"):
        return None
    return pull


def plan_cars(base: str, tip: str, repo: str, api: Callable[..., object] = gh_api, carried: Iterable[Car] = ()) -> list[Car]:
    commits = first_parent_range(base, tip)
    metas = {sha: commit_meta(sha) for sha in commits}
    cars: list[Car] = list(carried)
    pending_push: list[str] = []
    non_pr = [sha for sha in commits if not PR_SUBJECT.search(metas[sha]["subject"]) or len(metas[sha]["parents"]) > 1]
    pushes = push_groups(api, repo, commits, base) if non_pr else {}
    wanted = {int(m.group(1)) for m in (PR_SUBJECT.search(metas[sha]["subject"]) for sha in commits) if m}
    wanted |= {car.pr for car in cars if car.pr}
    known = merged_pulls(api, repo, wanted) if wanted else {}
    budget = [MAX_PULL_LOOKUPS]
    for car in cars:
        # A carried car keeps today's labels (nightly-hold), not none.
        pull = known.get(car.pr) if car.pr else None
        if pull is None and car.pr and budget[0] > 0:
            budget[0] -= 1
            try:
                pull = api(f"repos/{repo}/pulls/{car.pr}")
            except TrainError:
                pull = None
        if isinstance(pull, dict):
            car.labels = sorted(label.get("name", "") for label in pull.get("labels") or [])
            car.owner = car.owner or (pull.get("user") or {}).get("login", "")
            car.title = car.title or pull.get("title") or ""

    def flush() -> None:
        if not pending_push:
            return
        groups: dict[str, list[str]] = {}
        order: list[str] = []
        for sha in pending_push:
            key, _ = pushes.get(sha, (f"commit-{sha}", ""))
            if key not in groups:
                groups[key] = []
                order.append(key)
            groups[key].append(sha)
        for key in order:
            shas = groups[key]
            actor = pushes.get(shas[-1], ("", ""))[1]
            meta = metas[shas[-1]]
            if key.startswith("commit-"):
                cars.append(Car(id=f"commit-{shas[0][:12]}", kind="commit", commits=shas, owner=actor or meta["author"], title=meta["subject"]))
            else:
                cars.append(Car(id=f"push-{key[:12]}", kind="push", commits=shas, owner=actor or meta["author"], title=meta["subject"] if len(shas) == 1 else f"{len(shas)} commits: {meta['subject']}"))
        pending_push.clear()

    for sha in commits:
        meta = metas[sha]
        if len(meta["parents"]) > 1:
            flush()
            actor = pushes.get(sha, ("", ""))[1]
            cars.append(Car(id=f"merge-{sha[:12]}", kind="merge", commits=[sha], owner=actor or meta["author"], title=meta["subject"]))
            continue
        pull = pr_of(api, repo, sha, meta["subject"], known, budget)
        if pull is None:
            pending_push.append(sha)
            continue
        flush()
        cars.append(Car(
            id=f"pr-{pull['number']}", kind="pr", commits=[sha], pr=int(pull["number"]),
            owner=(pull.get("user") or {}).get("login", "") or meta["author"],
            merger=(pull.get("merged_by") or {}).get("login", ""),
            title=pull.get("title") or meta["subject"],
            labels=sorted(label.get("name", "") for label in pull.get("labels") or []),
        ))
    flush()
    for car in cars:
        if not car.files:
            car.files = sorted({path for sha in car.commits for path in changed_files(sha)})
    return cars


def carried_cars(train: TrainCommit) -> list[Car]:
    """The cars a base train commit quarantined, from its trailers."""
    by_id: dict[str, Car] = {}
    order: list[str] = []
    for line in train.cars:
        parts = line.split()
        if len(parts) < 2:
            continue
        car_id, shas = parts[0], [s for s in parts[1].split(",") if SHA_RE.match(s)]
        if car_id not in by_id:
            pr = int(car_id[3:]) if car_id.startswith("pr-") and car_id[3:].isdigit() else None
            by_id[car_id] = Car(id=car_id, kind="pr" if pr else "carried", commits=[], pr=pr, carried=True)
            order.append(car_id)
        by_id[car_id].commits.extend(s for s in shas if s not in by_id[car_id].commits)
    known = {sha for car in by_id.values() for sha in car.commits}
    for revert in train.reverts:
        if revert not in known:
            car_id = f"commit-{revert[:12]}"
            by_id[car_id] = Car(id=car_id, kind="commit", commits=[revert], carried=True)
            order.append(car_id)
    # Trailers list reverts newest first; cars ride oldest first.
    cars = [by_id[car_id] for car_id in order]
    for car in cars:
        car.commits = list(reversed(car.commits)) if car.commits else car.commits
    cars.reverse()
    return cars


def source_base(base_commit: str) -> tuple[str, list[Car]]:
    """(feat-cmux-next commit the base was built from, cars it quarantined)."""
    train = read_train_commit(base_commit)
    if train is None:
        return base_commit, []
    if len(train.parents) != 2:
        raise TrainError(f"train commit {base_commit} has {len(train.parents)} parents")
    return train.parents[1], carried_cars(train)


def require_on_tip(source: str, cars: list[Car], tip: str) -> None:
    """Refuse a train whose source or cars are not in the tip's history.

    The base comes from a build or a dispatch input, and its trailers name the
    carried cars, so a crafted base could name commits that never landed. The
    car guards check out every car, and the drive job holds the release App
    token while they run, so only feat-cmux-next history may get that far."""
    def on_tip(sha: str) -> bool:
        return bool(SHA_RE.match(sha)) and subprocess.run(
            ["git", "merge-base", "--is-ancestor", sha, tip], capture_output=True,
        ).returncode == 0

    if not on_tip(source):
        raise TrainError(f"the train's source {source[:12]} is not in the history of {tip[:12]}")
    for car in cars:
        off = [sha for sha in car.commits if not on_tip(sha)]
        if off:
            raise TrainError(f"car {car.id} names {off[0][:12]}, which is not in the history of {tip[:12]}")


# ---------------------------------------------------------------- candidates

def revert_order(cars: list[Car], quarantine: Iterable[str]) -> list[tuple[Car, str]]:
    """Every commit of the quarantined cars, newest car first, each car's
    commits newest first."""
    wanted = set(quarantine)
    out = []
    for car in reversed(cars):
        if car.id in wanted:
            out.extend((car, sha) for sha in reversed(car.commits))
    return out


def build_candidate(tip: str, cars: list[Car], quarantine: Iterable[str], max_pull_ins: int = 20) -> dict:
    """The tree of `tip` minus the quarantined cars, pulling in later cars
    that touch a conflicting file. {"tree", "reverts", "quarantined", "with"}."""
    quarantined = [car.id for car in cars if car.id in set(quarantine)]
    pulled_with: dict[str, str] = {}
    index = {car.id: i for i, car in enumerate(cars)}

    def in_tip(car: Car) -> bool:
        return bool(car.commits) and subprocess.run(
            ["git", "merge-base", "--is-ancestor", car.commits[-1], tip], capture_output=True,
        ).returncode == 0

    # A car that is not in this tip's history (a prefix candidate's later
    # cars) has nothing to revert.
    quarantined = [car_id for car_id in quarantined if in_tip(cars[index[car_id]])]
    for _ in range(max_pull_ins + 1):
        order = revert_order(cars, quarantined)
        tree, failed, conflicts = apply_reverts(tip, [sha for _, sha in order])
        if tree is not None:
            return {"tree": tree, "reverts": [sha for _, sha in order], "quarantined": quarantined, "with": pulled_with}
        failed_car = next(car for car, sha in order if sha == failed)
        later = [
            car for car in cars[index[failed_car.id] + 1:]
            if car.id not in quarantined and set(car.files) & set(conflicts) and in_tip(car)
        ]
        if not later:
            raise TrainError(f"the revert of {failed_car.id} ({failed[:12]}) conflicts in {', '.join(conflicts) or 'unknown files'} and no later car touches them")
        for car in later:
            quarantined.append(car.id)
            pulled_with[car.id] = failed_car.id
    raise TrainError(f"more than {max_pull_ins} rounds of pulled-in cars")


def train_message(tip: str, cars: list[Car], candidate: dict, title: str | None = None) -> str:
    by_id = {car.id: car for car in cars}
    lines = [title or f"nightly-next train: {tip[:12]} minus {len(candidate['quarantined'])} car(s)", ""]
    for car_id in candidate["quarantined"]:
        why = f" (quarantined with {candidate['with'][car_id]})" if car_id in candidate["with"] else ""
        lines.append(f"- {car_id}{why}: {by_id[car_id].title}")
    if candidate["quarantined"]:
        lines.append("")
    lines.append(TRAILER)
    for car_id in reversed(candidate["quarantined"]):
        # Newest commit first, the order the reverts apply in.
        lines.append(f"{CAR_TRAILER} {car_id} {','.join(reversed(by_id[car_id].commits))}")
    for sha in candidate["reverts"]:
        lines.append(f"{REVERT_TRAILER} {sha}")
    return "\n".join(lines) + "\n"


def make_train_commit(parent: str, tip: str, cars: list[Car], quarantine: Iterable[str], title: str | None = None) -> dict:
    candidate = build_candidate(tip, cars, quarantine)
    message = train_message(tip, cars, candidate, title)
    commit = git("commit-tree", candidate["tree"], "-p", parent, "-p", tip, "-F", "-", input=message, env={
        "GIT_AUTHOR_NAME": "cmux nightly train", "GIT_AUTHOR_EMAIL": "41898282+github-actions[bot]@users.noreply.github.com",
        "GIT_COMMITTER_NAME": "cmux nightly train", "GIT_COMMITTER_EMAIL": "41898282+github-actions[bot]@users.noreply.github.com",
    }).strip()
    return {**candidate, "commit": commit, "parent": parent, "tip": tip}


# ---------------------------------------------------------------- bisection

def bisect_points(lo: int, hi: int, k: int) -> list[int]:
    """Up to k prefix lengths strictly between lo (good) and hi (bad)."""
    if hi - lo <= 1:
        return []
    span = hi - lo
    points = sorted({lo + max(1, round(i * span / (k + 1))) for i in range(1, k + 1)})
    return [p for p in points if lo < p < hi]


def narrow(lo: int, hi: int, results: dict[int, bool]) -> tuple[int, int]:
    """New (good, bad) bounds from {prefix length: green}. Assumes the
    first red prefix holds the culprit (monotone)."""
    bad = min([p for p, green in results.items() if not green and lo < p < hi], default=hi)
    good = max([p for p, green in results.items() if green and lo < p < bad], default=lo)
    return good, bad


def prefix_candidate(cars: list[Car], length: int, quarantine: Iterable[str], source_base_commit: str) -> tuple[str, list[str]]:
    """(head commit, cars to revert) for the candidate holding the first
    `length` cars. A non-carried prefix is a real feat-cmux-next commit; the
    carried cars past the prefix and the quarantined cars in it are reverted."""
    quarantine = set(quarantine)
    included = cars[:length]
    fresh = [car for car in included if not car.carried]
    head = fresh[-1].commits[-1] if fresh else source_base_commit
    reverts = [car.id for car in cars if car.carried and car not in included]
    reverts += [car.id for car in included if car.id in quarantine]
    return head, reverts


# ---------------------------------------------------------------- CLI

def load_cars(path: str) -> list[Car]:
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
    return [Car(**{k: v for k, v in car.items() if k in Car.__dataclass_fields__}) for car in doc["cars"]]


def train_json(base: dict, source_base_commit: str, tip: str, cars: list[Car]) -> dict:
    return {
        "schema": 1, "base": base, "sourceBase": source_base_commit, "tip": tip,
        "cars": [asdict(car) for car in cars],
        "held": [car.id for car in cars if car.held],
    }


def summary_markdown(doc: dict) -> str:
    lines = [f"### nightly-next train plan (dry run)", "",
             f"- base: build {doc['base'].get('build') or '?'} at `{doc['base']['commit'][:12]}` ({doc['base']['source']})",
             f"- tip: `{doc['tip'][:12]}`, {len(doc['cars'])} car(s)", ""]
    if doc["cars"]:
        lines += ["| car | owner | commits | files | note |", "| --- | --- | --- | --- | --- |"]
        for car in doc["cars"][:200]:
            note = ", ".join(n for n in ("carried" if car["carried"] else "", "held" if HOLD_LABEL in car["labels"] else "") if n)
            lines.append(f"| {car['id']} | {car['owner'] or '?'} | {len(car['commits'])} | {len(car['files'])} | {note} |")
        if len(doc["cars"]) > 200:
            lines.append(f"| ... {len(doc['cars']) - 200} more | | | | |")
    return "\n".join(lines) + "\n"


def ensure_history(base: str, tip: str) -> None:
    """Fetch enough blobless history for base..tip (a CI checkout is shallow)."""
    def have(sha: str) -> bool:
        return subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True).returncode == 0

    shallow = git("rev-parse", "--is-shallow-repository", check=False).strip() == "true"
    if have(base) and have(tip) and not shallow:
        return
    git("fetch", "--no-tags", "--filter=blob:none", "origin", base, tip, check=False)
    if shallow:
        when = git("show", "-s", "--format=%cI", base, check=False).strip()
        if when:
            since = (_dt.datetime.fromisoformat(when) - _dt.timedelta(days=2)).strftime("%Y-%m-%d")
            git("fetch", "--no-tags", "--filter=blob:none", f"--shallow-since={since}", "origin", f"+refs/heads/{SOURCE}:refs/remotes/origin/{SOURCE}", tip, check=False)
        else:
            git("fetch", "--no-tags", "--filter=blob:none", "--unshallow", "origin", check=False)


def resolve_base(args: argparse.Namespace, api: Callable[..., object] = gh_api) -> dict:
    if args.base_commit:
        if not SHA_RE.match(args.base_commit):
            raise TrainError(f"--base-commit must be 40 lowercase hex, got {args.base_commit!r}")
        return {"build": None, "commit": args.base_commit, "source": "argument"}
    good = getattr(args, "good_build", "") or ""
    if good:
        # A fix-forward train (nightly_next_fix_forward.py): the build the
        # feed serves after the pull is the base, whatever its verdict.
        commit = build_commit(api, getattr(args, "repo", "") or "manaflow-ai/cmux", good)
        if not commit:
            raise TrainError(f"good build {good} has no nightly-next run, so no base")
        return {"build": good, "commit": commit, "source": "good_build"}
    feed = http_get(args.feed)
    found = last_good(feed.decode("utf-8") if feed else "", http_get, args.verdicts) if feed else None
    if found:
        return found
    head = git("ls-remote", "origin", f"refs/heads/{TARGET}").split()
    if not head:
        raise TrainError("no passing verdict and no nightly-next branch: no base")
    return {"build": None, "commit": head[0], "source": TARGET}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    v = sub.add_parser("verdict")
    v.add_argument("--build", required=True)
    v.add_argument("--verdict", required=True)
    v.add_argument("--commit", required=True)
    v.add_argument("--run-url", required=True)
    v.add_argument("--out", required=True)
    vc = sub.add_parser("verdict-check")
    vc.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    vc.add_argument("--build", required=True)
    vc.add_argument("--verdict", required=True)
    vc.add_argument("--canary-run", required=True)
    vc.add_argument("--out", required=True)
    b = sub.add_parser("base")
    p = sub.add_parser("plan")
    for q in (b, p):
        q.add_argument("--feed", default=FEED)
        q.add_argument("--verdicts", default=VERDICTS)
        q.add_argument("--base-commit", default="")
        q.add_argument("--good-build", default="")
        q.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    p.add_argument("--tip", required=True)
    p.add_argument("--out", default="")
    p.add_argument("--summary", default="", help="append the dry-run table to this file")
    c = sub.add_parser("candidate")
    c.add_argument("--tip", required=True)
    c.add_argument("--parent", required=True)
    c.add_argument("--quarantine", default="")
    c.add_argument("--train", required=True)
    c.add_argument("--out", default="")
    w = sub.add_parser("verify")
    w.add_argument("--commit", required=True)
    w.add_argument("--fetch", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "verdict":
            doc = verdict_document(args.build, args.verdict, args.commit, args.run_url)
            with open(args.out, "w", encoding="utf-8") as handle:
                json.dump(doc, handle, indent=2, sort_keys=True)
                handle.write("\n")
            print(json.dumps(doc))
        elif args.command == "verdict-check":
            doc = checked_verdict(gh_api, args.repo, args.build, args.verdict, args.canary_run)
            with open(args.out, "w", encoding="utf-8") as handle:
                json.dump(doc, handle, indent=2, sort_keys=True)
                handle.write("\n")
            print(json.dumps(doc))
        elif args.command == "base":
            print(json.dumps(resolve_base(args)))
        elif args.command == "plan":
            if not SHA_RE.match(args.tip):
                raise TrainError(f"--tip must be 40 lowercase hex, got {args.tip!r}")
            base = resolve_base(args)
            ensure_history(base["commit"], args.tip)
            src, carried = source_base(base["commit"])
            cars = plan_cars(src, args.tip, args.repo, carried=carried)
            doc = train_json(base, src, args.tip, cars)
            text = json.dumps(doc, indent=2)
            if args.out:
                with open(args.out, "w", encoding="utf-8") as handle:
                    handle.write(text + "\n")
            if args.summary:
                with open(args.summary, "a", encoding="utf-8") as handle:
                    handle.write(summary_markdown(doc))
            print(text if not args.out else json.dumps({"cars": len(cars), "out": args.out}))
        elif args.command == "candidate":
            cars = load_cars(args.train)
            quarantine = [q for q in args.quarantine.split(",") if q]
            result = make_train_commit(args.parent, args.tip, cars, quarantine)
            if args.out:
                with open(args.out, "w", encoding="utf-8") as handle:
                    json.dump(result, handle, indent=2)
            print(json.dumps(result))
        elif args.command == "verify":
            if args.fetch and SHA_RE.match(args.commit):
                fetch_for_verify(args.commit)
            result = verify_train_commit(args.commit)
            print(json.dumps(result))
            return 0 if result["ok"] else 1
    except TrainError as error:
        if args.command == "verify":
            print(json.dumps({"ok": False, "reason": str(error)[:500]}))
        print(f"nightly-next train: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
