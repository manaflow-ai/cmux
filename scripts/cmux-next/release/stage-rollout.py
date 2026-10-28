#!/usr/bin/env python3
"""Staged rollout of a cmux NEXT release: an operator tool, never a CI step.

The app takes an appcast item on a scheduled check only on the share of installs its
`<cmux:rolloutPercent>` names (CmuxUpdater `StagedRollout`); a check the person starts is never
held. This tool writes that percentage, and refuses to raise it until the current stage's
crash-free sessions in Sentry pass the stage's gate. The procedure is docs/cmux-next/release-rollout.md.

  stage-rollout.py show FEED...
  stage-rollout.py set FEED... --build N --percent P [--write]
  stage-rollout.py gate --release cmux-next@X+N [--since ISO] [--baseline cmux-next@Y+M] [--stage P]
  stage-rollout.py advance FEED... --build N --release cmux-next@X+N [--baseline ...] [--write] [--force-bake]

- FEED is a local copy of every appcast that lists the build (the stable `appcast.xml`,
  `appcast-arm64.xml` and `appcast-x86_64.xml`). The tool edits text in place: only the item's
  `<cmux:rolloutPercent>` and `<cmux:rolloutStagedAt>` and the `xmlns:cmux` declaration change.
  The prefix must stay `cmux`: Sparkle keeps an element outside its namespace under its written
  name. Without --write it prints the change and writes nothing. Uploading the files is the
  runbook's step; the tool holds no credential but the Sentry token.
- `0` halts the rollout (scheduled checks stop taking the build; a pull takes it off the feed).
- `gate` reads crash-free sessions of one release (environment release-next unless --env) since
  --since, or since the item's staged time when `advance` calls it. It needs SENTRY_AUTH_TOKEN
  and prints no secret (stability-health.py's transport).
- `advance` moves to the next stage of STAGES only when the current stage baked BAKE_HOURS and
  its gate passed.

Exit codes: 0 done or gate passed, 1 gate failed or the stage has not baked, 2 bad arguments or
feeds, 3 Sentry API error.
"""
from __future__ import annotations

import argparse
import datetime
import importlib.util
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

NAMESPACE = "https://cmux.com/xml-namespaces/rollout"  # StagedRollout.namespace
PERCENT = "rolloutPercent"  # StagedRollout.element is cmux:rolloutPercent
STAGED_AT = "rolloutStagedAt"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


@dataclass(frozen=True)
class Gate:
    """What a stage must show before the next one: Chrome's staged rollouts watch crash rates the
    same way before each step up."""
    min_sessions: int
    min_crash_free_pct: float
    # The largest drop below the baseline release's crash-free sessions, in points.
    max_drop_pct: float = 0.1


STAGES = [1.0, 5.0, 20.0, 50.0, 100.0]
BAKE_HOURS = 24.0
GATES = {
    1.0: Gate(min_sessions=300, min_crash_free_pct=99.5),
    5.0: Gate(min_sessions=1_500, min_crash_free_pct=99.7),
    20.0: Gate(min_sessions=5_000, min_crash_free_pct=99.8),
    50.0: Gate(min_sessions=10_000, min_crash_free_pct=99.8),
}


class RolloutError(Exception):
    """Bad arguments or a feed the tool cannot change safely (exit 2)."""


# MARK: feeds

ITEM = re.compile(r"<item\b[^>]*>.*?</item>", re.DOTALL)
RSS_OPEN = re.compile(r"<rss\b[^>]*>")


def item_versions(item: str) -> set[str]:
    """The `sparkle:version` of an item (element or enclosure attribute), deltas excluded."""
    body = re.sub(r"<sparkle:deltas>.*?</sparkle:deltas>", "", item, flags=re.DOTALL)
    found = set(re.findall(r"<sparkle:version>\s*([^<\s]+)\s*</sparkle:version>", body))
    for enclosure in re.findall(r"<enclosure\b[^>]*>", body):
        found.update(re.findall(r'sparkle:version="([^"]+)"', enclosure))
    return found


def element_value(item: str, name: str) -> str | None:
    match = re.search(rf"<cmux:{name}>\s*([^<]*?)\s*</cmux:{name}>", item)
    return match.group(1) if match else None


def set_element(item: str, name: str, value: str) -> str:
    pattern = re.compile(rf"<cmux:{name}>[^<]*</cmux:{name}>")
    element = f"<cmux:{name}>{value}</cmux:{name}>"
    if pattern.search(item):
        return pattern.sub(element, item, count=1)
    close = item.rindex("</item>")
    indent = re.search(r"\n([ \t]*)</item>$", item)
    child = (indent.group(1) + "    ") if indent else ""
    lead = "\n" + child if indent else ""
    tail = "\n" + indent.group(1) if indent else ""
    head = item[:close].rstrip()
    return f"{head}{lead}{element}{tail}</item>"


def declare_namespace(feed: str) -> str:
    opening = RSS_OPEN.search(feed)
    if not opening:
        raise RolloutError("the feed has no <rss> element")
    tag = opening.group(0)
    declared = re.search(r'xmlns:cmux="([^"]*)"', tag)
    if declared:
        if declared.group(1) != NAMESPACE:
            raise RolloutError(f"the feed binds the cmux prefix to {declared.group(1)}, not {NAMESPACE}")
        return feed
    return feed[:opening.start()] + tag[:-1].rstrip() + f' xmlns:cmux="{NAMESPACE}">' + feed[opening.end():]


def parse_percent(raw: str) -> float:
    """StagedRollout.percent: 0 through 100, an optional % sign."""
    text = raw.strip().removesuffix("%")
    try:
        value = float(text)
    except ValueError:
        raise RolloutError(f"percent {raw!r} is not a number") from None
    if not (0 <= value <= 100):
        raise RolloutError(f"percent {raw!r} is not from 0 through 100")
    return value


def format_percent(value: float) -> str:
    return f"{value:g}"


def stage_feed(feed: str, build: str, percent: float, now: datetime.datetime) -> str:
    """The feed with every item of `build` at `percent`, staged at `now`."""
    hits = 0

    def edit(match: re.Match[str]) -> str:
        nonlocal hits
        item = match.group(0)
        if build not in item_versions(item):
            return item
        hits += 1
        item = set_element(item, PERCENT, format_percent(percent))
        return set_element(item, STAGED_AT, now.strftime("%Y-%m-%dT%H:%M:%SZ"))

    changed = ITEM.sub(edit, feed)
    if hits == 0:
        raise RolloutError(f"no item of build {build} in the feed")
    changed = declare_namespace(changed)
    check_feed(changed, build, percent)
    return changed


def check_feed(feed: str, build: str, percent: float) -> None:
    """The edited feed still parses and every item of `build` carries `percent` in the cmux namespace."""
    try:
        root = ET.fromstring(feed.encode("utf-8"))
    except ET.ParseError as error:
        raise RolloutError(f"the edited feed does not parse: {error}") from None
    found = 0
    for item in root.iter("item"):
        versions = {v.text.strip() for v in item.iter(f"{{{SPARKLE_NS}}}version") if v.text}
        enclosure = item.find("enclosure")
        if enclosure is not None and enclosure.get(f"{{{SPARKLE_NS}}}version"):
            versions.add(enclosure.get(f"{{{SPARKLE_NS}}}version"))
        if build not in versions:
            continue
        element = item.find(f"{{{NAMESPACE}}}{PERCENT}")
        if element is None or element.text is None or parse_percent(element.text) != percent:
            raise RolloutError(f"an item of build {build} does not carry {format_percent(percent)} after the edit")
        found += 1
    if found == 0:
        raise RolloutError(f"no item of build {build} after the edit")


@dataclass(frozen=True)
class Stage:
    percent: float | None  # None: no element (every install)
    staged_at: datetime.datetime | None


def current_stage(feed: str, build: str) -> Stage:
    stages = set()
    for match in ITEM.finditer(feed):
        item = match.group(0)
        if build not in item_versions(item):
            continue
        raw = element_value(item, PERCENT)
        staged = element_value(item, STAGED_AT)
        stages.add((None if raw is None else parse_percent(raw),
                    None if staged is None else datetime.datetime.fromisoformat(staged.replace("Z", "+00:00"))))
    if not stages:
        raise RolloutError(f"no item of build {build} in the feed")
    if len(stages) != 1:
        raise RolloutError(f"the items of build {build} are at different stages: {sorted(map(str, stages))}")
    percent, staged_at = stages.pop()
    return Stage(percent, staged_at)


def next_stage(percent: float | None) -> float:
    if percent is None or percent >= 100:
        raise RolloutError("the build already reaches every install")
    for stage in STAGES:
        if stage > percent:
            return stage
    return 100.0


# MARK: the crash-free gate

def load_health() -> Any:
    path = Path(__file__).resolve().parent.parent / "stability-health.py"
    spec = importlib.util.spec_from_file_location("stability_health", path)
    if spec is None or spec.loader is None:
        raise RolloutError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


Fetch = Callable[[str, list[tuple[str, str]]], tuple[Any, dict[str, str]]]


def release_sessions(health: Any, fetch: Fetch, release: str, env: str, since: datetime.datetime | None,
                     now: datetime.datetime) -> dict[str, Any]:
    """Sessions and crash-free rates of one release, since `since` (else the last 14 days)."""
    cfg = health.Config(env=env)
    path = f"/organizations/{cfg.org}/sessions/"
    params = [("project", cfg.project_id), ("environment", env), ("interval", "1h"), ("includeSeries", "0"),
              ("query", f'release:"{release}"')]
    if since is None:
        params.append(("statsPeriod", "14d"))
    else:
        params += [("start", since.strftime("%Y-%m-%dT%H:%M:%S")), ("end", now.strftime("%Y-%m-%dT%H:%M:%S"))]
    params += [("field", f) for f in health.SESSION_FIELDS]
    data, _ = fetch(path, params)
    with health.response_shape(path):
        groups = data.get("groups") or [{}]
        return health.session_row(groups[0].get("totals", {}))


def judge(stage: float, row: dict[str, Any], baseline: dict[str, Any] | None) -> list[str]:
    """Why the stage fails its gate (empty: it passes)."""
    gate = GATES.get(stage)
    if gate is None:
        return [f"no gate for stage {format_percent(stage)} %"]
    misses = []
    if row["sessions"] < gate.min_sessions:
        misses.append(f"{row['sessions']} sessions, the gate needs {gate.min_sessions}")
    rate = row["crash_free_sessions_pct"]
    if rate is None:
        misses.append("Sentry gives no crash-free rate")
    else:
        if rate < gate.min_crash_free_pct:
            misses.append(f"crash-free sessions {rate} % < {gate.min_crash_free_pct} %")
        base = None if baseline is None else baseline["crash_free_sessions_pct"]
        if base is not None and rate < base - gate.max_drop_pct:
            misses.append(f"crash-free sessions {rate} % are more than {gate.max_drop_pct} points below the baseline's {base} %")
    return misses


# MARK: commands

def read(path: str) -> str:
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError as error:
        raise RolloutError(f"cannot read {path}: {error.strerror}") from None


def write_atomic(path: str, text: str) -> None:
    target = Path(path)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=target.parent, delete=False,
                                     prefix=f".{target.name}.", suffix=".tmp") as handle:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(handle.name, target)


def apply(feeds: list[str], build: str, percent: float, now: datetime.datetime, write: bool, out: Any) -> None:
    edited = [(path, stage_feed(read(path), build, percent, now)) for path in feeds]  # all checked before any write
    for path, text in edited:
        if write:
            write_atomic(path, text)
        print(f"{'wrote' if write else 'would write'} {path}: build {build} at {format_percent(percent)} %", file=out)
    if not write:
        print("dry run: pass --write to change the files", file=out)


def main(argv: list[str] | None = None, now: Callable[[], datetime.datetime] | None = None,
         fetch: Fetch | None = None, out: Any = sys.stdout) -> int:
    clock = now or (lambda: datetime.datetime.now(datetime.timezone.utc))
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    show = commands.add_parser("show")
    show.add_argument("feeds", nargs="+")
    show.add_argument("--build", required=True)
    setter = commands.add_parser("set")
    setter.add_argument("feeds", nargs="+")
    setter.add_argument("--build", required=True)
    setter.add_argument("--percent", required=True)
    setter.add_argument("--write", action="store_true")
    for name in ("gate", "advance"):
        command = commands.add_parser(name)
        if name == "advance":
            command.add_argument("feeds", nargs="+")
            command.add_argument("--build", required=True)
            command.add_argument("--write", action="store_true")
            command.add_argument("--force-bake", action="store_true", help="skip the bake time, never the gate")
        else:
            command.add_argument("--since", help="ISO time the stage started (default: the last 14 days)")
            command.add_argument("--stage", type=float, default=1.0, help="the stage whose gate applies")
        command.add_argument("--release", required=True, help="the Sentry release, cmux-next@<version>+<build>")
        command.add_argument("--baseline", help="the previous release, compared by max_drop_pct")
        command.add_argument("--env", default="release-next")
    args = parser.parse_args(argv)
    try:
        if args.command == "show":
            for path in args.feeds:
                stage = current_stage(read(path), args.build)
                where = "every install (no element)" if stage.percent is None else f"{format_percent(stage.percent)} %"
                print(f"{path}: build {args.build} at {where}, staged {stage.staged_at or 'unknown'}", file=out)
            return 0
        if args.command == "set":
            apply(args.feeds, args.build, parse_percent(args.percent), clock(), args.write, out)
            return 0
        health = load_health()
        if fetch is None:
            token = os.environ.get(health.TOKEN_ENV, "")
            if not token:
                print(f"set {health.TOKEN_ENV}", file=sys.stderr)
                return 2
            fetch = health.http_fetch(os.environ.get(health.BASE_URL_ENV, health.DEFAULT_BASE_URL), token)
        if args.command == "gate":
            since = None if args.since is None else datetime.datetime.fromisoformat(args.since.replace("Z", "+00:00"))
            stage = args.stage
        else:
            stages = {current_stage(read(path), args.build) for path in args.feeds}
            if len(stages) != 1:
                raise RolloutError(f"the feeds are at different stages: {sorted(map(str, stages))}")
            current = stages.pop()
            if current.percent is None:
                raise RolloutError("the build has no stage: start it with `set --percent 1`")
            stage, since = current.percent, current.staged_at
            target = next_stage(stage)
            if since is None:
                raise RolloutError("the item has no rolloutStagedAt: set the stage again with this tool")
            baked = (clock() - since).total_seconds() / 3600
            if baked < BAKE_HOURS and not args.force_bake:
                print(f"stage {format_percent(stage)} % has baked {baked:.1f} h of {BAKE_HOURS:g} h", file=out)
                return 1
        row = release_sessions(health, fetch, args.release, args.env, since, clock())
        baseline = None if not args.baseline else release_sessions(health, fetch, args.baseline, args.env, None, clock())
        misses = judge(stage, row, baseline)
        print(f"{args.release} at stage {format_percent(stage)} %: {row['sessions']} sessions, "
              f"crash-free {row['crash_free_sessions_pct']} %", file=out)
        for miss in misses:
            print(f"  gate: {miss}", file=out)
        if misses:
            return 1
        if args.command == "advance":
            apply(args.feeds, args.build, target, clock(), args.write, out)
        return 0
    except RolloutError as error:
        print(f"stage-rollout: {error}", file=sys.stderr)
        return 2
    except Exception as error:  # SentryError from stability-health.py, already redacted
        if type(error).__name__ == "SentryError":
            print(f"stage-rollout: {error}", file=sys.stderr)
            return 3
        raise


if __name__ == "__main__":
    sys.exit(main())
