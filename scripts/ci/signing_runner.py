#!/usr/bin/env python3
"""Pick the route for a release signing job: a drained owned Mac, else a moving Blacksmith macOS label.

Leo, 2026-10-28, on letting the release signing jobs run on our own Macs while
Blacksmith is starved: "ok. idk what the "risk" was before but like.. we can just
read the code and stuff." The routing order is Linux, then owned Macs, then
Blacksmith macOS last (Leo, 2026-10-24). A signing job imports the Developer ID
certificate into a per-job temporary keychain (scripts/ci/signing-keychain.sh),
so on an owned Mac it must have the mini to itself:

- `owned` is offered only while vars.CI_SIGN_OWNED is 1 (ENABLED), the owned
  runners can be read live (ROUTE_TOKEN), and no other signing job holds an
  owned Mac now (MAX_OWNED_SIGNING, counted with SNAPSHOT_TOKEN's actions: read).
  It names a mini none of whose runners is busy now (a drained mini; an offline
  runner GitHub calls idle is a parked slot), as the JSON runs-on array
  `["<pool label>", "glaeda-runner-<runner name>"]`: the pool label is one of
  OWNED_LABELS, so ci-owned-pool-rescue.yml watches the job, and the runner
  label pins it to that idle runner. Empty otherwise: a busy fleet is never
  waited on.
- With no drained mini (under steady PR load there never is one: run 40859232446), a nightly-next signing job is
  sent to drain one: an idle runner of glaeda's nightly slot (NIGHTLY_SLOT_LABEL, offered only when OWNED_LABELS
  names it, which nightly.yml's does and the DEV daily's does not) on the mini with the fewest busy runners. The
  slot listens however full its mini is, and the waiting signing job, a nightly job, stops every other admission
  and holds every other runner's gate there (glaeda FEED_FIRST): the running jobs finish, nothing new starts, and it
  takes the whole mini within glaeda's SIGNING_DRAIN_WAIT_S (600 s), or is refused and the run's Blacksmith twin
  signs. The hold is the waiting job's own marker, so it ends with the job and never strands the mini.
- On the mini, glaeda's job-started hook gives every signing job the exclusive
  class (glaeda SIGNING_JOBS): every capacity unit and both fast tokens, so no
  other job starts beside it, and it waits at most 300 s for the mini to drain
  before it is refused. Admitted, the hook writes GLAEDA_JOB_CLAIM=exclusive to
  $GITHUB_ENV, and the job's first step (scripts/ci/signing-runner-claim.sh)
  fails before any secret is read when that claim is missing on an owned Mac.
- `runner` and `alternate` are nightly_sign_runner.py's Blacksmith picks: the
  label whose queue moves, and the other size a re-run takes. `placement` is
  `unverified` when no fresh pool snapshot backs them (nightly_sign_runner.place()).

The workflow takes `owned` only on attempt 1; a re-run takes `alternate`, so a
job an owned runner refused or left queued leaves the fleet. It never fails the
job and never prints an empty `runner`:

    ENABLED=<vars.CI_SIGN_OWNED> ROUTE_TOKEN=<org runners: read> OWNED_LABELS='<a> <b>' \\
        SNAPSHOT_TOKEN=<actions: read> CANDIDATE=<vars.MACOS_RUNNER_26> signing_runner.py
    -> owned=..., runner=..., alternate=..., placement=... in $GITHUB_OUTPUT

`signing_runner.py owned` prints only `owned` (pick-nightly-sign-runner already
prints the Blacksmith pair).
"""

from __future__ import annotations

import collections
import datetime as dt
import json
import os
import sys
import time
import urllib.error
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nightly_sign_runner as blacksmith_picker  # noqa: E402
import pr_runner_pool as pool  # noqa: E402
from nightly_build_runner import NIGHTLY_SLOT_LABEL, owned_label  # noqa: E402

ENABLED_VALUE = "1"
# The signing jobs glaeda gives the whole mini (glaeda SIGNING_JOBS; tests/test_ci_signing_owned_mac.py keeps the
# lists equal): the workflow file and the job's display name (its `name:` or id; a matrix adds " (...)").
SIGNING_JOBS = {
    "nightly.yml": ("build-sign-notarize-nightly", "recover-nightly-next-notarization", "sign-nightly-identity-legacy"),
    "release.yml": ("build-sign-notarize",),
    "repair-v0-64-25-helper-rpaths.yml": ("repair",),
    "cmux-next-dev-daily.yml": ("Sign cmux NEXT DEV",),
}
# At most this many minis are held for signing at once (the coordinator's cap, 2026-10-29): a drained mini is taken
# whole, so each one held is a mini's worth of PR and nightly work sent elsewhere.
MAX_OWNED_SIGNING = 1
# The run statuses that are not finished (GitHub's `status` filter for workflow runs).
# Not "queued": a run is queued until its first job starts, so none of its jobs has a pick, and nothing of it carries a
# pin. Reading those failed every pick closed: nightly.yml and cmux-next-dev-daily.yml each keep over 100 queued runs
# (2026-10-29: 21 and 106 by 16:06Z; picks in runs 40897459413 and 40905688542 gave up on "more queued runs than one
# page lists"), so no owned Mac was ever offered.
ACTIVE_RUN_STATUSES = ("in_progress", "waiting", "pending", "requested")
# A GitHub 5xx is retried this many times before the count gives up (run 40899583793's pick gave up on one 502).
READ_RETRIES = 2


def member(name: str) -> str:
    """The mini a glaeda runner runs on: its name before `-glaeda` (pool, gui, fast and dedicated runners alike)."""
    head, found, _ = (name or "").partition("-glaeda")
    return head if found and head else ""


def drained_runner(runners: Sequence[Mapping[str, Any]], labels: Sequence[str], seed: str = "") -> tuple[str, str]:
    """(the JSON runs-on array for an idle runner on a mini with no busy runner, else one to drain, or "", why).

    A candidate runner is online, idle, carries one of `labels` (an owned pool label) and its own
    `glaeda-runner-<name>` label. Its mini is drained when no runner of that mini, whatever its
    labels or status, is busy now (an offline runner GitHub calls idle is a parked slot and runs nothing).
    `seed` picks among the drained minis; owned_pick passes none, so two pickers at once name the same
    mini and glaeda admits only one of them. With no drained mini, a candidate carrying a nightly slot label
    (NIGHTLY_SLOT_LABEL) is offered on the mini with the fewest busy runners, which glaeda drains for the
    signing job (the module docstring); the first by name on a tie, so two pickers name the same one.
    """
    # The owned labels nightly_build_runner offers: a persistent pool or glaeda's nightly slot, which
    # vars.CI_NIGHTLY_NEXT_BUILD_RUNNER may name (its hook still admits a signing job only as the exclusive class).
    wanted = [label for label in labels if label and owned_label(label)]
    if not wanted:
        return "", f"no owned pool label among {list(labels) or 'none'}"
    busy: collections.Counter[str] = collections.Counter()
    idle: dict[str, list[tuple[str, str]]] = {}
    for runner in runners:
        name = str(runner.get("name") or "")
        mini = member(name)
        if not mini:
            continue
        if runner.get("busy"):
            # A busy runner of any status keeps its mini: an offline one GitHub still calls busy may be running a
            # job whose end it has not seen.
            busy[mini] += 1
            continue
        if runner.get("status") != "online":
            # An offline runner GitHub calls idle runs nothing: glaeda parks most of a mini's registered runners
            # offline as spare slots (5 to 11 of 12 on every mini on 2026-10-29), so counting them as busy left no
            # mini ever drained and every pick empty. glaeda's admission, which takes every unit or refuses within
            # 300 s, stays the guarantee if one comes back with a job.
            continue
        names = pool.runner_labels(runner)
        label = next((label for label in wanted if pool.carries_office_pool_label(runner, label)), "")
        if label and pool.runner_label(name) in names:
            idle.setdefault(mini, []).append((label, name))
    drained = sorted(mini for mini in idle if mini not in busy)
    if not drained:
        slots = sorted((busy[mini], mini, label, name) for mini, found in idle.items()
                       for label, name in found if NIGHTLY_SLOT_LABEL.fullmatch(label))
        if slots:
            count, mini, label, name = slots[0]
            return (json.dumps([label, pool.runner_label(name)], separators=(",", ":")),
                    f"`{name}` on {mini}, to drain: no mini is drained now, and glaeda holds every new job off "
                    f"{mini} while this one waits for its {count} busy runner(s) to finish")
        return "", f"no mini with an idle {' or '.join(f'`{label}`' for label in wanted)} runner is drained now"
    mini = drained[sum(map(ord, seed)) % len(drained)] if seed else drained[0]
    label, name = sorted(idle[mini])[0]
    return (json.dumps([label, pool.runner_label(name)], separators=(",", ":")),
            f"`{name}` on {mini}, which runs no job now ({len(drained)} drained mini(s))")


PAGE = 100  # per_page of every listing owned_signing_jobs reads
# A listing longer than this many pages fails the count closed (no owned Mac is offered).
MAX_PAGES = 5


def every_page(read: Callable[[str], Any], path: str, key: str) -> list[Any]:
    """Every item of a listing, read page by page until GitHub returns an empty page. Neither a page's length nor
    total_count is trusted: total_count can run ahead of the items (run 40913618519's pick, 2026-10-29 16:54Z, failed
    closed on "more waiting runs than one page lists" while nightly.yml had no waiting run), and per_page is only a
    maximum. More than MAX_PAGES pages raises, so the caller offers no owned Mac."""
    items: list[Any] = []
    for number in range(1, MAX_PAGES + 2):
        page = read(f"{path}&per_page={PAGE}&page={number}").get(key) or []
        if not page:
            return items
        if number > MAX_PAGES:
            break
        items.extend(page)
    raise RuntimeError(f"{path} lists more than {MAX_PAGES} pages")


def owned_signing_jobs(read: Callable[[str], Any]) -> int:
    """How many signing jobs (SIGNING_JOBS) are queued or running on an owned Mac now: pinned by a
    `glaeda-runner-<name>` label, which only the owned pick adds to a signing job's runs-on. `read` GETs a path
    under the repository (actions: read). Raises on any read it cannot make, so the caller offers no owned Mac."""
    count, seen = 0, set()
    plain = read

    def read(path: str) -> Any:  # noqa: F811 - the same read, retried on a GitHub 5xx
        for attempt in range(READ_RETRIES + 1):
            try:
                return plain(path)
            except urllib.error.HTTPError as error:
                if error.code < 500 or attempt == READ_RETRIES:
                    raise
        raise AssertionError("unreachable")

    for workflow, names in SIGNING_JOBS.items():
        # Every run status GitHub has that is not finished, but queued (ACTIVE_RUN_STATUSES): a run waiting on an
        # environment, or pending a concurrency slot, can still hold a signing job that already carries its pin.
        for status in ACTIVE_RUN_STATUSES:
            runs = every_page(read, f"/actions/workflows/{workflow}/runs?status={status}", "workflow_runs")
            for run in runs:
                if run["id"] in seen:
                    continue
                seen.add(run["id"])
                jobs = every_page(read, f"/actions/runs/{run['id']}/jobs?filter=latest", "jobs")
                for job in jobs:
                    name = str(job.get("name") or "").split(" (", 1)[0]
                    if (name in names and job.get("status") in ("queued", "in_progress", "waiting", "pending", "requested")
                            and any(str(label).startswith(pool.RUNNER_LABEL_PREFIX) for label in job.get("labels") or [])):
                        count += 1
    return count


def write_output(env: Mapping[str, str], values: Mapping[str, str], lines: Sequence[str]) -> None:
    for line in lines:
        print(f"signing runner: {line}")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write("".join(f"{key}={value}\n" for key, value in values.items()))
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write("\nSigning runner:\n" + "".join(f"- {line}\n" for line in lines))


def owned_pick(env: Mapping[str, str],
               read_runners: Callable[[str, str], Sequence[Mapping[str, Any]]] | None = None,
               read_jobs: Callable[[str], Any] | None = None) -> tuple[str, str]:
    if (env.get("ENABLED") or "").strip() != ENABLED_VALUE:
        return "", "vars.CI_SIGN_OWNED is not 1, so signing stays off the owned Macs"
    if (env.get("GITHUB_RUN_ATTEMPT") or "1").strip() not in ("", "1"):
        return "", "a re-run signs on Blacksmith"
    token, repo = env.get("ROUTE_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    if not (token and repo):
        return "", "owned runners could not be read live (no routing token), so none is offered"
    jobs_token = env.get("SNAPSHOT_TOKEN", "")
    if not (jobs_token or read_jobs):
        return "", "the signing jobs on owned Macs could not be counted (no actions: read token), so none is offered"
    # The runners are read BEFORE the signing jobs are counted. A signing job that made a mini busy in this
    # snapshot is then already listed when the count runs, so the count sees it and nothing is offered; one not
    # yet started left its mini drained in the snapshot, and the first-drained pick (no run-ID spread) names that
    # same mini, where glaeda's exclusive admission lets only one of the two in (the other is refused within
    # 300 s and its re-run takes Blacksmith).
    try:
        runners = (read_runners or (lambda t, r: pool.GitHub(t, r).runners()))(token, repo)
    except Exception as error:  # noqa: BLE001 - never fail the job; Blacksmith takes it
        print(f"::warning title=signing runner::could not list owned runners ({str(error)[:200]})")
        return "", "owned runners could not be read"
    try:
        held = owned_signing_jobs(read_jobs or pool.GitHub(jobs_token, repo).get)
    except Exception as error:  # noqa: BLE001 - never fail the job; Blacksmith takes it
        print(f"::warning title=signing runner::could not count the signing jobs on owned Macs ({str(error)[:200]})")
        return "", "the signing jobs on owned Macs could not be counted, so none is offered"
    if held >= MAX_OWNED_SIGNING:
        return "", f"{held} signing job(s) already hold an owned Mac (at most {MAX_OWNED_SIGNING} at once)"
    return drained_runner(runners, (env.get("OWNED_LABELS") or "").split())


def main(env: Mapping[str, str] = os.environ, argv: Sequence[str] = (),
         read_runners: Callable[[str, str], Sequence[Mapping[str, Any]]] | None = None,
         read_jobs: Callable[[str], Any] | None = None,
         read_snapshot: Callable[[str, str], Any] | None = None, now: dt.datetime | None = None,
         sleep: Callable[[float], None] = time.sleep) -> int:
    owned, owned_why = owned_pick(env, read_runners, read_jobs)
    if list(argv[:1]) == ["owned"]:
        write_output(env, {"owned": owned}, [f"owned: {owned or 'none'} ({owned_why})"])
        return 0
    now = now or dt.datetime.now(dt.timezone.utc)
    variable = (env.get("CANDIDATE") or "").strip()
    snapshot, problem = None, "no token to read the pool snapshot"
    token, repo = env.get("SNAPSHOT_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    if token and repo:
        reader = read_snapshot or (lambda t, r: pool.GitHub(t, r).snapshot(now=now))
        snapshot, problem = blacksmith_picker.read_snapshot(lambda: reader(token, repo), "signing runner",
                                                            sleep=sleep)
    try:
        attempt = max(1, int((env.get("GITHUB_RUN_ATTEMPT") or "1").strip() or "1"))
    except ValueError:
        attempt = 1
    # Without a fresh snapshot the Blacksmith pick is unverified and says so (nightly_sign_runner.place()).
    label, other, why, verified = blacksmith_picker.place(variable, snapshot, now, attempt, problem)
    if not verified:
        print(f"::warning title=signing runner::{why}")
    write_output(env, {"owned": owned, "runner": label, "alternate": other,
                       "placement": "verified" if verified else "unverified"},
                 [f"owned: {owned or 'none'} ({owned_why})", f"blacksmith: {why}; a re-run takes `{other}`"])
    return 0


if __name__ == "__main__":
    sys.exit(main(argv=sys.argv[1:]))
