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
    ("republish-nightly-deltas", "release-${{ needs.published-build.outputs.track == 'nightly-next' && 'deltas' || 'publish' }}-"
                                 "${{ needs.published-build.outputs.release_tag }}"),
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
if "needs.published-build.outputs.publish_result == 'success'" not in notes_publish:
    failures.append("publish-release-notes must require a successful NEXT publication")

# A loop run's tail after the GitHub release runs in its own dispatched run (nightly_next_post_publish), so it
# never holds the one nightly-next push group (#36111): run 41982716550 published at 08:42Z and its comments
# (247 PRs, 40 min) kept the next push waiting, and the deltas and notes held it 17-35 min more
# (tests/test_nightly_next_tail_off_push_group.py). In that run decide skips, and only published-build and the
# jobs after the feed can start; every build, sign and publish job is skipped because a job it needs was. The
# GitHub release and dSYMs may start there too, and skip on the record's cross_run (the loop run wrote them).
def post_publish_runnable() -> list[str]:
    import yaml

    jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
    status_check = re.compile(r"\b(?:always|cancelled|failure|success)\s*\(")

    def conjuncts(cond: str) -> list[str]:
        cond = cond.strip()
        if cond.startswith("${{") and cond.endswith("}}"):
            cond = cond[3:-2].strip()
        parts, depth, start = [], 0, 0
        for index, char in enumerate(cond):
            depth += char == "("
            depth -= char == ")"
            if depth == 0 and cond.startswith("&&", index):
                parts.append(cond[start:index])
                start = index + 2
        return [part.strip() for part in parts + [cond[start:]]]

    def unwrap(term: str) -> str:
        while term.startswith("(") and term.endswith(")") and conjuncts(term[1:-1]) == [term[1:-1].strip()]:
            term = term[1:-1].strip()
        return term

    def requires_a_skipped_job(term: str, skipped: set[str]) -> bool:
        """The term holds only if one of the skipped jobs ran: needs.<job>.result or an output equals a non-empty value."""
        alternatives = [alt.strip() for alt in unwrap(term).split("||")]
        found = [re.fullmatch(r"needs\.([A-Za-z0-9_-]+)\.(?:result|outputs\.[A-Za-z0-9_]+) == '[^']+'", alt)
                 for alt in alternatives]
        return all(found) and all(match.group(1) in skipped for match in found)

    def requires_another_input(term: str) -> bool:
        """A dispatch input other than nightly_next_post_publish must be set; the post-publish dispatch sets none."""
        term = unwrap(term)
        return bool(re.fullmatch(r"inputs\.(?!nightly_next_post_publish\b)[a-z_]+ != ''", term)
                    or re.fullmatch(r"\(inputs\.[a-z_]+ \|\| '[a-z]+'\) != '[a-z]+'", term))

    skipped: set[str] = set()
    runnable: list[str] = []
    pending = dict(jobs)
    while pending:
        progressed = False
        for name, spec in list(pending.items()):
            needed = spec.get("needs") or []
            needed = [needed] if isinstance(needed, str) else needed
            if any(need in pending for need in needed):
                continue
            del pending[name]
            progressed = True
            cond = str(spec.get("if", ""))
            terms = conjuncts(cond) if cond else []
            if name in ("decide", "runner-preflight"):  # the same if: (test_nightly_runner_preflight.py)
                ok = "inputs.nightly_next_post_publish == ''" in cond
            elif not needed:
                ok = any(requires_another_input(term) for term in terms)
            elif not status_check.search(cond):
                ok = any(need in skipped for need in needed)  # GitHub's implicit success() skips it
            else:
                ok = any(requires_a_skipped_job(term, skipped) for term in terms)
            if ok:
                skipped.add(name)
            else:
                runnable.append(name)
        if not progressed:
            raise AssertionError(f"needs cycle among {sorted(pending)}")
    return runnable


POST_PUBLISH_JOBS = ["published-build", "publish-nightly-next-github", "keep-published-dsyms", "build-nightly-deltas", "generate-nightly-deltas",
                     "republish-nightly-deltas", "published-in", "sign-release-notes", "publish-release-notes",
                     "publish-nightly-reel", "sentry-dsyms-nightly", "report-nightly-failure", "close-nightly-failure-issue"]
runnable = post_publish_runnable()
if sorted(runnable) != sorted(POST_PUBLISH_JOBS):
    failures.append(f"a nightly_next_post_publish run must start only {POST_PUBLISH_JOBS}, not {runnable}")
published_in = job("published-in")
if "needs.published-build.outputs.comment == 'true'" not in published_in:
    failures.append("published-in must comment only on a new build of the run that published (comment)")
# The comments must not hold the mini while the whole-Mac publish jobs of the same run wait.
for trusted in ("publish-nightly-next-github", "generate-nightly-deltas", "republish-nightly-deltas"):
    if trusted not in needs(published_in):
        failures.append(f"published-in must wait for {trusted}: the comments must not hold the mini "
                        "while the whole-Mac publishing waits")
# The loop run dispatches the tail once its GitHub release is written; the dispatched run never dispatches again.
dispatch = job("dispatch-published-in") if "\n  dispatch-published-in:\n" in TEXT else ""
if "-f nightly_next_post_publish=" not in dispatch or "actions: write" not in dispatch \
        or "publish-nightly-next-github" not in needs(dispatch):
    failures.append("dispatch-published-in must dispatch nightly.yml with nightly_next_post_publish after the GitHub release")
if "needs.published-build.outputs.run_tail == 'true'" not in published_in:
    failures.append("published-in must comment only where the tail runs (run_tail), never in a loop run")

# The release's mutable names (rolling DMG, feed copy, body, tag) are steps of the upload job, not a job of their
# own: a second whole-Mac claim cost run 42018687632 a second set-up, token and variant download, and let the
# 12-min deltas job take cmux15 first, so the names moved 40 min after the feed. The writes keep what the names
# job's group gave: one writer at a time across runs, push or dispatch (an R2 lease of their own, which never
# cancels a waiter), and each write first runs still-newest, so no older build writes over a newer one's names.
def publish_steps() -> list[dict]:
    import yaml

    return yaml.safe_load(WORKFLOW.read_text())["jobs"]["publish-nightly-next-github"]["steps"]


if "\n  publish-nightly-next-github-names:\n" in TEXT:
    failures.append("the rolling names must be steps of publish-nightly-next-github, not a second whole-Mac job")
else:
    steps = publish_steps()
    names = [str(step.get("name", "")) for step in steps]

    def at(name: str) -> int:
        return names.index(name) if name in names else -1

    upload, order = at("Publish nightly-next release assets"), at("Check this build is still the feed's newest")
    writes = {
        "Take the release names lease": "steps.order.outputs.newest == 'true'",
        "Take the published feed": "steps.names_lease.outcome == 'success'",
        "Install the feed order check": "steps.names_lease.outcome == 'success'",
        "Publish the rolling DMG name and the feed copy": "steps.names_lease.outcome == 'success'",
        "Record the published build in the release body": "steps.publish_names.outputs.newest == 'true'",
        "Move the nightly-next tag to the published build": "steps.publish_names.outputs.newest == 'true'",
    }
    for name, gate in writes.items():
        index = at(name)
        if not 0 <= upload < order < index:
            failures.append(f"{name!r} must follow the immutable upload and the still-newest check")
            continue
        step = steps[index]
        if gate not in str(step.get("if", "")):
            failures.append(f"{name!r} must run only when {gate}")
        # A failed names write never turns the immutable publication red.
        if step.get("continue-on-error") is not True:
            failures.append(f"{name!r} must continue on error: the immutable assets are already published")
    lock, unlock = at("Take the release names lease"), at("Release the release names lease")
    lease_runs = [str(steps[i].get("run", "")) if i >= 0 else "" for i in (lock, unlock)]
    if not (0 <= lock < at("Take the published feed") and at("Move the nightly-next tag to the published build") < unlock
            and lease_runs[0].endswith("publish-lease.sh lock") and lease_runs[1].endswith("publish-lease.sh unlock")):
        failures.append("the names writes must run inside their own R2 lease (publish-lease.sh lock ... unlock)")
    else:
        key = steps[lock].get("env", {}).get("LEASE_KEY")
        if key != "nightly-next/locks/github-names.json" or steps[unlock].get("env") != steps[lock].get("env"):
            failures.append(f"the names lease must take and release nightly-next/locks/github-names.json, not {key}")
        if steps[unlock].get("if") != "always() && steps.names_lease.outcome != 'skipped'":
            failures.append("the names lease must be released whatever the writes did")
    for script in ("github-names-publish-rolling-name", "github-names-record-release-body", "github-names-move-tag"):
        body = (ROOT / "scripts" / "ci" / "nightly-steps" / f"{script}.sh").read_text()
        check_at = body.find('"$RUNNER_TEMP/still-newest"')
        writers = [body.find(writer) for writer in ("publish-release-assets.py", "finalize-release.py",
                                                     "update-release-tag.py")]
        write_at = min((i for i in writers if i >= 0), default=-1)
        if not 0 <= check_at < write_at:
            failures.append(f"{script}.sh must run still-newest before it writes")
    if "    concurrency:\n" in job("publish-nightly-next-github"):
        failures.append("publish-nightly-next-github takes no group: a newer run must never replace its uploads")
    # Only the source archive reads the build's tree; the 2-min full checkout runs only for it.
    archive_if = next((str(step.get("if", "")) for step in steps
                       if step.get("name") == "Publish the cmux-next source archive"), None)
    checkout_if = next((str(step.get("if", "")) for step in steps if step.get("name") == "Checkout publish ref"), "")
    if not archive_if or checkout_if != archive_if:
        failures.append("Checkout publish ref must run only when the source archive step runs")

if failures:
    print("FAIL: NEXT post-publication dependency contract\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: NEXT post-publication dependency contract")
