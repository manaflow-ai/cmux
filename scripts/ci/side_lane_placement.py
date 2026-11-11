#!/usr/bin/env python3
"""Choose the live route for trusted side-lane jobs and record idle runners.

Side-lane workflows (owned_pool_rescue.SIDE_WORKFLOW_PATHS) have no picker.
On attempt 1 of a trusted run their macOS jobs took vars.CI_SIDE_LANE_RUNNER,
the std minis' glaeda-side-* label, whatever the fleet's load. When every side
runner was busy, the jobs sat queued until ci-owned-pool-rescue.yml's budget
(90 s) ran out, and the rescue cancelled the run and re-ran it; attempt 2 took
Blacksmith. Of 60 cmux-next.yml runs on 2026-10-02 (UTC), 49 needed attempt 2,
and in each attempt 1 sampled the Mac jobs never got a runner.

A workflow's placement job runs this before its macOS jobs, on attempt 1 of a
trusted run. It lists the runners through the org route App
(pr_runner_pool.GitHub.runners(), as admission_placement.py does) and places
JOBS, in priority order, with pr_runner_pool.idle_placement(), the rule the
main picker places the light side lanes with: one job per runner carrying
the route that is online and idle now. The route is SIDE_LABEL or the same
side label on a wider class (compatible_labels(): a light job runs on a std
mini, never the reverse), whichever has the most idle, then online, runners
live (side_route()), so a starved light pool spills onto idle std side
runners. When no online runner carries a compatible side label, jobs use the
owned pool label so the minis can accept them. When a side label is online but
busy, the cascade's jobs (next_macos_cascade.CASCADE_JOBS) take a free Blacksmith
slot, else Blacksmith 6 vCPU's queue while it moves and is short
(next_macos_cascade.overflow()): the routing order's last resort, so none waits
on a saturated side label that nothing moves it off (cmux#26723's fast tier,
2026-10-29). Only with Blacksmith stalled or backed up too do they stay queued
on the side label, and not even then while the side label is the longer queue:
its oldest job has waited longer than 6 vCPU's, or one host alone serves it
(route_wait(), next_macos_cascade.dead_end(); cmux#26723's fast tier again at
08:24Z, behind 96 jobs whose oldest had waited 443 minutes).

Anything uncertain decides nothing and keeps the owned label watched by the
rescue: an attempt after 1, a SIDE_LABEL that is not a glaeda-side-* label (a
fork, owned pools off, the variable unset), or runners that cannot be read.

Outputs, each job key delimited by spaces with one at each end so a runs-on's
contains(' <key> ') matches whole keys only:
- `owned_jobs`: the jobs an idle owned runner takes;
- `fallback_jobs`: retained for the workflow output contract and always empty;
- `runner`: the live side label, or the owned pool label when no online side
  runner carries it;
- `gui_runner`: the local GUI label for the owned pool, or the std pool's
  when a light pool has no online GUI runner. GUI jobs always use this label
  when the run is trusted, so a headless AWS side runner cannot receive a GUI
  suite;
- `session_runner`: the owned pool's session label (pr_runner_pool.session_label(),
  glaeda#1530) while an online runner carries it, else `gui_runner`. Jobs that
  need a logged-in session but not the console gui token (daemon tests,
  generated files) take it, so they run beside a console GUI job; until the
  fleet carries the label they keep the gui label;
- `gui_runner` and `session_runner` are health-checked, not only live: a role label is
  written only while it has room (role_room()): an idle online runner carries it, or the
  janitor snapshot's queue on it is shorter than its online runners, or its queue per
  runner is no longer than Blacksmith 6 vCPU's queue per slot. A label whose queue is
  deeper than the pool (#26809, 2026-10-29: eleven swift tests queued behind nine busy
  gui runners for 45+ minutes) is written empty, so the GUI jobs take the workflow's
  Blacksmith macOS leg instead of joining it. A label the janitor's snapshot lists as
  unserved (a job queued on it, none running or started within ten minutes) has no room
  either, unless one of its runners is idle, and this holds before the stalled-overflow and
  health-contract keeps below: cmux#24295's daemon tests waited 90 minutes on a session label
  whose five online runners were busy, while the gui label moved. An empty session_runner
  sends those jobs to gui_runner. With no snapshot to weigh, the live label
  stays (today's route; the rescue still watches it). While that leg is itself stalled or
  dead (overflow_stalled(), read from a snapshot up to 45 minutes old too), a role label with
  an online runner stays, full or deep: a busy owned queue moves, a stalled Blacksmith one does not;
- `gui_overflow`: the Blacksmith macOS label the GUI jobs take when the owned GUI route
  is declined above (or the runners are unread), and on the rescue's full re-run
  (rerun_main()) when no GUI runner is idle: the largest size that starts them now
  (next_macos_cascade.gui_overflow_label(): 12 vCPU while it moves and has room, else
  6 vCPU). On the rescue's re-run gui_runner and session_runner name only an idle
  runner (the free labels), so the re-run takes a free owned Mac first;
- `session_lane_runner`: SESSION_LANE (vars.CI_SESSION_LANE_RUNNER, generated files' own glaeda-session-*
  label) while role_room() holds for it, else empty; generated files take the variable on the attempt this
  placement ran only when this is set;
- `watch`: "false" when every job took its fallback, so the run uploads no
  owned-pool-watch marker; "true" otherwise;
- `blacksmith_12_jobs`, `blacksmith_6_jobs` and `retry_runner`: the jobs no idle
  mini took that Blacksmith 12 vCPU, then 6 vCPU, has a free slot for now (and
  whose queue is not stalled), and the Blacksmith label of the bot's overflow
  attempt while one has a free slot, else empty (next_macos_cascade.py; the
  workflow reads it as `free_retry_runner`);
- `nightly_runner_ready`: `true` when the dedicated cmux NEXT nightly runner
  is online and idle for this placement; an empty value keeps the Blacksmith
  overflow route.
- `fast_runner`: FAST_LABEL (vars.CI_FAST_LANE_RUNNER, the fast tier's
  reserved glaeda-fast-* runner) while an online runner carrying it is idle
  now; with none idle, the light minis' side label (SIDE_LABEL on the light class) while
  one of its runners is idle and no nightly or release job waits on the light family
  (light_fast_route()); else empty (fast_route()). Only then does the fast tier leave JOBS and
  CASCADE_RUNS; otherwise it is placed like any other job, so a busy or shrunken
  fast pool never holds it in a queue no overflow reaches.
- `fresh_runner` and `fresh_jobs`: FRESH_LABEL (the DEV compile slot,
  glaeda-dev-std-xcode-<v>) and the FRESH_JOBS in FRESH_SLOT_JOBS its idle online runners take
  now, else empty (fresh_route()). Those jobs leave JOBS, CASCADE_RUNS and
  FIRST_JOBS; the rest of FRESH_JOBS are placed like any other job.
- `gateway_runner` and `gateway_attempt`: GATEWAY_LABEL (vars.CI_COMPILE_CHECK_GATEWAY,
  the tailnet runner label the build-fleet compile jobs hand their commit from)
  or the same label on a wider class, while it has an idle online runner for
  each of GATEWAY_JOBS beyond the ones this run's own jobs take, else empty
  (gateway_route());
  `gateway_attempt` is the run attempt GATEWAY_LABEL was judged in. A gateway
  job runs only on a `gateway_runner` judged in its own attempt: a re-run that
  reuses an earlier attempt's placement, a placement that did not run, and a
  base script that predates the outputs all skip it. With no idle gateway, the
  build-fleet compiles are skipped and
  their Mac fallbacks run, and GATEWAY_CASCADE (the Mac fallback of the PR's
  app compile, release-compile) joins CASCADE_RUNS, so it takes a free
  Blacksmith slot instead of the minis' queue.

PLACEMENT=app-compile judges only the PR app compile's gateway, before the PR
quiet period ends (app_compile_gateway()); macos-placement then places the Mac
jobs after the quiet period from its own reading.

PLACEMENT=promote places a trusted workflow's promoted Mac job (app-ffi-release.yml's build) as a
feat-cmux-next push's Release compile is placed: an idle PROMOTE_LABEL runner (`promote_runner`), else
the cascade's Blacksmith slots, never a side mini (promote_main()).

PROMOTE_LABEL, set on attempt 1 of a feat-cmux-next push, is the promotion
mini's label. When the dedicated nightly labels are supplied, its idle state
is preferred for Release compile and Blacksmith is the immediate overflow.
"""
from __future__ import annotations

import dataclasses
import datetime as dt
import importlib.util
import math
import os
import signal
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence


def _picker():
    path = Path(__file__).with_name("pr_runner_pool.py")
    spec = importlib.util.spec_from_file_location("pr_runner_pool", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("pr_runner_pool", module)
    spec.loader.exec_module(module)
    return module


pool = _picker()
SIDE_RETRY_CAP_SECONDS = 5.0
# Keep the placement step below its workflow timeout. A timed-out read must
# leave a concrete default route, not strand the dependent Mac jobs.
PLACEMENT_DEADLINE_SECONDS = 90


class PlacementDeadline(BaseException):
    """A whole-operation deadline that per-request error handlers cannot swallow."""


def _cascade():
    path = Path(__file__).with_name("next_macos_cascade.py")
    spec = importlib.util.spec_from_file_location("next_macos_cascade", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("next_macos_cascade", module)
    spec.loader.exec_module(module)
    return module


cascade = _cascade()


def compatible_labels(label: str) -> tuple[str, ...]:
    """`label`, then the same label on each wider class: every label whose runners can run its jobs.

    pr_runner_pool.RUN_CLASSES lists the owned classes widest first (std: 48 GB
    minis with GUI runners; light: 16 GB minis with two runners and none), so
    a job sized for a class also runs on any class before it, never after.
    Only the class token changes: the role (side, gui, session), the trust and
    fleet namespace (trusted, promote, aws) and the Xcode stay as they are, so
    no route crosses a trust boundary. Any other label is its own only label.
    """
    if not pool.persistent(label):
        return (label,) if label else ()
    parts = label.split("-")
    own = next((index for index, part in enumerate(parts) if part in pool.RUN_CLASSES), None)
    if own is None:
        return (label,)
    wider = pool.RUN_CLASSES[:pool.RUN_CLASSES.index(parts[own])]
    return (label, *("-".join([*parts[:own], name, *parts[own + 1:]]) for name in reversed(wider)))


def _online(label: str, runners: Sequence[Mapping[str, Any]]) -> int:
    return sum(1 for runner in runners
               if runner.get("status") == "online" and pool.carries_office_pool_label(runner, label))


def side_route(label: str, runners: Sequence[Mapping[str, Any]] | None, want: int = 0) -> str:
    """The compatible side label the run's jobs take, or "" when no online runner carries one.

    The job's own class first, while its idle runners can take all `want`
    jobs of the run. Otherwise the compatible label with the most live room:
    the most idle runners now, then the most online (the queue that drains
    fastest), ties to the own class. Live room is the runners API itself (the
    fleet's registered labels), not a count kept in a variable. On 2026-10-20
    at 22:22Z the light side label had 133 jobs queued on its 3 online
    runners while 51 std side runners sat idle; the light jobs could have run
    on any of them.
    """
    if runners is None or not label.startswith(pool.SIDE_PREFIX) or not pool.persistent(label):
        return ""
    best, room = "", (0, 0)
    for candidate in compatible_labels(label):
        online = _online(candidate, runners)
        if not online:
            continue
        here = (pool.live_owned_free(runners, [candidate])[candidate], online)
        if candidate == label and want > 0 and here[0] >= want:
            return candidate
        if not best or here > room:
            best, room = candidate, here
    return best


def route_wait(route: str, runners: Sequence[Mapping[str, Any]] | None, seen: Any) -> float | None:
    """How long `route` has started nothing, in minutes, when no idle runner carries it; None otherwise.

    math.inf when every online runner carrying it sits on one host: a single-host reservation, which the
    rulebook never lets a job wait on with no fallback ("No job waits on one reserved machine: every
    reservation (a label one host serves) has a fallback within minutes"). Otherwise the pool snapshot's
    oldest queued wait on it (next_macos_cascade.Seen.owned), 0 with no queue there. None while an idle
    runner carries it, or with the runners unread: nothing then is known to be stuck. The cascade sends the
    jobs to Blacksmith 6 vCPU when this queue is the longer one (next_macos_cascade.dead_end()).
    """
    if runners is None or not route:
        return None
    carriers = [runner for runner in runners
                if runner.get("status") == "online" and pool.carries_office_pool_label(runner, route)]
    if any(not runner.get("busy") for runner in carriers):
        return None
    hosts = {pool.runner_member(str(runner.get("name") or "")) or str(runner.get("name") or "")
             for runner in carriers}
    if len(hosts) <= 1:
        return math.inf
    if seen is None or getattr(seen, "stale", False):
        return None
    return float(getattr(seen, "owned", {}).get(route, 0.0))


def route_label(label: str, runners: Sequence[Mapping[str, Any]] | None, want: int = 0) -> str:
    """side_route(), else the owned pool label while no compatible side runner is online."""
    if runners is None:
        return ""
    return side_route(label, runners, want) or pool.pool_label(label)


def _live_role_label(label: str, runners: Sequence[Mapping[str, Any]] | None, role) -> str:
    """The first online `role` label (pr_runner_pool.gui_label or session_label) for an owned side label.

    The light minis run no GUI or session runner, so a light lane borrows a
    wider class's (compatible_labels()) before the workflow's Blacksmith
    fallback: on 2026-10-18 every glaeda-gui-light job sampled waited for a
    runner until the rescue moved its run to Blacksmith while the std GUI
    runners sat idle.
    """
    if not label.startswith(pool.SIDE_PREFIX) or not pool.persistent(label):
        return ""
    owned = pool.pool_label(label)
    # AWS labels intentionally have no GUI route. A GUI job must wait for a
    # logged-in owned mini rather than silently landing on a headless host.
    if owned.startswith("glaeda-aws-"):
        return ""
    if runners is None:
        return ""
    for candidate in (role(name) for name in compatible_labels(owned)):
        if candidate and any(runner.get("status") == "online" and candidate in pool.runner_labels(runner)
                             for runner in runners):
            return candidate
    return ""


# The Blacksmith queue a deep GUI queue is weighed against (role_room()). The leg the GUI jobs take is
# gui_overflow(): the largest Blacksmith macOS size that starts them now, this one last.
GUI_OVERFLOW = cascade.SMALL
# The jobs that take the GUI and session routes, and so gui_overflow (cmux-next.yml).
GUI_JOBS = ("swift-test", "daemon-test", "generated-files")


def gui_overflow(env: Mapping[str, str], live: Mapping[str, int] | None, waiting: Mapping[str, int] | None,
                 seen: Any, placed: Any = None) -> str:
    """next_macos_cascade.gui_overflow_label() for this run's GUI jobs (in JOBS), with the Blacksmith slots the
    run's own cascade just took (`placed`, a cascade.Placement) counted as in flight."""
    if live is not None and placed is not None:
        live = {**live, **{label: live.get(label, 0) + len(placed.jobs.get(label, ()))
                           for label in cascade.LABELS}}
    jobs = sum(1 for job in (env.get("JOBS") or "").split() if job in GUI_JOBS)
    return cascade.gui_overflow_label(live, waiting, seen, jobs)


def _role_online(candidate: str, runners: Sequence[Mapping[str, Any]]) -> tuple[int, int]:
    """(online, idle) runners carrying the role label `candidate`."""
    carrying = [runner for runner in runners
                if runner.get("status") == "online" and candidate in pool.runner_labels(runner)]
    return len(carrying), sum(1 for runner in carrying if not runner.get("busy"))


def role_room(candidate: str, runners: Sequence[Mapping[str, Any]], seen: Any = None,
              waiting: Mapping[str, int] | None = None) -> bool:
    """Whether a GUI or session job queued on `candidate` now gets a runner about as soon as anywhere else.

    Room is an idle online runner carrying it, or a queue (the janitor snapshot's, `seen.owned_queued`) shorter
    than its online runners: each queued job has a machine within one job length. A deeper queue keeps
    the label only while Blacksmith 6 vCPU's queue per slot is at least as deep (`waiting`, with
    next_macos_cascade.CAPACITY), so the job joins the shorter of the two queues. With no snapshot the
    queue is unknown and the label stays, as before this check.

    A label the janitor found unserved (`seen.unserved`: a job queued on it and none running or started
    within starved_labels.STARVED_AFTER) has no room whatever its counts say, unless a runner carrying it is
    idle now: its queue is not moving. On 2026-10-29 cmux#24295's daemon tests waited 90 minutes on
    glaeda-session-std-xcode-26.6, twice, with five session runners online and busy and the queue shorter
    than them, while the gui label beside it started jobs within a minute.
    """
    online, idle = _role_online(candidate, runners)
    if not online:
        return False
    if idle:
        return True
    if candidate in (getattr(seen, "unserved", None) or ()):
        return False
    queues = getattr(seen, "owned_queued", None)
    if queues is None:
        return True
    queued = int(queues.get(candidate, 0))
    if queued < online:
        return True
    if waiting is None:
        return False
    slots = cascade.CAPACITY.get(GUI_OVERFLOW, 1) or 1
    return queued / online <= waiting.get(GUI_OVERFLOW, 0) / slots


def overflow_stalled(seen: Any, waiting: Mapping[str, int] | None) -> bool:
    """Whether the GUI jobs' Blacksmith leg (GUI_OVERFLOW) is not moving: dead in the snapshot (Seen.dead), or
    stalled by the pickers' one rule (its oldest queued job has waited STALL_MINUTES; Seen.waits carry the
    snapshot's age). A snapshot too old for the counts, or Blacksmith's queue unread, still reads the wait the
    snapshot saw (Seen.waits, only for a label it saw a queue on; next_macos_cascade.late_waits()): on
    2026-10-31 every placement read no snapshot under 15 minutes and sent swift test and daemon tests to a
    6 vCPU queue whose oldest job had waited 179 min. No snapshot at all says nothing: False."""
    if seen is None:
        return False
    if GUI_OVERFLOW in cascade.seen_dead(seen):
        return True
    waits = getattr(seen, "waits", None) or {}
    wait = float(waits.get(GUI_OVERFLOW, 0.0))
    if waiting is None or getattr(seen, "stale", False):
        return cascade._picker_rule.blacksmith_stalled(1 if GUI_OVERFLOW in waits else 0, wait)
    return cascade._picker_rule.blacksmith_stalled(int(waiting.get(GUI_OVERFLOW, 0)), wait)


def healthy_role_label(live: str, runners: Sequence[Mapping[str, Any]] | None, seen: Any = None,
                       waiting: Mapping[str, int] | None = None) -> str:
    """`live` (a gui_route_label() or session_route_label() result) while role_room() holds, else ""."""
    if not live or runners is None:
        return live
    # An unserved label (Seen.unserved: a job queued on it, none running or started within
    # starved_labels.STARVED_AFTER) is not a busy queue that moves, so neither keep below holds it: with no idle
    # runner it has no room (role_room()). cmux#24295's daemon tests waited 90 minutes on such a session label,
    # twice, on 2026-10-29 while Blacksmith had no free slot; an empty session_runner sends them to gui_runner.
    idle = _role_online(live, runners)[1]
    if live in (getattr(seen, "unserved", None) or ()) and not idle:
        return ""
    # A busy owned queue still moves; a stalled or dead Blacksmith 6 vCPU queue does not. While the overflow
    # is not moving, a role label with an online runner stays, full or deep (run 41163886431, #28823,
    # 2026-10-31: the gui label read full, 37 queued on 10 busy runners, so swift-test took
    # `blacksmith-6vcpu-macos-26` with 91 queued on 10 slots, oldest 102 min, and waited 106 min unstarted).
    if overflow_stalled(seen, waiting) and _role_online(live, runners)[0]:
        return live
    # The janitor's glaeda health contract is the authoritative full-pool
    # signal. A queued job whose label has no listening runner and is held
    # offline for capacity, CPU, or claim livelock overflows immediately; the
    # existing runner/queue comparison remains the fallback until those fields
    # are present in the artifact.
    if getattr(seen, "owned_full", {}).get(live, False):
        return ""
    if getattr(seen, "owned_full_known", {}).get(live, False):
        # No backlog is not proof that a listener exists: an empty/offline
        # session lane must not become a route merely because it is not full.
        return live if _role_online(live, runners)[0] else ""
    return live if role_room(live, runners, seen, waiting) else ""


def gui_route_label(label: str, runners: Sequence[Mapping[str, Any]] | None) -> str:
    """Return a live GUI-token label paired with a side or pool label.

    An empty live runner list is meaningful: the picker must not synthesize a
    label that no online runner carries, or GUI jobs wait forever on a dead
    queue. An unreadable runner listing also keeps the output empty so the
    workflow's known fallback can choose the generic route.
    """
    return _live_role_label(label, runners, pool.gui_label)


def session_route_label(label: str, runners: Sequence[Mapping[str, Any]] | None) -> str:
    """Return a live session label paired with a side label, else gui_route_label().

    Before the fleet carries the session label (glaeda#1530's rollout) no online
    runner has it, so this is exactly the gui route and the session jobs keep
    today's label; it moves them once one online runner carries it.
    """
    return _live_role_label(label, runners, pool.session_label) or gui_route_label(label, runners)


def _free_role_label(label: str, runners: Sequence[Mapping[str, Any]] | None, role) -> str:
    """Return a compatible role label with at least one idle online runner.

    GUI and logged-in-session jobs should take a free owned Mac when one is
    visible. Returning an empty label when every compatible role runner is busy
    lets the workflow's Blacksmith fallback run immediately instead of joining
    an unbounded GUI queue; the five-minute rescue remains the last admission
    guard if that fallback is itself stalled.
    """
    if not label.startswith(pool.SIDE_PREFIX) or not pool.persistent(label) or runners is None:
        return ""
    owned = pool.pool_label(label)
    if owned.startswith("glaeda-aws-"):
        return ""
    for candidate in (role(name) for name in compatible_labels(owned)):
        if candidate and any(runner.get("status") == "online" and not runner.get("busy")
                             and candidate in pool.runner_labels(runner) for runner in runners):
            return candidate
    return ""


def free_gui_route_label(label: str, runners: Sequence[Mapping[str, Any]] | None) -> str:
    return _free_role_label(label, runners, pool.gui_label)


def free_session_route_label(label: str, runners: Sequence[Mapping[str, Any]] | None) -> str:
    return (_free_role_label(label, runners, pool.session_label)
            or free_gui_route_label(label, runners))


def decide(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None,
           ) -> tuple[tuple[str, ...], tuple[str, ...], str]:
    """(owned jobs, fallback jobs, why); ((), (), why) decides nothing and keeps today's route."""
    label = (env.get("SIDE_LABEL") or "").strip()
    jobs = tuple((env.get("JOBS") or "").split())
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip()
    if attempt not in ("", "1") and not cascade.bot_rerun(env):
        return (), (), f"attempt {attempt} keeps its own route"
    if not label.startswith(pool.SIDE_PREFIX) or not pool.persistent(label):
        return (), (), f"`{label or 'no label'}` is not an owned side label"
    if runners is None:
        return (), (), f"owned runners could not be read live; the jobs keep `{label}`"
    # The jobs take the compatible side label with the most room (side_route()), so idle runners
    # are counted where they go.
    route = side_route(label, runners, len(jobs)) or label
    owned = pool.idle_placement(runners, route, jobs)
    # A busy fleet is a queue, not an instantaneous Blacksmith decision. The
    # rescue moves a job only after the side queue budget has elapsed.
    fallback: tuple[str, ...] = ()
    if not owned:
        return owned, fallback, f"no idle `{route}` runner now; every job stays queued on the owned label"
    return owned, fallback, (f"{len(owned)} idle `{route}` runner(s) now take {', '.join(owned)}"
                             + "; remaining jobs stay queued on the owned label")


def promote_busy(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None) -> bool:
    """Whether PROMOTE_LABEL (a feat-cmux-next push's promotion mini) has no idle runner now.

    Unset, or runners that could not be read: False, so the promoted jobs keep that label.
    """
    label = (env.get("PROMOTE_LABEL") or "").strip()
    if not label or runners is None:
        return False
    return pool.live_owned_free(runners, [label])[label] == 0


def nightly_runner_ready(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None) -> bool:
    """Whether the dedicated cmux NEXT nightly runner can take this compile."""
    pool_label = (env.get("NIGHTLY_POOL") or "").strip()
    runner_label = (env.get("NIGHTLY_RUNNER") or "").strip()
    if not pool_label or not runner_label or runners is None:
        return False
    return any(
        runner.get("status") == "online"
        and not runner.get("busy")
        and pool.carries_office_pool_label(runner, pool_label)
        and runner_label in pool.runner_labels(runner)
        for runner in runners
    )


FAST_JOB = "fast-tier"
# The Mac job each build-fleet gateway job stands in for: it needs a Mac only when the fleet gives no
# pass, so it takes no idle runner from the gateway job.
GATEWAY_FALLBACKS = {"app-compile-fleet": "release-compile", "swift-canary-fleet": "swift-canary",
                     "release-compile-fast": "release-compile"}


def fast_route(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None) -> str:
    """FAST_LABEL while an online runner carrying it is idle now, else "".

    The fast tier's reserved label is one small pool. On 2026-10-25 the fleet
    reservation left two runners carrying glaeda-fast-light-xcode-26.6, each
    running a 20-minute fast tier back to back, and 15 runs' fast tiers queued
    behind them for an hour: with CI_FAST_LANE_RUNNER set the tier never
    joined the cascade, and nothing else moved it. So the label is a
    preference taken only when it is free; a busy label, unreadable runners or
    an unset variable send the tier down the cascade (Blacksmith), then the
    side route, like every other job.
    """
    label = (env.get("FAST_LABEL") or "").strip()
    if not label or runners is None:
        return ""
    return label if pool.live_owned_free(runners, [label])[label] > 0 else ""


def light_side_label(label: str) -> str:
    """The light class's side label for an owned side label (glaeda-side-std-xcode-26.6 ->
    glaeda-side-light-xcode-26.6), or "" when `label` is no owned side label or is light already."""
    if not label.startswith(pool.SIDE_PREFIX) or not pool.persistent(label):
        return ""
    own = pool.owned_class(label)
    if not own or own == pool.LIGHT_CLASS:
        return ""
    parts = label.split("-")
    return "-".join(pool.LIGHT_CLASS if part == own else part for part in parts)


def _family(label: str) -> str:
    """`<class>-xcode-<version>` for any glaeda label naming a class, whatever its role or namespace
    (side, fast, trusted, nightly, promote, signing, aws), else "". Wider than
    portable_job_placement.family(), which reads only pool.OWNED_LABEL: the nightly builder's pool
    (glaeda-trusted-light-xcode-26.6, cmux22) is a light mini, and its queue must hold the light minis too."""
    parts = (label or "").split("-")
    if not parts or parts[0] != "glaeda":
        return ""
    own = next((index for index, part in enumerate(parts) if part in (*pool.RUN_CLASSES, "xl")), None)
    if own is None or own + 2 >= len(parts) or parts[own + 1] != "xcode":
        return ""
    return "-".join(parts[own:own + 3])


def light_fast_route(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None, seen: Any) -> str:
    """The light minis' side label for the fast tier while one of its runners is idle, else "".

    Leo, 2026-11-08, on the PR verdict taking p50 31 minutes against 10: "Ci it's fine to start stuff in
    parallel sometimes the light minis are largely idling rn". Over the 7 days to 2026-11-08 the light
    minis (cmux17 to cmux23, 16 GB, glaeda class light) averaged 16 to 28% CPU and held 0.1 to 0.3 of their
    12 capacity units, while the std minis averaged 63 to 80% and glaeda-side-std-xcode-26.6 queued its
    jobs p50 4.7 min and p90 34 min (ci-dash speed.json). On the fast lane the light minis already run
    the fast tier (1,371 runs in 4 days, p50 8.8 min against 10.1 min on the std minis), but only on
    their one fast runner each (FAST_LABEL); a busy fast runner sent the tier to the std side queue while
    the same minis' side runners sat idle, because compatible_labels() never narrows a class.

    So the fast tier alone, which needs no GUI or session runner, takes an idle light side runner when
    no fast runner is idle. Only an idle runner (beyond the jobs already queued on the label), on attempt
    1 of a run decide() places, and never while a nightly or release job waits on the light family (the
    janitor snapshot's reserved_queued: nightly first). An unread or stale snapshot places nothing.
    """
    if not (env.get("FAST_LABEL") or "").strip() or runners is None:
        return ""
    if (env.get("GITHUB_RUN_ATTEMPT") or "").strip() not in ("", "1"):
        return ""
    label = light_side_label((env.get("SIDE_LABEL") or "").strip())
    if not label or FAST_JOB not in (env.get("JOBS") or "").split():
        return ""
    snapshot = getattr(seen, "snapshot", None) if seen is not None else None
    if not isinstance(snapshot, Mapping) or getattr(seen, "stale", True):
        return ""
    pools = snapshot.get("pools") or {}
    own = _family(label)
    if not isinstance(pools, Mapping) or any(
            _family(str(name)) == own and int((entry or {}).get("reserved_queued") or 0) > 0
            for name, entry in pools.items() if isinstance(entry, Mapping)):
        return ""
    queued = int((getattr(seen, "owned_queued", None) or {}).get(label, 0) or 0)
    return label if pool.live_owned_free(runners, [label])[label] - queued > 0 else ""


def fresh_route(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None) -> tuple[str, tuple[str, ...]]:
    """(FRESH_LABEL, the FRESH_JOBS it takes) while its online runners are idle for them, else ("", ()).

    The DEV compile slot: one side instance on each opted-in mini carries only
    FRESH_LABEL (glaeda-dev-std-xcode-<v>, glaeda#1628), and its hook admits
    only the jobs in FRESH_SLOT_JOBS (cmux-scheme-compile, a DEV daily's Release
    compile). Only those of FRESH_JOBS take it. On 2026-10-26 the DEV feed did
    not publish from 21:01Z: every DEV Release compile from 22:18Z queued on
    glaeda-side-std-xcode-26.6 behind PR compiles, with all 22 online side
    runners busy and Blacksmith macOS 68 deep. So the slot comes first, then
    the owned side label, then Blacksmith, like fast_route() a preference
    taken only while free: a busy, unregistered or unread label sends the
    jobs on through the side route and the cascade as before.
    """
    label = (env.get("FRESH_LABEL") or "").strip()
    admitted = set((env.get("FRESH_SLOT_JOBS") or "").split())
    jobs = [job for job in (env.get("FRESH_JOBS") or "").split()
            if job in admitted and job in (env.get("JOBS") or "").split()]
    if not label or not jobs or runners is None:
        return "", ()
    free = pool.live_owned_free(runners, [label])[label]
    return (label, tuple(jobs[:free])) if free > 0 else ("", ())


def fresh_slot_state(label: str, runners: Sequence[Mapping[str, Any]] | None) -> str:
    """Why FRESH_LABEL took no job, for the placement summary: unread, unregistered, or its runners by state.

    The slot's runners go offline while their glaeda gate holds the listener off (capacity units, disk, a
    fleet build's host lock), which the runners API shows only as `offline`. On 2026-10-27 both slot runners
    were offline when the DEV dailies at 04:23Z and 04:37Z were placed, and the summary said only "no idle
    runner"; naming them tells a busy slot (it frees when its compile ends) from a held one (glaeda's).
    """
    if runners is None:
        return "runners unread"
    states: dict[str, list[str]] = {"busy": [], "offline": []}
    for runner in runners:
        if label not in pool.runner_labels(runner):
            continue
        state = "offline" if runner.get("status") != "online" else "busy" if runner.get("busy") else ""
        if state:
            states[state].append(str(runner.get("name") or "?"))
    if not any(states.values()):
        return "no runner carries it"
    return "; ".join(f"{state}: {', '.join(sorted(names))}" for state, names in states.items() if names)


def without_jobs(env: Mapping[str, str], jobs: Sequence[str]) -> dict[str, str]:
    """`env` with `jobs` dropped from JOBS, CASCADE_RUNS, FIRST_JOBS and FRESH_JOBS: they run on their own slot."""
    trimmed = dict(env)
    for key in ("JOBS", "CASCADE_RUNS", "FIRST_JOBS", "FRESH_JOBS"):
        if key in trimmed:
            kept = [job for job in (trimmed[key] or "").split() if job not in jobs]
            trimmed[key] = f" {' '.join(kept)} " if key == "CASCADE_RUNS" and kept else " ".join(kept)
    return trimmed


def gateway_route(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None,
                  taken: Mapping[str, int] | None = None) -> str:
    """GATEWAY_LABEL or a wider class's same label with idle runners left for GATEWAY_JOBS, else "".

    The build-fleet compile jobs (app-compile-fleet, swift-canary-fleet) only
    hand a commit to the fleet controller over the tailnet, so any owned runner
    that carries the gateway label or a wider class of it can host them. They
    took vars.CI_COMPILE_CHECK_GATEWAY as is, and nothing moved them: at 06:00Z
    on 2026-10-26 glaeda-side-light-xcode-26.6 had 5 jobs running and 44 queued,
    the oldest for 58 minutes, with four of its minis reserved, and PR #24155's
    app compile was queued there three times until each newer push cancelled
    it. So a label is taken only while it has an idle runner for each of
    GATEWAY_JOBS (at least one) beyond those `taken` (this run's own jobs
    already placed on it), first the label itself, then the compatible wider
    labels (compatible_labels(): the std side minis). With none, the gateway
    jobs do not run and their Mac fallbacks take the cascade. Runners that
    could not be read show no idle runner either: a gateway job never queues
    on a label nobody saw free.
    """
    label = (env.get("GATEWAY_LABEL") or "").strip()
    if not label or runners is None:
        return ""
    want = max(1, len((env.get("GATEWAY_JOBS") or "").split()))
    for candidate in compatible_labels(label):
        if pool.live_owned_free(runners, [candidate])[candidate] - (taken or {}).get(candidate, 0) >= want:
            return candidate
    return ""


def gateway_taken(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None,
                  fast: str = "") -> dict[str, int]:
    """The idle runners this run's own Mac jobs take as they start, by label.

    The side jobs that run (in CASCADE_RUNS, as `env` holds it once the fast
    tier left) all take decide()'s route and race for its idle runners, while
    the GUI suites take another label. A Mac job a gateway job stands in for
    (GATEWAY_FALLBACKS) is not counted: it needs a Mac only without a fleet
    pass. The fast tier, routed, takes its own label (`fast`).
    """
    label = (env.get("SIDE_LABEL") or "").strip()
    jobs = (env.get("JOBS") or "").split()
    runs = set((env.get("CASCADE_RUNS") or "").split())
    replaced = {GATEWAY_FALLBACKS[job] for job in (env.get("GATEWAY_JOBS") or "").split() if job in GATEWAY_FALLBACKS}
    racing = [job for job in jobs if job in runs and job not in replaced]
    taken: dict[str, int] = {}
    if racing:
        taken[side_route(label, runners, len(jobs)) or label] = len(racing)
    if fast:
        taken[fast] = taken.get(fast, 0) + 1
    return taken


def fleet_gateway(placed: Any, env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None,
                  gateway: str, taken: Mapping[str, int] | None = None) -> Any:
    """`placed` with its fleet_jobs kept only while `gateway` has an idle runner for each of them.

    A listed job's build-fleet client (cmux-next.yml's <job>-fleet) runs on gateway_runner beside
    GATEWAY_JOBS, so it needs an idle runner there beyond theirs and beyond the run's own jobs (`taken`,
    as gateway_route() counts them). Without one the client would queue behind another gateway job
    until its timeout and report no verdict, so placement lists nothing and the job keeps its route
    (it waits on the owned label as before). No gateway (none idle, unread runners, a re-run) lists
    nothing either.

    A kept job that a Blacksmith macOS label also took (next_macos_cascade.place() lists it so the fleet
    builds it warm) leaves that label; a dropped one keeps it.
    """
    if not placed.fleet_jobs:
        return placed
    want = len((env.get("GATEWAY_JOBS") or "").split()) + len(placed.fleet_jobs)
    room = (pool.live_owned_free(runners, [gateway])[gateway] - (taken or {}).get(gateway, 0)
            if gateway and runners is not None else 0)
    if room >= want:
        fleet = set(placed.fleet_jobs)
        return dataclasses.replace(placed, jobs={label: tuple(job for job in names if job not in fleet)
                                                 for label, names in placed.jobs.items()})
    clients = ", ".join(f"{job}-fleet" for job in placed.fleet_jobs)
    where = f"`{gateway}`" if gateway else "the gateway"
    return dataclasses.replace(placed, fleet_jobs=(), why=(
        f"{placed.why}; {where} has no idle runner left for {clients} ({max(room, 0)} for {want} gateway jobs), "
        f"so {', '.join(placed.fleet_jobs)} keep their route"))


def without_cascade(env: Mapping[str, str], job: str) -> dict[str, str]:
    """`env` with `job` dropped from CASCADE_RUNS and FIRST_JOBS."""
    trimmed = dict(env)
    for key in ("CASCADE_RUNS", "FIRST_JOBS"):
        kept = [name for name in (env.get(key) or "").split() if name != job]
        if key in env:
            trimmed[key] = (f" {' '.join(kept)} " if kept else "") if key == "CASCADE_RUNS" else " ".join(kept)
    return trimmed


def with_gateway_cascade(env: Mapping[str, str]) -> dict[str, str]:
    """`env` with GATEWAY_CASCADE's jobs added to CASCADE_RUNS: their build-fleet compile has no gateway."""
    extra = [job for job in (env.get("GATEWAY_CASCADE") or "").split()
             if job not in (env.get("CASCADE_RUNS") or "").split()]
    if not extra:
        return dict(env)
    runs = [*(env.get("CASCADE_RUNS") or "").split(), *extra]
    return {**env, "CASCADE_RUNS": f" {' '.join(runs)} "}


def without_fast(env: Mapping[str, str]) -> dict[str, str]:
    """`env` with the fast tier dropped from JOBS and CASCADE_RUNS: it runs on its own idle runner."""
    trimmed = dict(env)
    for key in ("JOBS", "CASCADE_RUNS"):
        if key in trimmed:
            kept = [job for job in (trimmed[key] or "").split() if job != FAST_JOB]
            trimmed[key] = f" {' '.join(kept)} " if key == "CASCADE_RUNS" and kept else " ".join(kept)
    return trimmed


def delimited(jobs: Sequence[str]) -> str:
    return f" {' '.join(jobs)} " if jobs else ""


# The branch whose pushes run the cmux NEXT DEV pipeline.
FEAT_BRANCH = "refs/heads/feat-cmux-next"


def rerun_main(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None) -> int:
    """The rescue's full re-run (next_macos_cascade.bot_rerun()): only the cascade is placed afresh.

    The side runner is emitted only for freshly allocated owned jobs (the idle minis `owned` names);
    fast_runner and gateway_runner stay empty, as every re-run had them: those jobs keep the routes their
    runs-on gives a re-run. With no gateway the build-fleet compiles skip, so their Mac fallbacks cascade.
    The GUI jobs follow the routing order, as on attempt 1: gui_runner and session_runner (and the free
    labels) name only a GUI or session runner idle now, else gui_overflow names the Blacksmith leg.

    Idle minis are counted on SIDE_LABEL itself: a re-run's cascade jobs fall back to
    that exact label, never to side_route()'s wider class. A FEAT_BRANCH
    push's Release compile takes no placement on a re-run (its runs-on reads it on attempt 1 only), so it
    leaves the cascade and takes no slot, and no idle mini is counted for it.
    """
    if (env.get("GATEWAY_LABEL") or "").strip():
        env = with_gateway_cascade(env)
    jobs = tuple((env.get("JOBS") or "").split())
    if env.get("GITHUB_EVENT_NAME") == "push" and env.get("GITHUB_REF") == FEAT_BRANCH:
        env = without_cascade(env, "release-compile")
        jobs = tuple(job for job in jobs if job != "release-compile")
    label = (env.get("SIDE_LABEL") or "").strip()
    if runners is None or not label.startswith(pool.SIDE_PREFIX) or not pool.persistent(label):
        owned: tuple[str, ...] = ()
        why = f"owned runners could not be read live, or `{label}` is not an owned side label"
    else:
        owned = tuple(pool.idle_placement(runners, label, jobs))
        why = (f"{len(owned)} idle `{label}` runner(s) take {', '.join(owned)}" if owned
               else f"no idle `{label}` runner now")
    fallback: tuple[str, ...] = ()
    # The GUI jobs leave the owned GUI queue they were rescued from: only a GUI or session runner idle now
    # takes them (the free routes, never a queue), else the largest Blacksmith macOS size that starts them now
    # (gui_overflow()). The rescue still watches this attempt, so a free runner lost to a race moves once more.
    free_gui = free_gui_route_label(label, runners)
    free_session = free_session_route_label(label, runners)
    live, waiting, seen = cascade.read(env, pool, now=dt.datetime.now(dt.timezone.utc))
    # Runners read: the jobs past `owned` have no idle mini, so the cascade's overflow may take them.
    placed = cascade.place(env, owned, live, waiting, seen, saturated=runners is not None,
                           route_wait=route_wait(label, runners, seen))
    # A re-run emits no gateway_runner, so no build-fleet client runs (fleet_gateway()).
    placed = fleet_gateway(placed, env, runners, "")
    overflow = "" if free_gui else gui_overflow(env, live, waiting, seen, placed)
    gui_why = (f"the GUI jobs take idle `{free_gui}`" if free_gui
               else f"no idle GUI runner, so the GUI jobs take `{overflow}`")
    print(f"side-lane placement: the rescue's re-run; {why}; {gui_why}")
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"owned_jobs={delimited(owned)}\nfallback_jobs={delimited(fallback)}\n"
                         f"runner={label if owned else ''}\ndeferred_runner={label}\n"
                         f"gui_runner={free_gui}\nsession_runner={free_session}\n"
                         f"free_gui_runner={free_gui}\nfree_session_runner={free_session}\n"
                         f"gui_overflow={overflow}\n"
                         f"watch={'false' if fallback and not owned else 'true'}\n")
    print(f"macOS cascade: {placed.why}")
    cascade.write(placed, env)
    return 0


def read_runners(env: Mapping[str, str]) -> list[dict[str, Any]] | None:
    """The org's runners, read live, or None when no token could read them."""
    runners = None
    repo = env.get("GITHUB_REPOSITORY", "")
    # The routing App first, then cmux-bot (ROUTE_TOKEN_FALLBACK) when the first read is refused.
    # One retry for the whole read, shared by both tokens, after at most 5 s, on a refusal that
    # names a Retry-After: it adds at most one wait and one 15 s request (20 s) to today's reads,
    # however many reads and tokens those take.
    retries = pool.RetryBudget(1)
    for name in ("ROUTE_TOKEN", "ROUTE_TOKEN_FALLBACK"):
        token = env.get(name, "")
        if not (token and repo):
            continue
        try:
            client = pool.GitHub(token, repo, retry_cap=SIDE_RETRY_CAP_SECONDS, retries=retries)
            # The fallback mint grants org runner read only. Its approved org
            # groups remain readable when repository registrations are not.
            runners = (client.runners(include_repository=False) if name == "ROUTE_TOKEN_FALLBACK"
                       else client.runners())
            break
        except Exception as error:  # noqa: BLE001 - fail open: keep today's route
            print(f"::warning title=side-lane placement::could not list runners with {name} ({error})")
    return runners


def rerun_fleet(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None) -> tuple[str, str]:
    """(the gateway label the fast tier's build-fleet client takes on a person's re-run, why), or ("", why).

    A person's re-run carries attempt 1's macos-placement and its outputs (a successful job is not
    re-run), so the fast tier took vars.MACOS_RUNNER_26, Blacksmith 6 vCPU, and fast-tier-fleet skipped
    the stale gateway reading. On #38130 (run 42434830670) attempt 2 then ran out its 20 minutes on the
    same cold build as attempt 1. cmux-next.yml's fast-tier-rerun-placement is skipped on attempt 1, so
    a re-run evaluates it again and it reads the runners now: the client takes GATEWAY_LABEL (or a wider
    class of it) while a runner there is idle for it, as attempt 1's fleet_gateway() requires, and the
    tier only reports its verdict. The other gateway jobs skip on a re-run (their reading is attempt
    1's), so the client needs one idle runner.

    Nothing is listed on attempt 1 or the rescue's re-run (macos-placement places those), when the fast
    tier does not run again in this attempt (FAST_TIER_STATUS, its status in this attempt, is
    `completed`: its earlier result is carried), when that status is unread, or with no idle runner:
    the tier keeps its re-run route.
    """
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip() or "1"
    if attempt == "1" or cascade.bot_rerun(env):
        return "", f"attempt {attempt} is placed by macos-placement"
    status = (env.get("FAST_TIER_STATUS") or "").strip()
    if not status:
        return "", "the fast tier's status in this attempt is unread, so it keeps its re-run route"
    if status == "completed":
        return "", "the fast tier does not run again in this attempt (its earlier result is carried)"
    label = (env.get("GATEWAY_LABEL") or "").strip()
    gateway = gateway_route({"GATEWAY_LABEL": label, "GATEWAY_JOBS": f"{FAST_JOB}-fleet"}, runners)
    if not gateway:
        why = "owned runners unread" if runners is None else f"no idle `{label or 'gateway'}` runner (or a wider class's)"
        return "", f"{why}, so the fast tier keeps its re-run route"
    return gateway, (f"{FAST_JOB}-fleet takes idle `{gateway}` (a warm owned build before a cold Blacksmith "
                     "macOS one); the fast tier reports its verdict")


def rerun_fleet_main(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None) -> int:
    """Write rerun_fleet()'s reading in macos-placement's names: fleet_jobs, gateway_runner, gateway_attempt."""
    gateway, why = rerun_fleet(env, runners)
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip() or "1"
    print(f"fast tier re-run placement: {why}")
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"fleet_jobs={delimited((FAST_JOB,) if gateway else ())}\ngateway_runner={gateway}\n"
                         f"gateway_attempt={attempt if gateway else ''}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### Fast tier re-run placement\n\n{why}\n")
    return 0


def app_compile_gateway(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None) -> tuple[str, str]:
    """(the gateway label a pull request's app-compile-fleet takes now, why), or ("", why).

    cmux-next.yml's app-compile-placement runs this before the PR quiet period ends (Leo, 2026-11-08,
    option A: the Linux checks start at once and only the Mac jobs wait). app-compile-fleet's runner only
    hands the commit to the build fleet, so it starts at once too, on GATEWAY_LABEL (or a wider class of
    it) while a runner there is idle for each of GATEWAY_JOBS, as gateway_route() judges it for
    macos-placement. macos-placement reads the runners again once the quiet period ends, so the Mac jobs
    are placed from that fresh reading and see this job's runner as busy. Attempt 1 only: a re-run's
    gateway jobs skip (rerun_main() writes no gateway either), and their Mac fallback cascades.
    """
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip() or "1"
    if attempt != "1":
        return "", f"attempt {attempt} takes no gateway (a re-run's build-fleet compile skips)"
    label = (env.get("GATEWAY_LABEL") or "").strip()
    gateway = gateway_route(env, runners)
    if gateway:
        return gateway, f"app-compile-fleet takes idle `{gateway}`"
    why = ("no gateway label" if not label else "owned runners unread" if runners is None
           else f"no idle `{label}` runner (or a wider class's)")
    return "", f"{why}, so app-compile-fleet skips and the Mac Release compile takes the cascade"


def app_compile_gateway_main(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None) -> int:
    """Write app_compile_gateway()'s reading in macos-placement's names: gateway_runner, gateway_attempt."""
    gateway, why = app_compile_gateway(env, runners)
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip() or "1"
    print(f"app compile placement: {why}")
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"gateway_runner={gateway}\ngateway_attempt={attempt if gateway else ''}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### App compile placement\n\n{why}\n")
    return 0


def handback(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None,
             live: Mapping[str, int] | None, waiting: Mapping[str, int] | None, seen: Any) -> tuple[str, str]:
    """(the label the fast tier takes when its build-fleet client hands it back, why).

    cmux-next.yml's fast-tier-fleet hands the tier back (verdict `queued`) when a fleet step is still
    queued after the client's 20-minute wait, and the tier then runs its Swift suites itself. macos-placement's
    reading is from the start of the run, so fast-tier-handback-placement reads the runners and Blacksmith's
    health again here, after that wait: the fast tier's own label while a runner there is idle, else an idle
    owned side runner (a warm build), else Blacksmith 6 vCPU, the cascade's last resort, unless it has no free
    slot now, is full, under a declared outage, dead or stalled (cmux#38627's review: the hand-back then queued
    on an excluded label with no verdict). Then the owned route: the tier waits for a mini, as macos-placement's deferred_runner
    does. Unread runners vouch for no idle mini; an unread Blacksmith reading excludes nothing.
    """
    fast = fast_route(env, runners)
    if fast:
        return fast, f"the fast tier takes idle `{fast}`, its own label"
    label = (env.get("SIDE_LABEL") or "").strip()
    side = side_route(label, runners, 1)
    if side and runners is not None and pool.live_owned_free(runners, [side])[side] > 0:
        return side, f"idle `{side}` takes the fast tier (a warm owned build before a cold Blacksmith one)"
    small = cascade.SMALL
    out = ""
    # The pool snapshot carries only queued and running counts (no cap or health), so label_full_or_dead()
    # never calls the label full from it: count its free slots here, as the cascade's retry label does.
    slots = (min(cascade.CAPACITY[small] - live.get(small, 0) - waiting.get(small, 0),
                 cascade.pool_room(live, waiting) // cascade.vcpus(small))
             if live is not None and waiting is not None else 1)
    if slots <= 0:
        out = (f"full ({live.get(small, 0)} in flight + {waiting.get(small, 0)} queued of "
               f"{cascade.CAPACITY[small]}, {max(cascade.pool_room(live, waiting), 0)} of the pool's "
               f"{cascade.POOL_VCPU} vCPU free)")
    elif seen is not None and cascade.label_full_or_dead(small, seen.snapshot, live=(live or {}).get(small, 0),
                                                       queued=(waiting or {}).get(small, 0), now=seen.observed_at):
        out = "full or under a declared outage"
    elif small in cascade.seen_dead(seen):
        out = "dead (nothing running, no job started in an hour)"
    elif (seen is not None and live is not None and waiting is not None
          and small in cascade.stalled(live, waiting, seen.waits, seen.age)):
        out = f"stalled (oldest queued job {seen.waits.get(small, 0.0):.0f} min)"
    owned = route_label(label, runners, 1) or label
    if not out or not owned.startswith("glaeda-"):
        return small, f"no idle owned Mac, so the fast tier takes `{small}`"
    return owned, f"no idle owned Mac and `{small}` is {out}, so the fast tier waits on the owned route `{owned}`"


def handback_main(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None) -> int:
    """Write handback()'s label as `runner`."""
    live, waiting, seen = cascade.read(env, pool, now=dt.datetime.now(dt.timezone.utc))
    label, why = handback(env, runners, live, waiting, seen)
    print(f"fast tier hand-back placement: {why}")
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"runner={label}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### Fast tier hand-back placement\n\n{why}\n")
    return 0


def promote_route(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None) -> str:
    """PROMOTE_LABEL while an online runner carrying it is idle now, else "" (unset, busy or unread)."""
    label = (env.get("PROMOTE_LABEL") or "").strip()
    if not label or runners is None:
        return ""
    return label if pool.live_owned_free(runners, [label])[label] > 0 else ""


def promote_main(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None) -> int:
    """PLACEMENT=promote: a trusted workflow's promoted Mac job (PROMOTE_JOBS) takes the route a feat-cmux-next
    push's Release compile takes, never an owned side runner.

    app-ffi-release.yml's build gates the app FFI re-pin, which keeps feat-cmux-next red until it lands. It sat
    on vars.CI_NEXT_PROMOTE_POOL, or with that unset on Blacksmith 6 vCPU's queue behind PR CI: 11 to 66 minutes
    a build on 2026-11-10. Here it takes `promote_runner` (PROMOTE_LABEL) while a runner carrying it is idle now
    (promote_route()); otherwise the cascade places it as a feed's compile (FRESH_JOBS) on a free Blacksmith
    slot, 12 vCPU then 6, else 6 vCPU's queue while it moves (next_macos_cascade.place(), with promote_busy).
    No side mini takes it (owned is empty): its artifact is published, so it never shares a runner with PR
    code. SIDE_LABEL only says the run is on the owned pools (next_macos_cascade.skipped()). Unread runners
    vouch for no idle promote runner, so the job cascades.
    """
    route = promote_route(env, runners)
    live, waiting, seen = cascade.read(env, pool, now=dt.datetime.now(dt.timezone.utc))
    placed = cascade.place(env, (), live, waiting, seen, promote_busy=not route, saturated=True)
    label = (env.get("PROMOTE_LABEL") or "").strip()
    why = (f"the promoted jobs take idle `{route}`" if route
           else f"no idle `{label}` runner, so the promoted jobs take the cascade" if label and runners is not None
           else f"`{label}` runners unread, so the promoted jobs take the cascade" if label
           else "no promote label, so the promoted jobs take the cascade")
    print(f"promote placement: {why}")
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"promote_runner={route}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### Promote placement\n\n{why}\n")
    print(f"macOS cascade: {placed.why}")
    cascade.write(placed, env)
    return 0


def _main(env: Mapping[str, str] = os.environ) -> int:
    runners = read_runners(env)
    if (env.get("PLACEMENT") or "").strip() == "rerun-fleet":
        return rerun_fleet_main(env, runners)
    if (env.get("PLACEMENT") or "").strip() == "handback":
        return handback_main(env, runners)
    if (env.get("PLACEMENT") or "").strip() == "app-compile":
        return app_compile_gateway_main(env, runners)
    if (env.get("PLACEMENT") or "").strip() == "promote":
        return promote_main(env, runners)
    if cascade.bot_rerun(env):
        return rerun_main(env, runners)
    # The pool snapshot and Blacksmith's queues, read once: the light fast route and the GUI routes are
    # weighed against them here and the cascade places with them below.
    live, waiting, seen = cascade.read(env, pool, now=dt.datetime.now(dt.timezone.utc))
    fast = fast_route(env, runners)
    light_fast = "" if fast else light_fast_route(env, runners, seen)
    fast = fast or light_fast
    if fast:
        env = without_fast(env)
    fresh, fresh_jobs = fresh_route(env, runners)
    if fresh_jobs:
        env = without_jobs(env, fresh_jobs)
    owned, fallback, why = decide(env, runners)
    label = (env.get("SIDE_LABEL") or "").strip()
    route = route_label(label, runners, len((env.get("JOBS") or "").split()))
    live_gui = gui_route_label(label, runners)
    gui_route = healthy_role_label(live_gui, runners, seen, waiting)
    session_route = healthy_role_label(session_route_label(label, runners), runners, seen, waiting)
    # Generated files' own session lane (vars.CI_SESSION_LANE_RUNNER, a glaeda-session-* label): written only while
    # it has room, so the variable never sends the job to a queue deeper than its pool.
    lane = (env.get("SESSION_LANE") or "").strip()
    # Unread runners are no reading: the lane is not vouched for, so the job keeps the route it had without it.
    session_lane = (healthy_role_label(lane, runners, seen, waiting)
                    if lane.startswith("glaeda-") and runners is not None else "")
    if route and route != label:
        why += (f"; `{route}` has more live room than `{label}`, routing jobs there"
                if route.startswith(pool.SIDE_PREFIX) else f"; no online side runner, routing jobs on `{route}`")
    if (env.get("FAST_LABEL") or "").strip():
        why += (f"; no idle `{env['FAST_LABEL'].strip()}` runner, so the fast tier takes idle light `{fast}`"
                if light_fast else f"; the fast tier takes idle `{fast}`" if fast
                else f"; no idle `{env['FAST_LABEL'].strip()}` runner, so the fast tier is placed like the other jobs")
    if (env.get("FRESH_LABEL") or "").strip() and (env.get("FRESH_JOBS") or "").strip() or fresh_jobs:
        why += (f"; {', '.join(fresh_jobs)} take idle `{fresh}`, the freshness slot" if fresh_jobs
                else f"; no idle `{env['FRESH_LABEL'].strip()}` runner "
                     f"({fresh_slot_state(env['FRESH_LABEL'].strip(), runners)}), so the feed's compile is placed "
                     "like the other jobs")
    gateway_label = (env.get("GATEWAY_LABEL") or "").strip()
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip() or "1"
    taken = gateway_taken(env, runners, fast)
    gateway = gateway_route(env, runners, taken)
    if gateway_label:
        if gateway:
            why += f"; the build-fleet compiles take idle `{gateway}`"
        else:
            why += (f"; no idle `{gateway_label}` runner (or a wider class's), so the build-fleet compiles "
                    "do not run and their Mac fallbacks take the cascade")
            env = with_gateway_cascade(env)
    if gateway and "release-compile-fast" in (env.get("GATEWAY_JOBS") or "").split():
        # The push's fleet fast check runs: its Mac fallback runs only without a verdict, and then on its own
        # route (cmux-next.yml), so it takes no cascade slot from the run's other jobs.
        env = without_cascade(env, GATEWAY_FALLBACKS["release-compile-fast"])
    dedicated_ready = nightly_runner_ready(env, runners)
    # The jobs no idle mini took: Blacksmith 12 vCPU, then 6 vCPU, while each has a free slot now and its
    # queue moves; the rest stay on the owned label (no GitHub-hosted overflow).
    # The dedicated nightly runner is preferred for Release compile. When it is
    # configured but busy/offline, send the compile to Blacksmith immediately
    # instead of queueing it on the reserved promotion label.
    promotion_busy = promote_busy(env, runners)
    dedicated_configured = bool((env.get("NIGHTLY_POOL") or "").strip()
                                and (env.get("NIGHTLY_RUNNER") or "").strip())
    if dedicated_ready:
        promotion_busy = False
    elif dedicated_configured:
        # An unreadable runner list is not evidence that the dedicated builder
        # is free. Treat it as unavailable so the Release compile overflows to
        # Blacksmith instead of queueing indefinitely on the promotion mini.
        promotion_busy = True
    # Runners read live: the jobs no idle mini took never stay on the side label while Blacksmith 6 vCPU
    # is a live last resort (next_macos_cascade.overflow()).
    # The jobs Blacksmith does not take wait on `route`: when its queue is the longer one (it started nothing
    # for longer than 6 vCPU's oldest job has waited, or one host alone serves it), they take 6 vCPU.
    placed = cascade.place(env, owned, live, waiting, seen, promote_busy=promotion_busy,
                           saturated=runners is not None, route_wait=route_wait(route, runners, seen))
    # A job listed for the build fleet runs its client on the gateway only with an idle runner of its own there.
    placed = fleet_gateway(placed, env, runners, gateway, taken)
    # With no GUI route that has room, the GUI jobs take the largest Blacksmith macOS size that starts them now,
    # after the slots this run's cascade just took (gui_overflow()). An unread fleet vouches for no owned GUI
    # queue either, so it overflows too, as it did before (the step's synthesized `runner` sent it to 6 vCPU).
    overflow = "" if gui_route else gui_overflow(env, live, waiting, seen, placed)
    if live_gui and not gui_route:
        # Its own name: `owned` is the jobs the idle minis took, which cascade.place() read above.
        role_queues = getattr(seen, "owned_queued", None) or {}
        why += (f"; `{live_gui}` has no room ({role_queues.get(live_gui, 0)} queued, "
                f"{_role_online(live_gui, runners or [])[0]} online, none idle), so the GUI jobs take `{overflow}`")
    elif overflow:
        why += (f"; no online GUI runner, so the GUI jobs take `{overflow}`" if runners is not None
                else f"; owned runners unread, so the GUI jobs take `{overflow}`")
    print(f"side-lane placement: {why}")
    watch = "false" if fallback and not owned else "true"
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            free_gui = free_gui_route_label(label, runners)
            free_session = free_session_route_label(label, runners)
            handle.write(f"owned_jobs={delimited(owned)}\nfallback_jobs={delimited(fallback)}\n"
                         f"runner={route}\ndeferred_runner={route or label}\ngui_runner={gui_route}\n"
                         f"session_runner={session_route}\n"
                         f"free_gui_runner={free_gui}\nfree_session_runner={free_session}\n"
                         f"gui_overflow={overflow}\nsession_lane_runner={session_lane}\n"
                         f"nightly_runner_ready={'true' if dedicated_ready else ''}\n"
                         f"fast_runner={fast}\n"
                         f"fresh_runner={fresh}\nfresh_jobs={delimited(fresh_jobs)}\n"
                         f"gateway_runner={gateway}\ngateway_attempt={attempt if gateway_label else ''}\n"
                         f"watch={watch}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### macOS placement\n\n{why}\n")
    print(f"macOS cascade: {placed.why}")
    cascade.write(placed, env)
    return 0


def _timeout_fallback(env: Mapping[str, str]) -> int:
    """Publish a safe ephemeral Mac route when placement reads exceed the deadline."""
    output = env.get("GITHUB_OUTPUT")
    if output:
        retry_jobs = cascade.delimited(cascade.candidates(env, ())[:cascade.MAX_PER_RUN])
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(
                f"owned_jobs=\nfallback_jobs=\nrunner={cascade.SMALL}\ndeferred_runner=\n"
                f"gui_runner=\nsession_runner=\nfree_gui_runner=\nfree_session_runner=\n"
                f"gui_overflow={cascade.SMALL}\nsession_lane_runner=\n"
                f"nightly_runner_ready=\nfast_runner=\nfresh_runner=\nfresh_jobs=\n"
                f"gateway_runner=\ngateway_attempt=\npromote_runner=\nwatch=false\n"
                f"blacksmith_12_jobs=\nblacksmith_6_jobs=\nfresh_stalled=\nfleet_jobs=\n"
                f"retry_runner={cascade.SMALL}\nfree_retry_runner={cascade.SMALL}\n"
                f"retry_jobs={retry_jobs}\n"
            )
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### macOS placement\n\nPlacement exceeded its read deadline; using "
                         f"{cascade.SMALL}.\n")
    print(f"::warning title=side-lane placement::read deadline exceeded; using {cascade.SMALL}")
    return 0


def main(env: Mapping[str, str] = os.environ) -> int:
    """Run placement with a hard deadline and a deterministic default route."""
    previous = signal.getsignal(signal.SIGALRM)
    def timeout(_signum: int, _frame: Any) -> None:
        raise PlacementDeadline("side-lane placement read deadline exceeded")
    try:
        signal.signal(signal.SIGALRM, timeout)
        signal.setitimer(signal.ITIMER_REAL, PLACEMENT_DEADLINE_SECONDS)
        return _main(env)
    except PlacementDeadline:
        return _timeout_fallback(env)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


if __name__ == "__main__":
    sys.exit(main())
