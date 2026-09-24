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
Reading it costs two API requests (the artifact listing and its download
redirect); listing jobs here would cost one per in-flight run on every pull
request push, out of the GITHUB_TOKEN's shared budget of about 1000 an hour.
The janitor runs every 10 minutes on paper and every 10 to 30 in practice, so
a snapshot older than MAX_SNAPSHOT_MINUTES counts as unknown.

A pull request from a fork into manaflow-ai/cmux gets no repository
variables, so it takes the built-in order and threshold, and no Xcode pin:
each job then selects the newest SDK 26 Xcode on the pool it lands on, and the
product consumers restate compile admission's empty pin, so the run stays on
one toolchain. Blacksmith runners are ephemeral, so fork code on any of these
pools is fine; only pools in POOLS are ever chosen.

Anything uncertain keeps today's route: an event other than pull_request, a
same-repository run whose MACOS_RUNNER_PR names another pool or is unset (the
documented way back to the macOS 15 lane), an API error, a missing, stale or
malformed snapshot, or an invalid setting. The script then prints an empty
runner, and every job's own expression resolves exactly as before.
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
MAX_SNAPSHOT_MINUTES = 45
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


def decide(
    snapshot: Mapping[str, Any] | None,
    limits: Settings,
    *,
    now: dt.datetime,
    xcode_pins: Mapping[str, str],
    auto_xcode: bool = False,
) -> Choice:
    """The preference rule over a janitor snapshot. Uncertainty keeps today's route.

    `auto_xcode` (a fork run, which has no pins) lets every pool fall back to
    each job selecting its pool's newest SDK 26 Xcode.
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
    note = f" (skipped {', '.join(skipped)}: reserved or no Xcode pin)" if skipped else ""
    for label in usable:
        if load[label]["queued"] < limits.max_queued:
            return Choice(label, xcode(label) or "",
                          f"first pool in order with headroom (< {limits.max_queued} queued){note}")
    label = min(usable, key=lambda item: load[item]["queued"])
    return Choice(label, xcode(label) or "", f"no pool has headroom; fewest queued{note}")


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
    now: dt.datetime,
) -> tuple[Choice, Mapping[str, Any] | None]:
    """The pool for this run and the snapshot it was read from (None when none was read)."""
    if event != "pull_request":
        return Choice("", "", f"{event or 'unknown'} event; not a pull request"), None
    if not head_repo:
        return Choice("", "", "pull request head repository unknown"), None
    fork = head_repo != repo
    if fork:
        # No repository variables reach a fork run: built-in defaults, no pins.
        overflow = order = max_queued = None
        xcode_pins = {}
    elif (default_runner or "").strip() != DEFAULT_RUNNER:
        return Choice("", "", f"MACOS_RUNNER_PR is {default_runner or 'unset'}, not {DEFAULT_RUNNER}"), None
    limits = settings(overflow, order, max_queued)
    if limits is not None and fork:
        # Fork code runs only on ephemeral Blacksmith machines, never on a
        # persistent pool (owned Macs) that may join POOLS later.
        limits = dataclasses.replace(limits, order=tuple(
            label for label in limits.order if label.startswith(EPHEMERAL_PREFIX)))
    if limits is None:
        return Choice("", "", f"{OVERFLOW_VARIABLE} is 0, or {ORDER_VARIABLE}/{MAX_QUEUED_VARIABLE} "
                              "is invalid"), None
    try:
        snapshot = fetch()
    except Exception as error:  # noqa: BLE001 - every failure keeps the default
        return Choice("", "", f"could not read the pool snapshot ({error})"), None
    choice = decide(snapshot, limits, now=now, xcode_pins=xcode_pins, auto_xcode=fork)
    if fork and choice.runner:
        choice = dataclasses.replace(choice, reason=f"fork head, built-in defaults; {choice.reason}")
    return choice, snapshot


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:
        return None


def fetch_snapshot(token: str, repo: str, *, now: dt.datetime) -> Mapping[str, Any] | None:
    """The newest unexpired janitor snapshot, in two API requests."""
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "cmux-ci-pr-runner-pool",
    }
    listing = urllib.request.Request(f"{API}/repos/{repo}/actions/artifacts?name={ARTIFACT_NAME}&per_page=10",
                                     headers=headers)
    with urllib.request.urlopen(listing, timeout=15) as response:
        artifacts = json.loads(response.read()).get("artifacts") or []
    live = [artifact for artifact in artifacts if not artifact.get("expired")]
    if not live:
        return None
    newest = max(live, key=lambda artifact: str(artifact.get("created_at") or ""))
    created = parse_time(newest.get("created_at"))
    if created is None or (now - created).total_seconds() / 60 > MAX_SNAPSHOT_MINUTES:
        return None
    # The download answers with a redirect to signed blob storage, which must
    # not receive the token, so follow it by hand.
    opener = urllib.request.build_opener(_NoRedirect)
    download = urllib.request.Request(str(newest["archive_download_url"]), headers=headers)
    try:
        opener.open(download, timeout=15)
        raise RuntimeError("artifact download did not redirect")
    except urllib.error.HTTPError as error:
        location = error.headers.get("Location") if error.code in (301, 302, 303, 307, 308) else None
        if not location:
            raise RuntimeError(f"artifact download failed ({error.code})") from error
    with urllib.request.urlopen(urllib.request.Request(location, headers={"User-Agent": headers["User-Agent"]}),
                                timeout=30) as response:
        archive = zipfile.ZipFile(io.BytesIO(response.read()))
    return json.loads(archive.read(SNAPSHOT_FILE))


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

    def fetch() -> Mapping[str, Any] | None:
        if args.snapshot:
            with open(args.snapshot, encoding="utf-8") as handle:
                return json.load(handle)
        if not token or not repo:
            raise RuntimeError("GH_TOKEN and GITHUB_REPOSITORY are required")
        return fetch_snapshot(token, repo, now=now)

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
