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
SIDE_LABEL that is online and idle now. When no online runner carries the side
label, jobs use its owned pool label so the std minis can accept them. When a
side label is online but busy, jobs remain on it and the rescue supplies the
measured overflow boundary after the mini queue drains.

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
- `watch`: "false" when every job took its fallback, so the run uploads no
  owned-pool-watch marker; "true" otherwise;
- `blacksmith_12_jobs`, `blacksmith_6_jobs` and `retry_runner`: the jobs no idle
  mini took that Blacksmith 12 vCPU, then 6 vCPU, has a free slot for now, and
  the Blacksmith label of the bot's overflow attempt (next_macos_cascade.py).
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import os
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


def _cascade():
    path = Path(__file__).with_name("next_macos_cascade.py")
    spec = importlib.util.spec_from_file_location("next_macos_cascade", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("next_macos_cascade", module)
    spec.loader.exec_module(module)
    return module


cascade = _cascade()


def route_label(label: str, runners: Sequence[Mapping[str, Any]] | None) -> str:
    """Use the side label while online, otherwise its owned pool label."""
    if runners is None:
        return ""
    if any(runner.get("status") == "online" and label in pool.runner_labels(runner)
           for runner in runners):
        return label
    return pool.pool_label(label)


def _live_role_label(label: str, runners: Sequence[Mapping[str, Any]] | None, role) -> str:
    """The first online `role` label (pr_runner_pool.gui_label or session_label) for an owned side label.

    The light minis run no GUI or session runner, so a light lane borrows the
    std minis' before the workflow's Blacksmith fallback: on 2026-10-18 every
    glaeda-gui-light job sampled waited for a runner until the rescue moved its
    run to Blacksmith while the std GUI runners sat idle.
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
    candidates = [role(owned)]
    parts = owned.split("-")
    if pool.LIGHT_CLASS in parts:
        parts[parts.index(pool.LIGHT_CLASS)] = "std"
        candidates.append(role("-".join(parts)))
    for candidate in candidates:
        if candidate and any(runner.get("status") == "online" and candidate in pool.runner_labels(runner)
                             for runner in runners):
            return candidate
    return ""


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


def decide(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None,
           ) -> tuple[tuple[str, ...], tuple[str, ...], str]:
    """(owned jobs, fallback jobs, why); ((), (), why) decides nothing and keeps today's route."""
    label = (env.get("SIDE_LABEL") or "").strip()
    jobs = tuple((env.get("JOBS") or "").split())
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip()
    if attempt not in ("", "1"):
        return (), (), f"attempt {attempt} keeps its own route"
    if not label.startswith(pool.SIDE_PREFIX) or not pool.persistent(label):
        return (), (), f"`{label or 'no label'}` is not an owned side label"
    if runners is None:
        return (), (), f"owned runners could not be read live; the jobs keep `{label}`"
    owned = pool.idle_placement(runners, label, jobs)
    # A busy fleet is a queue, not an instantaneous Blacksmith decision. The
    # rescue moves a job only after the side queue budget has elapsed.
    fallback: tuple[str, ...] = ()
    if not owned:
        return owned, fallback, f"no idle `{label}` runner now; every job stays queued on the owned label"
    return owned, fallback, (f"{len(owned)} idle `{label}` runner(s) now take {', '.join(owned)}"
                             + "; remaining jobs stay queued on the owned label")


def delimited(jobs: Sequence[str]) -> str:
    return f" {' '.join(jobs)} " if jobs else ""


def main(env: Mapping[str, str] = os.environ) -> int:
    runners = None
    token, repo = env.get("ROUTE_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    if token and repo:
        try:
            runners = pool.GitHub(token, repo).runners()
        except Exception as error:  # noqa: BLE001 - fail open: keep today's route
            print(f"::warning title=side-lane placement::could not list runners ({error})")
    owned, fallback, why = decide(env, runners)
    label = (env.get("SIDE_LABEL") or "").strip()
    route = route_label(label, runners)
    gui_route = gui_route_label(label, runners)
    session_route = session_route_label(label, runners)
    if route and route != label:
        why += f"; no online side runner, routing jobs on `{route}`"
    print(f"side-lane placement: {why}")
    watch = "false" if fallback and not owned else "true"
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"owned_jobs={delimited(owned)}\nfallback_jobs={delimited(fallback)}\n"
                         f"runner={route}\ngui_runner={gui_route}\nsession_runner={session_route}\n"
                         f"watch={watch}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### macOS placement\n\n{why}\n")
    # The jobs no idle mini took: Blacksmith 12 vCPU, then 6 vCPU, while each has a free slot now.
    live, waiting = cascade.read(env, pool, now=dt.datetime.now(dt.timezone.utc))
    placed = cascade.place(env, owned, live, waiting)
    print(f"macOS cascade: {placed.why}")
    cascade.write(placed, env)
    return 0


if __name__ == "__main__":
    sys.exit(main())
