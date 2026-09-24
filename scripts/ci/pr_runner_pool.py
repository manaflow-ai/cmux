#!/usr/bin/env python3
"""Pick the macOS pool a pull request CI run lands on.

ci.yml's `changes` job calls this once per run, and every pull-request macOS
job in the run reads the answer: compile admission, the app-host consumers
that follow it, tests-build-and-lag, the Claude wrapper, CLI pipe and remote
daemon lanes. A run is never split across pools, because the app-host product
only loads under the Xcode that linked it (#14163).

The run takes the first pool in preference order that has headroom:

    vars.CI_PR_POOL_ORDER, comma-separated; by default
      blacksmith-12vcpu-macos-26   same macOS and Xcode as the lane, faster
      blacksmith-6vcpu-macos-26    vars.MACOS_RUNNER_PR today
      blacksmith-6vcpu-macos-15    macOS 15 Xcode (vars.CMUX_CI_XCODE_APP_MACOS_15),
                                   the pool and Xcode main's own CI runs on

    headroom = fewer than vars.CI_PR_POOL_MAX_QUEUED jobs queued (default 3)
               and no queued release or nightly job on the pool

When no pool has headroom, the run takes the one with the fewest queued jobs
(the earlier pool on a tie). A pool holding a queued release or nightly job
is never chosen: pull requests must not delay those. Every Blacksmith pool
is sponsored, so cost is not a reason to prefer one.

`vars.CI_PR_POOL_OVERFLOW == '0'` turns this off. Only the labels in POOLS
are accepted, because each one's Xcode pin is known here; a new pool (owned
Mac minis, say) joins POOLS with its Xcode before it can appear in the order.

The queue comes from the queue janitor, which lists every in-flight run's
jobs each sweep and publishes what it saw as the `macos-pool-load` artifact.
Only a copy uploaded by a run on main of this repository counts, so no other
branch can steer the choice. The janitor sweeps every 10 to 30 minutes, so
every pull request run created since the snapshot is replayed through the
same rule first, one queued job each, and a burst of pushes spreads across
the pools instead of all taking the one that looked idle. That costs three
API requests (the artifact listing, its download redirect, and one page of
CI runs); listing jobs here would cost one per in-flight run on every push,
out of the GITHUB_TOKEN's shared budget of about 1000 an hour. A snapshot
older than MAX_SNAPSHOT_MINUTES counts as unknown.

A pull request from a fork into manaflow-ai/cmux gets no repository
variables. It follows the settings and lane the janitor copied into the
snapshot (so the kill switch reaches it too), never pins an Xcode (each job
selects the newest SDK 26 Xcode on the pool it lands on, and the product
consumers restate compile admission's empty pin), and only lands on
ephemeral Blacksmith pools.

Anything uncertain keeps today's route: an event other than pull_request, a
lane (MACOS_RUNNER_PR) naming another pool or unset (the documented way back
to the macOS 15 lane), an API error, a missing, stale or malformed snapshot,
or an invalid setting. The script then prints an empty runner, and every
job's own expression resolves exactly as before.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import io
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections.abc import Callable, Mapping, Sequence
from typing import Any

DEFAULT_RUNNER = "blacksmith-6vcpu-macos-26"
LARGE_RUNNER = "blacksmith-12vcpu-macos-26"
MACOS_15_RUNNER = "blacksmith-6vcpu-macos-15"
# Pool -> the variable holding its Xcode pin; "" keeps the pull-request lane's
# own pin, which is right for every macOS 26 pool.
POOLS = {
    LARGE_RUNNER: "",
    DEFAULT_RUNNER: "",
    MACOS_15_RUNNER: "CMUX_CI_XCODE_APP_MACOS_15",
}
DEFAULT_ORDER = (LARGE_RUNNER, DEFAULT_RUNNER, MACOS_15_RUNNER)
# Pools whose machines are discarded after each job; the only ones a fork run may use.
EPHEMERAL_PREFIX = "blacksmith-"

OVERFLOW_VARIABLE = "CI_PR_POOL_OVERFLOW"
ORDER_VARIABLE = "CI_PR_POOL_ORDER"
MAX_QUEUED_VARIABLE = "CI_PR_POOL_MAX_QUEUED"
DEFAULT_MAX_QUEUED = 3

ARTIFACT_NAME = "macos-pool-load"
SNAPSHOT_FILE = "macos-pool-load.json"
SNAPSHOT_BRANCH = "main"
CI_WORKFLOW = "ci.yml"
MAX_SNAPSHOT_MINUTES = 45
PAGE_SIZE = 100
API = "https://api.github.com"


@dataclasses.dataclass(frozen=True)
class Settings:
    order: tuple[str, ...] = DEFAULT_ORDER
    max_queued: int = DEFAULT_MAX_QUEUED


@dataclasses.dataclass(frozen=True)
class Choice:
    runner: str  # "" keeps every job's own fallback expression
    xcode_app: str  # "" keeps every job's own Xcode pin
    reason: str


def settings(overflow: str | None, order: str | None, max_queued: str | None) -> Settings | None:
    """Settings from repository variables; None when turned off or invalid."""
    if (overflow or "").strip() == "0":
        return None
    labels = tuple(label.strip() for label in (order or "").split(",") if label.strip()) or DEFAULT_ORDER
    if len(set(labels)) != len(labels) or any(label not in POOLS for label in labels):
        return None
    try:
        limit = int(max_queued) if (max_queued or "").strip() else DEFAULT_MAX_QUEUED
    except ValueError:
        return None
    if limit < 1:
        return None
    return Settings(labels, limit)


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def snapshot_age_minutes(snapshot: Mapping[str, Any], now: dt.datetime) -> float | None:
    generated = parse_time(str(snapshot.get("generated_at") or ""))
    if generated is None:
        return None
    return (now - generated).total_seconds() / 60


def pool(snapshot: Mapping[str, Any], label: str) -> Mapping[str, int]:
    """One pool's counts; a pool the janitor saw no job on is empty, not unknown."""
    entry = (snapshot.get("pools") or {}).get(label) or {}
    return {key: int(entry.get(key) or 0) for key in ("queued", "running", "reserved_queued", "oldest_queued_minutes")}


def describe(snapshot: Mapping[str, Any], label: str) -> str:
    counts = pool(snapshot, label)
    text = f"{label}: {counts['queued']} queued, {counts['running']} running"
    if counts["queued"]:
        text += f", oldest {counts['oldest_queued_minutes']} min"
    if counts["reserved_queued"]:
        text += f", {counts['reserved_queued']} release/nightly queued"
    return text


def pick(queued: Mapping[str, int], usable: Sequence[str], max_queued: int) -> tuple[str, bool]:
    """The rule itself: first usable pool with headroom, else the fewest queued."""
    for label in usable:
        if queued[label] < max_queued:
            return label, True
    return min(usable, key=lambda label: queued[label]), False


def decide(
    snapshot: Mapping[str, Any] | None,
    limits: Settings,
    *,
    now: dt.datetime,
    xcode_pins: Mapping[str, str],
    routed_since: int = 0,
    auto_xcode: bool = False,
) -> Choice:
    """The preference rule over a janitor snapshot. Uncertainty keeps today's route.

    `routed_since` runs were created after the snapshot and each already took
    a pool by this rule; they are replayed first. `auto_xcode` (a fork run,
    which has no pins) lets every pool fall back to each job selecting its
    pool's newest SDK 26 Xcode.
    """
    if not isinstance(snapshot, Mapping) or not isinstance(snapshot.get("pools"), Mapping):
        return Choice("", "", "no readable pool snapshot")
    age = snapshot_age_minutes(snapshot, now)
    if age is None or age < -5 or age > MAX_SNAPSHOT_MINUTES:
        return Choice("", "", f"pool snapshot is stale or undated (age {age if age is None else round(age)} min)")
    try:
        load = {label: pool(snapshot, label) for label in limits.order}
    except (TypeError, ValueError, AttributeError):
        return Choice("", "", "malformed pool snapshot")

    def xcode(label: str) -> str | None:
        variable = POOLS[label]
        if not variable or auto_xcode:
            return ""
        return (xcode_pins.get(variable) or "").strip() or None

    usable = [label for label in limits.order if load[label]["reserved_queued"] == 0 and xcode(label) is not None]
    if not usable:
        return Choice("", "", "every pool in the order is reserved or has no Xcode pin")
    skipped = [label for label in limits.order if label not in usable]
    note = f"; skipped {', '.join(skipped)} (reserved or no Xcode pin)" if skipped else ""
    queued = {label: load[label]["queued"] for label in usable}
    for _ in range(max(0, routed_since)):
        earlier, _ = pick(queued, usable, limits.max_queued)
        queued[earlier] += 1
    label, headroom = pick(queued, usable, limits.max_queued)
    replay = f" after replaying {routed_since} newer run(s)" if routed_since else ""
    why = (f"first pool in order with headroom (< {limits.max_queued} queued){replay}" if headroom
           else f"no pool has headroom{replay}; fewest queued")
    return Choice(label, xcode(label) or "", why + note)


def choose(
    *,
    event: str,
    repo: str,
    head_repo: str,
    default_runner: str,
    overflow: str | None,
    order: str | None,
    max_queued: str | None,
    xcode_pins: Mapping[str, str],
    fetch: Callable[[], Mapping[str, Any] | None],
    count_routed: Callable[[str], int] = lambda since: 0,
    now: dt.datetime,
) -> tuple[Choice, Mapping[str, Any] | None]:
    """The pool for this run and the snapshot it was read from (None when none was read)."""
    if event != "pull_request":
        return Choice("", "", f"{event or 'unknown'} event; not a pull request"), None
    if not head_repo:
        return Choice("", "", "pull request head repository unknown"), None
    fork = head_repo != repo
    if not fork:
        if (default_runner or "").strip() != DEFAULT_RUNNER:
            return Choice("", "", f"MACOS_RUNNER_PR is {default_runner or 'unset'}, not {DEFAULT_RUNNER}"), None
        limits = settings(overflow, order, max_queued)
        if limits is None:
            return Choice("", "", f"{OVERFLOW_VARIABLE} is 0, or {ORDER_VARIABLE}/{MAX_QUEUED_VARIABLE} "
                                  "is invalid"), None
    try:
        snapshot = fetch()
    except Exception as error:  # noqa: BLE001 - every failure keeps the default
        return Choice("", "", f"could not read the pool snapshot ({error})"), None
    if fork:
        # No repository variables reach a fork run; the janitor copied them.
        copied = snapshot.get("settings") if isinstance(snapshot, Mapping) else None
        if not isinstance(copied, Mapping):
            return Choice("", "", "fork head; the snapshot carries no settings"), snapshot
        if str(copied.get("lane") or "").strip() != DEFAULT_RUNNER:
            return Choice("", "", f"fork head; the lane is {copied.get('lane') or 'unset'}, "
                                  f"not {DEFAULT_RUNNER}"), snapshot
        limits = settings(copied.get("overflow"), copied.get("order"), copied.get("max_queued"))
        if limits is None:
            return Choice("", "", f"fork head; {OVERFLOW_VARIABLE} is 0, or the copied settings "
                                  "are invalid"), snapshot
        # Fork code runs only on ephemeral Blacksmith machines, never on a
        # persistent pool (owned Macs) that may join POOLS later.
        limits = dataclasses.replace(limits, order=tuple(
            label for label in limits.order if label.startswith(EPHEMERAL_PREFIX)))
        if not limits.order:
            return Choice("", "", "fork head; no ephemeral pool in the order"), snapshot
    if not isinstance(snapshot, Mapping) or not snapshot.get("generated_at"):
        return Choice("", "", "no readable pool snapshot"), snapshot
    try:
        routed = count_routed(str(snapshot["generated_at"]))
    except Exception as error:  # noqa: BLE001 - every failure keeps the default
        return Choice("", "", f"could not count runs since the snapshot ({error})"), snapshot
    choice = decide(snapshot, limits, now=now, xcode_pins={} if fork else xcode_pins,
                    routed_since=routed, auto_xcode=fork)
    if fork and choice.runner:
        choice = dataclasses.replace(choice, reason=f"fork head; {choice.reason}")
    return choice, snapshot


def trusted_snapshot_artifact(artifact: Mapping[str, Any], branch: str) -> bool:
    """Uploaded by a run on `branch` of this repository itself, not a fork or another branch."""
    run = artifact.get("workflow_run") or {}
    return (
        not artifact.get("expired")
        and run.get("head_branch") == branch
        and run.get("repository_id") is not None
        and run.get("head_repository_id") == run.get("repository_id")
    )


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:
        return None


class GitHub:
    def __init__(self, token: str, repo: str) -> None:
        self.repo = repo
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-ci-pr-runner-pool",
        }

    def get(self, path: str) -> Any:
        request = urllib.request.Request(f"{API}/repos/{self.repo}{path}", headers=self.headers)
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read())

    def snapshot(self, *, now: dt.datetime, branch: str = SNAPSHOT_BRANCH) -> Mapping[str, Any] | None:
        """The newest trusted, unexpired janitor snapshot, in two API requests."""
        artifacts = self.get(f"/actions/artifacts?name={ARTIFACT_NAME}&per_page=20").get("artifacts") or []
        trusted = [artifact for artifact in artifacts if trusted_snapshot_artifact(artifact, branch)]
        if not trusted:
            return None
        newest = max(trusted, key=lambda artifact: str(artifact.get("created_at") or ""))
        created = parse_time(newest.get("created_at"))
        if created is None or (now - created).total_seconds() / 60 > MAX_SNAPSHOT_MINUTES:
            return None
        # The download answers with a redirect to signed blob storage, which must
        # not receive the token, so follow it by hand.
        opener = urllib.request.build_opener(_NoRedirect)
        download = urllib.request.Request(str(newest["archive_download_url"]), headers=self.headers)
        try:
            opener.open(download, timeout=15)
            raise RuntimeError("artifact download did not redirect")
        except urllib.error.HTTPError as error:
            location = error.headers.get("Location") if error.code in (301, 302, 303, 307, 308) else None
            if not location:
                raise RuntimeError(f"artifact download failed ({error.code})") from error
        blob = urllib.request.Request(location, headers={"User-Agent": self.headers["User-Agent"]})
        with urllib.request.urlopen(blob, timeout=30) as response:
            archive = zipfile.ZipFile(io.BytesIO(response.read()))
        return json.loads(archive.read(SNAPSHOT_FILE))

    def pull_request_runs_since(self, since: str, *, exclude_run_id: int | None) -> int:
        """CI pull request runs created at or after `since`, other than this one (one request)."""
        query = urllib.parse.urlencode({"event": "pull_request", "created": f">={since}", "per_page": PAGE_SIZE})
        runs = self.get(f"/actions/workflows/{CI_WORKFLOW}/runs?{query}").get("workflow_runs") or []
        return sum(1 for run in runs if run.get("id") != exclude_run_id)


def summary(choice: Choice, snapshot: Mapping[str, Any] | None, *, now: dt.datetime) -> str:
    runner = choice.runner or "each job's default (MACOS_RUNNER_PR or its fallback)"
    lines = ["### macOS pool for this run", "", f"- Pool: `{runner}`", f"- Why: {choice.reason}"]
    if choice.xcode_app:
        lines.append(f"- Xcode: `{choice.xcode_app}`")
    if isinstance(snapshot, Mapping) and isinstance(snapshot.get("pools"), Mapping):
        age = snapshot_age_minutes(snapshot, now)
        lines.append(f"- Queue seen by the janitor at {snapshot.get('generated_at')}"
                     + (f" ({round(age)} min before this run)" if age is not None else "") + ":")
        for label in POOLS:
            lines.append(f"  - {describe(snapshot, label)}")
    return "\n".join(lines) + "\n"


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--snapshot", help="read the snapshot from this file instead of the API")
    args = parser.parse_args(argv)
    now = dt.datetime.now(dt.timezone.utc)
    repo = env.get("GITHUB_REPOSITORY") or ""
    token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or ""
    run_id = (env.get("GITHUB_RUN_ID") or "").strip()

    def client() -> GitHub:
        if not token or not repo:
            raise RuntimeError("GH_TOKEN and GITHUB_REPOSITORY are required")
        return GitHub(token, repo)

    def fetch() -> Mapping[str, Any] | None:
        if args.snapshot:
            with open(args.snapshot, encoding="utf-8") as handle:
                return json.load(handle)
        return client().snapshot(now=now, branch=(env.get("POOL_SNAPSHOT_BRANCH") or SNAPSHOT_BRANCH))

    def count_routed(since: str) -> int:
        if args.snapshot:
            return 0
        return client().pull_request_runs_since(since, exclude_run_id=int(run_id) if run_id.isdigit() else None)

    choice, snapshot = choose(
        event=env.get("EVENT_NAME") or "",
        repo=repo,
        head_repo=env.get("HEAD_REPO") or "",
        default_runner=env.get("DEFAULT_RUNNER") or "",
        overflow=env.get("POOL_OVERFLOW"),
        order=env.get("POOL_ORDER"),
        max_queued=env.get("POOL_MAX_QUEUED"),
        xcode_pins={variable: env.get(variable) or "" for variable in POOLS.values() if variable},
        fetch=fetch,
        count_routed=count_routed,
        now=now,
    )
    text = summary(choice, snapshot, now=now)
    print(text)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(text)
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"runner={choice.runner}\nxcode_app={choice.xcode_app}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
