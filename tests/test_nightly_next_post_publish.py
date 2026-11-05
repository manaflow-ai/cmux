#!/usr/bin/env python3
"""The post-publication writers follow the one feed's publication.

nightly-next signs each build once, as cmux NIGHTLY (hq#7156; Leo, 2026-11-05:
"THERE SHOULDN'T BE 2"): no compatibility signer runs before or after
``publish-nightly``. The release notes and the delta republish write only while
the live feed still serves the build they describe.
"""

import re
import sys
from pathlib import Path
from nightly_workflow_text import nightly_text

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
TEXT = nightly_text()


def job(name: str) -> str:
    start = TEXT.index(f"  {name}:\n")
    match = re.search(r"^  [A-Za-z0-9_-]+:", TEXT[start + 4 :], re.MULTILINE)
    end = len(TEXT) if match is None else start + 4 + match.start()
    return TEXT[start:end]


def needs(job_text: str) -> str:
    match = re.search(r"^    needs: (.+)$", job_text, re.MULTILINE)
    return "" if match is None else match.group(1)


failures = []
publish = job("publish-nightly")
publish_needs = needs(publish)
# The second signing's jobs are gone: nothing re-signs a build for another feed.
for gone in ("legacy-identity-target", "sign-nightly-identity-legacy", "verify-nightly-identity-legacy",
             "publish-nightly-identity-legacy", "nightly-identity-legacy-published"):
    if f"\n  {gone}:\n" in TEXT or gone in publish_needs:
        failures.append(f"{gone} signs or publishes a second copy of the build")
notes_publish = job("publish-release-notes")
# The tag moves after the feed (publish-nightly-next-github), so the live feed is the check:
# `!=`, a newer build is live or this one was pulled.
if "id: current" not in notes_publish or "git/ref/tags/$RELEASE_TAG" in notes_publish:
    failures.append("publish-release-notes must check the live feed, not the tag that moves after it")
if "appcast-arm64.xml" not in notes_publish or "EXPECTED_BUILD" not in notes_publish or "live_build != EXPECTED_BUILD" not in notes_publish:
    failures.append("publish-release-notes must skip unless the live NEXT appcast serves this build")
delta = job("republish-nightly-deltas")
# `!=`, not `>`: a newer build may be live, or nightly-next-rollback.yml pulled this one (#21887).
if "CHANNEL_FEED_BASE/appcast-arm64.xml" not in delta or "live_build != NIGHTLY_BUILD" not in delta:
    failures.append("republish-nightly-deltas must skip unless the live NEXT appcast still serves this build")
if "if: steps.current.outputs.current == 'true'" not in notes_publish:
    failures.append("publish-release-notes must skip stale notes after a newer publication")
# Notes keep the publish lock (their writes have no compare-and-swap): publish-nightly's R2 lease,
# taken before the live feed is read and released last (tests/test_nightly_delivery_concurrency.py).
if ("    concurrency:\n" in notes_publish
        or notes_publish.find("publish-lease.sh lock") < 0
        or not notes_publish.find("publish-lease.sh lock") < notes_publish.find("id: current")
        or "env: *next-publish-lease" not in notes_publish):
    failures.append("publish-release-notes must hold publish-nightly's R2 lease, in no concurrency group")
for writer, group in (
    # nightly-next: its own group (the feed write is a compare-and-swap); classic and RC keep the publish lock.
    ("republish-nightly-deltas", "release-${{ needs.decide.outputs.track == 'nightly-next' && 'deltas' || 'publish' }}-"
                                 "${{ needs.decide.outputs.release_tag }}"),
):
    writer_text = job(writer)
    if "    concurrency:\n" not in writer_text:
        failures.append(f"{writer} must serialize its mutable publication writes")
    # Never publish-nightly's group on nightly-next: a queued writer would replace a waiting publish.
    if f"group: {group}" not in writer_text:
        failures.append(f"{writer} must serialize in the group {group}")
if "write-feed --feed \"$feed\" --same-build" not in job("republish-nightly-deltas"):
    failures.append("republish-nightly-deltas must write the nightly-next feed only by compare-and-swap (--same-build)")
    if "cancel-in-progress: false" not in writer_text:
        failures.append(f"{writer} must let an in-flight publication finish")
if "publish-nightly.result == 'success'" not in notes_publish:
    failures.append("publish-release-notes must require a successful NEXT publication")

if failures:
    print("FAIL: NEXT post-publication dependency contract\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: NEXT post-publication dependency contract")
