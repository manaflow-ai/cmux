#!/usr/bin/env python3
"""Decide what the cmux NIGHTLY-identity old feed job does next (cx-x7hwx).

Usage:
  nightly-next-legacy-target.py <next-appcast> <old-appcast> <dmg-prefix>
      [--pending-meta FILE --pending-run ID --now EPOCH] [--max-pending-hours H]
      [--max-same-build-hours H]

Prints GitHub output lines:
  action=continue|new|none
  build=<build>          the build the job works on (empty for none)
  pending_run=<run id>   the run whose pending submission to continue (continue only)

Rules:
- The old feed follows the newest cmux NEXT build that is newer than every build
  on the old feed, whichever run published it (publish-nightly, recovery of a
  build Apple accepted late, or a nightly_next_continue_only run).
- A pending cmux NIGHTLY-identity submission (--pending-meta, written by the job
  when Apple's queue outlasted its wait) whose build is still newer than the old
  feed is continued, never resubmitted:
  * while it is younger than --max-pending-hours (default 6), always;
  * after that, while it is younger than --max-same-build-hours (default 48,
    under the 3-day artifact retention) and the cmux NEXT feed has no newer
    build: Apple has held submissions for 13+ hours.
  Only a newer cmux NEXT build (after 6 h), or the 48-hour limit, starts a new
  submission. Once the old feed has the pending build it is stale.
- Fails when the cmux NEXT feed has no items, the newest item's enclosure is not
  the exact <dmg-prefix><build>.dmg, or the pending metadata is malformed.
"""
import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET

NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def items(path):
    out = []
    for item in ET.parse(path).getroot().iter("item"):
        version = (item.findtext(f"{NS}version") or "").strip()
        enclosure = item.find("enclosure")
        if re.fullmatch(r"\d+", version) and enclosure is not None:
            out.append((int(version), enclosure.get("url", "")))
    return out


def fail(message):
    print(message, file=sys.stderr)
    return 1


def main(argv):
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("next_appcast")
    parser.add_argument("old_appcast")
    parser.add_argument("dmg_prefix")
    parser.add_argument("--pending-meta")
    parser.add_argument("--pending-run")
    parser.add_argument("--now", type=int)
    parser.add_argument("--max-pending-hours", type=float, default=6.0)
    parser.add_argument("--max-same-build-hours", type=float, default=48.0)
    args = parser.parse_args(argv)

    next_items = items(args.next_appcast)
    if not next_items:
        return fail("cmux NEXT feed has no items")
    newest, url = max(next_items)
    expected = f"{args.dmg_prefix}{newest}.dmg"
    if url.rsplit("/", 1)[-1] != expected:
        return fail(f"cmux NEXT build {newest} enclosure is {url}, not {expected}")
    current = max((version for version, _ in items(args.old_appcast)), default=0)

    if args.pending_meta:
        if not args.pending_run or not re.fullmatch(r"\d+", args.pending_run) or args.now is None:
            return fail("--pending-meta needs --pending-run (a run id) and --now")
        try:
            meta = json.load(open(args.pending_meta, encoding="utf-8"))
            pending_build = int(str(meta["build"]))
            submitted = int(meta["submitted_epoch"])
            submission = str(meta["submission_id"])
        except (OSError, ValueError, KeyError, TypeError) as error:
            return fail(f"malformed pending metadata: {error}")
        if not re.fullmatch(r"[A-Za-z0-9-]+", submission):
            return fail(f"malformed pending submission id {submission!r}")
        age_hours = (args.now - submitted) / 3600
        continuable = pending_build > current and (
            age_hours < args.max_pending_hours
            or (age_hours < args.max_same_build_hours and newest <= pending_build)
        )
        if continuable:
            print("action=continue")
            print(f"build={pending_build}")
            print(f"pending_run={args.pending_run}")
            return 0

    if newest > current:
        print("action=new")
        print(f"build={newest}")
    else:
        print("action=none")
        print("build=")
    print("pending_run=")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
