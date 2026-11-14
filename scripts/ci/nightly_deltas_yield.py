#!/usr/bin/env python3
"""Post-publish deltas yield the signer Mac to the nightly-next build loop.

nightly.yml's generate-nightly-deltas signs a published build's deltas on the signer label (cmux15), holding
the whole Mac, as nightly-next-one does. It runs in the post-publish run ("Finish a published nightly-next
build") about 15 min after the publication, so it took the Mac in the gap between two builds: run
43555705551's generate-nightly-deltas held cmux15-glaeda-1 04:33:31-04:43:25Z on 2026-11-14 and
nightly-next-one of run 43557289118 (86dc299b) waited 6.6 min for it (queued 04:36:52, started 04:43:27).
Those deltas were never published: 86dc299b reached the feed at 05:03:53, and republish-nightly-deltas drops a
result once the live feed serves a newer build ("Skipping stale delta result").

Deltas are optional and downstream of the publication, and the build is what moves the feed (Leo, relayed:
"The nightly is one loop, latest wins, nothing queues"). So build-nightly-deltas, which runs on the
nightly-only minis before the keyed job asks for the signer, ends with this wait:

- the live feed serves a newer build than this one: its deltas could never be published (republish's own
  rule), so they are skipped (skip=true);
- feat-cmux-next has moved past nightly-next: a promotion and its build are on their way to the signer: wait;
- nightly-next has the tip for QUIET_MINUTES: go.

After MAX_MINUTES it goes anyway; an unreadable feed or ref does not skip. It reads only the public feed and
`git ls-remote`, no API budget (tests/test_ci_no_github_token_polling.py). Nothing is cancelled.

usage: nightly_deltas_yield.py --repo OWNER/NAME --build N --feed URL [--quiet-minutes 2] [--max-minutes 40]
Writes skip=true|false to $GITHUB_OUTPUT.
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

QUIET_MINUTES = 2.0
MAX_MINUTES = 40.0
POLL_SECONDS = 30.0


def newest_build(feed_xml: str) -> int | None:
    """The sparkle:version of the feed's first item (the build it serves), None when unreadable."""
    try:
        root = ET.fromstring(feed_xml)
    except ET.ParseError:
        return None
    for item in root.iter():
        if item.tag.rsplit("}", 1)[-1] != "item":
            continue
        for child in item:
            if child.tag.rsplit("}", 1)[-1] == "version" and (child.text or "").strip().isdigit():
                return int(child.text.strip())
        return None
    return None


def verdict(build: int, live: int | None, next_head: str, tip: str) -> str:
    """'skip', 'wait' or 'quiet' for this build's deltas at one look."""
    if live is not None and live > build:
        return "skip"
    if next_head and tip and next_head != tip:
        return "wait"
    return "quiet"


def read_feed(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "cmux-delta-yield/1"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8", "replace")


def ls_remote(repo: str, branch: str) -> str:
    out = subprocess.run(["git", "ls-remote", f"https://github.com/{repo}", f"refs/heads/{branch}"],
                         check=True, capture_output=True, text=True, timeout=60).stdout
    return out.split()[0] if out.split() else ""


def main(argv: list[str], feed=read_feed, ref=ls_remote,
         clock=lambda: dt.datetime.now(dt.timezone.utc), sleep=time.sleep) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--feed", required=True)
    parser.add_argument("--quiet-minutes", type=float, default=QUIET_MINUTES)
    parser.add_argument("--max-minutes", type=float, default=MAX_MINUTES)
    parser.add_argument("--poll-seconds", type=float, default=POLL_SECONDS)
    args = parser.parse_args(argv)
    start = clock()
    quiet_since = None
    answer = "go"
    while True:
        try:
            live = newest_build(feed(args.feed))
        except Exception as error:  # noqa: BLE001 - an unreadable feed never skips
            print(f"could not read {args.feed} ({error!r})")
            live = None
        try:
            next_head, tip = ref(args.repo, "nightly-next"), ref(args.repo, "feat-cmux-next")
        except Exception as error:  # noqa: BLE001 - an unreadable ref reads as quiet
            print(f"could not read nightly-next or feat-cmux-next ({error!r})")
            next_head = tip = ""
        look = verdict(args.build, live, next_head, tip)
        now = clock()
        if look == "skip":
            answer = "skip"
            break
        if look == "quiet":
            quiet_since = quiet_since or now
            if (now - quiet_since).total_seconds() / 60 >= args.quiet_minutes:
                answer = "go"
                break
        else:
            quiet_since = None
        if (now - start).total_seconds() / 60 >= args.max_minutes:
            answer = "go"
            break
        sleep(args.poll_seconds)
    waited = (clock() - start).total_seconds() / 60
    if answer == "skip":
        print(f"the feed serves a newer build than {args.build} after {waited:.0f} min; its deltas are skipped")
    else:
        print(f"the deltas of {args.build} take the signer after {waited:.0f} min")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"skip={'true' if answer == 'skip' else 'false'}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
