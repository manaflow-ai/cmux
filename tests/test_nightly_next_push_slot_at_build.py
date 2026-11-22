#!/usr/bin/env python3
"""A nightly-next loop run holds the push slot only while its nightly-next-one job builds and publishes.

With the one job on (vars.NIGHTLY_NEXT_ONE_JOB), the push serialization is nightly-next-one's own concurrency
group (nightly-next-one-push), not the workflow-level nightly-build-nightly-next-push group. The workflow-level
group held a loop run's whole post-feed tail (published-build, keep-published-dsyms, publish-nightly-next-github,
dispatch-published-in), 5-10 min after the feed write, and the next landing waited behind it: holder 43581845419
(feed 10:09:17Z, ended 10:19:08Z) delayed 43584856901, holder 43605506661 (feed 14:57:49Z, ended 15:02:43Z) delayed
43608103300; 22.1 and 23.9 min from landing to run created.

- With the one job on, a push run and the loop's retry are run-scoped at the workflow level, and nightly-next-one
  takes nightly-next-one-push-<host> (never cancel-in-progress), host from pick-nightly-next-signer on the attempt
  that made it, else cmux15 (note-33). With it off, the workflow-level push group is as before.
  The group reads every repository variable decide's one_job reads: with NIGHTLY_NEXT_SUBMISSIONS_PAUSED=1 or
  NIGHTLY_NEXT_NOTARY_PAUSED=1 decide builds the split jobs, which the workflow-level push group alone serializes.
  The test reads decide's oneJob from its script, so a new input there fails it until the group reads it too.
- The next run's notes and PR-comment span come from the live feed's newest cmux:sourceCommit (written inside
  nightly-next-one), not only from the release body and tag the previous run's tail writes after it: the next
  run's decide can now run before that tail is done.
- nightly-next-one's end asks main's tick at once (wake-nightly-next-tick), since the tick's workflow_run trigger
  fires only when the whole run ends.

Manual lane (Lawrence 2026-10-23: no new CI tests, lifted 2026-11-18): python3 tests/test_nightly_next_push_slot_at_build.py.
"""
from __future__ import annotations

import importlib.util
import itertools
import os
import re
import subprocess
import sys
import tempfile
import time
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

# The workflow-level group and decide's one_job read the same repository variables: a push run is run-scoped only
# when its nightly-next-one runs and serializes it. With NIGHTLY_NEXT_ONE_JOB=on and either pause variable set,
# decide builds the split jobs, which only the workflow-level push group serializes (two builds at once otherwise).
DECIDE_STEP = next(s for s in JOBS["decide"]["steps"] if s.get("id") == "decide")
DECIDE_JS = str(DECIDE_STEP["with"]["script"])
DECIDE_VARS = {name: var for name, var in
               ((n, re.search(r"vars\.(\w+)", str(v))) for n, v in (DECIDE_STEP.get("env") or {}).items()) if var}
# A push run's and the loop retry's facts that decide's one_job reads (none of them a repository variable).
PUSH_FACTS = {"isNextRef": True, "track": "nightly-next", "shouldPublish": True, "notaryTest": False,
              "continueOnly": False, "unsignedResume": False, "republish": False, "fastBuild": False,
              "browserDataOut": False}
if str((DOC.get("env") or {}).get("NIGHTLY_NEXT_BROWSER_DATA_IMPORT", "")) != "full":
    failures.append("NIGHTLY_NEXT_BROWSER_DATA_IMPORT is no longer the literal 'full': decide's importPaused then "
                    "depends on it, so the workflow-level group must too (update this test with it)")


def decide_definition(name: str) -> str:
    match = re.search(rf"const {name} = (.+?);\n", DECIDE_JS)
    return match[1] if match else ""


def decide_eval(name: str, env: dict, event: str, seen: tuple = ()) -> object:
    """decide's `const NAME = ...` for a push run, read from the script: a term it does not model fails the test."""
    if name in PUSH_FACTS:
        return PUSH_FACTS[name]
    text = decide_definition(name)
    if not text or name in seen:
        raise LookupError(name)
    expr = re.sub(r"process\.env\.(\w+)", lambda m: f"env.get({m[1]!r}, '')", text)
    expr = expr.replace("context.eventName", repr(event)).replace("===", "==").replace("!==", "!=")
    expr = re.sub(r"Boolean\(", "bool(", expr).replace("&&", " and ").replace("||", " or ")
    expr = re.sub(r"!(?!=)", " not ", expr)
    names = {}
    for ident in set(re.findall(r"\b([A-Za-z_]\w*)\b", re.sub(r"'[^']*'", "", expr))) - {
            "env", "get", "bool", "and", "or", "not"}:
        names[ident] = decide_eval(ident, env, event, seen + (name,))
    return eval(expr, {"__builtins__": {}}, {"env": env, "bool": bool, **names})  # noqa: S307


def one_job_env_inputs(name: str = "oneJob", seen: set | None = None) -> set[str]:
    seen = set() if seen is None else seen
    text = decide_definition(name)
    out = set(re.findall(r"process\.env\.(\w+)", text))
    for ident in set(re.findall(r"\b([A-Za-z_]\w*)\b", re.sub(r"process\.env\.\w+|'[^']*'", "", text))):
        if ident not in seen and ident not in PUSH_FACTS and decide_definition(ident):
            seen.add(ident)
            out |= one_job_env_inputs(ident, seen)
    return out


one_job_vars = {DECIDE_VARS[n][1]: n for n in one_job_env_inputs() if n in DECIDE_VARS}
if "NIGHTLY_NEXT_ONE_JOB" not in one_job_vars:
    failures.append(f"decide's oneJob no longer reads vars.NIGHTLY_NEXT_ONE_JOB (it reads {sorted(one_job_vars)})")
for var in sorted(one_job_vars):
    if f"vars.{var}" not in top:
        failures.append(f"decide's one_job reads vars.{var}, the workflow-level concurrency group does not")
# Every combination of those variables (unset, or each value decide compares), for a push run and the loop's retry.
choices = {var: sorted({""} | set(re.findall(rf"process\.env\.{env_name} === '([^']*)'", DECIDE_JS)))
           for var, env_name in one_job_vars.items()}
for values in itertools.product(*choices.values()):
    vars_ctx = {f"vars.{var}": value for var, value in zip(choices, values)}
    decide_env = {one_job_vars[var]: value for var, value in zip(choices, values)}
    for name, event, extra in (("a push run", "push", {}), ("the loop's retry", "workflow_dispatch", RETRY)):
        env = {**decide_env, "LOOP_RETRY": extra.get("inputs.nightly_next_loop_retry", ""), "SIGN_STAGE": ""}
        try:
            one_job = bool(decide_eval("oneJob", env, event))
        except LookupError as missing:
            failures.append(f"decide's oneJob reads {missing}, which this test does not model: model it, and make "
                            "the workflow-level group read the same input if it is a repository variable")
            break
        group = substitute(top, {**context(event, one_job=""), **extra, **vars_ctx})
        want = "nightly-build-nightly-next-run-43608103300" if one_job else "nightly-build-nightly-next-push"
        if group != want:
            failures.append(f"{name} with {vars_ctx}: decide's one_job is {str(one_job).lower()}, so the workflow-level "
                            f"group must be {want!r}, got {group!r}")

one_concurrency = ONE.get("concurrency") or {}
one_group = str(one_concurrency.get("group", ""))
if one_concurrency.get("cancel-in-progress") is not False:
    failures.append("nightly-next-one's group must never cancel a started build (cancel-in-progress: false)")
# One slot per signer Mac (docs/ci/nightly-workflow-notes.md#note-33): the pick's host on the attempt that made it,
# else cmux15 (a failed or skipped pick, or a re-run of failed jobs that kept an older pick).
PICK = "needs.pick-nightly-next-signer.outputs"
for name, ctx in (("a push run", context()), ("the loop's retry", context("workflow_dispatch", **RETRY))):
    for pick_ctx, want in (({f"{PICK}.host": "ultra1", f"{PICK}.attempt": "1", "github.run_attempt": "1"},
                            "nightly-next-one-push-ultra1"),
                           ({f"{PICK}.host": "cmux15", f"{PICK}.attempt": "1", "github.run_attempt": "1"},
                            "nightly-next-one-push-cmux15"),
                           ({f"{PICK}.host": "", f"{PICK}.attempt": "", "github.run_attempt": "1"},
                            "nightly-next-one-push-cmux15"),
                           ({f"{PICK}.host": "ultra1", f"{PICK}.attempt": "1", "github.run_attempt": "2"},
                            "nightly-next-one-push-cmux15")):
        group = substitute(one_group, {**ctx, **pick_ctx, "vars.NIGHTLY_NEXT_SLOTS": "2"})
        if group != want:
            failures.append(f"{name}'s nightly-next-one with {pick_ctx} must take the slot {want}, got {group!r}")
        for count, mini in (("", ""), ("1", ""), ("2", "one-mini")):
            group = substitute(one_group, {**ctx, **pick_ctx, "vars.NIGHTLY_NEXT_SLOTS": count, "vars.CI_NIGHTLY_MINI": mini})
            if group != "nightly-next-one-push":
                failures.append(f"{name} with slots={count!r} mini={mini!r} must keep the shared group, got {group!r}")
PICK_JOB = JOBS.get("pick-nightly-next-signer") or {}
if "pick-nightly-next-signer" not in (ONE.get("needs") or []):
    failures.append("nightly-next-one must need pick-nightly-next-signer (its group and pin)")
pick_if = str(PICK_JOB.get("if", ""))
for clause in ("github.ref == 'refs/heads/nightly-next'", "github.event_name == 'push'",
               "inputs.nightly_next_loop_retry != ''", "needs.decide.outputs.one_job == 'true'", "!cancelled()"):
    if clause not in pick_if:
        failures.append(f"pick-nightly-next-signer runs only for a loop run with the one job on: its if lacks {clause!r}")
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
    # The wait for the promotion moved off the signing Mac: a nightly-next-one that left before nightly-next moved
    # (left_pending) gets the loop's retry of its commit from here, unless nightly-next moved meanwhile.
    retry_step = next((s for s in wake.get("steps", [])
                       if "slot-left-retry.sh" in str(s.get("run", ""))), None)
    if retry_step is None:
        failures.append("wake-nightly-next-tick must retry a commit that left the slot pending (slot-left-retry.sh)")
    else:
        retry_if = str(retry_step.get("if", ""))
        if "needs.nightly-next-one.outputs.left_pending == 'true'" not in retry_if or "!cancelled()" not in retry_if:
            failures.append("the retry step runs only for a pending leave, even after a failed tick ask")
        retry_env = retry_step.get("env") or {}
        if "needs.resolve-nightly-cmux-tui-client.outputs.tip_sha" not in str(retry_env.get("TIP_SHA", "")) \
                or "inputs.nightly_next_loop_retry" not in str(retry_env.get("RETRY", "")):
            failures.append("the retry step reads the commit that left (TIP_SHA) and this run's retry count (RETRY)")
    if "steps.one-leave.outputs.pending" not in str((ONE.get("outputs") or {}).get("left_pending", "")):
        failures.append("nightly-next-one outputs left_pending (it left before nightly-next moved)")
    checkout = next((s for s in wake.get("steps", []) if "actions/checkout" in str(s.get("uses", ""))), {})
    if "scripts/cmux-next/lib" not in str((checkout.get("with") or {}).get("sparse-checkout", "")):
        failures.append("wake-nightly-next-tick checks out scripts/cmux-next/lib (origin-net.sh, the ls-remote read)")


def slot_left_retry(head: str | None, tip: str, retry: str = "") -> list[str]:
    """slot-left-retry.sh with nightly-next at `head` (None: the remote does not answer); the gh calls it made."""
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "gh").write_text(f'#!/bin/sh\necho "$*" >> {tmp}/calls\n')
        (Path(tmp) / "gh").chmod(0o755)
        answer = "exit 128" if head is None else f"printf '%s\\trefs/heads/nightly-next\\n' {head}"
        (Path(tmp) / "git").write_text(f'#!/bin/sh\n[ "$1" = -C ] && shift 2\n[ "$1" = ls-remote ] || exit 1\n{answer}\n')
        (Path(tmp) / "git").chmod(0o755)
        env = {**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}", "TIP_SHA": tip, "REPOSITORY": "o/r",
               "RETRY": retry, "ORIGIN_NET_TRIES": "1"}
        proc = subprocess.run(["bash", str(ROOT / "scripts/ci/nightly-steps/slot-left-retry.sh")], env=env,
                              capture_output=True, text=True, timeout=60)
        if proc.returncode != 0:
            return [f"exit {proc.returncode}: {proc.stderr[-200:]}"]
        calls = Path(tmp) / "calls"
        return calls.read_text().splitlines() if calls.exists() else []


RETRY_ASK = "workflow run nightly.yml --repo o/r --ref nightly-next -f nightly_next_loop_retry="
OLD, NEW = "c31b2b6786669f7d25210f6496653b58bcc71dd3", "7341dd7bef6021463ef2ad54a9189502e8361adf"
if slot_left_retry(OLD, OLD) != [RETRY_ASK + "1"]:
    failures.append("a push run that left the slot pending, with nightly-next still at its commit, gets retry 1")
if slot_left_retry(OLD, OLD, "1") != [RETRY_ASK + "2"]:
    failures.append("a first retry that left the slot pending gets retry 2")
if slot_left_retry(OLD, OLD, "2") != []:
    failures.append("the loop never dispatches a third retry")
if slot_left_retry(NEW, OLD) != []:
    failures.append("no retry once nightly-next moved: the newer push's run builds it")
if slot_left_retry(None, OLD) != [RETRY_ASK + "1"]:
    failures.append("an unread nightly-next counts as not moved (the retry leaves in resolve if it did move)")

# Latest wins at the slot too. A push run checks for a newer push before the slot (resolve's leave step), then may
# wait ~30 min at nightly-next-one-push while newer commits land; admitted, it would build its old commit. So the
# same check runs again as nightly-next-one's first step after the claim, and a run that leaves skips every build
# and publish step (LEFT_SLOT in the job's env): it ends green, nothing is cancelled. Main's tick does not count a
# run in that step as building (nightly_next_rolling.LEAVE_ONE_STEP), so it promotes the newest commit meanwhile.
# CLEANUP steps run after a leave and must pass with nothing built. "Finish the signed-app checks" is not one: with
# no start it exits 1 ("the signed-app checks were never started"), which turned left run 43672208506 red.
LEAVE_ONE_STEP = "Leave the push slot to a newer nightly-next push"
CLEANUP = {"Delete signing keychain before runtime checks",
           "Delete signing keychain after the DMG signature", "Release the nightly-next publish lease",
           "Bound the kept Rust target directories (warm nightly-next builder)", "Stop the helper builds still running",
           "Cleanup keychain", "Wipe this job's credentials and temp files"}
one_steps = ONE.get("steps") or []
leave_at = next((i for i, s in enumerate(one_steps) if s.get("id") == "one-leave"), None)
if leave_at is None:
    failures.append("nightly-next-one has no leave step (id one-leave) after the slot admits it")
else:
    leave_step = one_steps[leave_at]
    names = [s.get("name") for s in one_steps]
    if leave_step.get("name") != LEAVE_ONE_STEP:
        failures.append(f"nightly-next-one's leave step is named {LEAVE_ONE_STEP!r} (main's tick reads it by name)")
    if "Claim the whole Mac for signing" not in names[:leave_at] or leave_at > names.index(
            "Point the signing steps at the build products"):
        failures.append("the leave step runs right after the whole-Mac claim, before any build step")
    leave_if = str(leave_step.get("if", ""))
    for name, ctx in (("a push run", context()), ("the loop's retry", context("workflow_dispatch", **RETRY))):
        if not evaluate(parse_expression(leave_if), ctx):
            failures.append(f"{name} must reach the leave step in nightly-next-one")
    if evaluate(parse_expression(leave_if), {**context("workflow_dispatch"), "github.ref": "refs/heads/main"}):
        failures.append("only nightly-next loop runs leave at nightly-next-one's slot")
    leave_env = leave_step.get("env") or {}
    if str(leave_env.get("IN_SLOT")) != "1" or "resolve-leave-build-slot.sh" not in str(leave_step.get("run", "")):
        failures.append("the leave step runs resolve-leave-build-slot.sh with IN_SLOT=1 (the wait measured at the slot)")
    for key in ("GH_TOKEN", "TIP_SHA", "REPOSITORY", "LOOP_RETRY", "SUPERSEDE_SKIP"):
        if key not in leave_env:
            failures.append(f"the leave step sets {key}, as resolve's does")
    for step in one_steps[leave_at + 1:]:
        name = step.get("name")
        cond = str(step.get("if", "")).strip()
        bare = cond[3:-2].strip() if cond.startswith("${{") and cond.endswith("}}") else cond
        if name in CLEANUP:
            continue
        try:
            skipped = not evaluate(parse_expression(bare), {"env.LEFT_SLOT": "1"}) if bare else False
        except (ValueError, KeyError, IndexError, TypeError):
            skipped = bare.endswith("&& !env.LEFT_SLOT") and ("||" not in bare or bare.startswith("("))
        if not skipped:
            failures.append(f"nightly-next-one's step {name!r} must skip when the run left the slot (!env.LEFT_SLOT)")
    if "steps.one-leave.outputs.superseded" not in str((ONE.get("outputs") or {}).get("left", "")):
        failures.append("nightly-next-one outputs left (the run left the slot and published nothing)")
    for job_id in ("published-build", "attest-nightly-remote-daemon"):
        if "needs.nightly-next-one.outputs.left != 'true'" not in str(JOBS.get(job_id, {}).get("if", "")):
            failures.append(f"{job_id} must not run for a nightly-next-one that left the slot")


def leave_in_slot(heads: list[str], tip: str, *, feat: str = "", asked_min_ago: float = 0.5, calls: list | None = None,
                  gh_prelude: str = "", **env_extra) -> tuple:
    """resolve-leave-build-slot.sh with IN_SLOT=1: the fake gh answers `heads` for nightly-next in turn (the last one
    repeats), `feat` for feat-cmux-next and, for the run's jobs, resolve's end `asked_min_ago` minutes ago. Every gh
    call, with the GH_BUDGET_WAIT_MAX_SECONDS it saw, is appended to `calls`; `gh_prelude` runs first in the fake."""
    import datetime as dt
    asked = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=asked_min_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "heads").write_text("\n".join(heads) + "\n")
        fake = Path(tmp) / "gh"
        fake.write_text(f"""#!/bin/sh
echo "budget=${{GH_BUDGET_WAIT_MAX_SECONDS-unset}} $*" >> {tmp}/calls
{gh_prelude}
case "$2" in
  */heads/nightly-next) n=$(cat {tmp}/n 2>/dev/null || echo 1); sed -n "${{n}}p" {tmp}/heads | grep . || tail -n 1 {tmp}/heads
                        echo $((n + 1)) > {tmp}/n ;;
  */heads/feat-cmux-next) echo {feat} ;;
  */actions/runs/*/jobs*) echo {asked} ;;
  */actions/runs/*) echo 2020-01-01T00:00:00Z ;;
esac
""")
        fake.chmod(0o755)
        git = Path(tmp) / "git"
        git.write_text(f"""#!/bin/sh
[ "$1" = -C ] && shift 2
[ "$1" = ls-remote ] || exit 1
n=$(cat {tmp}/n 2>/dev/null || echo 1); h=$(sed -n "${{n}}p" {tmp}/heads | grep .) || h=$(tail -n 1 {tmp}/heads)
echo $((n + 1)) > {tmp}/n
[ -n "$h" ] && printf '%s\\trefs/heads/nightly-next\\n' "$h"
""")
        git.chmod(0o755)
        out, envfile = Path(tmp) / "out", Path(tmp) / "env"
        envfile.write_text("")
        env = {k: v for k, v in os.environ.items() if k not in ("LOOP_RETRY", "SUPERSEDE_SKIP")}
        env.update(PATH=f"{tmp}:{os.environ['PATH']}", GITHUB_OUTPUT=str(out), GITHUB_ENV=str(envfile), TIP_SHA=tip,
                   REPOSITORY="o/r", GITHUB_RUN_ID="1", YIELD_MINUTES="1", YIELD_POLL_SECONDS="0", IN_SLOT="1")
        env.update(env_extra)
        try:
            subprocess.run(["bash", str(ROOT / "scripts/ci/nightly-steps/resolve-leave-build-slot.sh")], env=env,
                           check=True, capture_output=True, timeout=120)
        except subprocess.TimeoutExpired:
            return "still running after 120 s", ""
        if calls is not None:
            calls_file = Path(tmp) / "calls"
            calls.extend(calls_file.read_text().splitlines() if calls_file.exists() else [])
        return out.read_text().strip(), envfile.read_text().strip()


OLD_HEAD, NEW_HEAD = "c31b2b6786669f7d25210f6496653b58bcc71dd3", "7341dd7bef6021463ef2ad54a9189502e8361adf"
FEAT_TIP = "fdb12f557063a1c5d4bb55b4ef47c6e70f6ef0b3"
TICK_ASK = "workflow run nightly-next-tick.yml --repo o/r --ref main"
# P2(C) waited 30 min at the slot while D and E landed. Admitted, it waits for nothing on the signing Mac (2026-11-19:
# 63.5 of 83.0 Mac-minutes in 29 runs with no feed were this step waiting for the tick; run 44014825385 24.7 min). It
# asks main's tick at once and leaves with pending=true; wake-nightly-next-tick retries the commit unless it moves.
slot_calls: list[str] = []
started = time.monotonic()
got = leave_in_slot([OLD_HEAD, OLD_HEAD, NEW_HEAD], OLD_HEAD, feat=FEAT_TIP, asked_min_ago=30, calls=slot_calls,
                    YIELD_POLL_SECONDS="30")
if got != ("superseded=true\npending=true", "LEFT_SLOT=1"):
    failures.append(f"a push run admitted after 30 min at the slot, with newer commits on feat-cmux-next, must leave at "
                    f"once with the promotion pending (superseded=true, pending=true, LEFT_SLOT=1), got {got!r}")
if time.monotonic() - started > 20:
    failures.append("the leave step at the slot must not wait for the promotion on the signing Mac")
if not any(call.endswith(TICK_ASK) for call in slot_calls):
    failures.append(f"a stale run at the slot asks main's tick at once ({TICK_ASK}), got {slot_calls!r}")
if any(not call.startswith("budget=0 ") for call in slot_calls):
    failures.append(f"every gh call of the leave step skips the rate-limit wait (GH_BUDGET_WAIT_MAX_SECONDS=0), "
                    f"got {slot_calls!r}")
# nightly-next already moved when it is admitted: it leaves to that push, nothing pending, no ask needed.
moved_calls: list[str] = []
got = leave_in_slot([OLD_HEAD, NEW_HEAD], OLD_HEAD, feat=FEAT_TIP, asked_min_ago=30, calls=moved_calls)
if got != ("superseded=true", "LEFT_SLOT=1") or any(TICK_ASK in call for call in moved_calls):
    failures.append(f"a stale run whose head nightly-next already moved past leaves to it with nothing pending, got {got!r}")
# The loop's last retry has no retry after it: it asks the tick and builds its own commit, with no wait.
last_calls: list[str] = []
got = leave_in_slot([OLD_HEAD], OLD_HEAD, feat=FEAT_TIP, asked_min_ago=30, calls=last_calls, LOOP_RETRY="2")
if got != ("superseded=false", "") or not any(call.endswith(TICK_ASK) for call in last_calls):
    failures.append(f"the loop's last retry, stale at the slot, asks the tick and builds its commit, got {got!r}")
# A failed ask never holds the Mac: the run still leaves (the wake job asks again).
got = leave_in_slot([OLD_HEAD], OLD_HEAD, feat=FEAT_TIP, asked_min_ago=30,
                    gh_prelude='[ "$1" = workflow ] && exit 1')
if got != ("superseded=true\npending=true", "LEFT_SLOT=1"):
    failures.append(f"a refused tick ask still leaves the slot with the promotion pending, got {got!r}")
# A gh call that hangs (a rate-limit wait, a dead connection) is bounded: unknown keeps the slot and builds.
started = time.monotonic()
got = leave_in_slot([OLD_HEAD], OLD_HEAD, feat=FEAT_TIP, asked_min_ago=30, gh_prelude="sleep 60", GH_CALL_SECONDS="1")
if time.monotonic() - started > 30 or got != ("superseded=false", ""):
    failures.append(f"each gh call of the leave step is bounded (GH_CALL_SECONDS) and an unanswered read builds, "
                    f"got {got!r} after {time.monotonic() - started:.0f} s")
# Admitted at once (the slot was free): it builds, however old the run (resolve already checked its age).
if leave_in_slot([OLD_HEAD, NEW_HEAD], OLD_HEAD, feat=FEAT_TIP, asked_min_ago=1) != ("superseded=false", ""):
    failures.append("a run admitted with no wait at the slot builds its commit at once")
if leave_in_slot([OLD_HEAD], OLD_HEAD, asked_min_ago=30) != ("superseded=false", ""):
    failures.append("a run at nightly-next's head with nothing newer on feat-cmux-next keeps the slot")
if leave_in_slot([NEW_HEAD], OLD_HEAD, LOOP_RETRY="1") != ("superseded=true", "LEFT_SLOT=1"):
    failures.append("a loop retry whose head nightly-next moved past leaves at the slot too")

# The next run's set-up overlaps this one's notarization. Push runs 43634178843, 43642011551 and 43644053566 waited
# 19.6-26.8 min from landing to run created behind the previous nightly-next-one, then 4.7 min more (21:38:45 to
# 21:43:25) for wake, tick, promote, preflight, decide and resolve. nightly-next-one asks main's tick right before
# its notarize step; main's tick (nightly_next_rolling.FINISH_STEPS) counts a run from that step on as finishing and
# promotes ONE run, whose nightly-next-one then waits pending on nightly-next-one-push. wake-nightly-next-tick still
# asks at the end, for a landing that came later.
ASK_STEP, NOTARIZE_STEP = "Ask main's nightly-next tick at notarization", "Notarize app ticket through final DMG"
names = [s.get("name") for s in one_steps]
if ASK_STEP not in names or NOTARIZE_STEP not in names or names.index(ASK_STEP) + 1 != names.index(NOTARIZE_STEP):
    failures.append(f"nightly-next-one must run {ASK_STEP!r} right before {NOTARIZE_STEP!r} (main's tick reads both "
                    "names)")
else:
    ask = one_steps[names.index(ASK_STEP)]
    ask_if = str(ask.get("if", ""))
    for name, ctx in (("a push run", context()), ("the loop's retry", context("workflow_dispatch", **RETRY))):
        if not evaluate(parse_expression(ask_if), ctx):
            failures.append(f"{name} must ask main's tick at notarization")
        if evaluate(parse_expression(ask_if), {**ctx, "env.LEFT_SLOT": "1"}):
            failures.append(f"{name} that left the slot asks nothing at notarization")
    if evaluate(parse_expression(ask_if), {**context("workflow_dispatch"), "github.ref": "refs/heads/main"}):
        failures.append("only nightly-next loop runs ask the tick at notarization")
    ask_run = str(ask.get("run", ""))
    if "gh workflow run nightly-next-tick.yml" not in ask_run or "--ref main" not in ask_run or "-f sha=" in ask_run:
        failures.append("the ask dispatches nightly-next-tick.yml on main with no sha (the rolling rule applies)")
    if ask.get("continue-on-error") is not True:
        failures.append("a failed ask never fails the build: the end's wake and the 5-minute cron still ask")
    if str((ask.get("env") or {}).get("GH_BUDGET_WAIT_MAX_SECONDS")) != "0":
        failures.append("the ask never waits through a rate limit before notarization (GH_BUDGET_WAIT_MAX_SECONDS 0)")
if (ONE.get("permissions") or {}).get("actions") != "write":
    failures.append("nightly-next-one dispatches main's tick at notarization: it needs actions: write")
# The post-feed uploads and cleanup stay in the slot: the next nightly-next-one reuses this kept workspace (final-dmg/,
# tested/, remote-daemon-assets/, build-universal's dSYMs) and this Mac's build.keychain and Rust target dirs, so a
# job after the slot would upload, delete or prune what the next build is writing.
release_at = names.index("Release the nightly-next publish lease") if "Release the nightly-next publish lease" in names \
    else len(names)
for kept in ("Upload nightly variant artifacts", "Keep the nightly-next dSYMs for publication",
             "Bound the kept Rust target directories (warm nightly-next builder)", "Cleanup keychain",
             "Wipe this job's credentials and temp files"):
    if kept not in names[release_at:]:
        failures.append(f"{kept!r} stays in nightly-next-one after the feed (the next build reuses its workspace)")

if failures:
    print("FAIL: nightly-next push slot at nightly-next-one\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly-next push slot at nightly-next-one")
