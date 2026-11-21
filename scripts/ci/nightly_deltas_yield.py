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
- nightly-next is no longer the commit the feed serves (its item's cmux:sourceCommit): a promoted build is on its
  way to the signer (86dc299b's run was created at 04:34:04, its nightly-next-one asked for the signer at
  04:36:52): wait, and skip once it publishes;
- feat-cmux-next has moved past nightly-next: a promotion and its build are on their way to the signer: wait;
- nightly-next has the tip and is the build the feed serves for QUIET_MINUTES: go.

After MAX_MINUTES it goes anyway; an unreadable feed or ref does not skip. It reads only the public feed and
`git ls-remote`, no API budget (tests/test_ci_no_github_token_polling.py). Nothing is cancelled.

The two waits hold only while one Mac signs (--signers 1). Since 2026-11-12 two do (Leo, hq#10366: "ultra1 signs
the nightly too, cmux15 stays ready as the standby signer"), and the loop builds one nightly at a time, so the
build in flight holds one and the deltas usually take the other: with --signers 2 or more only the newer-build
skip is left. A build can still wait for the deltas (about 10 min of the keyed job) when another signing job, such
as the classic nightly, holds the second Mac, or when the run's signer pick (pick-nightly-sign-runner, made at the
run's start) pinned the deltas to the Mac the next build then takes; deltas, at 10x smaller updates, are worth
that. One-mini mode (CI_NIGHTLY_MINI) has one signer, so the workflow passes 1 there. The waits never ended in a
busy loop (a landing every few minutes keeps feat-cmux-next past nightly-next, and the next build publishes
before the loop is quiet): run 44023631489 waited 33 min and skipped, and 6 of the
8 published builds before it (2026-11-16 21:14Z to 2026-11-17 05:22Z) skipped their deltas, so the feed served
231 MB full DMGs where the delta from the build before was 15-24 MB. NIGHTLY_NEXT_SIGNERS=1 (a repository
variable) puts the waits back while a signer is out.

usage: nightly_deltas_yield.py --repo OWNER/NAME --build N --feed URL [--signers 2] [--quiet-minutes 2]
       [--max-minutes 40]
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
from pathlib import Path

# Run as a file (python3 .publish-tooling/scripts/ci/nightly_deltas_yield.py): its own directory holds deadline_http.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402

QUIET_MINUTES = 2.0
MAX_MINUTES = 40.0
POLL_SECONDS = 30.0


def newest_item(feed_xml: str) -> tuple[int | None, str]:
    """The feed's first item (the build it serves): its sparkle:version (None when unreadable) and its
    cmux:sourceCommit ("" when absent)."""
    try:
        root = ET.fromstring(feed_xml)
    except ET.ParseError:
        return None, ""
    for item in root.iter():
        if item.tag.rsplit("}", 1)[-1] != "item":
            continue
        build, commit = None, ""
        for child in item:
            name, text = child.tag.rsplit("}", 1)[-1], (child.text or "").strip()
            if name == "version" and text.isdigit() and build is None:
                build = int(text)
            elif name == "sourceCommit" and len(text) == 40:
                commit = text
        return build, commit
    return None, ""


def newest_build(feed_xml: str) -> int | None:
    """The sparkle:version of the feed's first item (the build it serves), None when unreadable."""
    return newest_item(feed_xml)[0]


def verdict(build: int, live: int | None, next_head: str, tip: str, live_commit: str = "", signers: int = 1) -> str:
    """'skip', 'wait' or 'quiet' for this build's deltas at one look. With a second signer the build in flight
    never waits for the deltas, so only a newer build on the feed matters."""
    if live is not None and live > build:
        return "skip"
    if signers >= 2:
        return "quiet"
    if live == build and live_commit and next_head and next_head != live_commit:
        return "wait"
    if next_head and tip and next_head != tip:
        return "wait"
    return "quiet"


def read_feed(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "cmux-delta-yield/1"})
    _, body, _ = deadline_http.request(request, 30, raise_errors=True)
    return body.decode("utf-8", "replace")


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
    parser.add_argument("--signers", type=int, default=1,
                        help="Macs that carry the nightly-next signing label; with 2 or more the deltas "
                             "do not wait for the loop")
    parser.add_argument("--quiet-minutes", type=float, default=QUIET_MINUTES)
    parser.add_argument("--max-minutes", type=float, default=MAX_MINUTES)
    parser.add_argument("--poll-seconds", type=float, default=POLL_SECONDS)
    args = parser.parse_args(argv)
    start = clock()
    quiet_since = None
    answer = "go"
    while True:
        try:
            live, live_commit = newest_item(feed(args.feed))
        except Exception as error:  # noqa: BLE001 - an unreadable feed never skips
            print(f"could not read {args.feed} ({error!r})")
            live, live_commit = None, ""
        try:
            # Two signers decide on the feed alone.
            next_head, tip = ("", "") if args.signers >= 2 else (ref(args.repo, "nightly-next"),
                                                                  ref(args.repo, "feat-cmux-next"))
        except Exception as error:  # noqa: BLE001 - an unreadable ref reads as quiet
            print(f"could not read nightly-next or feat-cmux-next ({error!r})")
            next_head = tip = ""
        look = verdict(args.build, live, next_head, tip, live_commit, args.signers)
        now = clock()
        if look == "quiet" and args.signers >= 2:
            break
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
