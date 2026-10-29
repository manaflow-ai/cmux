#!/usr/bin/env python3
"""Place a feat-cmux-next landing's DEV Release compile on the free owned Mac whose cache is nearest.

Every feat-cmux-next push compiles the cmux NEXT DEV Release app at once (cmux-next.yml,
dev-landing-compile), so the next landing finds a cache a commit or two behind. An owned Mac's
warm state is its host tree (compile-dev-release.sh: one source tree, DerivedData and Xcode
compilation cache per host, under a host lock), so the compile should go to the host that built
the nearest commit. After a host-mode compile the job (and the DEV run's) uploads the artifact
`cmux-next-dev-cas-holder-<host>` (fixed name per host, `overwrite: true`); its run's head_sha,
which GitHub writes, is the commit that host last compiled. Only records from this repository's
feat-cmux-next runs count, so a pull request cannot point a landing anywhere; a wrong or stale
record only costs a colder compile.

The order (the rulebook's routing order):
1. a free owned root runner on the host whose record is nearest (fewest commits either way),
   pinned by its static label `glaeda-runner-<name>` (glaeda gives root runners one; side runners
   have none, so a side runner cannot be pinned to a host);
2. otherwise any free owned runner: the side label when a side runner is free, else a free root
   runner (that host is cold for this tree and warms from now on);
3. otherwise, after looking again every POLL_SECONDS for WAIT_SECONDS (about two minutes), the
   Blacksmith overflow label. Runners that cannot be read (no token, an API error) overflow at
   once: a landing never waits on a queue nobody saw free.

Placement reserves nothing, so the landings in flight are read once (in_flight()): a root runner
another landing's queued compile is pinned to is not free, and a host where one is compiling holds
its host lock (this compile would fall back to a per-runner tree), so it is not pinned either.

`place` (default) prints runs_on= (JSON for fromJSON), runner_label=, pool= (owned|blacksmith),
host=, holder_sha=, gap= and reason= for $GITHUB_OUTPUT. Env: ROUTE_TOKEN, GITHUB_REPOSITORY,
GITHUB_REPOSITORY_ID, GITHUB_RUN_ID, SHA, SIDE_LABEL, OVERFLOW_LABEL, WAIT_SECONDS, POLL_SECONDS,
GAP_REPO and GAP_REMOTE (a bare repository and the remote to fetch commits into it).
`gap FROM TO` prints the commits between two commits (either direction), or nothing; every fetch
has a deadline, so a stalled network never holds the job.

`place` with FRESH_LABEL set places a DEV daily's Release compile (cmux-next.yml, dev-daily-place, for
cmux-scheme-compile) the same way, with the DEV compile slots as candidates too. Of 15 DEV compiles on
2026-10-28, 4 hit a warm cache, every one on the same host: the slot label FRESH_LABEL went to whichever
slot was idle, and with both busy the compile took the side label onto a host with no tree (0 of 509
cache hits, 808 s against 130 s warm). So in this mode:
1. the candidates are the free runners carrying FRESH_LABEL (pinned by their static label when they
   have one; an unpinned slot is a host-specific pick only while it is the one idle slot) and the free
   pinnable root runners, scored by their host's holder distance, a slot before a root at equal distance;
2. when the nearest host overall (by record, idle or not) is busy and the best free pick is WAIT_GAP or
   more commits farther (or cold), it looks again every POLL_SECONDS for up to WAIT_SECONDS for that
   host to free, then takes the best free pick (rulebook: a fallback within minutes);
3. with no free owned runner on a host with a record, a free slot by label, then a free side runner;
   with none of those it prints an empty runs_on and the compile keeps macos-placement's route.
A host where another DEV compile runs holds its host lock, so it is not free until that runner is idle.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

HOLDER_PREFIX = "cmux-next-dev-cas-holder-"
BRANCH = "feat-cmux-next"
COMPILE_JOB = "cmux NEXT DEV Release compile (landing)"
# The DEV daily's compile (cmux-scheme-compile's name in a dev_daily run): it holds a host lock too.
DAILY_COMPILE_JOB = "cmux NEXT DEV Release compile"
COMPILE_JOBS = frozenset({COMPILE_JOB, DAILY_COMPILE_JOB})
# A DEV daily placement that places nothing: the compile keeps macos-placement's route.
DAILY_KEEP = {"runs_on": "", "runner_label": "", "pool": "", "host": "", "holder_sha": "", "gap": ""}
RUNNER_LABEL_PREFIX = "glaeda-runner-"
DEV_SLOT_PREFIX = "glaeda-dev-"  # the DEV compile slots' label (glaeda's freshness slot)
SHA = re.compile(r"^[0-9a-f]{40}$")
FETCH_SECONDS = 45
# In-flight landings older than this are not read (a compile takes minutes).
IN_FLIGHT_MINUTES = 60
IN_FLIGHT_RUNS = 10


def host_of(runner_name: str) -> str:
    """The mini a runner instance runs on: `cmux14-glaeda-2` -> `cmux14` (bash: ${RUNNER_NAME%-glaeda*})."""
    name = runner_name.lower()
    cut = name.rfind("-glaeda")
    return name[:cut] if cut > 0 else name


def static_label(runner_name: str) -> str:
    """glaeda-cmux-runner's runner_label(): the label only this runner carries."""
    return RUNNER_LABEL_PREFIX + re.sub(r"[^a-z0-9._-]+", "-", runner_name.lower())


def free_runners(runners: Sequence[Mapping[str, Any]], side_label: str,
                 taken: set[str] = frozenset()) -> tuple[list[str], list[str]]:
    """(free root runners that can be pinned, free side runners) of SIDE_LABEL's pool, by name."""
    root_label = side_label.replace("glaeda-side-", "glaeda-root-", 1)
    roots, sides = [], []
    for runner in runners:
        name = str(runner.get("name") or "")
        if not name or runner.get("status") != "online" or runner.get("busy"):
            continue
        labels = {str(label.get("name")) for label in runner.get("labels") or [] if isinstance(label, Mapping)}
        if root_label in labels and static_label(name) in labels:
            if static_label(name) not in taken:
                roots.append(name)
        elif side_label in labels:
            sides.append(name)
    return sorted(roots), sorted(sides)


def in_flight(runs: Sequence[Mapping[str, Any]], jobs_of: Callable[[int], Sequence[Mapping[str, Any]]],
              own_run: str, now: dt.datetime) -> tuple[set[str], set[str]]:
    """(labels other queued jobs claim a runner by, runners other DEV compiles run on).

    Both a landing's compile and a DEV daily's (COMPILE_JOBS) hold their host's lock. The second set
    names runners, not hosts: a host is busy while that runner is (busy_hosts()), so a placement that
    keeps looking sees the host free once that compile ends."""
    taken, busy_hosts = set(), set()
    recent = []
    for run in runs:
        created = str(run.get("created_at") or "")
        try:
            age = now - dt.datetime.fromisoformat(created.replace("Z", "+00:00"))
        except ValueError:
            continue
        if str(run.get("id")) != own_run and age < dt.timedelta(minutes=IN_FLIGHT_MINUTES):
            recent.append(run)
    for run in recent[:IN_FLIGHT_RUNS]:
        for job in jobs_of(int(run["id"])):
            labels = [str(label) for label in job.get("labels") or []]
            if job.get("status") in ("queued", "waiting", "pending", "requested"):
                pinned = [label for label in labels if label.startswith(RUNNER_LABEL_PREFIX)]
                # Any queued job pinned to a runner claims it. One that asked for a DEV slot by its label
                # alone (a feed compile on macos-placement's fresh_runner) claims whichever slot is idle,
                # so its label goes in too and free_slots() offers no slot while it waits.
                taken.update(pinned or [label for label in labels if label.startswith(DEV_SLOT_PREFIX)])
            if job.get("name") not in COMPILE_JOBS:
                continue
            if job.get("status") == "in_progress" and job.get("runner_name"):
                busy_hosts.add(str(job["runner_name"]))
    return taken, busy_hosts


def busy_hosts(compiling: set[str], runners: Sequence[Mapping[str, Any]]) -> set[str]:
    """The hosts of the runners in `compiling` (in_flight()) that are still busy, or not listed."""
    idle = {str(runner.get("name") or "") for runner in runners if runner.get("status") == "online" and not runner.get("busy")}
    return {host_of(name) for name in compiling if name not in idle}


def holder_sha(artifacts: Sequence[Mapping[str, Any]], host: str, repository_id: str) -> str:
    """The commit `host` last compiled: its newest trusted holder record's run head_sha, or ""."""
    trusted = []
    for item in artifacts:
        run = item.get("workflow_run") or {}
        if item.get("name") != HOLDER_PREFIX + host or item.get("expired"):
            continue
        if str(run.get("repository_id")) != repository_id or str(run.get("head_repository_id")) != repository_id:
            continue
        if run.get("head_branch") != BRANCH or not SHA.match(str(run.get("head_sha") or "")):
            continue
        trusted.append(item)
    trusted.sort(key=lambda item: str(item.get("created_at") or ""), reverse=True)
    return str(trusted[0]["workflow_run"]["head_sha"]) if trusted else ""


def git(repo: str, *args: str, timeout: float = 20) -> subprocess.CompletedProcess | None:
    try:
        return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None


def fetch_commits(repo: str, remote: str, sha: str) -> None:
    """Commits only (no trees or blobs) of sha's last 300, bounded by FETCH_SECONDS."""
    if repo and remote and SHA.match(sha):
        # A depth flag only in an already-shallow checkout: in a full clone it would make every
        # worktree sharing the git directory shallow.
        is_shallow = git(repo, "rev-parse", "--is-shallow-repository")
        depth = ["--depth=300"] if is_shallow and is_shallow.stdout.strip() == "true" else []
        git(repo, "fetch", "-q", "--no-tags", "--filter=tree:0", *depth, remote, sha, timeout=FETCH_SECONDS)


def has_commit(repo: str, sha: str) -> bool:
    result = git(repo, "cat-file", "-e", f"{sha}^{{commit}}")
    return bool(result and result.returncode == 0)


def git_distance(repo: str, holder: str, head: str, remote: str = "") -> int | None:
    """Commits between holder and head (either direction), or None when unknown.

    A holder newer than head (a later landing compiled there first) is not in head's history, so
    it is fetched too."""
    if not (repo and SHA.match(holder) and SHA.match(head)):
        return None
    if holder == head:
        return 0
    if not has_commit(repo, holder):
        fetch_commits(repo, remote, holder)
    result = git(repo, "rev-list", "--count", f"{holder}...{head}")
    out = result.stdout.strip() if result and result.returncode == 0 else ""
    return int(out) if out.isdigit() else None


def labels_of(runner: Mapping[str, Any]) -> set[str]:
    return {str(label.get("name")) for label in runner.get("labels") or [] if isinstance(label, Mapping)}


def free_slots(runners: Sequence[Mapping[str, Any]], fresh_label: str,
               taken: set[str] = frozenset()) -> list[tuple[str, bool]]:
    """The free runners carrying FRESH_LABEL (the DEV compile slots), as (name, has its static label).

    None while a queued job asked for FRESH_LABEL alone (in_flight() puts the label in `taken`): GitHub
    hands that job the next idle slot, and which one is unknown."""
    if fresh_label in taken:
        return []
    free = []
    for runner in runners:
        name = str(runner.get("name") or "")
        if not name or not fresh_label or runner.get("status") != "online" or runner.get("busy"):
            continue
        labels = labels_of(runner)
        if fresh_label in labels and static_label(name) not in taken:
            free.append((name, static_label(name) in labels))
    return sorted(free)


def record_hosts(runners: Sequence[Mapping[str, Any]], labels: set[str]) -> list[str]:
    """The hosts of the online runners carrying any of `labels`: where a warm tree can be."""
    return sorted({host_of(str(runner.get("name") or "")) for runner in runners
                   if runner.get("name") and runner.get("status") == "online" and labels & labels_of(runner)})


def waitable_hosts(runners: Sequence[Mapping[str, Any]], labels: set[str], busy: set[str]) -> list[str]:
    """The hosts worth waiting for: a runner there carries one of `labels` and its static label (a pick could
    claim it once free), and none of those is idle, or another DEV compile holds the host's lock (`busy`). A
    host whose only runners are unpinned slots is never waited for: freeing it gives no pick to claim, so the
    compile takes the shared label at once."""
    pinnable: dict[str, bool] = {}
    for runner in runners:
        name = str(runner.get("name") or "")
        names = labels_of(runner)
        if not name or runner.get("status") != "online" or not (labels & names) or static_label(name) not in names:
            continue
        host = host_of(name)
        pinnable[host] = pinnable.get(host, False) or not runner.get("busy")
    return sorted(host for host, idle in pinnable.items() if host in busy or not idle)


def choose_daily(roots: Sequence[str], slots: Sequence[tuple[str, bool]], side_label: str, fresh_label: str,
                 distance_of: Callable[[str], tuple[str, int | None]],
                 busy: set[str] = frozenset()) -> tuple[tuple[int, int, str] | None, dict[str, str] | None]:
    """(the best host-specific pick's (distance, kind, name) and placement) for a DEV daily, or (None, None).

    A pick claims a host only when its label can land on exactly one runner: a slot with its static label, or
    an unpinned slot while it is the one free slot of them all (`slots`, busy hosts included: GitHub can hand
    the shared label to any of them). kind 0 is a slot, 1 a root runner: a slot first at equal distance.
    A root runner is pinned as [its pool's root label, its static label], as the landing compile pins it: the
    owned-pool rescue watches a job queued on a glaeda-root-* label, so a runner taken between this read and
    the job's start has the rescue's fallback. runner_label is the first label (the job's CMUX_NEXT_RUNNER)."""
    root_label = side_label.replace("glaeda-side-", "glaeda-root-", 1)
    scored = []
    for name, pinned in slots:
        if host_of(name) in busy:
            continue
        if pinned or len(slots) == 1:
            holder, distance = distance_of(host_of(name))
            if distance is not None:
                runs_on = [fresh_label, static_label(name)] if pinned else fresh_label
                scored.append(((distance, 0, name), holder, runs_on, fresh_label))
    for name in roots:
        if host_of(name) in busy:
            continue
        holder, distance = distance_of(host_of(name))
        if distance is not None:
            scored.append(((distance, 1, name), holder, [root_label, static_label(name)], root_label))
    if not scored:
        return None, None
    key, holder, runs_on, label = min(scored, key=lambda item: item[0])
    distance, _, name = key
    return key, {"runs_on": json.dumps(runs_on), "runner_label": label, "pool": "owned", "host": host_of(name),
                 "holder_sha": holder, "gap": str(distance),
                 "reason": f"{name} is free on {host_of(name)}, whose cache is {distance} commits from this commit"}


def choose(roots: Sequence[str], sides: Sequence[str], side_label: str,
           distance_of: Callable[[str], tuple[str, int | None]], busy_hosts: set[str] = frozenset()) -> dict[str, str] | None:
    """The owned placement for this read, or None when no owned runner is free."""
    root_label = side_label.replace("glaeda-side-", "glaeda-root-", 1)
    scored = []
    for name in roots:
        if host_of(name) in busy_hosts:
            continue
        holder, distance = distance_of(host_of(name))
        if distance is not None:
            scored.append((distance, host_of(name), name, holder))
    if scored:
        distance, host, name, holder = min(scored)
        return {"runs_on": json.dumps([root_label, static_label(name)]), "runner_label": root_label,
                "pool": "owned", "host": host, "holder_sha": holder, "gap": str(distance),
                "reason": f"{name} is free on {host}, whose cache is {distance} commits from this landing"}
    if sides:
        return {"runs_on": json.dumps(side_label), "runner_label": side_label, "pool": "owned", "host": "",
                "holder_sha": "", "gap": "", "reason": f"no free host holds a near cache; {len(sides)} side runners are free"}
    if roots:
        name = roots[0]
        return {"runs_on": json.dumps([root_label, static_label(name)]), "runner_label": root_label,
                "pool": "owned", "host": host_of(name), "holder_sha": "", "gap": "",
                "reason": f"no free host holds a near cache; {name} is free (cold for this tree)"}
    return None


def place(env: Mapping[str, str], read_runners: Callable[[], Sequence[Mapping[str, Any]]],
          read_holders: Callable[[str], Sequence[Mapping[str, Any]]],
          read_in_flight: Callable[[], tuple[set[str], set[str]]] = lambda: (set(), set()),
          sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic) -> dict[str, str]:
    side_label = env.get("SIDE_LABEL", "")
    overflow = env.get("OVERFLOW_LABEL") or "blacksmith-12vcpu-macos-26"
    overflowed = {"runs_on": json.dumps(overflow), "runner_label": overflow, "pool": "blacksmith",
                  "host": "", "holder_sha": "", "gap": ""}
    if not side_label.startswith("glaeda-side-"):
        if (env.get("FRESH_LABEL") or "").strip():  # a DEV daily keeps the route its run already has
            return {**DAILY_KEEP, "reason": f"owned pools are off for this run (side route {side_label or 'unset'})"}
        return {**overflowed, "reason": f"owned pools are off for this run (side route {side_label or 'unset'})"}
    head, repo_id = env.get("SHA", ""), env.get("GITHUB_REPOSITORY_ID", "")
    gap_repo, gap_remote = env.get("GAP_REPO", ""), env.get("GAP_REMOTE", "")
    wait, poll = float(env.get("WAIT_SECONDS") or 120), max(1.0, float(env.get("POLL_SECONDS") or 30))
    holders: dict[str, tuple[str, int | None]] = {}

    def distance_of(host: str) -> tuple[str, int | None]:
        if host not in holders:
            try:
                sha = holder_sha(read_holders(host), host, repo_id)
            except Exception as error:  # noqa: BLE001 - an unreadable record is a cold host
                print(f"dev_landing_place: holder record of {host} unreadable: {error}", file=sys.stderr)
                sha = ""
            holders[host] = (sha, git_distance(gap_repo, sha, head, gap_remote) if sha else None)
        return holders[host]

    try:
        taken, compiling = read_in_flight()
    except Exception as error:  # noqa: BLE001 - unknown in-flight landings: place on the live state
        print(f"dev_landing_place: landings in flight unreadable: {error}", file=sys.stderr)
        taken, compiling = set(), set()
    fresh_label = (env.get("FRESH_LABEL") or "").strip()
    if fresh_label:
        return place_daily(env, side_label, fresh_label, read_runners, distance_of, taken, compiling,
                           wait, poll, sleep, clock)
    started = clock()
    reads = 0
    while True:
        reads += 1
        try:
            runners = read_runners()
            roots, sides = free_runners(runners, side_label, taken)
        except Exception as error:  # noqa: BLE001 - nobody saw an owned runner free
            return {**overflowed, "reason": f"owned runners unreadable ({error}); overflow at once"}
        picked = choose(roots, sides, side_label, distance_of, busy_hosts(compiling, runners))
        if picked:
            return picked
        if clock() - started + poll > wait:
            return {**overflowed, "reason": f"no owned runner was free in {reads} looks over {int(clock() - started)}s"}
        sleep(poll)


def place_daily(env: Mapping[str, str], side_label: str, fresh_label: str,
                read_runners: Callable[[], Sequence[Mapping[str, Any]]],
                distance_of: Callable[[str], tuple[str, int | None]], taken: set[str], compiling: set[str],
                wait: float, poll: float, sleep: Callable[[float], None], clock: Callable[[], float]) -> dict[str, str]:
    """A DEV daily's compile: the free runner nearest its cache, waiting at most WAIT_SECONDS for a nearer busy host."""
    root_label = side_label.replace("glaeda-side-", "glaeda-root-", 1)
    keep = DAILY_KEEP
    wait_gap = int(env.get("WAIT_GAP") or 3)
    started = clock()
    reads = 0
    while True:
        reads += 1
        try:
            runners = read_runners()
        except Exception as error:  # noqa: BLE001 - nobody saw an owned runner free: keep the route
            return {**keep, "reason": f"owned runners unreadable ({error}); the compile keeps its route"}
        busy = busy_hosts(compiling, runners)
        roots, sides = free_runners(runners, side_label, taken)
        slots = free_slots(runners, fresh_label, taken)
        key, picked = choose_daily(roots, slots, side_label, fresh_label, distance_of, busy)
        known = [(distance, host) for host in waitable_hosts(runners, {fresh_label, root_label}, busy)
                 for _, distance in [distance_of(host)] if distance is not None]
        nearest = min(known) if known else None
        better_busy = nearest is not None and (key is None or key[0] - nearest[0] >= wait_gap)
        if not better_busy or clock() - started + poll > wait:
            if picked:
                if better_busy:
                    picked["reason"] += f"; {nearest[1]} ({nearest[0]} commits) stayed busy for {int(clock() - started)}s"
                return picked
            if slots:
                return {**keep, "runs_on": json.dumps(fresh_label), "runner_label": fresh_label, "pool": "owned",
                        "reason": f"no free runner on a host with a cache record; {len(slots)} DEV slots are free"}
            if sides:
                return {**keep, "runs_on": json.dumps(side_label), "runner_label": side_label, "pool": "owned",
                        "reason": f"no free runner on a host with a cache record; {len(sides)} side runners are free"}
            if not better_busy:
                return {**keep, "reason": "no owned runner is free; the compile keeps its route"}
            return {**keep, "reason": f"no owned runner was free in {reads} looks over {int(clock() - started)}s; "
                                      "the compile keeps its route"}
        sleep(poll)


def gap_main(source: str, head: str) -> int:
    if not (SHA.match(source) and SHA.match(head)):
        return 0
    if source == head:
        print(0)
        return 0
    remote = os.environ.get("GAP_REMOTE") or (
        f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{os.environ.get('GITHUB_REPOSITORY', 'manaflow-ai/cmux')}")
    with tempfile.TemporaryDirectory(prefix="cmux-dev-gap-") as repo:
        git(repo, "init", "-q", "--bare")
        fetch_commits(repo, remote, head)
        distance = git_distance(repo, source, head, remote)
        if distance is not None:
            print(distance)
    return 0


def main(argv: Sequence[str]) -> int:
    if argv[:1] == ["gap"]:
        return gap_main(argv[1] if len(argv) > 1 else "", argv[2] if len(argv) > 2 else "")
    env = dict(os.environ)
    from pr_runner_pool import GitHub  # noqa: PLC0415 - the checked-out base's client

    token, repo = env.get("ROUTE_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    api = GitHub(token, repo) if token and repo else None

    def read_runners() -> Sequence[Mapping[str, Any]]:
        if api is None:
            raise RuntimeError("no routing token")
        return api.runners()

    def read_holders(host: str) -> Sequence[Mapping[str, Any]]:
        if api is None:
            return []
        return api.get(f"/actions/artifacts?name={HOLDER_PREFIX}{host}&per_page=10").get("artifacts") or []

    def read_in_flight() -> tuple[set[str], set[str]]:
        if api is None:
            return set(), set()
        # A landing's compile runs in a push run, a DEV daily's in a dispatch: both hold a host lock.
        runs = []
        for event in ("push", "workflow_dispatch"):
            runs += api.get(f"/actions/workflows/cmux-next.yml/runs?event={event}&branch={BRANCH}&status=in_progress"
                            "&per_page=30").get("workflow_runs") or []
        runs.sort(key=lambda run: str(run.get("created_at") or ""), reverse=True)
        return in_flight(runs, lambda run_id: api.get(f"/actions/runs/{run_id}/jobs?filter=latest&per_page=100")
                         .get("jobs") or [], env.get("GITHUB_RUN_ID", ""), dt.datetime.now(dt.timezone.utc))

    outputs = place(env, read_runners, read_holders, read_in_flight)
    print(f"::notice title=DEV compile placement::{outputs['reason']}", file=sys.stderr)
    for key in ("runs_on", "runner_label", "pool", "host", "holder_sha", "gap", "reason"):
        print(f"{key}={' '.join(str(outputs.get(key, '')).split())}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
