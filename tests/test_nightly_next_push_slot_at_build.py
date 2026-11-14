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
  The group reads every repository variable decide's one_job reads: with NIGHTLY_NEXT_SUBMISSIONS_PAUSED=1 or
  NIGHTLY_NEXT_NOTARY_PAUSED=1 decide builds the split jobs, which the workflow-level push group alone serializes.
  The test reads decide's oneJob from its script, so a new input there fails it until the group reads it too.
- The next run's notes and PR-comment span come from the live feed's newest cmux:sourceCommit (written inside
  nightly-next-one), not only from the release body and tag the previous run's tail writes after it: the next
  run's decide can now run before that tail is done.
- nightly-next-one's end asks main's tick at once (wake-nightly-next-tick), since the tick's workflow_run trigger
  fires only when the whole run ends.

Manual lane (Lawrence 2026-10-23: no new CI tests): python3 tests/test_nightly_next_push_slot_at_build.py.
"""
from __future__ import annotations

import importlib.util
import itertools
import os
import re
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
