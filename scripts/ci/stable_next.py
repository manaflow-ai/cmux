#!/usr/bin/env python3
"""cmux NEXT Stable: the nightly-picked, gated sibling of the cmux NEXT nightly (stable-next.yml).

cmux NEXT Stable is a separate app (com.cmuxterm.app.nightly.cmux-next-stable, "cmux NEXT Stable")
for the team. Once a night it takes the newest nightly-next build on the cmux NEXT feed, runs the
stable gates on that build's commit and on its signed bits, re-signs the same bits under the stable
identity and publishes them to its own feed:

    https://files-next.cmux.com/nightly-next/stable/appcast-arm64.xml

The feed sits under /nightly-next/ on purpose: UpdateFeedResolver classifies a feed by that path
segment, and only the cmux NEXT classification accepts ring-tagged items. Every stable item is tagged
`cmux-next-stable`, which every ring accepts, so the app's update channel setting never hides it.

  window [--now ISO]
      Whether a scheduled tick may start a stable run now: between 21:00 and 06:59 America/Los_Angeles.
      GITHUB_OUTPUT lines: open=true|false, night_start=<ISO UTC of the night's 21:00 local>.
  pick --feed NEXT.xml [--stable STABLE.xml] [--pulled PULLED.json] [--stable-pulled PULLED.json]
       [--verdicts DIR|URL] [--build B]
      The build to promote, as GITHUB_OUTPUT lines: build, run_id, short_version, url, length,
      minimum_system_version, and skip=true with skip_reason when the stable feed already serves
      that build or a newer one. The newest item Nightly apps are offered (untagged, cmux-next or
      cmux-next-stable) that was never pulled from the stable feed, or B. Refuses (exit 1) a build
      pulled from the cmux NEXT feed, a build pulled from the stable feed, and a fail verdict.
  published-tonight --stable STABLE.xml --night-start ISO
      published=true|false: whether the stable feed's newest item was published since night_start.
  test-shards --package Packages/macOS/CmuxNext/Package.swift --shards N
      matrix=<JSON>: the package's test targets, by name (package-test-lane.sh suite takes a target
      name as a filter), dealt round robin into N shards ({"include": [{"shard": 1, "filters": "A,B"}]}).
  merge-feed --new NEW.xml [--live LIVE.xml] --out OUT.xml [--keep N]
      The stable feed after publishing NEW's one item: that item, tagged cmux-next-stable, then the
      live feed's items below its build, newest first, KEEP (3) items in all, so a rollback always
      has earlier stable builds to serve. Refuses when the live feed already has this build or a newer.
  rollback --live LIVE.xml --out OUT.xml (--bad-build B | --to-build B) [--allow-empty]
      The live feed without B and every newer item (or every item above B). Refuses to empty it
      unless --allow-empty (pulling the only stable build). Prints the pulled builds as JSON.
  record-pulled --pulled PULLED.json --builds B[,B...] --reason R --out OUT.json
      The stable pulled.json with these builds added; pick never takes a build listed there again.
  write-feed --feed OUT --expect-sha256 HEX|absent
      Writes the file to R2 as <NIGHTLY_NEXT_R2_PREFIX><basename> (only the stable prefix) only
      while the live object still has the bytes that were read (compare and swap).
  crash-delta --base-tree DIR --head-tree DIR
      The crash-class ratchet between two exported trees: the commit the stable feed serves and the
      candidate's. Each counted (unwaived) hit row of scripts/cmux-next/crash_ratchet.py's scanner
      may not rise, after proven moves between modules, so a stable build never adds a crash-class
      hit over the last one. Debt the last stable build already shipped does not block (the
      whole-tree ratchet is red on feat-cmux-next itself). Exit 1 when a row rose.
  sentry-new-crashes --release R [--project ID] [--org SLUG]
      The unhandled-error issues Sentry first saw in release R (cmux-next@<short>+<build>), from
      SENTRY_AUTH_TOKEN. Exit 0 with none, 1 with any (listed), 2 when Sentry cannot be read.
"""
from __future__ import annotations

import argparse
import datetime as dt
import email.utils
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
STABLE_CHANNEL = "cmux-next-stable"
NIGHTLY_CHANNELS = (None, "cmux-next", STABLE_CHANNEL)
KEEP = 3
LOCAL_ZONE = ZoneInfo("America/Los_Angeles")
WINDOW_START_HOUR = 21
WINDOW_END_HOUR = 7  # exclusive: the last tick that may start is before 07:00 local

ITEM = re.compile(r"[ \t]*<item>.*?</item>[ \t]*\n?", re.S)
VERSION = re.compile(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>")
SHORT = re.compile(r"<sparkle:shortVersionString>\s*([^<]*?)\s*</sparkle:shortVersionString>")
MINIMUM = re.compile(r"<sparkle:minimumSystemVersion>\s*([^<]*?)\s*</sparkle:minimumSystemVersion>")
CHANNEL = re.compile(r"<sparkle:channel>\s*([^<]*?)\s*</sparkle:channel>")
PUBDATE = re.compile(r"<pubDate>\s*([^<]*?)\s*</pubDate>")
ENCLOSURE = re.compile(r"<enclosure\b[^>]*>")
ATTR = re.compile(r'([\w:]+)="([^"]*)"')
TARGET = re.compile(r'\.testTarget\(\s*name:\s*"([A-Za-z0-9_]+)"')


class Refused(Exception):
    pass


def items(text: str) -> list[tuple[re.Match, int]]:
    found = []
    for match in ITEM.finditer(text):
        version = VERSION.search(match.group(0))
        if version is None:
            raise Refused(f"an item has no numeric sparkle:version: {match.group(0)[:160]!r}")
        found.append((match, int(version.group(1))))
    return found


def channel_of(item: str) -> str | None:
    found = CHANNEL.search(item)
    return found.group(1) if found else None


def enclosure_of(item: str) -> dict[str, str]:
    found = ENCLOSURE.search(item)
    return dict(ATTR.findall(found.group(0))) if found else {}


def out(lines: dict[str, str], github_output: str | None) -> None:
    text = "".join(f"{key}={value}\n" for key, value in lines.items())
    sys.stdout.write(text)
    if github_output:
        with open(github_output, "a", encoding="utf-8") as handle:
            handle.write(text)


# window -------------------------------------------------------------------------------------------

def night_start(now: dt.datetime) -> dt.datetime:
    local = now.astimezone(LOCAL_ZONE)
    day = local.date() if local.hour >= WINDOW_START_HOUR else local.date() - dt.timedelta(days=1)
    start = dt.datetime.combine(day, dt.time(WINDOW_START_HOUR), tzinfo=LOCAL_ZONE)
    return start.astimezone(dt.timezone.utc)


def window(now: dt.datetime) -> dict[str, str]:
    hour = now.astimezone(LOCAL_ZONE).hour
    open_ = hour >= WINDOW_START_HOUR or hour < WINDOW_END_HOUR
    return {"open": "true" if open_ else "false",
            "night_start": night_start(now).strftime("%Y-%m-%dT%H:%M:%SZ")}


# pick ---------------------------------------------------------------------------------------------

def read_verdict(source: str | None, build: int) -> str | None:
    if not source:
        return None
    if re.match(r"^https://", source):
        # The feed's CDN refuses Python's default user agent (403).
        request = urllib.request.Request(f"{source.rstrip('/')}/{build}.json", headers={"User-Agent": "cmux-stable-next/1"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response).get("verdict")
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise
    path = Path(source) / f"{build}.json"
    return json.loads(path.read_text()).get("verdict") if path.is_file() else None


def pulled_builds_text(text: str | None) -> set[int]:
    doc = json.loads(text) if text and text.strip() else []
    entries = doc if isinstance(doc, list) else [doc]
    return {int(entry["build"]) for entry in entries if str(entry.get("build", "")).isdigit()}


def pulled_builds(path: str | None) -> set[int]:
    if not path or not Path(path).is_file():
        return set()
    return pulled_builds_text(Path(path).read_text())


def pick(feed: str, stable: str | None, pulled: set[int], verdict_of, build: int | None,
         stable_pulled: set[int] = frozenset()) -> dict[str, str]:
    offered = [(m, b) for m, b in items(feed) if channel_of(m.group(0)) in NIGHTLY_CHANNELS]
    if build is not None and build in stable_pulled:
        raise Refused(f"build {build} was pulled from the stable feed")
    offered = [(m, b) for m, b in offered if b not in stable_pulled]
    if build is not None:
        offered = [(m, b) for m, b in offered if b == build]
        if not offered:
            raise Refused(f"build {build} is not on the cmux NEXT feed")
    if not offered:
        raise Refused("the cmux NEXT feed offers Nightly apps no build that was not pulled from stable")
    match, chosen = max(offered, key=lambda entry: entry[1])
    if chosen in pulled:
        raise Refused(f"build {chosen} was pulled from the cmux NEXT feed")
    verdict = verdict_of(chosen)
    if verdict == "fail":
        raise Refused(f"build {chosen} has a fail verdict from the cmux NEXT canary")
    item = match.group(0)
    enclosure = enclosure_of(item)
    url, length = enclosure.get("url", ""), enclosure.get("length", "")
    if not url.startswith("https://") or not length.isdigit():
        raise Refused(f"build {chosen} has no usable enclosure")
    short = SHORT.search(item)
    minimum = MINIMUM.search(item)
    result = {
        "build": str(chosen),
        # nightly.yml's build number is <run id><two-digit attempt>.
        "run_id": str(chosen)[:-2],
        "short_version": short.group(1) if short else "",
        "url": url,
        "length": length,
        "minimum_system_version": minimum.group(1) if minimum else "",
        "verdict": verdict or "none",
        "skip": "false",
        "skip_reason": "",
    }
    if stable:
        served = [b for _, b in items(stable)]
        if served and max(served) >= chosen:
            result["skip"] = "true"
            result["skip_reason"] = f"the stable feed already serves build {max(served)}"
    return result


def published_tonight(stable: str | None, start: dt.datetime) -> bool:
    if not stable:
        return False
    found = items(stable)
    if not found:
        return False
    match, _ = max(found, key=lambda entry: entry[1])
    date = PUBDATE.search(match.group(0))
    if date is None:
        return False
    return email.utils.parsedate_to_datetime(date.group(1)) >= start


# test shards --------------------------------------------------------------------------------------

def test_shards(package: str, shards: int) -> dict:
    targets = sorted(set(TARGET.findall(package)))
    if not targets:
        raise Refused("the package declares no test target")
    if shards < 1:
        raise Refused("--shards must be at least 1")
    groups: list[list[str]] = [[] for _ in range(min(shards, len(targets)))]
    for index, target in enumerate(targets):
        groups[index % len(groups)].append(target)
    return {"include": [{"shard": n + 1, "filters": ",".join(group)} for n, group in enumerate(groups)]}


# feeds --------------------------------------------------------------------------------------------

def set_channel(item: str, channel: str) -> str:
    if CHANNEL.search(item):
        first = True

        def keep_first(match: re.Match) -> str:
            nonlocal first
            if first:
                first = False
                return f"<sparkle:channel>{channel}</sparkle:channel>"
            return ""
        return CHANNEL.sub(keep_first, item)
    return item.replace("<item>", f"<item>\n            <sparkle:channel>{channel}</sparkle:channel>", 1)


def merge_feed(new: str, live: str | None, keep: int = KEEP) -> str:
    fresh = items(new)
    if len(fresh) != 1:
        raise Refused(f"the new feed must hold exactly one item, it holds {len(fresh)}")
    match, build = fresh[0]
    item = set_channel(match.group(0).strip("\n"), STABLE_CHANNEL)
    kept = []
    if live:
        older = []
        for live_match, live_build in items(live):
            if live_build >= build:
                raise Refused(f"the live stable feed already serves build {live_build} (>= {build})")
            older.append((live_build, live_match.group(0).strip("\n")))
        kept = [text for _, text in sorted(older, reverse=True)[: keep - 1]]
    body = "\n".join([item] + kept)
    head, tail = new[: match.start()], new[match.end():]
    return f"{head.rstrip()}\n{body}\n{tail.lstrip()}"


def rollback(live: str, bad: int | None, to: int | None, allow_empty: bool = False) -> tuple[str, list[int]]:
    found = items(live)
    if bad is not None:
        drop = {b for _, b in found if b >= bad}
        if bad not in {b for _, b in found}:
            raise Refused(f"build {bad} is not on the stable feed")
    else:
        if to not in {b for _, b in found}:
            raise Refused(f"build {to} is not on the stable feed")
        drop = {b for _, b in found if b > to}
    if not drop:
        raise Refused("nothing to pull")
    if len(drop) == len(found) and not allow_empty:
        raise Refused("the rollback would leave the stable feed empty (pass --allow-empty to pull the only build)")
    text, cursor, parts = live, 0, []
    for match, build in found:
        parts.append(text[cursor: match.start()])
        if build not in drop:
            parts.append(match.group(0))
        cursor = match.end()
    parts.append(text[cursor:])
    return "".join(parts), sorted(drop)


def record_pulled(pulled: str | None, builds: list[int], reason: str, when: str) -> str:
    entries = json.loads(pulled) if pulled and pulled.strip() else []
    if not isinstance(entries, list):
        raise Refused("the stable pulled.json is not a list")
    known = {str(entry.get("build")) for entry in entries}
    for build in builds:
        if str(build) not in known:
            entries.append({"build": str(build), "reason": reason, "pulledAt": when})
    return json.dumps(entries, indent=2) + "\n"


def _r2_module():
    spec = importlib.util.spec_from_file_location("publish_nightly_next_r2", HERE / "publish-nightly-next-r2.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_feed(feed: Path, expect: str) -> int:
    r2 = _r2_module()
    prefix = r2.env("NIGHTLY_NEXT_R2_PREFIX")
    if prefix != "nightly-next/stable/":
        raise Refused(f"NIGHTLY_NEXT_R2_PREFIX must be nightly-next/stable/, got {prefix!r}")
    key = prefix + feed.name
    r2.guard_key(key)
    live = r2.read_live(key)
    actual = "absent" if live is None else hashlib.sha256(live).hexdigest()
    if actual != expect:
        raise Refused(f"{key} changed since it was read ({actual} != {expect}); run again")
    mode = ["--write-once"] if live is None else ["--replace-sha256", expect]
    content_type = "application/json" if feed.suffix == ".json" else "application/xml"
    result = subprocess.run(r2.uploader_args(feed, key, r2.FEED_CACHE, content_type) + mode)
    if result.returncode == 0:
        print(f"{feed.name}: live at {r2.public_base()}{feed.name}")
    return result.returncode


# crash delta ----------------------------------------------------------------------------------------

def _ratchet_module(head_tree: Path):
    spec = importlib.util.spec_from_file_location("crash_ratchet", head_tree / "scripts/cmux-next/crash_ratchet.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def scan_rows(ratchet, scan) -> dict[tuple, int]:
    """{(section, lang, class, module): hits} of a scan, in baseline_rows' shape."""
    data = {}
    for lang, kinds in scan.counts.items():
        for kind, modules in kinds.items():
            data.setdefault(lang, {})[kind] = dict(modules)
    data[ratchet.WAIVED] = {lang: {kind: dict(m) for kind, m in kinds.items()} for lang, kinds in scan.waived.items()}
    return ratchet.baseline_rows(data)


def crash_delta(base_tree: Path, head_tree: Path) -> list[str]:
    ratchet = _ratchet_module(head_tree)
    old, new = ratchet.scan_tree(str(base_tree), True), ratchet.scan_tree(str(head_tree), True)
    base_rows, head_rows = scan_rows(ratchet, old), scan_rows(ratchet, new)
    found = []
    risen = {row: n for row, n in head_rows.items() if row[0] != ratchet.WAIVED and n > base_rows.get(row, 0)}
    if risen:
        allowance, _ = ratchet.carry_moves(base_rows, risen, ratchet.proven_moves(old, new))
        found += [f"{ratchet.row_label(row)}: {base_rows.get(row, 0)} -> {n}"
                  for row, n in sorted(risen.items()) if n > allowance.get(row, 0)]
    # Banned classes (force_unwrap and as_bang in CmuxNext, index_subscript in render modules) are
    # kept per file, not per module; compare each class's total so a renamed file is no new hit.
    def banned(scan):
        totals = {}
        for (kind, _path), hits in scan.banned_files.items():
            totals[kind] = totals.get(kind, 0) + hits
        return totals
    was, now = banned(old), banned(new)
    found += [f"banned {kind}: {was.get(kind, 0)} -> {n}" for kind, n in sorted(now.items()) if n > was.get(kind, 0)]
    return found


# sentry -------------------------------------------------------------------------------------------

def sentry_new_crashes(release: str, org: str, project: str, token: str) -> list[dict]:
    query = f'firstRelease:"{release}" error.unhandled:true'
    params = urllib.parse.urlencode({"project": project, "query": query, "statsPeriod": "14d", "limit": 25})
    request = urllib.request.Request(f"https://sentry.io/api/0/organizations/{org}/issues/?{params}",
                                     headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


# main ---------------------------------------------------------------------------------------------

def read_optional(path: str | None) -> str | None:
    if not path:
        return None
    file = Path(path)
    return file.read_text(encoding="utf-8") if file.is_file() and file.stat().st_size else None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    w = sub.add_parser("window")
    w.add_argument("--now")
    p = sub.add_parser("pick")
    p.add_argument("--feed", required=True)
    p.add_argument("--stable")
    p.add_argument("--pulled")
    p.add_argument("--stable-pulled")
    p.add_argument("--verdicts")
    p.add_argument("--build", type=int)
    t = sub.add_parser("published-tonight")
    t.add_argument("--stable", required=True)
    t.add_argument("--night-start", required=True)
    s = sub.add_parser("test-shards")
    s.add_argument("--package", required=True)
    s.add_argument("--shards", type=int, default=4)
    m = sub.add_parser("merge-feed")
    m.add_argument("--new", required=True)
    m.add_argument("--live")
    m.add_argument("--out", required=True)
    m.add_argument("--keep", type=int, default=KEEP)
    r = sub.add_parser("rollback")
    r.add_argument("--live", required=True)
    r.add_argument("--out", required=True)
    group = r.add_mutually_exclusive_group(required=True)
    group.add_argument("--bad-build", type=int)
    group.add_argument("--to-build", type=int)
    r.add_argument("--allow-empty", action="store_true")
    rp = sub.add_parser("record-pulled")
    rp.add_argument("--pulled")
    rp.add_argument("--builds", required=True)
    rp.add_argument("--reason", required=True)
    rp.add_argument("--out", required=True)
    f = sub.add_parser("write-feed")
    f.add_argument("--feed", required=True, type=Path)
    f.add_argument("--expect-sha256", required=True)
    cd = sub.add_parser("crash-delta")
    cd.add_argument("--base-tree", required=True, type=Path)
    cd.add_argument("--head-tree", required=True, type=Path)
    c = sub.add_parser("sentry-new-crashes")
    c.add_argument("--release", required=True)
    c.add_argument("--org", default="manaflow")
    c.add_argument("--project", default="4510796264636416")
    args = parser.parse_args(argv)
    github_output = os.environ.get("GITHUB_OUTPUT")
    try:
        if args.command == "window":
            now = dt.datetime.fromisoformat(args.now.replace("Z", "+00:00")) if args.now else dt.datetime.now(dt.timezone.utc)
            out(window(now), github_output)
        elif args.command == "pick":
            feed = Path(args.feed).read_text(encoding="utf-8")
            result = pick(feed, read_optional(args.stable), pulled_builds(args.pulled),
                          lambda b: read_verdict(args.verdicts, b), args.build, pulled_builds(args.stable_pulled))
            out(result, github_output)
        elif args.command == "published-tonight":
            start = dt.datetime.fromisoformat(args.night_start.replace("Z", "+00:00"))
            out({"published": "true" if published_tonight(read_optional(args.stable), start) else "false"},
                github_output)
        elif args.command == "test-shards":
            matrix = test_shards(Path(args.package).read_text(encoding="utf-8"), args.shards)
            out({"matrix": json.dumps(matrix, separators=(",", ":"))}, github_output)
        elif args.command == "merge-feed":
            merged = merge_feed(Path(args.new).read_text(encoding="utf-8"), read_optional(args.live), args.keep)
            Path(args.out).write_text(merged, encoding="utf-8")
            print(f"stable feed: {', '.join(str(b) for _, b in items(merged))}")
        elif args.command == "rollback":
            text, dropped = rollback(Path(args.live).read_text(encoding="utf-8"), args.bad_build, args.to_build,
                                     args.allow_empty)
            Path(args.out).write_text(text, encoding="utf-8")
            left = [b for _, b in items(text)]
            print(json.dumps({"pulled": dropped, "serves": max(left) if left else None}))
        elif args.command == "record-pulled":
            when = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            builds = [int(b) for b in args.builds.split(",") if b.strip()]
            Path(args.out).write_text(record_pulled(read_optional(args.pulled), builds, args.reason, when), encoding="utf-8")
        elif args.command == "write-feed":
            return write_feed(args.feed, args.expect_sha256)
        elif args.command == "crash-delta":
            risen = crash_delta(args.base_tree, args.head_tree)
            for line in risen:
                print(f"crash-delta: {line}")
            print(f"crash-delta: {len(risen)} crash-class row(s) rose over the last stable build")
            return 1 if risen else 0
        elif args.command == "sentry-new-crashes":
            token = os.environ.get("SENTRY_AUTH_TOKEN", "").strip()
            if not token:
                print("SENTRY_AUTH_TOKEN is not set", file=sys.stderr)
                return 2
            try:
                issues = sentry_new_crashes(args.release, args.org, args.project, token)
            except (urllib.error.URLError, OSError, ValueError) as error:
                print(f"Sentry could not be read: {error}", file=sys.stderr)
                return 2
            for issue in issues:
                print(f"- {issue.get('shortId')}: {issue.get('title')} ({issue.get('count')} events) {issue.get('permalink')}")
            print(f"{len(issues)} new unhandled issue(s) first seen in {args.release}")
            return 1 if issues else 0
    except Refused as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
