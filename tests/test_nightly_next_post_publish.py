#!/usr/bin/env python3
"""Keep NEXT feed publication independent of slow post-publication checks.

The signed arm64 feed is the user-facing readiness boundary.  macOS 15 launch
coverage and the NIGHTLY-identity compatibility lane consume that publication
and may run for much longer (or fail independently); neither may become a
dependency of ``publish-nightly``.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
TEXT = WORKFLOW.read_text(encoding="utf-8")


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
post_jobs = ("nightly-next-macos15-launch", "legacy-identity-target")

for post_job in post_jobs:
    if post_job in publish_needs:
        failures.append(f"publish-nightly must not wait for post-publication job {post_job}")
    post = job(post_job)
    if "publish-nightly" not in needs(post):
        failures.append(f"{post_job} must depend on publish-nightly")
    if post_job == "nightly-next-macos15-launch" and "publish-nightly.result == 'success'" not in post:
        failures.append(f"{post_job} must require a successful NEXT publication")

macos15 = job("nightly-next-macos15-launch")
if "continue-on-error: true" not in macos15:
    failures.append("macOS 15 launch coverage must remain advisory after publication")
# A release build keeps Chromium's cookie key in the login keychain. With HOME
# pointed at an empty directory there is no default keychain: the key's
# SecItemAdd raises the "keychain not found" dialog, nobody answers it on a
# runner, and the Chromium tab never loads (every run from 2026-10-17 to
# 2026-10-18). The probe runs as the runner's own user, as on the Tart VMs.
if re.search(r"(?:^|[\s;])(?:export\s+|env\s+)?HOME=|^\s+HOME:\s", macos15, re.MULTILINE):
    failures.append("macOS 15 launch must run the probe with the runner's HOME: a scratch HOME has no login keychain")

legacy = job("legacy-identity-target")
if "publish-release-notes" not in needs(legacy):
    failures.append("legacy identity targeting must wait for signed NEXT release notes")
notes_publish = job("publish-release-notes")
if "id: current" not in notes_publish or "git/ref/tags/$RELEASE_TAG" not in notes_publish:
    failures.append("publish-release-notes must recheck the exact release tag before uploading")
if "appcast-arm64.xml" not in notes_publish or "EXPECTED_BUILD" not in notes_publish or "live_build > EXPECTED_BUILD" not in notes_publish:
    failures.append("publish-release-notes must skip when a newer NEXT appcast is already live")
delta = job("republish-nightly-deltas")
# `!=`, not `>`: a newer build may be live, or nightly-next-rollback.yml pulled this one (#21887).
if "CHANNEL_FEED_BASE/appcast-arm64.xml" not in delta or "live_build != NIGHTLY_BUILD" not in delta:
    failures.append("republish-nightly-deltas must skip unless the live NEXT appcast still serves this build")
if "if: steps.current.outputs.current == 'true'" not in notes_publish:
    failures.append("publish-release-notes must skip stale notes after a newer publication")
for writer in ("publish-release-notes", "republish-nightly-deltas"):
    writer_text = job(writer)
    if "    concurrency:\n" not in writer_text:
        failures.append(f"{writer} must serialize its mutable publication writes")
    if "group: release-publish-${{ needs.decide.outputs.release_tag }}" not in writer_text:
        failures.append(f"{writer} must share publish-nightly's channel publication lock")
    if "cancel-in-progress: false" not in writer_text:
        failures.append(f"{writer} must let an in-flight publication finish")
if "publish-nightly.result == 'success'" not in notes_publish:
    failures.append("publish-release-notes must require a successful NEXT publication")
for downstream in ("sign-nightly-identity-legacy", "verify-nightly-identity-legacy", "publish-nightly-identity-legacy"):
    downstream_needs = needs(job(downstream))
    if "legacy-identity-target" not in downstream_needs:
        failures.append(f"{downstream} must remain downstream of legacy-identity-target")

if failures:
    print("FAIL: NEXT post-publication dependency contract\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: NEXT post-publication dependency contract")
