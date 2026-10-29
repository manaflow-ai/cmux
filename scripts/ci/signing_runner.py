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
- On the mini, glaeda's job-started hook gives every signing job the exclusive
  class (glaeda SIGNING_JOBS): every capacity unit and both fast tokens, so no
  other job starts beside it, and it waits at most 300 s for the mini to drain
  before it is refused. Admitted, the hook writes GLAEDA_JOB_CLAIM=exclusive to
  $GITHUB_ENV, and the job's first step (scripts/ci/signing-runner-claim.sh)
  fails before any secret is read when that claim is missing on an owned Mac.
- `runner` and `alternate` are nightly_sign_runner.py's Blacksmith picks: the
  label whose queue moves, and the other size a re-run takes.

The workflow takes `owned` only on attempt 1; a re-run takes `alternate`, so a
job an owned runner refused or left queued leaves the fleet. It never fails the
job and never prints an empty `runner`:

    ENABLED=<vars.CI_SIGN_OWNED> ROUTE_TOKEN=<org runners: read> OWNED_LABELS='<a> <b>' \\
        SNAPSHOT_TOKEN=<actions: read> CANDIDATE=<vars.MACOS_RUNNER_26> signing_runner.py
    -> owned=..., runner=..., alternate=... in $GITHUB_OUTPUT

`signing_runner.py owned` prints only `owned` (pick-nightly-sign-runner already
prints the Blacksmith pair).
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nightly_sign_runner as blacksmith_picker  # noqa: E402
import pr_runner_pool as pool  # noqa: E402
from nightly_build_runner import owned_label  # noqa: E402

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


def member(name: str) -> str:
    """The mini a glaeda runner runs on: its name before `-glaeda` (pool, gui, fast and dedicated runners alike)."""
    head, found, _ = (name or "").partition("-glaeda")
    return head if found and head else ""


def drained_runner(runners: Sequence[Mapping[str, Any]], labels: Sequence[str], seed: str = "") -> tuple[str, str]:
    """(the JSON runs-on array for an idle runner on a mini with no busy runner, or "", why).

    A candidate runner is online, idle, carries one of `labels` (an owned pool label) and its own
    `glaeda-runner-<name>` label. Its mini qualifies only when no runner of that mini, whatever its
    labels or status, is busy now (an offline runner GitHub calls idle is a parked slot and runs nothing).
    `seed` picks among the qualifying minis; owned_pick passes none, so two pickers at once name the same
    mini and glaeda admits only one of them.
    """
    # The owned labels nightly_build_runner offers: a persistent pool or glaeda's nightly slot, which
    # vars.CI_NIGHTLY_NEXT_BUILD_RUNNER may name (its hook still admits a signing job only as the exclusive class).
    wanted = [label for label in labels if label and owned_label(label)]
    if not wanted:
        return "", f"no owned pool label among {list(labels) or 'none'}"
    busy: set[str] = set()
    idle: dict[str, list[tuple[str, str]]] = {}
    for runner in runners:
        name = str(runner.get("name") or "")
        mini = member(name)
        if not mini:
            continue
        if runner.get("busy"):
            # A busy runner of any status keeps its mini: an offline one GitHub still calls busy may be running a
            # job whose end it has not seen.
            busy.add(mini)
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
        return "", f"no mini with an idle {' or '.join(f'`{label}`' for label in wanted)} runner is drained now"
    mini = drained[sum(map(ord, seed)) % len(drained)] if seed else drained[0]
    label, name = sorted(idle[mini])[0]
    return (json.dumps([label, pool.runner_label(name)], separators=(",", ":")),
            f"`{name}` on {mini}, which runs no job now ({len(drained)} drained mini(s))")


def owned_signing_jobs(read: Callable[[str], Any]) -> int:
    """How many signing jobs (SIGNING_JOBS) are queued or running on an owned Mac now: pinned by a
    `glaeda-runner-<name>` label, which only the owned pick adds to a signing job's runs-on. `read` GETs a path
    under the repository (actions: read). Raises on any read it cannot make, so the caller offers no owned Mac."""
    count = 0
    for workflow, names in SIGNING_JOBS.items():
        for status in ("in_progress", "queued"):
            runs = read(f"/actions/workflows/{workflow}/runs?status={status}&per_page=50").get("workflow_runs") or []
            for run in runs:
                jobs = read(f"/actions/runs/{run['id']}/jobs?filter=latest&per_page=100").get("jobs") or []
                for job in jobs:
                    name = str(job.get("name") or "").split(" (", 1)[0]
                    if (name in names and job.get("status") in ("queued", "in_progress", "waiting", "pending")
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
    try:
        held = owned_signing_jobs(read_jobs or pool.GitHub(jobs_token, repo).get)
    except Exception as error:  # noqa: BLE001 - never fail the job; Blacksmith takes it
        print(f"::warning title=signing runner::could not count the signing jobs on owned Macs ({str(error)[:200]})")
        return "", "the signing jobs on owned Macs could not be counted, so none is offered"
    if held >= MAX_OWNED_SIGNING:
        return "", f"{held} signing job(s) already hold an owned Mac (at most {MAX_OWNED_SIGNING} at once)"
    try:
        runners = (read_runners or (lambda t, r: pool.GitHub(t, r).runners()))(token, repo)
    except Exception as error:  # noqa: BLE001 - never fail the job; Blacksmith takes it
        print(f"::warning title=signing runner::could not list owned runners ({str(error)[:200]})")
        return "", "owned runners could not be read"
    # No run-ID spread: two pickers at once name the same mini, and glaeda's exclusive admission lets only one of
    # them have it (the other is refused within 300 s and re-runs on Blacksmith), so the cap holds through a race.
    return drained_runner(runners, (env.get("OWNED_LABELS") or "").split())


def main(env: Mapping[str, str] = os.environ, argv: Sequence[str] = (),
         read_runners: Callable[[str, str], Sequence[Mapping[str, Any]]] | None = None,
         read_jobs: Callable[[str], Any] | None = None,
         read_snapshot: Callable[[str, str], Any] | None = None, now: dt.datetime | None = None) -> int:
    owned, owned_why = owned_pick(env, read_runners, read_jobs)
    if list(argv[:1]) == ["owned"]:
        write_output(env, {"owned": owned}, [f"owned: {owned or 'none'} ({owned_why})"])
        return 0
    now = now or dt.datetime.now(dt.timezone.utc)
    variable = (env.get("CANDIDATE") or "").strip()
    snapshot = None
    token, repo = env.get("SNAPSHOT_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    if token and repo:
        try:
            snapshot = (read_snapshot or (lambda t, r: pool.GitHub(t, r).snapshot(now=now)))(token, repo)
        except Exception as error:  # noqa: BLE001 - the variable keeps its say
            print(f"::warning title=signing runner::could not read the pool snapshot ({str(error)[:200]})")
    label, why = blacksmith_picker.pick(variable, snapshot, now)
    rerun_pick = (env.get("GITHUB_RUN_ATTEMPT") or "1").strip() not in ("", "1")
    other = label if rerun_pick else blacksmith_picker.alternate(variable, label, snapshot, now)
    write_output(env, {"owned": owned, "runner": label, "alternate": other},
                 [f"owned: {owned or 'none'} ({owned_why})", f"blacksmith: {why}; a re-run takes `{other}`"])
    return 0


if __name__ == "__main__":
    sys.exit(main(argv=sys.argv[1:]))
