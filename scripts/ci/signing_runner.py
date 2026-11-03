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
  names it, which nightly.yml's does and the DEV daily's does not) on the mini whose busy runners finish soonest,
  and only one they all finish within DRAIN_HORIZON_SECONDS (DRAIN_BY_REMAINING_TIME, below). The slot listens
  however full its mini is, and the waiting signing job, a nightly job, stops every other admission and holds every
  other runner's gate there (glaeda FEED_FIRST): the running jobs finish, nothing new starts, and it takes the whole
  mini within glaeda's SIGNING_DRAIN_WAIT_S (3600 s since glaeda #1768), or is refused and the run's Blacksmith twin
  signs. The hold is the waiting job's own marker, so it ends with the job and never strands the mini. With no such
  mini, nothing is offered and the job signs on Blacksmith at once.
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
job an owned runner refused or left queued leaves the fleet. With PICK_ON_RERUN=1
(nightly.yml's legacy sign) a re-run that runs the picker again is offered an
owned Mac too, and the workflow reads it only on that attempt. It never fails the
job and never prints an empty `runner`:

    ENABLED=<vars.CI_SIGN_OWNED> ROUTE_TOKEN=<org runners: read> OWNED_LABELS='<a> <b>' \\
        SNAPSHOT_TOKEN=<actions: read> CANDIDATE=<vars.MACOS_RUNNER_26> signing_runner.py
    -> owned=..., runner=..., alternate=..., placement=... in $GITHUB_OUTPUT

`signing_runner.py owned` prints `owned` and its shared `owned_pool` label
(pick-nightly-sign-runner already prints the Blacksmith pair).
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
import warm_distance  # noqa: E402
from nightly_build_runner import NIGHTLY_SLOT_LABEL, owned_label  # noqa: E402

ENABLED_VALUE = "1"
# The signing jobs glaeda gives the whole mini (glaeda SIGNING_JOBS; tests/test_ci_signing_owned_mac.py keeps the
# lists equal): the workflow file and the job's display name (its `name:` or id; a matrix adds " (...)").
SIGNING_JOBS = {
    "nightly.yml": ("build-sign-notarize-nightly", "recover-nightly-next-notarization", "sign-nightly-identity-legacy",
                    "generate-nightly-deltas", "publish-nightly", "publish-nightly-next-github",
                    "publish-nightly-next-github-names"),
    "release.yml": ("build-sign-notarize",),
    "repair-v0-64-25-helper-rpaths.yml": ("repair",),
    "cmux-next-dev-daily.yml": ("Sign cmux NEXT DEV",),
}
# At most this many minis are held for signing at once (the coordinator's cap, 2026-10-29): a drained mini is taken
# whole, so each one held is a mini's worth of PR and nightly work sent elsewhere.
MAX_OWNED_SIGNING = 1
# DRAIN_BY_REMAINING_TIME: the mini a nightly signing job drains is chosen by when its busy runners finish, not by how
# many there are. On 2026-10-30 cmux12s's nightly slot took 18 legacy signing jobs; 11 waited glaeda's whole drain
# (600 s then; 3600 s since glaeda #1768) and were refused, because a PR job admitted just before (swift-test on its gui
# runner, 15 to 45 min) held 4 of its 14 units: "fewest busy runners" counted that mini as nearly free. Each futile
# drain also held every PR job off the mini for its whole drain. A busy runner's remaining time comes from the queue
# janitor's pool snapshot (which job each owned runner runs and since when, `running`) and warm_distance's job lengths
# (remaining_seconds), the same estimate pr_runner_pool's warm routing uses; no other GitHub read. A busy runner with no
# estimate (no snapshot entry, a job the model has no length for, one past its p90, or a snapshot older than
# DRAIN_SNAPSHOT_MAX_MINUTES) keeps its mini busy, and a mini is offered only when every busy runner on it finishes
# within DRAIN_HORIZON_SECONDS. With none, the job takes Blacksmith now instead of a drain that cannot end inside the
# bound.
DRAIN_HORIZON_SECONDS = 120.0
# DRAIN_ANYWAY: a caller that sets DRAIN_ANYWAY=1 (nightly.yml's legacy-identity sign) still drains a mini when none
# frees up within the horizon, instead of signing on Blacksmith. Leo, 2026-10-30, when every legacy sign since #28555
# queued on blacksmith-6vcpu-macos-26 (15 runners, all busy) and blacksmith-12vcpu-macos-26 (none online) while the
# old feed sat a day behind: "JUST USE ONE OF THE EXISTING FUCKIBNG FLEET MINIS ... STOP FALLING ONLY TO A FUCKING
# BLACKSMITH THAT ISN'T AVAILABLE". A waiting nightly job comes first on the fleet (the rulebook), so the mini whose
# busy runners finish soonest (a known estimate first, then the fewest busy runners, then by name) is drained; glaeda
# still gives the job the whole mini or refuses it, and a refusal still sends the Blacksmith twin.
DRAIN_ANYWAY_VALUE = "1"
# The oldest pool snapshot a drain is chosen from. The janitor writes one about every 10 minutes; an older one may list
# a job that has since ended on a runner that now runs another, whose end it would put too soon. Older counts as none.
DRAIN_SNAPSHOT_MAX_MINUTES = 15.0
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


def drain_seconds(names: Sequence[str], running: Mapping[str, Any] | None, model: Mapping[str, Any],
                  now: dt.datetime) -> float | None:
    """When the last of these busy runners finishes its job, in seconds from now (DRAIN_BY_REMAINING_TIME), or None
    when any of them has no estimate: unknown counts as busy."""
    if running is None:
        return None
    longest = 0.0
    for name in names:
        left = warm_distance.remaining_seconds(running.get(name), model, now)
        if left is None:
            return None
        longest = max(longest, left)
    return longest


def drained_runner(runners: Sequence[Mapping[str, Any]], labels: Sequence[str], seed: str = "",
                   running: Mapping[str, Any] | None = None, model: Mapping[str, Any] | None = None,
                   now: dt.datetime | None = None, drain_anyway: bool = False) -> tuple[str, str]:
    """(the JSON runs-on array for an idle runner on a mini with no busy runner, else one to drain, or "", why).

    A candidate runner is online, idle, carries one of `labels` (an owned pool label) and its own
    `glaeda-runner-<name>` label. Its mini is drained when no runner of that mini, whatever its
    labels or status, is busy now (an offline runner GitHub calls idle is a parked slot and runs nothing).
    `seed` picks among the drained minis; owned_pick passes none, so two pickers at once name the same
    mini and glaeda admits only one of them. With no drained mini, a candidate carrying a nightly slot label
    (NIGHTLY_SLOT_LABEL) is offered on the mini whose busy runners all finish soonest, and only within
    DRAIN_HORIZON_SECONDS (DRAIN_BY_REMAINING_TIME: `running` is the pool snapshot's runner -> {job, started_at},
    None when there is no fresh one, and `model` warm_distance's); glaeda drains that mini for the signing job (the
    module docstring). The first by name on a tie, so two pickers name the same one.
    """
    # The owned labels nightly_build_runner offers: a persistent pool or glaeda's nightly slot, which
    # vars.CI_NIGHTLY_NEXT_BUILD_RUNNER may name (its hook still admits a signing job only as the exclusive class).
    wanted = [label for label in labels if label and owned_label(label)]
    if not wanted:
        return "", f"no owned pool label among {list(labels) or 'none'}"
    busy: collections.Counter[str] = collections.Counter()
    busy_names: dict[str, list[str]] = {}
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
            busy_names.setdefault(mini, []).append(name)
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
        moment = now or dt.datetime.now(dt.timezone.utc)
        weights = model if model is not None else warm_distance.load_model()
        waits: dict[str, float | None] = {}
        slots = []
        anyway = []
        for mini, found in idle.items():
            for label, name in found:
                if not NIGHTLY_SLOT_LABEL.fullmatch(label):
                    continue
                if mini not in waits:
                    waits[mini] = drain_seconds(busy_names.get(mini, []), running, weights, moment)
                wait = waits[mini]
                if wait is not None and wait <= DRAIN_HORIZON_SECONDS:
                    slots.append((wait, mini, label, name))
                # DRAIN_ANYWAY: known waits first (soonest), then unknown ones by fewest busy runners.
                anyway.append((wait is None, wait or 0.0, busy[mini], mini, label, name))
        if slots:
            wait, mini, label, name = sorted(slots)[0]
            return (json.dumps([label, pool.runner_label(name)], separators=(",", ":")),
                    f"`{name}` on {mini}, to drain: no mini is drained now, and glaeda holds every new job off "
                    f"{mini} while this one waits for its {busy[mini]} busy runner(s) to finish (about "
                    f"{wait:.0f} s)")
        if anyway and drain_anyway:
            unknown_wait, wait, count, mini, label, name = sorted(anyway)[0]
            return (json.dumps([label, pool.runner_label(name)], separators=(",", ":")),
                    f"`{name}` on {mini}, to drain anyway (DRAIN_ANYWAY): no mini frees up within "
                    f"{DRAIN_HORIZON_SECONDS:g} s, and glaeda holds every new job off {mini} while this one waits for "
                    f"its {count} busy runner(s) to finish"
                    + (" (remaining time unknown)" if unknown_wait else f" (about {wait:.0f} s)"))
        if waits:
            unknown = sorted(mini for mini, wait in waits.items() if wait is None)
            return "", (f"no mini with an idle nightly slot frees up within {DRAIN_HORIZON_SECONDS:g} s "
                        f"({len(unknown)} of {len(waits)} with a busy runner whose remaining time is unknown"
                        f"{' (no fresh pool snapshot)' if running is None else ''}), so this job signs on Blacksmith "
                        "now instead of draining one")
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
                    labels = {str(label) for label in job.get("labels") or []}
                    owned_route = any(label.startswith(pool.RUNNER_LABEL_PREFIX) or owned_label(label)
                                      for label in labels)
                    if (name in names and job.get("status") in ("queued", "in_progress", "waiting", "pending", "requested")
                            and owned_route):
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
               read_jobs: Callable[[str], Any] | None = None,
               read_snapshot: Callable[[str, str], Any] | None = None, now: dt.datetime | None = None,
               sleep: Callable[[float], None] = time.sleep,
               bounded_snapshot: Callable[[str, str], tuple[Any, str]] | None = None) -> tuple[str, str]:
    if (env.get("ENABLED") or "").strip() != ENABLED_VALUE:
        return "", "vars.CI_SIGN_OWNED is not 1, so signing stays off the owned Macs"
    # A re-run signs on Blacksmith unless its workflow picks again on every attempt and reads the pick only on the
    # attempt that made it (PICK_ON_RERUN=1, nightly.yml's legacy sign): a re-run of failed jobs keeps the old pick,
    # and its runs-on then takes Blacksmith.
    if (env.get("GITHUB_RUN_ATTEMPT") or "1").strip() not in ("", "1") and (env.get("PICK_ON_RERUN") or "") != "1":
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
    # DRAIN_BY_REMAINING_TIME: what each busy owned runner runs and since when, from the queue janitor's pool snapshot
    # (two requests, the read main() makes for the Blacksmith pick); none, or a stale one, leaves every busy runner's
    # remaining time unknown, so no busy mini is drained.
    moment = now or dt.datetime.now(dt.timezone.utc)
    reader = read_snapshot or (lambda t, r: pool.GitHub(t, r).snapshot(now=moment))
    bounded = bounded_snapshot or (lambda t, r: blacksmith_picker.read_snapshot(lambda: reader(t, r), "signing runner",
                                                                                 sleep=sleep))
    snapshot, _ = bounded(jobs_token, repo) if jobs_token else (None, "")
    running = snapshot.get("running") if (not pool.snapshot_problem(snapshot, moment)
                                          and (pool.snapshot_age_minutes(snapshot, moment) or 0.0)
                                          <= DRAIN_SNAPSHOT_MAX_MINUTES
                                          and isinstance(snapshot.get("running"), Mapping)) else None
    return drained_runner(runners, (env.get("OWNED_LABELS") or "").split(), running=running, now=moment,
                          drain_anyway=(env.get("DRAIN_ANYWAY") or "").strip() == DRAIN_ANYWAY_VALUE)


def owned_pool_label(owned: str) -> str:
    """Return the shared pool label from an owned pick, never its per-runner label."""
    if not owned:
        return ""
    try:
        labels = json.loads(owned)
    except (TypeError, ValueError):
        return ""
    return labels[0] if isinstance(labels, list) and labels and isinstance(labels[0], str) else ""


def main(env: Mapping[str, str] = os.environ, argv: Sequence[str] = (),
         read_runners: Callable[[str, str], Sequence[Mapping[str, Any]]] | None = None,
         read_jobs: Callable[[str], Any] | None = None,
         read_snapshot: Callable[[str, str], Any] | None = None, now: dt.datetime | None = None,
         sleep: Callable[[float], None] = time.sleep) -> int:
    now = now or dt.datetime.now(dt.timezone.utc)
    reader = read_snapshot or (lambda t, r: pool.GitHub(t, r).snapshot(now=now))
    kept: list[tuple[Any, str]] = []

    def bounded(token: str, repo: str) -> tuple[Any, str]:
        """One bounded snapshot read (with its retries) for both picks; a failed read is kept too, so the Blacksmith
        pick never retries what the owned pick already could not read."""
        if not kept:
            kept.append(blacksmith_picker.read_snapshot(lambda: reader(token, repo), "signing runner", sleep=sleep))
        return kept[0]

    owned, owned_why = owned_pick(env, read_runners, read_jobs, read_snapshot, now, sleep, bounded)
    # A shared pool label is only safe once the controller can prove every eligible listener has the
    # exclusive-capable hook. That aggregate does not exist yet, so publication controls use their
    # trusted Blacksmith fallback while the runner-specific signing pick remains unchanged.
    owned_pool = ""
    owned_pool_why = "shared owned-pool publication route withheld until the controller supplies hook evidence"
    if list(argv[:1]) == ["owned"]:
        write_output(env, {"owned": owned, "owned_pool": owned_pool},
                     [f"owned: {owned or 'none'} ({owned_why})", f"owned_pool: none ({owned_pool_why})"])
        return 0
    variable = (env.get("CANDIDATE") or "").strip()
    snapshot, problem = None, "no token to read the pool snapshot"
    token, repo = env.get("SNAPSHOT_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    if token and repo:
        snapshot, problem = bounded(token, repo)
    try:
        attempt = max(1, int((env.get("GITHUB_RUN_ATTEMPT") or "1").strip() or "1"))
    except ValueError:
        attempt = 1
    # Without a fresh snapshot the Blacksmith pick is unverified and says so (nightly_sign_runner.place()).
    label, other, why, verified = blacksmith_picker.place(variable, snapshot, now, attempt, problem)
    if not verified:
        print(f"::warning title=signing runner::{why}")
    write_output(env, {"owned": owned, "owned_pool": owned_pool, "runner": label, "alternate": other,
                       "placement": "verified" if verified else "unverified"},
                 [f"owned: {owned or 'none'} ({owned_why})", f"owned_pool: none ({owned_pool_why})",
                  f"blacksmith: {why}; a re-run takes `{other}`"])
    return 0


if __name__ == "__main__":
    sys.exit(main(argv=sys.argv[1:]))
