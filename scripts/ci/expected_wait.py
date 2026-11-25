#!/usr/bin/env python3
"""Admission by expected wait, not by label (cmuxterm-hq#16113 step 3).

GitHub-hosted Linux runs at most HOSTED_SLOTS jobs at once for manaflow-ai, and an owned Mac pool runs as many as it
has runners. A job binds `runs-on` when it is created, so the only lever is what RUNNER_POOLS says then. On
2026-11-20 a burst sent about 11,000 runner-minutes to hosted Linux and its wait p50 was 19.8 h: the label was
"allowed", so jobs kept being sent to a pool that could not start them.

A capped pool takes a job only while its expected wait is under TARGET_SECONDS:

    expected wait = (queued + running) / slots * p50 run time of the pool's jobs

with no wait at all while a slot is free (queued + running < slots). While jobs are queued, the p50 wait of the jobs
that started on the pool within QUEUE_WINDOW (`queue_p50_s`) counts too: counts can say a slot is free while the pool
starts nothing. The verdict has hysteresis: a pool saturates at TARGET_SECONDS and clears only below
CLEAR_FRACTION of it, judged against the previous pass's `_admission`, so it does not flap every pass. A saturated
pool's job goes to the next rung. The overflow probe's pool pass (linux_pool_spill.py) computes this each pass and
writes the verdict into RUNNER_POOLS:

    "_admission": {"at": <when>, "target_s": 300,
                   "pools": {<label>: {"queued", "running", "slots", "p50_s", "wait_s", "queue_p50_s", "saturated"}}}
    "hosted_saturated": true|false   (the GitHub-hosted Linux verdict; cmux#46011 step 1's key)

`_admission` is rewritten only when a verdict (a pool's `saturated`, or `hosted_saturated`) changes, or when the one
published is REFRESH old (record()), so a steady pass writes nothing and the picker's 30-minute freshness holds.

The two kinds of capped pool are judged differently, because the timing feed names only a runner class per job:
- GitHub-hosted Linux: every `ubuntu-*` label shares the account's HOSTED_SLOTS, so they are counted together and
  get one verdict, from the `github` class's run and wait p50s;
- an owned Mac family: the feed's `mini` class mixes every self-hosted pool (each Mac family, signing,
  glaeda-linux), and neither its records' runner names nor anything else in them names a family, so no p50 there is
  the family's. An owned family is judged by its live counts alone: saturated while jobs are queued and every slot
  is taken, clear once its queue is empty.

Counts and run times come from the build controller's feeds, not GitHub REST, so a pass spends no API quota:
`GET /v1/github/actions` (in-flight jobs with their labels, from webhooks) and `GET /v1/github/timing/records`
(finished jobs: runner class and seconds). Anything missing (controller unreachable, a stale feed, too few finished
jobs for a p50) gives no verdict for that pool, and a pool with no verdict routes exactly as before.

Slots: hosted Linux has HOSTED_SLOTS. It counts only jobs whose every label is a hosted Ubuntu one, and a running
one only on a GitHub-hosted runner (the owned persistent pool's runners carry `ubuntu-24.04` too). More than
HOSTED_RUNNING_SANE running is a wrong feed, so it gives no hosted verdict. An owned Mac family has as many slots as
it has distinct online runners carrying any of its labels (root, side, gui, session, the pool), read from GitHub's
runner listing each pass (owned_capacity(), read_runners()), and each label's own online runners are published beside
it (`runners`). CI_OWNED_POOL_SLOTS was a hand-set count that drifted above what was online (cmuxterm-hq
docs/handbook/hand-set-concurrency-number.md); it now only names the labels a route is configured for, which stay at
1 or more, and is the count only when the listing cannot be read (owned_slots(), the max over a family's labels). Its
queued entries older than OWNED_QUEUED_MAX_AGE are ghosts, not load.
"""

from __future__ import annotations

import datetime as dt
import json
import math
import re
import statistics
import sys
import urllib.parse
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any, Callable

UTC = dt.timezone.utc
TARGET_SECONDS = 300
HOSTED_SLOTS = 20
ADMISSION_KEY = "_admission"
HOSTED_KEY = "hosted_saturated"
HOSTED_LABEL = "ubuntu-24.04"
HOSTED_LINUX = re.compile(r"^ubuntu-(?:latest|\d{2}\.\d{2})$")
# glaeda-[aws-][root-|side-|gui-|session-]<class>-xcode-<version>: one family on the same machines
# (simple_pool_picker.OWNED_FAMILY).
OWNED_FAMILY = re.compile(r"^glaeda-(?:(?P<namespace>aws)-)?(?:root-|side-|gui-|session-)?"
                          r"(?P<class>std|light|xl)-xcode-(?P<version>[0-9]+(?:\.[0-9]+)*)$")
# The timing feed's runner class for GitHub-hosted jobs (owned pools are judged by counts: see the docstring).
HOSTED_CLASS = "github"
# GitHub drops a job queued for 24 h and ends one running for 6 h (hosted's limit); a feed entry older than that is
# a lost webhook, not load.
QUEUED_MAX_AGE = dt.timedelta(hours=24)
RUNNING_MAX_AGE = dt.timedelta(hours=6)
# An owned label's queued entry older than this is a ghost (a lost webhook) or a job pinned to one busy member, not
# the family's load: owned families start a queued job within minutes when a runner is free.
OWNED_QUEUED_MAX_AGE = dt.timedelta(hours=2)
# More hosted jobs running than this is a wrong feed (the account runs HOSTED_SLOTS at once): no hosted verdict.
HOSTED_RUNNING_SANE = 2 * HOSTED_SLOTS
# A feed whose newest delivery is older than this decides nothing: the probe runs every 10 minutes.
FEED_MAX_AGE = dt.timedelta(minutes=20)
# The run p50 is over jobs finished in this window, and needs at least MIN_SAMPLES of them. A run time is the
# pool's job mix, which changes slowly; it only scales counts, so an idle pool (a free slot) waits 0 whatever it is.
RECORD_WINDOW = dt.timedelta(hours=2)
# The wait p50 is over jobs that started within this window (about 2 probe intervals): an old long wait must not keep
# a pool saturated after it drains.
QUEUE_WINDOW = dt.timedelta(minutes=20)
MIN_SAMPLES = 5
# Hysteresis: saturate at the target, clear below this fraction of it.
CLEAR_FRACTION = 0.5
# A published verdict whose routing has not changed is rewritten once it is this old (the picker trusts 30 minutes).
REFRESH = dt.timedelta(minutes=15)
MAX_RECORD_PAGES = 3
DEFAULT_CONTROLLER = "http://100.89.225.106:18765"


def parse_time(value: object) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        moment = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo is not None else None


def iso(moment: dt.datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def expected_wait(queued: int, running: int, slots: int, p50_s: float) -> float:
    """Seconds a job sent now waits: (queued + running) / slots * p50, or 0 while a slot is free."""
    if slots <= 0:
        return float("inf")
    if queued + running < slots:
        return 0.0
    return (queued + running) / slots * p50_s


def owned_family(label: str) -> str:
    match = OWNED_FAMILY.fullmatch(label or "")
    if not match:
        return ""
    namespace = f"{match.group('namespace')}-" if match.group("namespace") else ""
    return f"{namespace}{match.group('class')}-xcode-{match.group('version')}"


def owned_slots(raw: str | None) -> dict[str, int]:
    """CI_OWNED_POOL_SLOTS (label -> runners) as owned family -> runners; anything else names none."""
    try:
        data = json.loads(raw or "{}")
    except (TypeError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    families: dict[str, int] = {}
    for label, count in data.items():
        family = owned_family(str(label))
        if family and isinstance(count, int) and not isinstance(count, bool) and count > 0:
            families[family] = max(families.get(family, 0), count)
    return families


def configured_labels(raw: str | None) -> set[str]:
    """The owned family labels CI_OWNED_POOL_SLOTS routes to (any positive count): each stays at 1 or more."""
    try:
        data = json.loads(raw or "{}")
    except (TypeError, ValueError):
        return set()
    if not isinstance(data, dict):
        return set()
    return {str(label) for label, count in data.items() if owned_family(str(label))
            and isinstance(count, int) and not isinstance(count, bool) and count > 0}


def runner_labels(runner: Mapping[str, Any]) -> set[str]:
    """A runner listing entry's label names (GitHub gives `labels` as [{"name": ...}])."""
    names = set()
    for label in runner.get("labels") or ():
        name = label.get("name") if isinstance(label, Mapping) else label
        if isinstance(name, str) and name:
            names.add(name)
    return names


def owned_capacity(runners: Iterable[Mapping[str, Any]], slots_raw: str | None = None
                   ) -> tuple[dict[str, int], dict[str, int]]:
    """(label -> online runners carrying it, family -> distinct online runners carrying any label of it), from
    GitHub's runner listing (read_runners()).

    A family's slots are its distinct online runners: a mini's runner carries the pool label and its role label
    (root, side, gui, session) at once, so a sum counts it twice, and the max over labels misses the runners that
    carry only some of them. An offline runner takes no job, so it counts for nothing. A label CI_OWNED_POOL_SLOTS
    routes to stays at 1 or more, and so does its family: pr_runner_pool.gui_runner() and side_runner() skip a label
    at 0, so a configured route is never published as a label with no runner."""
    members: dict[str, set[Any]] = {}
    for runner in runners:
        if not isinstance(runner, Mapping) or runner.get("status") != "online":
            continue
        key = runner.get("id") if runner.get("id") is not None else runner.get("name")
        if key is None:
            continue
        for label in runner_labels(runner):
            if owned_family(label):
                members.setdefault(label, set()).add(key)
    labels = {label: len(keys) for label, keys in members.items()}
    by_family: dict[str, set[Any]] = {}
    for label, keys in members.items():
        by_family.setdefault(owned_family(label), set()).update(keys)
    families = {family: len(keys) for family, keys in by_family.items()}
    for label in configured_labels(slots_raw):
        labels[label] = max(1, labels.get(label, 0))
        family = owned_family(label)
        families[family] = max(1, families.get(family, 0))
    return labels, families


def feed_fresh(feed: Mapping[str, Any], now: dt.datetime) -> bool:
    """The actions feed's newest delivery is within FEED_MAX_AGE (and not from the future)."""
    stamps = [parse_time(feed.get("receiver_last_delivery"))]
    stamps += [parse_time(job.get("received_at")) for job in feed.get("jobs") or () if isinstance(job, Mapping)]
    newest = max((stamp for stamp in stamps if stamp is not None), default=None)
    return newest is not None and now - FEED_MAX_AGE <= newest <= now + dt.timedelta(minutes=1)


def label_load(jobs: Iterable[Mapping[str, Any]], now: dt.datetime,
               queued_max_age: dt.timedelta = QUEUED_MAX_AGE) -> dict[str, dict[str, int]]:
    """Label -> {queued, running} over the feed's in-flight jobs, without entries older than GitHub keeps."""
    load: dict[str, dict[str, int]] = {}
    for job in jobs:
        if not isinstance(job, Mapping):
            continue
        status = job.get("status")
        if status == "queued":
            since, bound, key = parse_time(job.get("created_at")), queued_max_age, "queued"
        elif status == "in_progress":
            since, bound, key = parse_time(job.get("started_at")), RUNNING_MAX_AGE, "running"
        else:
            continue
        if since is None or now - since > bound:
            continue
        for label in job.get("labels") or ():
            if isinstance(label, str):
                entry = load.setdefault(label, {"queued": 0, "running": 0})
                entry[key] += 1
    return load


def number(value: object) -> float | None:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0 else None


def hosted_load(jobs: Iterable[Mapping[str, Any]], now: dt.datetime) -> tuple[dict[str, int], set[str]]:
    """({queued, running}, labels) over the in-flight jobs every label of which is a GitHub-hosted Ubuntu one.

    A running job counts only on a GitHub-hosted runner (`GitHub Actions <n>`, or none named yet): the owned
    persistent pool's runners carry `ubuntu-24.04` too, and the jobs they run take none of the account's slots."""
    hosted = [job for job in jobs if isinstance(job, Mapping) and job.get("labels")
              and all(isinstance(label, str) and HOSTED_LINUX.match(label) for label in job["labels"])
              and (job.get("status") != "in_progress"
                   or not job.get("runner") or str(job.get("runner")).startswith("GitHub Actions"))]
    load = label_load(hosted, now)
    total = {"queued": sum(entry["queued"] for entry in load.values()),
             "running": sum(entry["running"] for entry in load.values())}
    return total, set(load)


def class_p50(records: Iterable[Mapping[str, Any]], now: dt.datetime,
              field: str = "seconds") -> dict[str, float]:
    """Runner class -> p50 of FIELD, for a class with MIN_SAMPLES or more: `seconds` (run) over the jobs that
    finished within RECORD_WINDOW, `queue` (waited) over the jobs that started within QUEUE_WINDOW.

    The controller rounds `queue` to whole seconds and leaves it out when it is 0, so a job with no `queue` started
    at once: it counts as 0, not as unknown (an idle pool's p50 is made of those)."""
    values: dict[str, list[float]] = {}
    for record in records:
        if not isinstance(record, Mapping) or record.get("conclusion") not in ("success", "failure"):
            continue
        at, seconds = parse_time(record.get("at")), number(record.get("seconds"))
        if at is None or seconds is None:
            continue
        if field == "queue":
            value = number(record.get("queue", 0))
            if value is None or now - (at - dt.timedelta(seconds=seconds)) > QUEUE_WINDOW:
                continue
        else:
            value = seconds
            if value == 0 or now - at > RECORD_WINDOW:
                continue
        values.setdefault(str(record.get("runner") or ""), []).append(value)
    return {name: statistics.median(found) for name, found in values.items() if len(found) >= MIN_SAMPLES}


def previously_saturated(previous: Mapping[str, Any] | None, now: dt.datetime) -> set[str]:
    """The labels the previous `_admission` (published within FEED_MAX_AGE + REFRESH) called saturated."""
    if not isinstance(previous, Mapping):
        return set()
    at = parse_time(previous.get("at"))
    pools = previous.get("pools")
    if at is None or not isinstance(pools, Mapping) or not now - (FEED_MAX_AGE + REFRESH) <= at <= now:
        return set()
    return {label for label, entry in pools.items() if isinstance(entry, Mapping) and entry.get("saturated") is True}


def verdicts(feed: Mapping[str, Any] | None, records: Iterable[Mapping[str, Any]] | None, *, now: dt.datetime,
             slots_raw: str | None = None, target_s: float = TARGET_SECONDS,
             previous: Mapping[str, Any] | None = None,
             runners: Iterable[Mapping[str, Any]] | None = None) -> dict[str, dict[str, Any]]:
    """Capped label -> its admission verdict. A pool without counts (or, hosted, a run p50) is left out: no verdict.

    `previous` is the `_admission` the last pass published, for the hysteresis (previously_saturated()). `runners` is
    GitHub's runner listing (read_runners()): an owned family's slots are its distinct online runners and each label
    gets its own online count (owned_capacity()); None (unread) falls back to CI_OWNED_POOL_SLOTS (owned_slots())."""
    if not isinstance(feed, Mapping) or not feed_fresh(feed, now):
        return {}
    records = list(records) if records is not None else None
    jobs = list(feed.get("jobs") or ())
    was = previously_saturated(previous, now)
    found: dict[str, dict[str, Any]] = {}

    # Hosted needs a run p50, so no timing records is no hosted verdict; owned families need counts only.
    p50 = class_p50(records, now).get(HOSTED_CLASS) if records is not None else None
    hosted, seen = hosted_load(jobs, now)
    if p50 is not None and hosted["running"] > HOSTED_RUNNING_SANE:
        print(f"::warning title=Expected-wait admission::{hosted['running']} hosted Linux jobs running is over "
              f"{HOSTED_RUNNING_SANE}; the feed is wrong, so no hosted verdict")
        p50 = None
    if p50 is not None:
        # One account-wide cap for every GitHub-hosted Ubuntu label, so they are counted and judged together.
        labels = sorted(seen | {HOSTED_LABEL})
        queued, running, slots = hosted["queued"], hosted["running"], HOSTED_SLOTS
        wait = expected_wait(queued, running, slots, p50)
        entry: dict[str, Any] = {"queued": queued, "running": running, "slots": slots, "p50_s": round(p50),
                                 "wait_s": round(wait)}
        score = wait
        waited = class_p50(records or (), now, "queue").get(HOSTED_CLASS)
        if waited is not None and queued > 0:
            # The wait of the jobs that started recently, while jobs wait: a pool that starts nothing while its
            # counts say a slot is free (2026-11-20: hosted wait p50 19.8 h) is saturated too.
            entry["queue_p50_s"] = round(waited)
            score = max(score, waited)
        held = bool(was & set(labels))
        entry["saturated"] = score >= target_s or (held and score >= CLEAR_FRACTION * target_s)
        for label in labels:
            found[label] = dict(entry)

    online: dict[str, int] | None = None
    if runners is not None:
        online, families = owned_capacity(runners, slots_raw)
    else:
        families = owned_slots(slots_raw)
    load = label_load(jobs, now, OWNED_QUEUED_MAX_AGE)
    if families:
        totals: dict[str, dict[str, int]] = {}
        members: dict[str, set[str]] = {}
        try:
            listed = [str(label) for label in json.loads(slots_raw or "{}")]
        except (TypeError, ValueError):
            listed = []
        if not isinstance(listed, list):
            listed = []
        listed += list(online or ())
        for label in [*load, *listed]:
            family = owned_family(label)
            if family in families:
                members.setdefault(family, set()).add(label)
        for label, counts in load.items():
            family = owned_family(label)
            if family in families:
                total = totals.setdefault(family, {"queued": 0, "running": 0})
                total["queued"] += counts["queued"]
                total["running"] += counts["running"]
        for family, labels in members.items():
            total = totals.get(family, {"queued": 0, "running": 0})
            queued, running, slots = total["queued"], total["running"], families[family]
            full = queued > 0 and queued + running >= slots
            # Counts only (the docstring): saturate while jobs queue on a full family; hold while jobs still queue
            # and the family is still near full (CLEAR_FRACTION of its slots), so an idle family clears.
            near_full = queued + running >= math.ceil(CLEAR_FRACTION * slots)
            saturated = full or (bool(was & labels) and queued > 0 and near_full)
            for label in sorted(labels):
                found[label] = {"queued": queued, "running": running, "slots": slots, "basis": "counts",
                                "saturated": saturated}
                if online is not None:
                    found[label].update(slots_from="runners", runners=online.get(label, 0))
    return found


def routing(admission: Mapping[str, Any] | None) -> dict[str, bool] | None:
    """Label -> saturated in an `_admission` value: the part of it routing reads."""
    pools = admission.get("pools") if isinstance(admission, Mapping) else None
    if not isinstance(pools, Mapping):
        return None
    return {str(label): entry.get("saturated") is True for label, entry in pools.items() if isinstance(entry, Mapping)}


def record(found: Mapping[str, Mapping[str, Any]], now: dt.datetime,
           target_s: float = TARGET_SECONDS, previous: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """The RUNNER_POOLS keys this pass publishes: `_admission` and `hosted_saturated`; none without a verdict.

    When every label's verdict is what `previous` (the published `_admission`) says and that is under REFRESH old,
    `previous` is published again unchanged, so the variable is not rewritten for numbers alone."""
    if not found:
        return {}
    admission = {"at": iso(now), "target_s": int(target_s),
                 "pools": {label: dict(found[label]) for label in sorted(found)}}
    at = parse_time(previous.get("at")) if isinstance(previous, Mapping) else None
    if (at is not None and now - REFRESH < at <= now and previous.get("target_s") == int(target_s)
            and routing(previous) == routing(admission)):
        admission = dict(previous)
    keys: dict[str, Any] = {ADMISSION_KEY: admission}
    if HOSTED_LABEL in found:
        keys[HOSTED_KEY] = bool(found[HOSTED_LABEL]["saturated"])
    return keys


def read_feeds(controller: str, repo: str, now: dt.datetime, *,
               request: Callable[[str, float], tuple[int, bytes, Any]] | None = None
               ) -> tuple[dict[str, Any] | None, list[dict[str, Any]] | None]:
    """(actions feed, timing records) from the controller; None for one that could not be read."""
    if request is None:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import deadline_http  # noqa: PLC0415

        request = deadline_http.request
    base = controller.rstrip("/")
    query = urllib.parse.urlencode({"repo": repo})
    feed: dict[str, Any] | None = None
    try:
        status, body, _ = request(f"{base}/v1/github/actions?{query}", 60)
        parsed = json.loads(body) if status == 200 else None
        feed = parsed if isinstance(parsed, dict) else None
    except Exception as error:  # noqa: BLE001 - no feed is no verdict
        print(f"::warning title=Expected-wait admission::could not read the actions feed ({error})")
    records: list[dict[str, Any]] | None = []
    seen: set[tuple[Any, Any]] = set()
    cursor = int((now - RECORD_WINDOW).timestamp())
    try:
        for _ in range(MAX_RECORD_PAGES):
            page_query = urllib.parse.urlencode({"repo": repo, "since": cursor, "limit": 20000})
            status, body, _ = request(f"{base}/v1/github/timing/records?{page_query}", 60)
            if status != 200:
                raise ValueError(f"timing feed answered {status}")
            page = json.loads(body)
            batch = [item for item in page.get("records") or () if isinstance(item, dict)]
            # A page starts at the last one's final second, so the records of that second come twice.
            records += [item for item in batch if (key := (item.get("id"), item.get("attempt"))) not in seen
                        and not seen.add(key)]
            last = parse_time(batch[-1].get("at")) if batch else None
            if not page.get("more") or last is None:
                break
            cursor = max(cursor + 1, int(last.timestamp()))
    except Exception as error:  # noqa: BLE001 - no run times is no verdict
        print(f"::warning title=Expected-wait admission::could not read the timing feed ({error})")
        records = None
    return feed, records


def read_runners(token: str, repo: str, *, github: Callable[[str, str], Any] | None = None
                 ) -> list[Mapping[str, Any]] | None:
    """GitHub's runner listing, through the one reader the PR picker uses (pr_runner_pool.GitHub.runners(): the
    repository's runners plus the org's glaeda-minis group, or the trusted runner-state document when it is fresh).
    None when it cannot be read (no token, a refused or partial listing): the pass then falls back to
    CI_OWNED_POOL_SLOTS rather than read a missing listing as runners gone."""
    if not token or "/" not in repo:
        return None
    try:
        if github is None:
            # The probe has loaded main's policy (runner_pool_reconcile.load_policy()), which imports main's
            # pr_runner_pool; otherwise this checkout's.
            sys.path.append(str(Path(__file__).resolve().parent))
            import pr_runner_pool  # noqa: PLC0415

            github = pr_runner_pool.GitHub
        return [runner for runner in github(token, repo).runners() if isinstance(runner, Mapping)]
    except Exception as error:  # noqa: BLE001 - no listing is the variable's count
        print(f"::warning title=Expected-wait admission::could not list the runners ({error}); "
              "owned slots come from CI_OWNED_POOL_SLOTS")
        return None


def admission(env: Mapping[str, str], now: dt.datetime, *,
              request: Callable[[str, float], tuple[int, bytes, Any]] | None = None,
              previous: Mapping[str, Any] | None = None,
              github: Callable[[str, str], Any] | None = None) -> dict[str, Any]:
    """This pass's RUNNER_POOLS admission keys, or {} when RUNNER_ADMISSION_CONTROLLER is unset or nothing was read.

    The controller is opt-in (the probe workflow sets it), so a pass without it routes exactly as before. `previous`
    is the `_admission` RUNNER_POOLS holds now (hysteresis, and no rewrite for numbers alone). With
    RUNNER_ADMISSION_RUNNERS_TOKEN (a token that reads the repository's and the org's self-hosted runners, as
    ci.yml's routing token does) the owned slots come from the online runners (read_runners()); without it, or when
    the listing cannot be read, from CI_OWNED_POOL_SLOTS."""
    controller = (env.get("RUNNER_ADMISSION_CONTROLLER") or "").strip()
    repo = (env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or "").strip()
    if not controller or not repo:
        return {}
    feed, records = read_feeds(controller, repo, now, request=request)
    runners = read_runners((env.get("RUNNER_ADMISSION_RUNNERS_TOKEN") or "").strip(), repo, github=github)
    found = verdicts(feed, records, now=now, slots_raw=env.get("CI_OWNED_POOL_SLOTS"), previous=previous,
                     runners=runners)
    return record(found, now, previous=previous)


if __name__ == "__main__":
    import os

    moment = dt.datetime.now(UTC)
    environment = dict(os.environ)
    environment.setdefault("RUNNER_ADMISSION_CONTROLLER", DEFAULT_CONTROLLER)
    print(json.dumps(admission(environment, moment), indent=2, sort_keys=True))
