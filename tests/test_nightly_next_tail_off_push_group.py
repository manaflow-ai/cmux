#!/usr/bin/env python3
"""What follows the nightly-next feed runs outside the push group.

nightly-next has one push group: one run builds and the newest pushed head waits for that whole run.
The GitHub release, deltas, dSYMs, release notes and reel held it 17 to 35 minutes after the feed
went live (7 runs before 2026-11-06; run 42149108998 spent 20 of its 43 queued minutes behind the
previous run's tail). The push run now ends at publish-nightly: dispatch-published-in sends the
published build's record (scripts/ci/nightly_published_build.py) to a dispatched nightly.yml run,
whose published-build job hands it to the tail jobs. Main's nightly and RC still run the tail in
their own run, from the same record of their own jobs.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
SCRIPT = ROOT / "scripts" / "ci" / "nightly_published_build.py"
TEXT = WORKFLOW.read_text()
JOBS = yaml.safe_load(TEXT)["jobs"]
TAIL = ("publish-nightly-next-github", "keep-published-dsyms", "generate-nightly-deltas", "republish-nightly-deltas",
        "sign-release-notes", "publish-release-notes", "publish-nightly-reel", "published-in")
PUSH_RUN_JOBS = ("decide", "publish-nightly", "build-nightly-app", "resolve-nightly-cmux-tui-client")
# Artifacts the tail reads from the run that published (the tail run makes the deltas and the notes itself).
CROSS_RUN = {
    "publish-nightly-next-github": ("Download nightly variant artifacts", "Download verified DMG digests",
                                    "Download SSH daemon assets for publication", "Download the published feed",
                                    "Download the cmux-next source archive"),
    "generate-nightly-deltas": ("Download nightly variant",),
}

failures: list[str] = []


def job_text(name: str) -> str:
    start = TEXT.index(f"\n  {name}:\n") + 1
    match = re.search(r"^  [A-Za-z0-9_-]+:\n", TEXT[start + 4:], re.MULTILINE)
    return TEXT[start:] if match is None else TEXT[start:start + 4 + match.start()]


def needs(name: str) -> list[str]:
    value = JOBS.get(name, {}).get("needs") or []
    return [value] if isinstance(value, str) else list(value)


source = JOBS.get("published-build")
if source is None:
    failures.append("no published-build job hands the published build's record to the tail jobs")
else:
    cond = str(source.get("if", ""))
    for term in ("inputs.nightly_next_post_publish != ''", "needs.decide.outputs.track != 'nightly-next'",
                 "needs.publish-nightly.result == 'success'"):
        if term not in cond:
            failures.append(f"published-build must run only in the dispatched run or off nightly-next ({term})")
    if "nightly_published_build.py outputs" not in job_text("published-build"):
        failures.append("published-build must write its outputs with nightly_published_build.py outputs")

for name in TAIL:
    if name not in JOBS:
        failures.append(f"{name} is gone")
        continue
    if "published-build" not in needs(name):
        failures.append(f"{name} must need published-build")
    body = job_text(name)
    for job in PUSH_RUN_JOBS:
        if job in needs(name) or f"needs.{job}." in body:
            failures.append(f"{name} must read the published build from published-build, not needs.{job}")
    if re.search(r"\*pub-(feeds|channel|dmg|tag)\b", body):
        failures.append(f"{name} must not alias publish-nightly's needs.decide env (*pub-*)")

for name, steps in CROSS_RUN.items():
    spec = JOBS.get(name, {})
    if (spec.get("permissions") or {}).get("actions") != "read":
        failures.append(f"{name} reads another run's artifacts: it needs actions: read")
    by_name = {str(step.get("name", "")): step for step in spec.get("steps", [])}
    for step_name in steps:
        step = next((s for n, s in by_name.items() if n.startswith(step_name)), None)
        with_ = (step or {}).get("with") or {}
        if "published-build.outputs.source_run" not in str(with_.get("run-id", "")) \
                or "github.token" not in str(with_.get("github-token", "")):
            failures.append(f"{name}: {step_name!r} must download from the published build's run")

dispatch = JOBS.get("dispatch-published-in", {})
for name in TAIL:
    if name in needs("dispatch-published-in"):
        failures.append(f"dispatch-published-in must not wait for {name}: the push run ends at publish-nightly")
if "nightly_published_build.py pack" not in job_text("dispatch-published-in"):
    failures.append("dispatch-published-in must send the record from nightly_published_build.py pack")
dispatch_if = str(dispatch.get("if", ""))
if "source != 'recovered'" in dispatch_if or "already_published != 'true'" in dispatch_if:
    failures.append("dispatch-published-in must dispatch for every publication the tail handles "
                    "(a recovered or already published build still gets its release or dSYMs)")

if "needs.published-build.outputs.comment == 'true'" not in str(JOBS.get("published-in", {}).get("if", "")):
    failures.append("published-in must comment only on a new build of the run that published (comment)")
report = JOBS.get("report-nightly-failure", {})
if "published-build" not in needs("report-nightly-failure") or "dispatch-published-in" not in needs("report-nightly-failure"):
    failures.append("report-nightly-failure must see the tail run's jobs and a failed dispatch")
if "results['published-build']" not in job_text("report-nightly-failure"):
    failures.append("report-nightly-failure must count skipped notes only in the run that ran the tail")
if "needs.published-build.result == 'success'" not in str(JOBS.get("close-nightly-failure-issue", {}).get("if", "")):
    failures.append("close-nightly-failure-issue must close only in the run that ran the tail")

# The record round-trips: packed in the run that published, read back in the dispatched run.
if SCRIPT.exists():
    sha = "a" * 40
    needs_ctx = {
        "decide": {"result": "success", "outputs": {"track": "nightly-next", "should_publish": "true",
                                                    "published_sha": "b" * 40, "variants": '["arm64"]',
                                                    "early_mini_jobs": " ignored "}},
        "publish-nightly": {"result": "success", "outputs": {"build": "123", "build_sha": sha, "source": "own",
                                                             "tag_status": "updated"}},
        "build-nightly-app": {"result": "success", "outputs": {"daemon_build": "123", "daemon_version": "0.1.0"}},
        "resolve-nightly-cmux-tui-client": {"result": "success", "outputs": {"build_sha": sha}},
    }
    env = {**os.environ, "NEEDS": json.dumps(needs_ctx), "RUN_ID": "42", "RUN_ATTEMPT": "1", "SHA": sha}

    def run(mode: str, extra: dict[str, str]) -> tuple[int, dict[str, str]]:
        with tempfile.NamedTemporaryFile("r", suffix=".out") as out:
            proc = subprocess.run([sys.executable, str(SCRIPT), mode], env={**env, **extra, "GITHUB_OUTPUT": out.name},
                                  capture_output=True, text=True)
            if mode == "pack":
                return proc.returncode, {"stdout": proc.stdout}
            return proc.returncode, dict(line.split("=", 1) for line in out.read().splitlines() if "=" in line)

    code, packed = run("pack", {})
    record = json.loads(packed["stdout"]) if code == 0 else {}
    if record.get("source_run") != "42" or record.get("head_sha") != sha or record.get("version") != "0.1.0":
        failures.append("pack must keep published-in's fields (source_run, version, head_sha, published_sha)")
    if "early_mini_jobs" in json.dumps(record):
        failures.append("pack must send only the fields the tail reads")
    code, outputs = run("outputs", {"SOURCE": packed["stdout"], "NEEDS": "{}"})
    want = {"track": "nightly-next", "publish_build": "123", "publish_build_sha": sha, "resolve_build_sha": sha,
            "variants": '["arm64"]', "publish_result": "success", "source_run": "42", "cross_run": "true",
            "comment": "true"}
    if code != 0 or any(outputs.get(k) != v for k, v in want.items()):
        failures.append(f"the dispatched run must read the record back, got {code} {outputs}")
    code, outputs = run("outputs", {"SOURCE": ""})
    if code != 0 or outputs.get("track") != "nightly-next" or outputs.get("cross_run") != "" \
            or outputs.get("comment") != "false":
        failures.append(f"in the run that published, the record comes from its own jobs, got {code} {outputs}")
    old = json.dumps({"source_run": "42", "version": "0.1.0", "head_sha": sha, "published_sha": sha})
    code, outputs = run("outputs", {"SOURCE": old})
    if code != 0 or outputs.get("track") != "" or outputs.get("comment") != "true":
        failures.append("an older push run's dispatch (no tail) must only comment")
    bad = json.loads(packed["stdout"]) if packed.get("stdout") else {"tail": {}}
    bad["tail"]["source_sha"] = "nope"
    code, _ = run("outputs", {"SOURCE": json.dumps(bad)})
    if code == 0:
        failures.append("a malformed tail record must fail published-build")
else:
    failures.append("scripts/ci/nightly_published_build.py is missing")

if failures:
    print("FAIL: nightly-next tail off the push group\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly-next tail off the push group")
