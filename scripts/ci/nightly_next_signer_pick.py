#!/usr/bin/env python3
"""Pick the signer Mac for one nightly-next-one build, so two builds can run at once, one per signer Mac.

Why: docs/ci/nightly-workflow-notes.md#note-33 (design manaflow-ai/cmuxterm-hq#17011, 2026-11-21). Both signer Macs
(cmux15 and ultra1) carry the signer label glaeda-trusted-next-signing, and each has more than one runner with it.
With the label alone, GitHub can hand two in-flight builds to cmux15's two runners: the second then waits in
glaeda's start hook for the whole Mac while ultra1 sits idle. So nightly.yml's pick-nightly-next-signer runs this
script, and nightly-next-one takes:

- runs-on: the pin printed here, `["glaeda-trusted-next-signing","glaeda-runner-<runner>"]`. It ALWAYS starts with
  the literal signer label, so it can only narrow within the signers, never widen past them (the pattern
  signing_runner.drained_runner(..., signer_only=True) prints for the split signing jobs).
- concurrency: `nightly-next-one-push-<host>` for a push or the loop's retry (one build per Mac, never cancelled),
  host in HOSTS.

The pick, in order:
1. A free signer: a host in HOSTS with an online, idle signer runner, no busy signer runner and no open loop run's
   nightly-next-one queued, pending or running for it. cmux15 first when both are free (signer #1).
2. Else the host whose holder ends soonest: a host busy only with a signer tail job (keep-published-dsyms,
   the delta jobs; minutes), then a holder at or past FINISH_STEPS (notarizing or publishing), then the holder
   that started first. A host that already has a nightly-next-one waiting for it is never picked: a second waiting
   job in its group would get GitHub to replace (cancel) the first.
A host whose last finished nightly-next-one failed in CRASH_STEPS (the app build) is a crashed host: steps 1 and 2
take the other host whenever it can take the build (free, or rankable in step 2) and the crashed host only when no
other can. Without it, one Mac with a crashing build service took every build: 2026-11-27 15:24Z-17:57Z, 9 builds
in a row picked the same Mac as "an idle signer" and failed in "Build nightly app (Release)", 21 of 22 builds in 48 h
ran there, and nothing moved them to the other signer.
3. Else, and on ANY failure (no census, a read that fails, a malformed answer): host cmux15 and the pin of the label
   alone, which is exactly the routing before this script (one group, either Mac).

Reads, all bounded and none waiting on a rate limit: vars.CI_RUNNER_STATE (the runner census runner-heal publishes
every two minutes, no API call), then one listing of nightly.yml's runs on nightly-next and one jobs listing for
each open loop run (at most MAX_RUNS), plus one for each of the newest finished loop runs (at most MAX_DONE_RUNS) to
find each host's last finished nightly-next-one. Each request has a READ_TIMEOUT and is never retried with the same
token. The reads go first as SPARE_READ_TOKEN (the glaeda-route App's read-only token decide already mints: its own hourly
budget) and, on a 403 or 429 or with no spare, as the job's GITHUB_TOKEN (actions: read). With the GITHUB_TOKEN alone
the shared budget ran dry and the pick fell back (run 45575194160, 2026-11-25: "HTTP Error 403: Forbidden"), so
both builds took cmux15 and the second waited 10.5 min at the slot. Leo (ask-c0123d25e8): "why so long that they
didnt publish either tho cuz it's been 5h". The script never fails the job.

usage: nightly_next_signer_pick.py   (env: GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_TOKEN, CI_RUNNER_STATE)
Writes host=..., pin=... and reason=... to $GITHUB_OUTPUT.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402
import pr_runner_pool as pool  # noqa: E402
from signing_runner import SIGNER_LABEL, member  # noqa: E402

# The signer Macs, each its own slot (concurrency group nightly-next-one-push-<host>). Any other host never names a
# group, so the group names stay a fixed set.
HOSTS = ("cmux15", "ultra1")
FALLBACK_HOST = "cmux15"
FALLBACK_PIN = json.dumps([SIGNER_LABEL], separators=(",", ":"))
ONE_JOB = "nightly-next-one"
# nightly-next-one's steps from which a holder is finishing (main's scripts/ci/nightly_next_rolling.py FINISH_STEPS;
# tests/test_nightly_next_signer_pick.py checks nightly.yml still has both).
FINISH_STEPS = ("Ask main's nightly-next tick at notarization", "Notarize app ticket through final DMG")
RETRY_TITLE = re.compile(r"^Retry nightly-next \([1-9][0-9]* of [1-9][0-9]*\)$")
RESUME_TITLE = re.compile(r"^Resume nightly-next\b")
WAITING = ("queued", "pending", "waiting", "requested")
RUNNER_PIN = re.compile(r"^glaeda-runner-[a-z0-9._-]+$")
READ_TIMEOUT = 10.0
MAX_RUNS = 6
# The newest finished loop runs read for each host's last finished nightly-next-one (the crashed-host check).
MAX_DONE_RUNS = 3
# A nightly-next-one that failed in one of these steps marks its host as crashed (the app build: the build service
# crash on one signer Mac is host state, and the next build there crashes the same way).
CRASH_STEPS = ("Build nightly app (Release)",)
# The census's age the pick accepts. vars are read when the run starts, and the pick runs after resolve (~13 min):
# runs 44990363506, 44992267457 and 44993740115 (2026-11-22) read censuses 30, 36 and 23 min old against the pool's
# 5 min, so every pick fell back and every build queued in nightly-next-one-push-cmux15, one at a time. The pick
# reads which signer runners are online and busy from the census, and the nightly-next-one builds holding or
# waiting for each host from the live jobs listing; an older census can pin a runner that went offline since.
CENSUS_MAX_AGE_SECONDS = 50 * 60


def loop_run(run: Mapping[str, Any], finished: bool = False) -> bool:
    """A nightly.yml run on nightly-next whose nightly-next-one takes a slot group: a push (not a resume) or the
    loop's retry dispatch. Every other run's nightly-next-one is run-scoped. Open runs, or with finished, done ones."""
    if run.get("head_branch") not in (None, "nightly-next") or (run.get("status") == "completed") != finished:
        return False
    title = str(run.get("display_title") or "")
    if run.get("event") == "push":
        return not RESUME_TITLE.match(title)
    return run.get("event") == "workflow_dispatch" and bool(RETRY_TITLE.match(title))


def finishing(job: Mapping[str, Any]) -> bool:
    return job.get("status") == "in_progress" and any(
        step.get("name") in FINISH_STEPS and (step.get("status") == "in_progress" or step.get("status") == "completed"
                                              and step.get("conclusion") in ("success", "failure"))
        for step in job.get("steps") or [])


def pin_for(runner: str) -> str:
    """The runs-on pin for one signer runner: the literal signer label first, then that runner's own label."""
    label = pool.runner_label(runner)
    if not RUNNER_PIN.fullmatch(label):
        raise ValueError(f"runner label {label!r} is not a glaeda runner label")
    return json.dumps([SIGNER_LABEL, label], separators=(",", ":"))


def labels_of(runner: Mapping[str, Any]) -> set[str]:
    return pool.runner_labels(runner)


def signers(runners: Sequence[Mapping[str, Any]]) -> dict[str, list[Mapping[str, Any]]]:
    """HOSTS -> their runners carrying the signer label and their own runner label."""
    out: dict[str, list[Mapping[str, Any]]] = {host: [] for host in HOSTS}
    for runner in runners:
        name = str(runner.get("name") or "")
        host = member(name)
        if host in out and SIGNER_LABEL in labels_of(runner) and pool.runner_label(name) in labels_of(runner):
            out[host].append(runner)
    return out


def holder_host(job: Mapping[str, Any], names: Sequence[str]) -> str:
    """The host a nightly-next-one holds or waits for: its runner's, else its pin's, else FALLBACK_HOST (a job on
    the label alone, which the fallback pick's group, nightly-next-one-push-cmux15, holds)."""
    runner = str(job.get("runner_name") or "")
    if runner and member(runner):
        return member(runner)
    for label in job.get("labels") or []:
        label = str(label)
        if not label.startswith(pool.RUNNER_LABEL_PREFIX):
            continue
        for name in names:
            if pool.runner_label(name) == label:
                return member(name)
        guess = member(label[len(pool.RUNNER_LABEL_PREFIX):])
        if guess:
            return guess
    return FALLBACK_HOST


def crashed_hosts(done: Sequence[Mapping[str, Any]]) -> frozenset[str]:
    """HOSTS whose last finished nightly-next-one (by completed_at) failed in CRASH_STEPS."""
    last: dict[str, Mapping[str, Any]] = {}
    for job in done:
        if job.get("name") != ONE_JOB or job.get("status") != "completed" or not job.get("runner_name"):
            continue
        host = member(str(job.get("runner_name")))
        if host in HOSTS and str(job.get("completed_at") or "") >= str(last.get(host, {}).get("completed_at") or ""):
            last[host] = job
    return frozenset(host for host, job in last.items() if job.get("conclusion") == "failure" and any(
        step.get("name") in CRASH_STEPS and step.get("conclusion") == "failure" for step in job.get("steps") or []))


def pick(runners: Sequence[Mapping[str, Any]], holders: Sequence[Mapping[str, Any]],
         crashed: frozenset[str] = frozenset()) -> tuple[str, str, str]:
    """(host, pin, why) from the census runners and the open loop runs' nightly-next-one jobs (not this run's).
    The crashed hosts are picked only when no other host can take the build."""
    healthy = tuple(host for host in HOSTS if host not in crashed)
    if healthy != HOSTS:
        found = pick_among(runners, holders, healthy)
        if found:
            host, pin, why = found
            return host, pin, f"{why}; {', '.join(sorted(crashed))} skipped: its last build failed in the app build"
    return pick_among(runners, holders, HOSTS) or (
        FALLBACK_HOST, FALLBACK_PIN,
        "no signer is free and none can take a waiting build without replacing one; the signer label alone, as before")


def pick_among(runners: Sequence[Mapping[str, Any]], holders: Sequence[Mapping[str, Any]],
               hosts: Sequence[str]) -> tuple[str, str, str] | None:
    """pick's steps 1 and 2 over hosts only; None when none of them can take the build."""
    by_host = signers(runners)
    names = [str(r.get("name") or "") for r in runners]
    claims: dict[str, list[Mapping[str, Any]]] = {host: [] for host in HOSTS}
    for job in holders:
        if job.get("name") != ONE_JOB or job.get("status") not in (*WAITING, "in_progress"):
            continue
        host = holder_host(job, names)
        if host in claims:
            claims[host].append(job)
    online = {host: sorted((r for r in found if r.get("status") == "online"), key=lambda r: str(r.get("name")))
              for host, found in by_host.items()}
    idle = {host: [r for r in found if not r.get("busy")] for host, found in online.items()}
    busy = {host: any(r.get("busy") for r in found) for host, found in by_host.items()}
    for host in hosts:
        if idle[host] and not busy[host] and not claims[host]:
            runner = str(idle[host][0].get("name"))
            return host, pin_for(runner), f"`{runner}` on {host}: an idle signer with no nightly-next-one for it"
    ranked = []
    for host in hosts:
        if not online[host] or any(job.get("status") in WAITING for job in claims[host]) or len(claims[host]) > 1:
            continue
        runner = str((idle[host] or online[host])[0].get("name"))
        if not claims[host]:
            ranked.append(((0, ""), host, runner, "busy only with a signer tail job"))
            continue
        job = claims[host][0]
        started = str(job.get("started_at") or "")
        held = str(job.get("runner_name") or "")
        if held and any(str(r.get("name")) == held for r in online[host]) and not idle[host]:
            runner = held
        if finishing(job):
            ranked.append(((1, started), host, runner, "its nightly-next-one is notarizing or publishing"))
        else:
            ranked.append(((2, started or "~"), host, runner, f"its nightly-next-one started first ({started or '?'})"))
    if ranked:
        _, host, runner, why = sorted(ranked)[0]
        return host, pin_for(runner), f"`{runner}` on {host}, no signer is free: {why}"
    return None


def api_get(repo: str, tokens: Sequence[str]) -> Callable[[str], Any]:
    """A reader that sends each request as the first token that still has budget: a 403 or 429 moves to the next."""
    remaining = [token for token in tokens if token]

    def get(path: str) -> Any:
        while True:
            request = urllib.request.Request(f"https://api.github.com/repos/{repo}/{path}", headers={
                "Accept": "application/vnd.github+json", "Authorization": f"Bearer {remaining[0]}",
                "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-nightly-next-signer-pick"})
            try:
                _, body, _ = deadline_http.request(request, READ_TIMEOUT, follow_redirects=False, raise_errors=True)
            except urllib.error.HTTPError as error:
                if error.code in (403, 429) and len(remaining) > 1:
                    remaining.pop(0)
                    continue
                raise
            return json.loads(body)
    return get


def evaluate(env: Mapping[str, str], get: Callable[[str], Any] | None = None,
             now: dt.datetime | None = None) -> tuple[str, str, str]:
    """(host, pin, why); any failure is the fallback (cmux15, the label alone)."""
    try:
        repo = env.get("GITHUB_REPOSITORY", "")
        document = pool.runner_state(repo, raw=env.get("CI_RUNNER_STATE", ""), now=now,
                                     max_age_seconds=CENSUS_MAX_AGE_SECONDS)
        if document is None:
            raise LookupError("vars.CI_RUNNER_STATE is missing, stale or not a complete census")
        runners = pool.census_runners(document)
        if get is None:
            tokens = [token for token in (env.get("SPARE_READ_TOKEN", ""), env.get("GITHUB_TOKEN", "")) if token]
            if not tokens:
                raise LookupError("no SPARE_READ_TOKEN or GITHUB_TOKEN to read the open nightly-next runs")
            get = api_get(repo, tokens)
        own = str(env.get("GITHUB_RUN_ID") or "")
        listing = get("actions/workflows/nightly.yml/runs?" + urllib.parse.urlencode(
            {"branch": "nightly-next", "per_page": 30}))
        runs = [run for run in listing["workflow_runs"] if loop_run(run) and str(run.get("id")) != own]
        done_runs = [run for run in listing["workflow_runs"] if loop_run(run, finished=True)][:MAX_DONE_RUNS]
        if len(runs) > MAX_RUNS:
            raise LookupError(f"{len(runs)} open nightly-next loop runs (more than {MAX_RUNS})")
        holders = []
        for run in runs:
            holders.extend(get(f"actions/runs/{int(run['id'])}/jobs?filter=latest&per_page=100")["jobs"])
        crashed: frozenset[str] = frozenset()
        try:
            done = []
            for run in done_runs:
                done.extend(get(f"actions/runs/{int(run['id'])}/jobs?filter=latest&per_page=100")["jobs"])
            crashed = crashed_hosts(done)
        except Exception as error:  # noqa: BLE001 - the crashed-host check only reorders; a failed read skips it
            print(f"::warning title=nightly-next signer pick::crashed-host check skipped ({type(error).__name__})")
        return pick(runners, holders, crashed)
    except Exception as error:  # noqa: BLE001 - never fail the job: the label alone is the routing before this
        why = f"pick failed ({type(error).__name__}: {str(error)[:200]}); the signer label alone, as before"
        print(f"::warning title=nightly-next signer pick::{why}")
        return FALLBACK_HOST, FALLBACK_PIN, why


def main(env: Mapping[str, str] = os.environ) -> int:
    host, pin, why = evaluate(env)
    if host not in HOSTS or not pin.startswith(f'["{SIGNER_LABEL}"'):
        host, pin, why = FALLBACK_HOST, FALLBACK_PIN, f"refused an unexpected pick ({host!r}, {pin!r})"
    print(f"nightly-next signer: host={host} pin={pin} ({why})")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"host={host}\npin={pin}\nreason={why}\n")
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(f"\nnightly-next signer: `{host}`, runs-on `{pin}` ({why})\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
