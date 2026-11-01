#!/usr/bin/env python3
"""Place jobs that run anywhere: fleet Linux first, then a free owned mini, Blacksmith last.

Leo, 2026-10-31, after Blacksmith cut us off at about $10k a day: "y'know, we'll have to be
more self-reliant and size the stuff better" and "i mean the linux things cant our minis just
run them". Some jobs need neither Linux nor Blacksmith: stdlib Python, bash and bun checks
(cmux-next checks, the cmux-next CI guard group, the release-notary guard group, the tooling
tests) and the cmux-tui macOS targets, which are Mac builds. They took Blacksmith Linux 16 or
32 vCPU on every pull request and push (about 1.17M vCPU-minutes a day, 2026-10-31).

A workflow's placement step runs this before those jobs, on attempt 1 (and the rescue bot's
attempt 2) of a trusted run. Each job in JOBS, in priority order, gets:

1. fleet Linux: vars.LINUX_RUNNER (FLEET_LINUX) when it names one of our own Linux runners
   (not a Blacksmith label, not a GitHub-hosted image). MAC_FIRST jobs skip this step: a macOS
   target builds natively on a Mac first.
2. a free mini: the side label (SIDE_LABEL, vars.CI_SIDE_LANE_RUNNER) or the same label on a
   wider class (side_lane_placement.side_route()), one job per runner idle now less the jobs the
   pool snapshot already shows queued there, so no job queues behind a busy mini. A mini takes
   none while a nightly or release job is queued on any label of its family (the janitor
   snapshot's `reserved_queued`): nightly jobs come first on the fleet. An unread runner list or
   no fresh snapshot places nothing there (nothing is known to be free or to have no nightly).
   A nightly run's own jobs (NIGHTLY=1, nightly.yml) skip that refusal: they are the nightly
   jobs that come first. They still take only runners idle now beyond the label's queue, and
   once queued there the janitor counts them as `reserved_queued`, so pull request placements
   stay off those minis while they wait.
3. the job's own Blacksmith expression, which the workflow keeps as the last alternative of
   runs-on (with its CI_CLOUD_OVERFLOW_SAVED failover).

Only runners idle at placement time take a job, so a placed job starts within seconds; the
rest go to Blacksmith at once rather than to a queue.

Outputs (GITHUB_OUTPUT), job keys delimited by spaces with one at each end so a runs-on's
contains(' <key> ') matches whole keys only:
- `linux_runner`: FLEET_LINUX, or empty;
- `linux_jobs`: the jobs that take it;
- `mini_runner`: the side label the idle minis carry, or empty;
- `mini_jobs`: the jobs that take it.
For early nightly controls, unread capacity keeps portable jobs on the configured
owned-mini pool. Other callers write empty values and keep their Blacksmith route.

LINUX_ONLY jobs (the nightly signer compiler emits a Linux executable) never
take a mini. NIGHTLY_WAIT_FOR_FLEET=1 retries placement for at most three minutes
before returning unplaced jobs to overflow. The process-wide deadline bounds
reads too, and main always clears its alarm and restores the previous handler.
REQUIRE_LIVE_CAPACITY=1 never emits an owned-mini label without a fresh live
capacity observation, including after the admission wait expires.
"""
from __future__ import annotations

import dataclasses
import datetime as dt
import importlib.util
import os
import signal
import sys
import time
from pathlib import Path
from typing import Any, Mapping, Sequence


def _load(name: str):
    path = Path(__file__).with_name(f"{name}.py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(name, module)
    spec.loader.exec_module(module)
    return sys.modules[name]


pool = _load("pr_runner_pool")
side = _load("side_lane_placement")

# Labels that are not our own Linux fleet: Blacksmith, and GitHub's hosted images (never in the
# routing order at all).
NOT_FLEET_LINUX = ("blacksmith-", "ubuntu-", "macos-", "windows-", "glaeda-")
# Keep the step below its own timeout; early nightly controls retain their fleet fallback.
DEADLINE_SECONDS = 60


class Deadline(BaseException):
    """A whole-operation deadline that per-request error handlers cannot swallow."""


@dataclasses.dataclass(frozen=True)
class Placement:
    linux_runner: str = ""
    linux_jobs: tuple[str, ...] = ()
    mini_runner: str = ""
    mini_jobs: tuple[str, ...] = ()
    why: str = ""


def fleet_linux(label: str) -> str:
    """`label` when it names one of our own Linux runners, else ""."""
    label = (label or "").strip()
    if not label or label.startswith(NOT_FLEET_LINUX) or "${{" in label:
        return ""
    return label


def family(label: str) -> str:
    """The owned family (`<class>-xcode-<version>`, namespaced) of any owned label, else ""."""
    match = pool.OWNED_LABEL.fullmatch(label or "")
    if not match:
        return ""
    parts = [part for part in label.split("-")[1:] if part not in pool.ROLE_NAMES and part != "fast"]
    return "-".join(parts)


def nightly_waiting(snapshot: Mapping[str, Any] | None, label: str) -> int:
    """Nightly and release jobs the snapshot shows queued on any label of `label`'s family."""
    pools = (snapshot or {}).get("pools") or {}
    own = family(label)
    if not own:
        return 0
    return sum(int((entry or {}).get("reserved_queued") or 0)
               for name, entry in pools.items() if family(str(name)) == own)


def queued_on(snapshot: Mapping[str, Any] | None, label: str) -> int:
    """Jobs the snapshot shows queued on `label` itself (they take its idle runners first)."""
    entry = ((snapshot or {}).get("pools") or {}).get(label) or {}
    return int(entry.get("queued") or 0)


def eligible(env: Mapping[str, str]) -> str:
    """Why this run places nothing on a mini before reading anything, or ""."""
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip() or "1"
    actor = (env.get("GITHUB_TRIGGERING_ACTOR") or "").strip()
    if attempt != "1" and not (attempt == "2" and actor in pool.RESCUE_ACTORS):
        return f"attempt {attempt} keeps its Blacksmith route"
    label = (env.get("SIDE_LABEL") or "").strip()
    if not label.startswith(pool.SIDE_PREFIX) or not pool.persistent(label):
        return f"`{label or 'no label'}` is not an owned side label"
    if label.startswith("glaeda-aws-"):
        return f"`{label}` is the AWS pool, not the minis"
    return ""


def decide(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None,
           snapshot: Mapping[str, Any] | None, now: dt.datetime) -> Placement:
    jobs = tuple(dict.fromkeys((env.get("JOBS") or "").split()))
    mac_first = set((env.get("MAC_FIRST") or "").split())
    linux_only = set((env.get("LINUX_ONLY") or "").split())
    linux = fleet_linux(env.get("FLEET_LINUX", ""))
    problem = pool.snapshot_problem(snapshot, now)
    if linux and env.get("REQUIRE_LIVE_CAPACITY") == "1":
        matching = [runner for runner in runners or [] if linux in pool.runner_labels(runner)]
        # A custom label alone is not proof of Linux: never let a shared Mac
        # carrying the same label receive a credentialed Linux-only control.
        linux_members = bool(matching) and all(
            str(runner.get("os", "")).lower() == "linux" for runner in matching)
        idle = sum(runner.get("status") == "online" and runner.get("busy") is False
                   for runner in matching)
        # The macOS pool snapshot may omit Linux job demand entirely. An omitted
        # pool is *unknown*, never zero queued: routing behind unseen Linux jobs
        # breaks the live-capacity guarantee (cmux#30680).
        entry = ((snapshot or {}).get("pools") or {}).get(linux)
        queued = entry.get("queued") if isinstance(entry, Mapping) else None
        known_queue = type(queued) is int and queued >= 0
        if problem or not linux_members or not known_queue or idle <= queued:
            linux = ""
    linux_jobs = tuple(job for job in jobs if linux and job not in mac_first)
    rest = tuple(job for job in jobs if job not in linux_jobs and job not in linux_only)
    notes = [f"{', '.join(linux_jobs)} take fleet Linux `{linux}`"] if linux_jobs else []
    if not linux:
        notes.append("vars.LINUX_RUNNER names no fleet Linux runner")

    def done(why: str, mini: str = "", mini_jobs: tuple[str, ...] = ()) -> Placement:
        left = [job for job in rest if job not in mini_jobs]
        tail = [why] if why else []
        if left:
            tail.append(f"{', '.join(left)} take Blacksmith")
        return Placement(linux if linux_jobs else "", linux_jobs, mini, mini_jobs, "; ".join(notes + tail))

    if not rest:
        return done("")
    refusal = eligible(env)
    if refusal:
        return done(refusal)
    if ((runners is None or problem) and env.get("NIGHTLY") == "1"
            and env.get("NIGHTLY_WAIT_FOR_FLEET") == "1" and env.get("REQUIRE_LIVE_CAPACITY") != "1"):
        # An exhausted routing API is not evidence of a fleet no-start. Queue
        # these secret-free controls on the already configured owned pool,
        # rather than turn a missing observation into permission for paid work.
        # This is not a reservation or a bounded no-start overflow mechanism.
        # `rest` excludes Linux-only work (in particular the signer compiler).
        return done("capacity unknown; portable nightly controls queue on the owned fleet",
                    env["SIDE_LABEL"].strip(), rest)
    if runners is None:
        return done("the runners could not be read, so no mini is known to be free")
    if problem:
        return done(f"{problem}, so no mini is known to have no nightly job waiting")
    label = env["SIDE_LABEL"].strip()
    want = int(env.get("MINI_ALL_OR_NONE") == "1") and len(rest)
    route = side.side_route(label, runners, len(rest))
    if not route:
        return done(f"no online runner carries `{label}` or a wider class of it")
    waiting = nightly_waiting(snapshot, route)
    if waiting and env.get("NIGHTLY") != "1":
        return done(f"{waiting} nightly or release job(s) wait on `{family(route)}`, so its minis take none")
    idle = pool.live_owned_free(runners, [route])[route]
    free = max(0, idle - queued_on(snapshot, route))
    if want and free < want:
        return done(f"`{route}` has {free} free runner(s) for {want} jobs that go together")
    placed = rest[:free]
    if not placed:
        return done(f"`{route}` has no idle runner beyond its queue ({idle} idle, {queued_on(snapshot, route)} queued)")
    return done(f"{', '.join(placed)} take free mini(s) on `{route}`", route, placed)


def delimited(jobs: Sequence[str]) -> str:
    return f" {' '.join(jobs)} " if jobs else ""


def read(env: Mapping[str, str], now: dt.datetime
         ) -> tuple[Sequence[Mapping[str, Any]] | None, Mapping[str, Any] | None]:
    """The runners (routing App, then cmux-bot) and the janitor's pool snapshot; None when unread."""
    repo = env.get("GITHUB_REPOSITORY", "")
    runners = snapshot = None
    if not repo or eligible(env):
        return runners, snapshot
    retries = pool.RetryBudget(1)
    for name in ("ROUTE_TOKEN", "ROUTE_TOKEN_FALLBACK"):
        token = env.get(name, "")
        if not token:
            continue
        try:
            runners = pool.GitHub(token, repo, retry_cap=side.SIDE_RETRY_CAP_SECONDS, retries=retries).runners()
            break
        except Exception as error:  # noqa: BLE001 - fail open: every job keeps Blacksmith
            print(f"::warning title=portable placement::could not list runners with {name} ({error})")
    token = env.get("SNAPSHOT_TOKEN", "")
    if runners is not None and token:
        try:
            snapshot = pool.GitHub(token, repo).snapshot(now=now)
        except Exception as error:  # noqa: BLE001 - fail open, as above
            print(f"::warning title=portable placement::could not read the pool snapshot ({error})")
    return runners, snapshot


def write(placed: Placement, env: Mapping[str, str]) -> None:
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"linux_runner={placed.linux_runner}\nlinux_jobs={delimited(placed.linux_jobs)}\n"
                         f"mini_runner={placed.mini_runner}\nmini_jobs={delimited(placed.mini_jobs)}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### Portable job placement\n\n{placed.why}\n")
    print(f"portable placement: {placed.why}")


def main(env: Mapping[str, str] = os.environ) -> int:
    previous = signal.getsignal(signal.SIGALRM)

    def timeout(_signum: int, _frame: Any) -> None:
        raise Deadline("portable placement read deadline exceeded")

    now = dt.datetime.now(dt.timezone.utc)
    try:
        signal.signal(signal.SIGALRM, timeout)
        # Nightly controls wait for fleet capacity before using paid overflow.
        # This is placement only: it never cancels a started job or run. Other
        # callers keep their immediate placement behavior.
        wait_seconds = 180 if env.get("NIGHTLY_WAIT_FOR_FLEET") == "1" else 0
        signal.setitimer(signal.ITIMER_REAL, DEADLINE_SECONDS + wait_seconds)
        runners, snapshot = read(env, now)
        # Waiting is safe only when both runner inventory and the janitor snapshot
        # are fresh. Unknown or stale capacity must take the bounded Blacksmith
        # overflow immediately; it must never queue every job on an owned label.
        if wait_seconds and (runners is None or pool.snapshot_problem(snapshot, now)):
            wait_seconds = 0
        stop = time.monotonic() + wait_seconds
        placed = decide(env, runners, snapshot, now)
        wanted = set((env.get("JOBS") or "").split())
        if env.get("REQUIRE_LIVE_CAPACITY") != "1":
            wanted -= set((env.get("LINUX_ONLY") or "").split())
        while wait_seconds and not wanted.issubset(set(placed.linux_jobs + placed.mini_jobs)):
            remaining = stop - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(30, remaining))
            now = dt.datetime.now(dt.timezone.utc)
            runners, snapshot = read(env, now)
            placed = decide(env, runners, snapshot, now)
        signal.setitimer(signal.ITIMER_REAL, 0)
        write(placed, env)
    except Deadline:
        write(decide(env, None, None, now), env)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
    return 0


if __name__ == "__main__":
    sys.exit(main())
