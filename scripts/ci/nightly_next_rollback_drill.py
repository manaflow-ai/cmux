#!/usr/bin/env python3
"""The weekly rollback drill's feed half (nightly-next-rollback-drill.yml).

The drill publishes a deliberately bad canary to a test channel and rolls it
back through the real rollback jobs (nightly-next-rollback.yml with drill on),
so the pull is timed on the production route: R2 and files-next.cmux.com. The
test channel is the drill folder, nightly-next/drill/, which no app reads
unless it is pointed there (updates.test_feed). The users' appcast is never
written, and nightly-next-guard.py keeps the drill inside its folder.

  pick --feed FILE --run-id ID --attempt N --out FILE
      The drill appcast: the live feed's two newest Nightly-ring items (N, the
      bad canary, and K, the build it rolls back to), byte for byte, and no
      other item, with a <cmux:drillRun> element naming this run before them.
      The rollback copies everything but the pulled items byte for byte, so
      the element stays through the pull, and the probe matches it to the
      receipt's publish run: a receipt from another run is not this feed's. Prints {"bad", "kept", "bad_url", "kept_url"}. Exit 1 when
      the live feed holds fewer than two Nightly-ring items: then a real pull
      of N would have nothing to serve, which is what the drill is there to find.
  receipt publish --bad B --kept B --at ISO8601 --run-id ID --attempt N --run-url URL --out FILE
  receipt pull --existing FILE --publish-run-id ID --publish-attempt N --ordered-at ISO8601
               [--served-at ISO8601] --outcome served|failed --run-id ID --attempt N --run-url URL --out FILE
  receipt check --existing FILE --now ISO8601 [--max-age-s S]
      receipt.json, beside the drill appcast, is what the cmuxterm-hq probe
      reads (goals/release-rollback-drilled.md). Publish writes it with the
      pull fields empty, so a week whose pull fails leaves a receipt saying so,
      never last week's. Pull adds the pull fields to a published receipt.
      Check refuses (exit 1) a receipt that is not a fresh, unpulled publish,
      and prints {"bad", "kept", "publish_run_id", "publish_attempt"} for the
      pull to take. Pull refuses a receipt whose publish run or attempt is not
      the one check read: a publish that replaced it meanwhile is another
      drill, and its receipt never gets this pull's times.
  served --feed FILE --pulled FILE --bad B --kept B
      Exit 0 when the served drill appcast no longer offers B, still offers K,
      and the served pulled.json lists B; exit 1 with what is missing.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys

ITEM = re.compile(r"[ \t]*<item>.*?</item>[ \t]*\n?", re.S)
VERSION = re.compile(r"<sparkle:version>\s*([0-9]+)\s*</sparkle:version>")
CHANNEL = re.compile(r"<sparkle:channel>\s*([^<]*?)\s*</sparkle:channel>")
ENCLOSURE = re.compile(r'<enclosure\s[^>]*?url="([^"]+)"')
CMUX_NS = "https://cmux.com/xml-namespaces/cmux"
DRILL_RUN = re.compile(r"[ \t]*<cmux:drillRun\b[^>]*>[^<]*</cmux:drillRun>[ \t]*\n?")
# The tags a NIGHTLY on its default ring is offered (UpdateRing.acceptedSparkleChannels), so the
# drill's N reaches a test Mac without switching its ring.
NIGHTLY_RING = ("cmux-next-stable", "cmux-next")
SCHEMA = "cmux.rollback-drill.receipt.v1"
FEED_ROUTE = "r2"
# A publish older than this is last week's: the pull refuses it.
MAX_AGE_S = 3 * 3600


class Refused(Exception):
    pass


def nightly_items(text: str) -> list[tuple[re.Match[str], str]]:
    """(match, build) for every Nightly-ring item, newest build first."""
    found = []
    for match in ITEM.finditer(text):
        version, channel = VERSION.search(match.group(0)), CHANNEL.search(match.group(0))
        if version and channel and channel.group(1) in NIGHTLY_RING:
            found.append((match, version.group(1)))
    return sorted(found, key=lambda entry: int(entry[1]), reverse=True)


def drill_run_element(run_id: str, attempt: str) -> str:
    if not run_id.isdigit() or not attempt.isdigit():
        raise Refused(f"run id {run_id!r} and attempt {attempt!r} must be numbers")
    return f'        <cmux:drillRun xmlns:cmux="{CMUX_NS}" attempt="{attempt}">{run_id}</cmux:drillRun>\n'


def pick(text: str, run_id: str, attempt: str) -> tuple[str, dict]:
    """(drill appcast text, summary): the live feed with every item but N and K cut out, and the run named."""
    run = drill_run_element(run_id, attempt)
    text = DRILL_RUN.sub("", text)
    found = nightly_items(text)
    if len(found) < 2:
        builds = ", ".join(build for _, build in found) or "none"
        raise Refused(f"the live feed holds {len(found)} Nightly-ring item(s) ({builds}): a pull of the newest "
                      "would leave nothing to serve")
    (bad, bad_build), (kept, kept_build) = found[0], found[1]
    keep = {bad.start(), kept.start()}
    out, last, named = [], 0, False
    for match in ITEM.finditer(text):
        if not named:
            out.append(text[last:match.start()] + run)
            last, named = match.start(), True
        if match.start() in keep:
            continue
        out.append(text[last:match.start()])
        last = match.end()
    out.append(text[last:])
    urls = {}
    for name, match in (("bad", bad), ("kept", kept)):
        url = ENCLOSURE.search(match.group(0))
        if url is None:
            raise Refused(f"item {match.group(0)[:120]!r} has no enclosure")
        urls[name] = url.group(1)
    return "".join(out), {"bad": bad_build, "kept": kept_build, "bad_url": urls["bad"], "kept_url": urls["kept"]}


def parse_at(value: str) -> datetime:
    try:
        at = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise Refused(f"time {value!r} is not YYYY-MM-DDTHH:MM:SSZ") from error
    return at.replace(tzinfo=timezone.utc)


def run_fields(run_id: str, attempt: str, run_url: str) -> dict:
    if not run_id.isdigit() or not attempt.isdigit():
        raise Refused(f"run id {run_id!r} and attempt {attempt!r} must be numbers")
    return {"run_id": run_id, "run_attempt": attempt, "run_url": run_url}


def publish_receipt(bad: str, kept: str, at: str, run: dict) -> dict:
    if not (bad.isdigit() and kept.isdigit()) or int(kept) >= int(bad):
        raise Refused(f"bad {bad!r} must be a build above kept {kept!r}")
    parse_at(at)
    return {"schema": SCHEMA, "feed_route": FEED_ROUTE, "bad_build": bad, "kept_build": kept,
            "published_at": at, "publish": run, "outcome": "published",
            "pull_ordered_at": "", "served_at": "", "pull": {}}


def check_receipt(receipt: dict, now: str, max_age_s: int = MAX_AGE_S) -> dict:
    """{"bad", "kept"} of a fresh, unpulled publish; Refused otherwise."""
    if receipt.get("schema") != SCHEMA:
        raise Refused(f"receipt schema {receipt.get('schema')!r} is not {SCHEMA}")
    if receipt.get("outcome") != "published" or receipt.get("pull_ordered_at"):
        raise Refused(f"receipt outcome {receipt.get('outcome')!r}: this publish was already pulled")
    age = (parse_at(now) - parse_at(str(receipt.get("published_at", "")))).total_seconds()
    if not 0 <= age <= max_age_s:
        raise Refused(f"receipt published {age:.0f} s before now, outside 0..{max_age_s} s: not this week's")
    publish = receipt.get("publish") or {}
    return {"bad": receipt["bad_build"], "kept": receipt["kept_build"],
            "publish_run_id": str(publish.get("run_id", "")), "publish_attempt": str(publish.get("run_attempt", ""))}


def pull_receipt(receipt: dict, publish_run_id: str, publish_attempt: str, ordered_at: str, served_at: str,
                 outcome: str, run: dict) -> dict:
    if receipt.get("schema") != SCHEMA or receipt.get("outcome") != "published":
        raise Refused(f"receipt outcome {receipt.get('outcome')!r} is not a published drill")
    publish = receipt.get("publish") or {}
    got = (str(publish.get("run_id", "")), str(publish.get("run_attempt", "")))
    if got != (publish_run_id, publish_attempt):
        raise Refused(f"receipt is publish run {got[0]} attempt {got[1]}, not the {publish_run_id} attempt "
                      f"{publish_attempt} this pull checked: another publish replaced it")
    if outcome not in ("served", "failed"):
        raise Refused(f"outcome {outcome!r} is not served or failed")
    ordered = parse_at(ordered_at)
    if outcome == "served":
        if not served_at or parse_at(served_at) < ordered:
            raise Refused(f"served at {served_at!r} must be at or after the pull was ordered ({ordered_at})")
    elif served_at:
        raise Refused("a failed pull has no served time")
    return {**receipt, "outcome": outcome, "pull_ordered_at": ordered_at, "served_at": served_at, "pull": run}


def served(feed: str, pulled: str, bad: str, kept: str) -> list[str]:
    """What the served drill files still lack; empty once the rollback is served."""
    builds = {version.group(1) for version in VERSION.finditer(feed)}
    missing = []
    if bad in builds:
        missing.append(f"the drill appcast still offers {bad}")
    if kept not in builds:
        missing.append(f"the drill appcast does not offer {kept}")
    try:
        listed = {str(entry.get("build")) for entry in json.loads(pulled) if isinstance(entry, dict)}
    except (json.JSONDecodeError, TypeError, AttributeError):
        listed = set()
    if bad not in listed:
        missing.append(f"pulled.json does not list {bad}")
    return missing


def read_json(path: str) -> dict:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise Refused(f"{path}: {error}") from error
    if not isinstance(value, dict):
        raise Refused(f"{path} is not a JSON object")
    return value


def write_json(path: str, value: dict) -> None:
    Path(path).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("pick")
    p.add_argument("--feed", required=True)
    p.add_argument("--run-id", required=True)
    p.add_argument("--attempt", required=True)
    p.add_argument("--out", required=True)
    r = sub.add_parser("receipt")
    rs = r.add_subparsers(dest="mode", required=True)
    for name in ("publish", "pull"):
        m = rs.add_parser(name)
        m.add_argument("--run-id", required=True)
        m.add_argument("--attempt", required=True)
        m.add_argument("--run-url", required=True)
        m.add_argument("--out", required=True)
    rp = rs.choices["publish"]
    rp.add_argument("--bad", required=True)
    rp.add_argument("--kept", required=True)
    rp.add_argument("--at", required=True)
    rq = rs.choices["pull"]
    rq.add_argument("--existing", required=True)
    rq.add_argument("--publish-run-id", required=True)
    rq.add_argument("--publish-attempt", required=True)
    rq.add_argument("--ordered-at", required=True)
    rq.add_argument("--served-at", default="")
    rq.add_argument("--outcome", required=True)
    rc = rs.add_parser("check")
    rc.add_argument("--existing", required=True)
    rc.add_argument("--now", required=True)
    rc.add_argument("--max-age-s", type=int, default=MAX_AGE_S)
    s = sub.add_parser("served")
    s.add_argument("--feed", required=True)
    s.add_argument("--pulled", required=True)
    s.add_argument("--bad", required=True)
    s.add_argument("--kept", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "pick":
            text, summary = pick(Path(args.feed).read_text(encoding="utf-8"), args.run_id, args.attempt)
            Path(args.out).write_text(text, encoding="utf-8")
            print(json.dumps(summary))
        elif args.command == "served":
            feed = Path(args.feed).read_text(encoding="utf-8")
            pulled = Path(args.pulled).read_text(encoding="utf-8")
            missing = served(feed, pulled, args.bad, args.kept)
            if missing:
                print("not served yet: " + "; ".join(missing), file=sys.stderr)
                return 1
        elif args.mode == "check":
            print(json.dumps(check_receipt(read_json(args.existing), args.now, args.max_age_s)))
        else:
            run = run_fields(args.run_id, args.attempt, args.run_url)
            if args.mode == "publish":
                value = publish_receipt(args.bad, args.kept, args.at, run)
            else:
                value = pull_receipt(read_json(args.existing), args.publish_run_id, args.publish_attempt,
                                     args.ordered_at, args.served_at, args.outcome, run)
            write_json(args.out, value)
            print(json.dumps(value))
    except (OSError, UnicodeDecodeError, Refused) as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
