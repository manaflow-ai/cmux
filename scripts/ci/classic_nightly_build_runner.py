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
- the runner list could not be read: keep the pinned tuple (the behaviour before this script;
  the rescue still watches it), with a warning.

`blacksmith` is the Blacksmith macOS 26 label whose queue moves, by simple_pool_picker's one stall
rule over the queue janitor's snapshot: 12 vCPU first (the build's old default), then 6 vCPU; with
both stalled, 6 vCPU (more slots); with no fresh snapshot, 12 vCPU. A re-run of failed jobs keeps
these outputs, so attempt 2 on takes `cloud`. Nothing here routes to any owned label other
than the pinned pair, so the ci-cache-writer keys and the Sentry token stay on the trusted mini.
FIRST (a label among those two, or its size, `6vcpu` or `12vcpu`) puts that label ahead: the sign
and verify jobs of main's nightly
and the DEV publisher's Mac jobs keep 6 vCPU, their old pinned default, while it moves. With
ENABLED unset the trusted pick is skipped and only `cloud` is read. `alternate` is the other label,
for a re-run.
`classic_nightly_build_runner.py prepare` prints only `trusted`, read once with no wait, and false
when the list cannot be read: prepare-nightly-variant (no secrets) takes the same pinned tuple while
that mini is idle right after the build, else its Blacksmith label. Its three legs ran about 1 min
each but queued 27-42 min on blacksmith-6vcpu-macos-26 in runs 40557789720 and 40567539918, and
run 40604652316's sat queued from 00:54:52Z with every Blacksmith macOS 26 label stalled, while the
mini that had just built the app sat idle. Signing and verify stay on Blacksmith.
It never fails the job and never prints an empty `cloud`:

    ROUTE_TOKEN=<runners: read> SNAPSHOT_TOKEN=<actions: read> TRUSTED_POOL=... TRUSTED_RUNNER=...
    ENABLED=1 classic_nightly_build_runner.py  -> trusted=true|false, cloud=<label>, alternate=<label>
"""

from __future__ import annotations

import datetime as dt
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


def runner_state(pool: str, runner: str, runners: Sequence[Mapping[str, Any]] | None) -> str:
    """'idle', 'busy', 'offline' or 'unread' for the runner carrying both pinned labels."""
    if runners is None:
        return "unread"
    online = [item for item in runners if item.get("status") == "online"
              and {pool, runner} <= {str(label.get("name")) for label in item.get("labels") or ()
                                     if isinstance(label, Mapping)}]
    if not online:
        return "offline"
    return "idle" if any(not item.get("busy") for item in online) else "busy"


def trusted_route(pool: str, runner: str, read: Callable[[], Sequence[Mapping[str, Any]] | None],
                  enabled: bool, attempt: str, *, wait_seconds: float = WAIT_SECONDS,
                  look_seconds: float = LOOK_SECONDS, sleep: Callable[[float], None] = time.sleep,
                  clock: Callable[[], float] = time.monotonic, unread_keeps: bool = True) -> tuple[bool, str]:
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


def blacksmith_route(snapshot: Mapping[str, Any] | None, now: dt.datetime,
                     first: str = "") -> tuple[str, str]:
    """(the first Blacksmith macOS 26 label whose queue moves, why)."""
    order = candidates(first)
    if not isinstance(snapshot, Mapping) or not isinstance(snapshot.get("pools"), Mapping):
        return order[0], f"no fresh pool snapshot, so `{order[0]}`"
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
             if picker.blacksmith_stalled(int(field(label, "queued")), field(label, "oldest_queued_minutes") + age)]
    moving = [label for label in order if label not in stuck]
    if not moving:
        return SMALL, f"every Blacksmith macOS 26 label is stalled; `{SMALL}` has the most slots"
    return moving[0], f"`{moving[0]}`" + (f", past stalled `{stuck[0]}`" if moving[0] != order[0] else "")


def alternate(label: str) -> str:
    """The other Blacksmith macOS 26 label. The jobs take it on an attempt later than the one that made
    the pick (`attempt`): a re-run of failed jobs keeps the pick job's outputs, and GitHub never
    re-routes a queued job, so the re-run leaves the label that stalled after the pick. A re-run of all
    jobs runs the picker again, and that attempt takes the fresh pick."""
    return next(other for other in CANDIDATES if other != label) if label in CANDIDATES else SMALL


def main(env: Mapping[str, str] = os.environ, argv: Sequence[str] = (),
         read_runners: Callable[[str, str], Sequence[Mapping[str, Any]]] | None = None,
         read_snapshot: Callable[[str, str], Any] | None = None, now: dt.datetime | None = None,
         sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic,
         wall: Callable[[], dt.datetime] = lambda: dt.datetime.now(dt.timezone.utc)) -> int:
    repo = env.get("GITHUB_REPOSITORY", "")
    route_token = env.get("ROUTE_TOKEN", "")

    def read() -> Sequence[Mapping[str, Any]] | None:
        if not (route_token and repo):
            return None
        try:
            if read_runners is not None:
                return read_runners(route_token, repo)
            import pr_runner_pool  # noqa: PLC0415 - only for the live read

            return pr_runner_pool.GitHub(route_token, repo).runners()
        except Exception as error:  # noqa: BLE001 - never fail the job
            print(f"::warning title=classic nightly build runner::could not list runners ({str(error)[:200]})")
            return None

    # Wall time before the wait: the snapshot's queue ages are read against it plus the wait.
    now = now or wall()
    started = clock()
    prepare = list(argv[:1]) == ["prepare"]
    trusted, trusted_why = trusted_route((env.get("TRUSTED_POOL") or "").strip(),
                                         (env.get("TRUSTED_RUNNER") or "").strip(), read,
                                         (env.get("ENABLED") or "").strip() == "1",
                                         (env.get("GITHUB_RUN_ATTEMPT") or "").strip(), sleep=sleep, clock=clock,
                                         wait_seconds=0 if prepare else WAIT_SECONDS, unread_keeps=not prepare)
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
    snapshot = None
    snapshot_token = env.get("SNAPSHOT_TOKEN", "")
    if snapshot_token and repo:
        try:
            if read_snapshot is not None:
                snapshot = read_snapshot(snapshot_token, repo)
            else:
                import pr_runner_pool  # noqa: PLC0415

                snapshot = pr_runner_pool.GitHub(snapshot_token, repo).snapshot(now=now)
                if snapshot is not None and pr_runner_pool.snapshot_problem(snapshot, now):
                    snapshot = None
        except Exception as error:  # noqa: BLE001 - the default label keeps its say
            print(f"::warning title=classic nightly build runner::could not read the pool snapshot ({str(error)[:200]})")
    blacksmith, blacksmith_why = blacksmith_route(snapshot, now, (env.get("FIRST") or "").strip())
    lines = [f"trusted: {'yes' if trusted else 'no'} ({trusted_why})", f"blacksmith: {blacksmith} ({blacksmith_why})"]
    for line in lines:
        print(f"classic nightly build runner: {line}")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"trusted={'true' if trusted else 'false'}\ncloud={blacksmith}\n"
                         f"alternate={alternate(blacksmith)}\nattempt={(env.get('GITHUB_RUN_ATTEMPT') or '1').strip()}\n")
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write("\nNightly build runner:\n" + "".join(f"- {line}\n" for line in lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(argv=sys.argv[1:]))
