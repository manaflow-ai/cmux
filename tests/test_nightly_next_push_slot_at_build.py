#!/usr/bin/env python3
"""A nightly-next loop run holds the push slot only while its nightly-next-one job builds and publishes.

With the one job on (vars.NIGHTLY_NEXT_ONE_JOB), the push serialization is nightly-next-one's own concurrency
group (nightly-next-one-push), not the workflow-level nightly-build-nightly-next-push group. The workflow-level
group held a loop run's whole post-feed tail (published-build, keep-published-dsyms, publish-nightly-next-github,
dispatch-published-in), 5-10 min after the feed write, and the next landing waited behind it: holder 43581845419
(feed 10:09:17Z, ended 10:19:08Z) delayed 43584856901, holder 43605506661 (feed 14:57:49Z, ended 15:02:43Z) delayed
43608103300; 22.1 and 23.9 min from landing to run created.

- With the one job on, a push run and the loop's retry are run-scoped at the workflow level, and nightly-next-one
  takes nightly-next-one-push (never cancel-in-progress). With it off, the workflow-level push group is as before.
- The next run's notes and PR-comment span come from the live feed's newest cmux:sourceCommit (written inside
  nightly-next-one), not only from the release body and tag the previous run's tail writes after it: the next
  run's decide can now run before that tail is done.
- nightly-next-one's end asks main's tick at once (wake-nightly-next-tick), since the tick's workflow_run trigger
  fires only when the whole run ends.

Manual lane (Lawrence 2026-10-23: no new CI tests): python3 tests/test_nightly_next_push_slot_at_build.py.
"""
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import gh_expressions  # noqa: E402
import workflow_jobs  # noqa: E402
from test_ci_fork_runner_routing import parse_expression  # noqa: E402
from test_nightly_trusted_routing import evaluate  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
DOC = yaml.safe_load(WORKFLOW.read_text())
JOBS = DOC["jobs"]
ONE = JOBS.get("nightly-next-one") or {}
NOTES_SCRIPT = ROOT / "scripts" / "ci" / "nightly-steps" / "publish-prepare-release-notes.sh"
failures: list[str] = []


def substitute(text: str, context: dict) -> str:
    return gh_expressions.EXPRESSION.sub(lambda m: str(evaluate(parse_expression(m[1]), context)), text)


def context(event: str = "push", one_job: str = "on", **extra) -> dict:
    return {"github.ref_name": "nightly-next", "github.ref": "refs/heads/nightly-next", "github.event_name": event,
            "github.run_id": "43608103300", "vars.NIGHTLY_NEXT_ONE_JOB": one_job, **extra}


RETRY = {"inputs.nightly_next_loop_retry": "1"}
top = str(DOC.get("concurrency", {}).get("group", ""))
# The one job on: the run itself holds nothing shared; its nightly-next-one does.
for name, ctx in (("a push run", context()), ("the loop's retry", context("workflow_dispatch", **RETRY))):
    group = substitute(top, ctx)
    if group != "nightly-build-nightly-next-run-43608103300":
        failures.append(f"with the one job on, {name} must be run-scoped at the workflow level, got {group!r}")
# The one job off (the split jobs build): the workflow-level push group serializes them, as before.
for name, ctx in (("a push run", context(one_job="")), ("the loop's retry", context("workflow_dispatch", "", **RETRY))):
    group = substitute(top, ctx)
    if group != "nightly-build-nightly-next-push":
        failures.append(f"with the one job off, {name} must keep the workflow-level push group, got {group!r}")
if substitute(top, context("workflow_dispatch", inputs__x="") | {"inputs.nightly_next_sign_stage": "true"}) \
        != "nightly-build-nightly-next-sign":
    failures.append("a sign stage keeps the sign group")
if DOC.get("concurrency", {}).get("cancel-in-progress") is not False:
    failures.append("the workflow-level group never cancels in progress")

one_concurrency = ONE.get("concurrency") or {}
one_group = str(one_concurrency.get("group", ""))
if one_concurrency.get("cancel-in-progress") is not False:
    failures.append("nightly-next-one's group must never cancel a started build (cancel-in-progress: false)")
for name, ctx in (("a push run", context()), ("the loop's retry", context("workflow_dispatch", **RETRY))):
    group = substitute(one_group, ctx)
    if group != "nightly-next-one-push":
        failures.append(f"{name}'s nightly-next-one must take the push slot nightly-next-one-push, got {group!r}")
other = substitute(one_group, {**context("workflow_dispatch"), "github.ref": "refs/heads/main", "github.ref_name": "main"})
if other != "nightly-next-one-43608103300":
    failures.append(f"any other run's nightly-next-one stays run-scoped, got {other!r}")

# The published commit the next run's notes start from: the live feed's, read inside nightly-next-one.
outputs = ONE.get("outputs") or {}
if "steps.notes.outputs.published_sha" not in str(outputs.get("published_sha", "")):
    failures.append("nightly-next-one must output the published commit its notes started from (published_sha)")
notes_step = next((s for s in ONE.get("steps", []) if s.get("id") == "notes"), None)
if notes_step is None:
    failures.append("nightly-next-one has no notes step")
notes_text = NOTES_SCRIPT.read_text()
if "nightly_version.py\" published-source" not in notes_text or "--base" not in notes_text \
        or "published_sha=" not in notes_text:
    failures.append("the notes step must read the live feed's published source (nightly_version.py published-source), "
                    "pass it to nightly_release_notes.py --base and output published_sha")

# nightly_version.py published-source: the newest item's cmux:sourceCommit.
FEED = """<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:cmux="https://cmux.com/xml-namespaces/cmux">
<channel>
<item><sparkle:version>4358485690101</sparkle:version><cmux:sourceCommit>{old}</cmux:sourceCommit></item>
<item><sparkle:version>4360550666101</sparkle:version><cmux:sourceCommit>{new}</cmux:sourceCommit></item>
</channel></rss>
"""
with tempfile.TemporaryDirectory() as work:
    feed = Path(work) / "appcast-arm64.xml"
    feed.write_text(FEED.format(old="a" * 40, new="b" * 40))
    proc = subprocess.run([sys.executable, str(ROOT / "scripts/ci/nightly_version.py"), "published-source",
                           "--feed", str(feed)], capture_output=True, text=True)
    if proc.returncode != 0 or proc.stdout.strip() != "b" * 40:
        failures.append(f"published-source must print the newest item's source commit, got {proc.returncode} "
                        f"{proc.stdout!r} {proc.stderr[-300:]!r}")
    feed.write_text(FEED.format(old="a" * 40, new="b" * 40).replace("<cmux:sourceCommit>" + "b" * 40
                                                                    + "</cmux:sourceCommit>", ""))
    proc = subprocess.run([sys.executable, str(ROOT / "scripts/ci/nightly_version.py"), "published-source",
                           "--feed", str(feed)], capture_output=True, text=True)
    if proc.returncode != 0 or proc.stdout.strip() != "":
        failures.append(f"a newest item without a source prints nothing (the caller falls back), got "
                        f"{proc.returncode} {proc.stdout!r}")
proc = subprocess.run([sys.executable, str(ROOT / "scripts/ci/nightly_release_notes.py"), "--help"],
                      capture_output=True, text=True)
if "--base" not in proc.stdout:
    failures.append("nightly_release_notes.py must take --base (the published commit read from the feed)")

# The record the dispatched tail reads (PR comments, signed notes) takes the same published commit.
spec = importlib.util.spec_from_file_location("nightly_published_build", ROOT / "scripts/ci/nightly_published_build.py")
published = importlib.util.module_from_spec(spec)
spec.loader.exec_module(published)
needs = {"decide": {"result": "success", "outputs": {"track": "nightly-next", "published_sha": "a" * 40}},
         "nightly-next-one": {"result": "success", "outputs": {"build_sha": "c" * 40, "published_sha": "b" * 40}}}
rec = published.record(needs, "1", "1", "c" * 40)
if rec.get("published_sha") != "b" * 40:
    failures.append(f"the record must take nightly-next-one's published_sha over decide's, got {rec.get('published_sha')}")
needs["nightly-next-one"]["outputs"]["published_sha"] = ""
if published.record(needs, "1", "1", "c" * 40).get("published_sha") != "a" * 40:
    failures.append("with no published_sha from nightly-next-one the record keeps decide's")

# nightly-next-one's end wakes main's tick, which promotes the newest buildable commit then.
wake = JOBS.get("wake-nightly-next-tick")
if wake is None:
    failures.append("no wake-nightly-next-tick job asks main's tick when nightly-next-one ends")
else:
    wake_needs = wake.get("needs") or []
    wake_needs = [wake_needs] if isinstance(wake_needs, str) else list(wake_needs)
    if "nightly-next-one" not in wake_needs:
        failures.append("wake-nightly-next-tick must need nightly-next-one")
    for late in ("published-build", "publish-nightly-next-github", "keep-published-dsyms", "dispatch-published-in"):
        if late in wake_needs:
            failures.append(f"wake-nightly-next-tick must not wait for {late}: the tail holds no slot")
    cond = str(wake.get("if", ""))
    for term in ("always()", "needs.decide.outputs.one_job == 'true'", "needs.nightly-next-one.result != 'skipped'",
                 "github.ref == 'refs/heads/nightly-next'"):
        if term not in cond:
            failures.append(f"wake-nightly-next-tick runs after every loop run's nightly-next-one ({term})")
    if (wake.get("permissions") or {}).get("actions") != "write":
        failures.append("wake-nightly-next-tick dispatches a workflow: it needs actions: write")
    runs = " ".join(str(s.get("run", "")) for s in wake.get("steps", []))
    if "gh workflow run nightly-next-tick.yml" not in runs or "--ref main" not in runs:
        failures.append("wake-nightly-next-tick must dispatch nightly-next-tick.yml on main")
    if "-f sha=" in runs:
        failures.append("wake-nightly-next-tick asks with no sha, so the tick applies its rolling rule")
    runs_on = workflow_jobs.single_runs_on(wake)
    if "blacksmith" in runs_on.lower() or "CI_NIGHTLY_MINI" not in runs_on:
        failures.append("wake-nightly-next-tick runs on the nightly mini, as the other loop control jobs")

if failures:
    print("FAIL: nightly-next push slot at nightly-next-one\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly-next push slot at nightly-next-one")
