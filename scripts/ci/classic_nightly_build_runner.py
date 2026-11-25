#!/usr/bin/env python3
"""Pick where main's nightly build-nightly-app runs: the pinned trusted mini, else a moving Blacksmith label.

build-nightly-app asked for the trusted pool and the pinned runner's own label
(["<vars.CI_SEED_TRUSTED_POOL>", "<vars.CI_NIGHTLY_TRUSTED_RUNNER>"]) on attempt 1 with no other
way out but the owned-pool rescue. While that one mini was busy or away the build waited: run
40466119349 queued 119.6 min and 40500497848 55 min (2026-10-27), and the rescue gave up on a 403.

This reads the pinned runner live once, before the build is queued:
- online and idle: `trusted=true`, and the build asks for the same pinned tuple as before;
- online and busy: look again every LOOK_SECONDS for up to WAIT_SECONDS, then Blacksmith;
- offline, or no runner carries both labels: Blacksmith now;
- the runner list could not be read: count the nightly builds already queued or running on the
  pinned runner label (BACKLOG, read with SNAPSHOT_TOKEN's actions: read); any, Blacksmith now;
  none, keep the pinned tuple (the rescue still watches it); that count unreadable too, keep the
  pinned tuple, with a warning. On 2026-11-25 the list was refused, a stale census left it unread,
  and every pick kept the pin: nine build-nightly-app jobs queued behind one mini, the oldest 124 min.

`blacksmith` is the Blacksmith macOS 26 label whose queue moves, by simple_pool_picker's one stall
rule over the queue janitor's snapshot: FIRST's label first, else 12 vCPU, then the other; with
both stalled, 6 vCPU (more slots); with no fresh snapshot, the first. nightly.yml's build pick
passes FIRST=6vcpu (#39585: blacksmith-12vcpu-macos-26 starts nothing while the 6 vCPU queue takes
every freed slot). A re-run of failed jobs keeps these outputs, so attempt 2 on takes `cloud`. Nothing here routes to any owned label other
than the pinned pair, so the ci-cache-writer keys and the Sentry token stay on the trusted mini.
FIRST (a label among those two, or its size, `6vcpu` or `12vcpu`) puts that label ahead: main's
nightly app build, its sign and verify jobs and the DEV publisher's Mac jobs take 6 vCPU while it
moves. With ENABLED unset the trusted pick is skipped and only `cloud` is read. `alternate` is the other label,
for a re-run, unless the snapshot shows it stalled or dead: then it is `cloud` itself.
A label the snapshot shows dead (simple_pool_picker.blacksmith_dead(): nothing running and no job started on it
for an hour; a snapshot up to six hours old still proves it) is never picked nor offered as `alternate` while
another label shows life. The stall rule alone could not tell it from a busy label: on 2026-10-30 every DEV
daily re-run (verify, tip-dmg-build) took the 12 vCPU `alternate` and queued there for hours while that label
had started nothing for about a day.
RUNNER_POOLS (vars.RUNNER_POOLS, runner_pools.py's one routing variable) is read too: a label its `_dead` marks
seen dead within MARK_TTL counts as dead, and with every candidate dead the pick is the variable's live macos_26
member (the pool keeps its first member then), never the other one. `alternate` never names a label the
snapshot or a mark shows dead, even when every candidate is dead: then it is `cloud` itself. Until 2026-10-31
dead_macos_26() dropped the evidence when it showed both labels dead, so a re-run of the DEV daily's verify and
tip-dmg-build still took blacksmith-12vcpu-macos-26 (05:44Z: 88 queued, none running, the oldest 1403 min).
`classic_nightly_build_runner.py prepare` prints only `trusted`, read once with no wait, and false
when the list cannot be read: prepare-nightly-variant (no secrets) takes the same pinned tuple while
that mini is idle right after the build, else its Blacksmith label. Its three legs ran about 1 min
each but queued 27-42 min on blacksmith-6vcpu-macos-26 in runs 40557789720 and 40567539918, and
run 40604652316's sat queued from 00:54:52Z with every Blacksmith macOS 26 label stalled, while the
mini that had just built the app sat idle. Signing and verify stay on Blacksmith.
It never fails the job and never prints an empty `cloud`:

    ROUTE_TOKEN=<runners: read> SNAPSHOT_TOKEN=<actions: read> TRUSTED_POOL=... TRUSTED_RUNNER=...
    RUNNER_POOLS=<vars.RUNNER_POOLS> ENABLED=1 classic_nightly_build_runner.py  -> trusted=true|false, cloud=<label>, alternate=<label>
"""

from __future__ import annotations

import base64
import datetime as dt
import gzip
import io
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import simple_pool_picker as picker  # noqa: E402

LARGE, SMALL = "blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26"
CANDIDATES = (LARGE, SMALL)
SIZES = {"12vcpu": LARGE, "6vcpu": SMALL}
# The pinned mini's previous nightly usually ends inside this; past it a cold Blacksmith build
# (about 60 min) starts sooner than the wait the 2026-10-27 runs saw.
WAIT_SECONDS = 5 * 60
LOOK_SECONDS = 30
TRUSTED_POOL = re.compile(r"glaeda-(?:root-)?trusted-(?:xl|std|light)-xcode-[0-9]+(?:\.[0-9]+)*")
TRUSTED_RUNNER = re.compile(r"glaeda-runner-[a-z0-9][a-z0-9-]*")
# The nightly's own runs read for the pinned runner's backlog when the runner list is unread.
NIGHTLY_WORKFLOW = "nightly.yml"
BACKLOG_RUNS = 10
BACKLOG_STATUSES = ("queued", "in_progress", "waiting", "pending", "requested")
# RUNNER_POOLS' dead marks (label -> when last seen dead) and the pool the candidates form. A mark older than
# runner_pools.DEAD_TTL is one its writer would drop (it re-marks a still-dead label every pass), so it proves nothing.
DEAD_KEY = picker.DEAD_MARKS_KEY
POOL = "macos_26"
MARK_TTL = dt.timedelta(minutes=picker.DEAD_MARK_TTL_MINUTES)
# vars.CI_RUNNER_STATE (cmuxterm-hq build-fleet/mini-ops/RUNNER-STATE.md): the registration census, read when the
# live runner list is refused. On 2026-11-25 the routing token got 403 listing runners, the unread list kept the
# pinned pair, no online runner carried both labels, and run 45540008136's build-nightly-app sat queued over an hour.
CENSUS_SCHEMA = "runner-state/v1"
CENSUS_MAX_ENCODED = 48 * 1024
CENSUS_MAX_DECODED = 2 * 1024 * 1024
CENSUS_MAX_AGE = dt.timedelta(minutes=30)


def runner_state(pool: str, runner: str, runners: Sequence[Mapping[str, Any]] | None) -> str:
    """'idle', 'busy', 'offline' or 'unread' for the runner carrying both pinned labels."""
    if runners is None:
        return "unread"
    online = [item for item in runners if item.get("status") == "online"
              and {pool, runner} <= {str(label.get("name") if isinstance(label, Mapping) else label)
                                     for label in item.get("labels") or ()}]
    if not online:
        return "offline"
    return "idle" if any(not item.get("busy") for item in online) else "busy"


def census_runners(raw: str | None, now: dt.datetime) -> list[Mapping[str, Any]] | None:
    """The runner rows of vars.CI_RUNNER_STATE (gzip, base64, runner-state/v1), or None when it is missing, out of
    shape, incomplete or more than CENSUS_MAX_AGE old: then the list stays unread, as before."""
    if not raw or len(raw) > CENSUS_MAX_ENCODED:
        return None
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(base64.b64decode(raw, validate=True))) as source:
            body = source.read(CENSUS_MAX_DECODED + 1)
        state = json.loads(body) if len(body) <= CENSUS_MAX_DECODED else None
        if not isinstance(state, Mapping) or state.get("schema") != CENSUS_SCHEMA or state.get("complete") is not True:
            return None
        stamp = dt.datetime.fromisoformat(str(state.get("generated_at")).replace("Z", "+00:00"))
        if stamp.tzinfo is None or not -dt.timedelta(seconds=5) <= now - stamp <= CENSUS_MAX_AGE:
            return None
        rows = list(state.get("repository_runners") or [])
        groups = state.get("runner_groups")
        for group in (groups.values() if isinstance(groups, Mapping) else ()):
            rows += list(group or [])
    except Exception:  # noqa: BLE001 - an unreadable census keeps the old behaviour
        return None
    return [row for row in rows if isinstance(row, Mapping) and isinstance(row.get("labels") or [], list)]


def trusted_route(pool: str, runner: str, read: Callable[[], Sequence[Mapping[str, Any]] | None],
                  enabled: bool, attempt: str, *, wait_seconds: float = WAIT_SECONDS,
                  look_seconds: float = LOOK_SECONDS, sleep: Callable[[float], None] = time.sleep,
                  clock: Callable[[], float] = time.monotonic, unread_keeps: bool = True,
                  backlog: Callable[[], int | None] | None = None) -> tuple[bool, str]:
    """(whether the build asks for the pinned trusted tuple, why).

    `unread_keeps` False (the prepare pick) takes Blacksmith when the runner list cannot be read."""
    if not enabled:
        return False, "not a main push or schedule with the owned pool on"
    if attempt not in ("", "1"):
        return False, f"attempt {attempt} takes Blacksmith"
    if not (TRUSTED_POOL.fullmatch(pool) and TRUSTED_RUNNER.fullmatch(runner)):
        return False, "the trusted pool or runner variable is unset or not a trusted label"
    deadline = clock() + wait_seconds
    while True:
        state = runner_state(pool, runner, read())
        if state == "idle":
            return True, f"`{runner}` is online and idle"
        if state == "unread":
            if not unread_keeps:
                return False, "the runner list could not be read"
            waiting = backlog() if backlog is not None else None
            if waiting:
                return False, (f"the runner list could not be read and {waiting} nightly build(s) already queue or "
                               f"run on `{runner}`")
            if waiting == 0:
                return True, (f"the runner list could not be read and no other nightly build queues on `{runner}`, "
                              "so it keeps the build (the rescue watches it)")
            return True, f"the runner list could not be read, so `{runner}` keeps the build (the rescue watches it)"
        if state == "offline":
            return False, f"`{runner}` is offline"
        if clock() + look_seconds > deadline:
            return False, f"`{runner}` stayed busy for {wait_seconds / 60:g} min"
        sleep(look_seconds)


def candidates(first: str = "") -> tuple[str, ...]:
    """CANDIDATES, with `first` ahead when it is one of them or its size (the job's own default label).

    A size lets a nightly step name the label without naming Blacksmith outside a runs-on
    (tests/test_ci_nightly_off_blacksmith.py)."""
    first = SIZES.get(first, first)
    return (first, *(label for label in CANDIDATES if label != first)) if first in CANDIDATES else CANDIDATES


def runner_pools(raw: str | None) -> Mapping[str, Any]:
    """The RUNNER_POOLS value, or {} when it is unset or not a JSON object (simple_pool_picker.runner_pools())."""
    return picker.runner_pools(raw)


def marked_dead(pools: Mapping[str, Any] | None, now: dt.datetime) -> set[str]:
    """The candidates RUNNER_POOLS' `_dead` marks saw dead within MARK_TTL of `now` (simple_pool_picker.marked_dead())."""
    return picker.marked_dead(pools, now) & set(CANDIDATES)


def every_dead(evidence: Mapping[str, Any] | None, now: dt.datetime, pools: Mapping[str, Any] | None = None) -> set[str]:
    """Every candidate the snapshot (`evidence`, fresh or not) or a RUNNER_POOLS mark shows dead, all of them included."""
    return {label for label in CANDIDATES if picker.blacksmith_dead(evidence, label, now)} | marked_dead(pools, now)


def dead_labels(evidence: Mapping[str, Any] | None, now: dt.datetime, pools: Mapping[str, Any] | None = None) -> set[str]:
    """The candidates every_dead() names, or none when it names every one: with no label showing life it says
    nothing to choose by, and the caller's own order holds (live_member() leads it then)."""
    dead = every_dead(evidence, now, pools)
    return set() if dead >= set(CANDIDATES) else dead


def live_member(evidence: Mapping[str, Any] | None, now: dt.datetime, pools: Mapping[str, Any] | None) -> str:
    """With every candidate dead, RUNNER_POOLS' live macos_26 member (runner_pools.py keeps the pool's first member
    when every member is marked), else ""."""
    member = (pools or {}).get(POOL)
    if member in CANDIDATES and every_dead(evidence, now, pools) >= set(CANDIDATES):
        return str(member)
    return ""


def blacksmith_route(snapshot: Mapping[str, Any] | None, now: dt.datetime,
                     first: str = "", evidence: Mapping[str, Any] | None = None,
                     pools: Mapping[str, Any] | None = None) -> tuple[str, str]:
    """(the first Blacksmith macOS 26 label whose queue moves, why).

    `snapshot` is a fresh snapshot (None when there is none); `evidence` a readable one too old for the stall rule,
    read only for dead labels (dead_labels()); `pools` the RUNNER_POOLS value, for its dead marks and live member."""
    fresh = isinstance(snapshot, Mapping) and isinstance(snapshot.get("pools"), Mapping)
    member = live_member(snapshot if fresh else evidence, now, pools)
    if member:
        return member, f"every Blacksmith macOS 26 label is taking a breather; `{member}`, RUNNER_POOLS' live {POOL} member"
    order = candidates(first)
    dead = dead_labels(snapshot if fresh else evidence, now, pools)
    if not fresh:
        label = next(label for label in order if label not in dead)
        return label, f"no fresh pool snapshot, so `{label}`" + (
            f", past resting `{order[0]}`" if label != order[0] else "")
    pools = snapshot["pools"]
    try:
        generated = dt.datetime.fromisoformat(str(snapshot.get("generated_at")).replace("Z", "+00:00"))
        age = max(0.0, (now - generated).total_seconds() / 60)
    except (TypeError, ValueError):
        age = 0.0

    def field(label: str, key: str) -> float:
        entry = pools.get(label)
        try:
            return max(0.0, float(entry.get(key, 0))) if isinstance(entry, Mapping) else 0.0
        except (TypeError, ValueError):
            return 0.0

    stuck = [label for label in order
             if picker.blacksmith_stalled(int(field(label, "queued")), field(label, "oldest_queued_minutes") + age)
             or label in dead]
    moving = [label for label in order if label not in stuck]
    if not moving:
        # A busy label still starts jobs; a dead one starts none.
        label = SMALL if SMALL not in dead else next(label for label in order if label not in dead)
        return label, (f"every Blacksmith macOS 26 label is busy right now; `{label}` "
                       + ("has the most slots" if label == SMALL else f"still starts jobs (`{SMALL}` is resting)"))
    return moving[0], f"`{moving[0]}`" + (f", past {'resting' if stuck[0] in dead else 'busy'} `{stuck[0]}`"
                                          if moving[0] != order[0] else "")


def alternate(label: str, snapshot: Mapping[str, Any] | None = None, now: dt.datetime | None = None,
              evidence: Mapping[str, Any] | None = None, pools: Mapping[str, Any] | None = None) -> str:
    """The other Blacksmith macOS 26 label, unless the snapshot shows it stalled (`snapshot`, fresh) or dead
    (`snapshot` or `evidence`, or a RUNNER_POOLS mark in `pools`: every_dead(), so also when every label shows
    dead): then `label` itself. The jobs take it on an attempt later than the
    one that made the pick (`attempt`): a re-run of failed jobs keeps the pick job's outputs, and GitHub never
    re-routes a queued job, so the re-run leaves the label that stalled after the pick. A re-run of all
    jobs runs the picker again, and that attempt takes the fresh pick. With no snapshot at all the other label
    is unverified and still offered (the behaviour before the snapshot existed)."""
    if label not in CANDIDATES:
        return SMALL
    other = next(other for other in CANDIDATES if other != label)
    now = now or dt.datetime.now(dt.timezone.utc)
    fresh = isinstance(snapshot, Mapping) and isinstance(snapshot.get("pools"), Mapping)
    if other in every_dead(snapshot if fresh else evidence, now, pools):
        return label
    if fresh and blacksmith_route(snapshot, now, other, pools=pools)[0] != other:
        return label
    return other


def pinned_backlog(get: Callable[[str], Any], runner: str, own_run: str) -> int:
    """Jobs of the nightly's other unfinished runs that queue or run on the pinned runner label `runner`.

    `get` is a GET under the repository. At most 1 + BACKLOG_RUNS requests, newest runs first."""
    runs: list[Mapping[str, Any]] = []
    for status in ("in_progress", "queued"):
        page = get(f"/actions/workflows/{NIGHTLY_WORKFLOW}/runs?status={status}&per_page={BACKLOG_RUNS}")
        runs += [run for run in (page.get("workflow_runs") or []) if isinstance(run, Mapping)]
    count = 0
    seen: set[str] = set()
    for run in runs[:BACKLOG_RUNS]:
        run_id = str(run.get("id") or "")
        if not run_id or run_id == own_run or run_id in seen:
            continue
        seen.add(run_id)
        jobs = get(f"/actions/runs/{run_id}/jobs?filter=latest&per_page=100").get("jobs") or []
        count += sum(1 for job in jobs if isinstance(job, Mapping) and job.get("status") in BACKLOG_STATUSES
                     and runner in (job.get("labels") or ()))
    return count


def main(env: Mapping[str, str] = os.environ, argv: Sequence[str] = (),
         read_runners: Callable[[str, str], Sequence[Mapping[str, Any]]] | None = None,
         read_snapshot: Callable[[str, str], Any] | None = None, now: dt.datetime | None = None,
         read_backlog: Callable[[str, str, str, str], int] | None = None,
         sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic,
         wall: Callable[[], dt.datetime] = lambda: dt.datetime.now(dt.timezone.utc)) -> int:
    repo = env.get("GITHUB_REPOSITORY", "")
    route_token = env.get("ROUTE_TOKEN", "")

    def read() -> Sequence[Mapping[str, Any]] | None:
        if not (route_token and repo):
            return census_runners(env.get("RUNNER_STATE"), now or wall())
        try:
            if read_runners is not None:
                return read_runners(route_token, repo)
            import pr_runner_pool  # noqa: PLC0415 - only for the live read

            return pr_runner_pool.GitHub(route_token, repo).runners()
        except Exception as error:  # noqa: BLE001 - never fail the job
            print(f"::warning title=classic nightly build runner::could not list runners ({str(error)[:200]})")
            rows = census_runners(env.get("RUNNER_STATE"), now or wall())
            if rows is not None:
                print("classic nightly build runner: judged the pinned runner from vars.CI_RUNNER_STATE")
            return rows

    def backlog() -> int | None:
        token = env.get("SNAPSHOT_TOKEN", "")
        if not (token and repo):
            return None
        try:
            if read_backlog is not None:
                return read_backlog(token, repo, (env.get("TRUSTED_RUNNER") or "").strip(),
                                    env.get("GITHUB_RUN_ID", ""))
            import pr_runner_pool  # noqa: PLC0415 - only for the live read

            return pinned_backlog(pr_runner_pool.GitHub(token, repo).get, (env.get("TRUSTED_RUNNER") or "").strip(),
                                  env.get("GITHUB_RUN_ID", ""))
        except Exception as error:  # noqa: BLE001 - never fail the job
            print(f"::warning title=classic nightly build runner::could not count the pinned runner's backlog "
                  f"({str(error)[:200]})")
            return None

    # Wall time before the wait: the snapshot's queue ages are read against it plus the wait.
    now = now or wall()
    started = clock()
    prepare = list(argv[:1]) == ["prepare"]
    trusted, trusted_why = trusted_route((env.get("TRUSTED_POOL") or "").strip(),
                                         (env.get("TRUSTED_RUNNER") or "").strip(), read,
                                         (env.get("ENABLED") or "").strip() == "1",
                                         (env.get("GITHUB_RUN_ATTEMPT") or "").strip(), sleep=sleep, clock=clock,
                                         wait_seconds=0 if prepare else WAIT_SECONDS, unread_keeps=not prepare,
                                         backlog=backlog)
    if prepare:
        line = f"prepare: {'trusted' if trusted else 'blacksmith'} ({trusted_why})"
        print(f"classic nightly build runner: {line}")
        if env.get("GITHUB_OUTPUT"):
            with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
                handle.write(f"trusted={'true' if trusted else 'false'}\n")
        if env.get("GITHUB_STEP_SUMMARY"):
            with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
                handle.write(f"\nNightly prepare runner:\n- {line}\n")
        return 0
    now += dt.timedelta(seconds=max(0.0, clock() - started))
    snapshot = evidence = None
    snapshot_token = env.get("SNAPSHOT_TOKEN", "")
    if snapshot_token and repo:
        try:
            if read_snapshot is not None:
                snapshot = evidence = read_snapshot(snapshot_token, repo)
            else:
                import pr_runner_pool  # noqa: PLC0415

                snapshot = evidence = pr_runner_pool.GitHub(snapshot_token, repo).snapshot(now=now)
                if snapshot is not None and pr_runner_pool.snapshot_problem(snapshot, now):
                    # Too old for the stall rule; still read for dead labels (blacksmith_dead()).
                    snapshot = None
        except Exception as error:  # noqa: BLE001 - the default label keeps its say
            print(f"::warning title=classic nightly build runner::could not read the pool snapshot ({str(error)[:200]})")
    evidence = evidence if isinstance(evidence, Mapping) else None
    pools = runner_pools(env.get("RUNNER_POOLS"))
    blacksmith, blacksmith_why = blacksmith_route(snapshot, now, (env.get("FIRST") or "").strip(), evidence, pools)
    other = alternate(blacksmith, snapshot, now, evidence, pools)
    # Every candidate dead (the snapshot, fresh or not, or a RUNNER_POOLS mark): `cloud` is then a label that starts
    # nothing, so a job with no owned Mac to take (the DEV publisher's advisory tip-deltas) skips rather than queue.
    dead = every_dead(evidence, now, pools) >= set(CANDIDATES)
    lines = [f"trusted: {'yes' if trusted else 'no'} ({trusted_why})", f"blacksmith: {blacksmith} ({blacksmith_why})"]
    if dead:
        lines.append("every Blacksmith macOS 26 label is resting for now (dead=true)")
    for line in lines:
        print(f"classic nightly build runner: {line}")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"trusted={'true' if trusted else 'false'}\ncloud={blacksmith}\n"
                         f"alternate={other}\nattempt={(env.get('GITHUB_RUN_ATTEMPT') or '1').strip()}\n"
                         f"dead={'true' if dead else 'false'}\n")
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write("\nNightly build runner:\n" + "".join(f"- {line}\n" for line in lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(argv=sys.argv[1:]))
