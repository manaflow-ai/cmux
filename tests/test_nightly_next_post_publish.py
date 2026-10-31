#!/usr/bin/env python3
"""Keep NEXT feed publication independent of the compatibility identity.

The signed arm64 artifact is the user-facing readiness boundary. The
NIGHTLY-identity compatibility lane runs after the NEXT publication; it must
not become a dependency of ``publish-nightly``.
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
compatibility_jobs = ("legacy-identity-target",)

for post_job in compatibility_jobs:
    if post_job in publish_needs:
        failures.append(f"publish-nightly must not wait for post-publication job {post_job}")
    post = job(post_job)
    if "prepare-nightly-variant" not in needs(post):
        failures.append(f"{post_job} must wait for the prepared NEXT artifact")
    if "publish-nightly" not in needs(post):
        failures.append(f"{post_job} must run after the primary NEXT publication")
legacy = job("legacy-identity-target")
if "build-nightly-app" not in needs(legacy):
    failures.append("legacy identity targeting must know the current build number")
if "CURRENT_BUILD_READY" not in legacy or "--candidate-build" not in legacy:
    failures.append("legacy identity targeting must admit the current signed artifact")
if "CURRENT_BUILD_SHA" not in legacy or "source_sha=$source_sha" not in legacy:
    failures.append("legacy identity targeting must carry the current build commit into parallel signing")
if "verify_remote_daemon_release.py" not in job("sign-nightly-identity-legacy") or "cmux-nightly-remote-daemon" not in job("sign-nightly-identity-legacy"):
    failures.append("parallel identity signing must embed the verified remote daemon manifest")
if 'accepted build $pending_build is not on the live cmux NEXT Nightly feed' not in legacy:
    failures.append("legacy identity continuation must require live NEXT feed membership")
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
for writer, group in (
    # Notes keep the publish lock: their writes have no compare-and-swap.
    ("publish-release-notes", "release-publish-${{ needs.decide.outputs.release_tag }}"),
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
for downstream in ("sign-nightly-identity-legacy", "verify-nightly-identity-legacy", "publish-nightly-identity-legacy"):
    downstream_needs = needs(job(downstream))
    if "legacy-identity-target" not in downstream_needs:
        failures.append(f"{downstream} must remain downstream of legacy-identity-target")
if "publish-nightly" not in needs(job("publish-nightly-identity-legacy")):
    failures.append("legacy identity publication must wait for successful NEXT publication")
legacy_publish = job("publish-nightly-identity-legacy")
pause_exemption = "needs.decide.outputs.notary_paused != 'true' || needs.legacy-identity-target.outputs.action == 'continue'"
if pause_exemption not in job("sign-nightly-identity-legacy"):
    failures.append("parallel identity signing must honor the notary pause except for accepted continuations")
if pause_exemption not in legacy_publish:
    failures.append("parallel identity publication must honor the notary pause except for accepted continuations")
if "needs.publish-nightly.outputs.refused != 'true'" not in legacy_publish:
    failures.append("legacy identity publication must stop when NEXT publication was refused")
if "needs.publish-nightly.outputs.build == needs.legacy-identity-target.outputs.build" not in legacy_publish:
    failures.append("legacy identity publication must match the exact NEXT build selected for the compatibility feed")
if "needs.publish-nightly.result == 'skipped' && needs.legacy-identity-target.outputs.action == 'continue'" not in legacy_publish:
    failures.append("legacy identity continuation must remain available when publish-nightly is intentionally skipped")
# Run 41126559170 (2026-10-30): the rescue's full re-runs skipped publish-nightly (the build was already on the
# NEXT feed), so a legacy sign there could never publish. A target from the live feed publishes from any run.
if "|| needs.legacy-identity-target.outputs.source_run == '')" not in legacy_publish:
    failures.append("a legacy target from the live NEXT feed (source_run empty) must publish whatever this run's publish-nightly did")

if failures:
    print("FAIL: NEXT post-publication dependency contract\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: NEXT post-publication dependency contract")
