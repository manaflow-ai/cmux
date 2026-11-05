#!/usr/bin/env python3
"""Decide what the cmux NIGHTLY-identity old feed job does next (cx-x7hwx).

Usage:
  nightly-next-legacy-target.py <next-appcast> <old-appcast> <dmg-prefix>
      [--pending-meta FILE --pending-run ID --now EPOCH] [--max-pending-hours H]
      [--max-same-build-hours H] [--failure-log FILE] [--max-failures N]
      [--candidate-build N --candidate-url URL]
      [--refuse-build N]...

Prints GitHub output lines:
  action=continue|new|none
  build=<build>          the build the job works on (empty for none)
  pending_run=<run id>   the run whose pending metadata is continued (continue only)
  bundle_run=<run id>    the run that holds that submission's bundle (continue only)

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
- A submission Apple ACCEPTED (metadata "accepted": true, written when a later
  check failed) is continued with no time limit, and its build is never
  submitted again while its bundle is kept: the next run re-staples, re-checks
  and publishes it.
- Failures count per build from --failure-log (lines "Build N failed:"). A build
  with --max-failures (default 2) counted failures is not continued and not
  submitted again; a newer cmux NEXT build still is.
- A --refuse-build N (a build that lacks a commit in
  NIGHTLY_LEGACY_REQUIRED_COMMITS, or whose check failed) is neither continued
  nor submitted.
- Fails when the cmux NEXT feed has no items, the newest item's enclosure is not
  the exact <dmg-prefix><build>.dmg, or the pending metadata is malformed.
"""
import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET

NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
FEED_PREFIXES = {"sparkle": NS[1:-1], "cmux": "https://cmux.com/xml-namespaces/cmux"}


def bind_feed_prefixes(data):
    """DATA with every feed prefix it uses declared on the <rss> root (the live
    cmux NEXT feed carried an unbound cmux: prefix on 2026-11-01)."""
    root = re.search(rb"<rss\b[^>]*>", data)
    if root is None:
        return data
    opening = root.group(0)
    for prefix, uri in FEED_PREFIXES.items():
        used = re.search(rb"[<\s]" + prefix.encode() + rb":[A-Za-z_]", data) is not None
        if used and re.search(rb"\sxmlns:" + prefix.encode() + rb"\s*=", opening) is None:
            opening = opening[:-1] + f' xmlns:{prefix}="{uri}">'.encode()
    return data[:root.start()] + opening + data[root.end():]


def items(path):
    out = []
    with open(path, "rb") as handle:
        root = ET.fromstring(bind_feed_prefixes(handle.read()))
    for item in root.iter("item"):
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
    parser.add_argument("--failure-log")
    parser.add_argument("--max-failures", type=int, default=2)
    parser.add_argument("--refuse-build", type=int, action="append", default=[])
    parser.add_argument("--candidate-build", type=int)
    parser.add_argument("--candidate-url")
    args = parser.parse_args(argv)

    next_items = items(args.next_appcast)
    if args.candidate_build is not None:
        if not args.candidate_url:
            return fail("--candidate-build needs --candidate-url")
        expected_candidate = f"{args.dmg_prefix}{args.candidate_build}.dmg"
        if args.candidate_url.rsplit("/", 1)[-1] != expected_candidate:
            return fail(f"candidate build {args.candidate_build} enclosure is {args.candidate_url}, not {expected_candidate}")
        next_items.append((args.candidate_build, args.candidate_url))
    if not next_items:
        return fail("cmux NEXT feed has no items")
    newest, url = max(next_items)
    expected = f"{args.dmg_prefix}{newest}.dmg"
    if url.rsplit("/", 1)[-1] != expected:
        return fail(f"cmux NEXT build {newest} enclosure is {url}, not {expected}")
    current = max((version for version, _ in items(args.old_appcast)), default=0)

    failure_text = ""
    if args.failure_log:
        try:
            failure_text = open(args.failure_log, encoding="utf-8").read()
        except OSError as error:
            return fail(f"unreadable failure log: {error}")

    def failures(build):
        return len(re.findall(rf"(?m)^Build {build} failed:", failure_text))

    def emit(action, build="", pending_run="", bundle_run=""):
        print(f"action={action}")
        print(f"build={build}")
        print(f"pending_run={pending_run}")
        print(f"bundle_run={bundle_run}")
        return 0

    blocked = set(args.refuse_build)  # builds never submitted (or continued)
    if args.pending_meta:
        if not args.pending_run or not re.fullmatch(r"\d+", args.pending_run) or args.now is None:
            return fail("--pending-meta needs --pending-run (a run id) and --now")
        try:
            meta = json.load(open(args.pending_meta, encoding="utf-8"))
            pending_build = int(str(meta["build"]))
            submitted = int(meta["submitted_epoch"])
            submission = str(meta["submission_id"])
            accepted = meta.get("accepted") is True
            bundle_run = str(meta.get("bundle_run") or args.pending_run)
        except (OSError, ValueError, KeyError, TypeError) as error:
            return fail(f"malformed pending metadata: {error}")
        if not re.fullmatch(r"[A-Za-z0-9-]+", submission):
            return fail(f"malformed pending submission id {submission!r}")
        if not re.fullmatch(r"\d+", bundle_run):
            return fail(f"malformed pending bundle run {bundle_run!r}")
        if pending_build > current and pending_build not in blocked:
            age_hours = (args.now - submitted) / 3600
            if accepted:
                # Apple accepted it: never resubmit this build while the bundle is kept.
                blocked.add(pending_build)
                continuable = True
            else:
                continuable = age_hours < args.max_pending_hours or (
                    age_hours < args.max_same_build_hours and newest <= pending_build
                )
            if continuable and failures(pending_build) < args.max_failures:
                return emit("continue", pending_build, args.pending_run, bundle_run)
            if continuable:
                blocked.add(pending_build)

    if newest > current and newest not in blocked and failures(newest) < args.max_failures:
        return emit("new", newest)
    return emit("none")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
