#!/usr/bin/env python3
"""What follows the nightly-next feed runs in the run that published, from one record.

nightly-next is one loop (Leo, 2026-11-06): one run at a time builds, signs, publishes and then runs
the GitHub release, deltas, dSYMs, release notes, reel and PR comments, and the push group's newest
pushed head runs next. A separately dispatched tail run (cmux#37030) took the nightly mini beside the
next push run (run 42244796779 waited 36 min behind one). So published-build hands the run's own
jobs' record (scripts/ci/nightly_published_build.py) to the tail jobs on every track; it still reads
an older push run's post-publication dispatch from that run's checked artifact.
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
TAIL = ("publish-nightly-next-github", "keep-published-dsyms", "build-nightly-deltas", "generate-nightly-deltas", "republish-nightly-deltas",
        "sign-release-notes", "publish-release-notes", "publish-nightly-reel", "published-in")
PUSH_RUN_JOBS = ("decide", "publish-nightly", "build-nightly-app", "resolve-nightly-cmux-tui-client")
# Artifacts the tail reads from the run that published (the tail run makes the deltas and the notes itself).
CROSS_RUN = {
    "publish-nightly-next-github": ("Download nightly variant artifacts", "Download verified DMG digests",
                                    "Download SSH daemon assets for publication", "Download the published feed",
                                    "Download the cmux-next source archive"),
    "generate-nightly-deltas": ("Download published variant",),
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
    for term in ("inputs.nightly_next_post_publish != ''", "needs.publish-nightly.result == 'success'"):
        if term not in cond:
            failures.append(f"published-build must run in the run that published or an older dispatch ({term})")
    if "track != 'nightly-next'" in cond:
        failures.append("published-build must run in nightly-next's own push run too: the tail is part of the loop")
    body = job_text("published-build")
    if "nightly_published_build.py outputs" not in body:
        failures.append("published-build must write its outputs with nightly_published_build.py outputs")
    # Anyone who may dispatch the workflow writes the input, and the tail checks out the record's build commit
    # with the Sparkle key. So the record comes only from the push run's own artifact, after the API confirms
    # that run is a nightly.yml push on nightly-next here.
    if (source.get("permissions") or {}).get("actions") != "read":
        failures.append("published-build reads the push run's artifact and run: it needs actions: read")
    if not re.search(r"gh api [^\n]*actions/runs/[^\n]*/attempts/", body) \
            or "nightly_published_build.py check-source" not in body:
        failures.append("published-build must check the source run through the API (check-source)")
    download = next((s for s in source.get("steps", []) if "download-artifact" in str(s.get("uses", ""))), None)
    with_ = (download or {}).get("with") or {}
    if download is None or "nightly-published-build" not in str(with_.get("name", "")) \
            or "steps.source.outputs.run" not in str(with_.get("run-id", "")):
        failures.append("published-build must read the record from the checked source run's artifact")

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

if "dispatch-published-in" in JOBS or re.search(r"-f nightly_next_post_publish=", TEXT):
    failures.append("no job may dispatch a separate tail run: the tail runs in the loop's own run")
if "fromJSON(inputs.nightly_next_post_publish)" in TEXT:
    failures.append("no job may read the dispatch input's fields: they are unchecked (use published-build's outputs)")
if "needs.published-build.outputs.resolve_build_sha" not in job_text("published-in"):
    failures.append("published-in must check out the checked record's build commit")
if "needs.published-build.outputs.comment == 'true'" not in str(JOBS.get("published-in", {}).get("if", "")):
    failures.append("published-in must comment only on a new build of the run that published (comment)")
report = JOBS.get("report-nightly-failure", {})
if "published-build" not in needs("report-nightly-failure"):
    failures.append("report-nightly-failure must see the tail jobs")
if "results['published-build']" not in job_text("report-nightly-failure"):
    failures.append("report-nightly-failure must count skipped notes only in the run that ran the tail")
if "needs.published-build.result == 'success'" not in str(JOBS.get("close-nightly-failure-issue", {}).get("if", "")):
    failures.append("close-nightly-failure-issue must close only in the run that ran the tail")

# A job with a permissions block gets nothing it does not list, so a checkout needs contents: read.
for name in ("published-build", *TAIL):
    job = JOBS.get(name) or {}
    perms = job.get("permissions")
    checks_out = any("actions/checkout@" in str(step.get("uses", "")) for step in job.get("steps") or [])
    if checks_out and isinstance(perms, dict) and perms.get("contents") not in ("read", "write"):
        failures.append(f"{name} checks out the repository but its permissions leave out contents: read")

# A dispatched run whose published-build fails has no record and no decide outputs: it still reports,
# under nightly-next's incident label.
report = JOBS.get("report-nightly-failure") or {}
report_if = str(report.get("if", ""))
if "inputs.nightly_next_post_publish != '' && needs.published-build.result == 'failure'" not in report_if:
    failures.append("report-nightly-failure must report a failed published-build in the dispatched run")
report_env = (report.get("steps") or [{}])[0].get("env") or {}
for key in ("CHANNEL_RELEASE_TAG", "TRACK"):
    if "'nightly-next'" not in str(report_env.get(key, "")):
        failures.append(f"report-nightly-failure's {key} must fall back to nightly-next when the dispatched run has no record")

# The record round-trips: packed in the run that published, read back in the dispatched run.
if SCRIPT.exists():
    sha = "a" * 40
    needs_ctx = {
        "decide": {"result": "success", "outputs": {"track": "nightly-next", "should_publish": "true",
                                                    "published_sha": "b" * 40, "variants": '["arm64"]',
                                                    "early_mini_jobs": " ignored "}},
        "publish-nightly": {"result": "success", "outputs": {"build": "123", "build_sha": sha, "source": "own",
                                                             "tag_status": "updated",
                                                             "downloads": "- arm64: a.dmg\n- x86_64: b.dmg"}},
        "build-nightly-app": {"result": "success", "outputs": {"daemon_build": "123", "daemon_version": "0.1.0"}},
        "resolve-nightly-cmux-tui-client": {"result": "success", "outputs": {"build_sha": sha}},
    }
    work = Path(tempfile.mkdtemp())
    record_file = work / "published-build.json"
    env = {**os.environ, "NEEDS": json.dumps(needs_ctx), "RUN_ID": "42", "RUN_ATTEMPT": "1", "SHA": sha,
           "GITHUB_REPOSITORY": "manaflow-ai/cmux"}

    def parse_outputs(text: str) -> dict[str, str]:
        """GITHUB_OUTPUT as the runner reads it: name=value lines and name<<DELIM blocks."""
        outputs, lines = {}, iter(text.splitlines())
        for line in lines:
            if "<<" in line and ("=" not in line or line.index("<<") < line.index("=")):
                name, delim = line.split("<<", 1)
                body = []
                for part in lines:
                    if part == delim:
                        break
                    body.append(part)
                outputs[name] = "\n".join(body)
            elif "=" in line:
                name, value = line.split("=", 1)
                outputs[name] = value
        return outputs

    def run(mode: str, extra: dict[str, str]) -> tuple[int, dict[str, str], str]:
        with tempfile.NamedTemporaryFile("r", suffix=".out") as out:
            proc = subprocess.run([sys.executable, str(SCRIPT), mode], env={**env, **extra, "GITHUB_OUTPUT": out.name},
                                  capture_output=True, text=True)
            return proc.returncode, parse_outputs(out.read()), proc.stdout

    code, _, stdout = run("pack", {"RECORD_FILE": str(record_file)})
    packed = json.loads(stdout) if code == 0 else {}
    if packed != {"source_run": "42", "source_attempt": "1", "tail": "artifact"}:
        failures.append(f"pack must send only the source run and attempt (the record goes in its artifact), got {packed}")
    if not record_file.exists() or json.loads(record_file.read_text()).get("resolve_build_sha") != sha:
        failures.append("pack must write the record to RECORD_FILE for the artifact")
    source_env = {"SOURCE": stdout, "NEEDS": "{}"}

    code, outputs, _ = run("source", source_env)
    if code != 0 or outputs != {"run": "42", "attempt": "1"}:
        failures.append(f"source must name the run and attempt to check, got {code} {outputs}")

    good_run = {"id": 42, "run_attempt": 1, "event": "push", "head_branch": "nightly-next",
                "path": ".github/workflows/nightly.yml", "repository": {"full_name": "manaflow-ai/cmux"},
                "head_repository": {"full_name": "manaflow-ai/cmux"}}
    forged = {"event": "pull_request_target", "head_branch": "feature", "path": ".github/workflows/other.yml",
              "repository": {"full_name": "someone/cmux"}, "head_repository": {"full_name": "someone/cmux"},
              "id": 41, "run_attempt": 2}
    for field in (None, *forged):
        run_json = dict(good_run) if field is None else {**good_run, field: forged[field]}
        (work / "run.json").write_text(json.dumps(run_json))
        code, _, _ = run("check-source", {**source_env, "SOURCE_RUN_FILE": str(work / "run.json")})
        if (code == 0) != (field is None):
            failures.append(f"check-source must accept only a nightly.yml push run on nightly-next here "
                            f"({field or 'the real run'} gave {code})")
    # Manual builds, unsigned resumes, continuations and republishes on nightly-next dispatch the tail too.
    (work / "run.json").write_text(json.dumps({**good_run, "event": "workflow_dispatch"}))
    code, _, _ = run("check-source", {**source_env, "SOURCE_RUN_FILE": str(work / "run.json")})
    if code != 0:
        failures.append(f"check-source must accept a manually dispatched nightly.yml run on nightly-next (gave {code})")

    code, outputs, _ = run("outputs", {**source_env, "RECORD_FILE": str(record_file)})
    want = {"track": "nightly-next", "publish_build": "123", "publish_build_sha": sha, "resolve_build_sha": sha,
            "variants": '["arm64"]', "publish_result": "success", "source_run": "42", "cross_run": "true",
            "comment": "true", "daemon_version": "0.1.0", "publish_downloads": "- arm64: a.dmg\n- x86_64: b.dmg"}
    if code != 0 or any(outputs.get(k) != v for k, v in want.items()):
        failures.append(f"the dispatched run must read the record back from the artifact, got {code} {outputs}")
    code, _, _ = run("outputs", {"SOURCE": json.dumps({"source_run": "43", "source_attempt": "1", "tail": "artifact"}),
                                 "RECORD_FILE": str(record_file)})
    if code == 0:
        failures.append("a record from another run than the checked one must fail published-build")
    if not record_file.exists():
        record_file.write_text(json.dumps({"source_run": "42", "source_attempt": "1", "source_sha": sha}))
    inline = json.loads(record_file.read_text())
    code, _, _ = run("outputs", {"SOURCE": json.dumps({"source_run": "42", "source_attempt": "1", "tail": inline})})
    if code == 0:
        failures.append("a record carried in the input itself must fail published-build: nobody checked it")
    code, outputs, _ = run("outputs", {"SOURCE": ""})
    if code != 0 or outputs.get("track") != "nightly-next" or outputs.get("cross_run") != "" \
            or outputs.get("publish_downloads") != "- arm64: a.dmg\n- x86_64: b.dmg" \
            or outputs.get("comment") != "true":
        failures.append(f"in the run that published, the record comes from its own jobs and it comments its PRs, "
                        f"got {code} {outputs}")
    old = json.dumps({"source_run": "42", "version": "0.1.0", "head_sha": sha, "published_sha": sha})
    code, outputs, _ = run("outputs", {"SOURCE": old})
    if code != 0 or outputs.get("track") != "" or outputs.get("comment") != "false":
        failures.append("an older push run's dispatch (no tail) runs nothing: its fields are unchecked")
    bad = json.loads(record_file.read_text())
    bad["source_sha"] = "nope"
    record_file.write_text(json.dumps(bad))
    code, _, _ = run("outputs", {**source_env, "RECORD_FILE": str(record_file)})
    if code == 0:
        failures.append("a malformed record must fail published-build")
else:
    failures.append("scripts/ci/nightly_published_build.py is missing")

if failures:
    print("FAIL: nightly-next tail in the loop's run\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly-next tail in the loop's run")
