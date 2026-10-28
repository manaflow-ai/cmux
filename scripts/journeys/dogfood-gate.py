#!/usr/bin/env python3
"""Refuse a dogfood build unless it keeps every earlier fix, passed every P0 journey, and QA says ship.

    scripts/journeys/dogfood-gate.py --build JOB [--results DIR] [--qa FILE] [--fixes FILE] [--repo DIR]

Run by the lead before a dogfood build goes to Lawrence (holistic-quality.md 2 and 3); it is not a
CI gate. Refuses (exit 1) unless all three hold for the exact build of fleet job JOB:

  (a) fixes: every commit in dogfood-fixes.list is an ancestor of the build's commit
      (`git merge-base --is-ancestor`, after fetching the commit; an unknown sha refuses too);
  (b) journeys: every P0 journey in scripts/journeys/journeys has a `pass` line for JOB and its
      commit in some results.jsonl under DIR (run.py's output; default artifacts/journeys), the
      newest line per journey counting, with passing app, daemon and frame evidence, its check
      frames on disk, and a clip on disk that shows at least 2 different frames of the journey's action;
      and no failed attempt of that journey on JOB in DIR (a later pass does not undo a failure);
  (c) QA: the independent QA agent's verdict file (default artifacts/journeys/qa/<JOB>.json) names
      JOB ("build_job") and its commit, names its QA agent ("qa_agent", not the author), says
      "verdict": "ship", lists what it tried, and has no open bug: none of high or worse severity,
      and every other bug names its journey ("bugs"; README.md).

Prints the build report (fixes, P0 results with clip links, the QA verdict) either way.
Exit 0: ship; 1: refused; 2: usage or the build could not be read.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "scripts" / "cmux-next"))
import run as journeys  # noqa: E402

REQUIRED = ("app", "daemon", "frame")


def build_record(job):
    ci = shutil.which("cmux-ci") or str(Path.home() / ".local/bin/cmux-ci")
    done = subprocess.run([ci, "status", job], capture_output=True, text=True, timeout=120)
    if done.returncode != 0:
        raise SystemExit(f"dogfood-gate: cmux-ci status {job} failed: {(done.stderr or done.stdout).strip()[-300:]}")
    return json.loads(done.stdout)


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)


def check_fixes(repo, sha, fixes):
    rows, refusals = [], []
    if git(repo, "cat-file", "-e", f"{sha}^{{commit}}").returncode != 0:
        git(repo, "fetch", "-q", "origin", sha)
    if git(repo, "cat-file", "-e", f"{sha}^{{commit}}").returncode != 0:
        return [], [f"fixes: the build commit {sha} is not in {repo} even after a fetch"]
    for raw in Path(fixes).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        commit, _, why = line.partition(" ")
        known = git(repo, "rev-parse", "--verify", "-q", f"{commit}^{{commit}}")
        if known.returncode != 0:
            rows.append(("UNKNOWN", commit, why))
            refusals.append(f"fixes: {commit} ({why}) is not a commit in {repo}")
            continue
        ancestor = git(repo, "merge-base", "--is-ancestor", commit, sha).returncode
        if ancestor == 0:
            rows.append(("ok", commit, why))
        else:
            rows.append(("MISSING", commit, why))
            refusals.append(f"fixes: {sha[:11]} lacks {commit} ({why})")
    return rows, refusals


def newest_results(results_dir, job, failed=None):
    """The newest result line per journey for JOB; `failed` (a dict) gets every failed attempt per journey."""
    newest = {}
    for path in sorted(Path(results_dir).rglob("results.jsonl")):
        for raw in path.read_text().splitlines():
            try:
                line = json.loads(raw)
            except ValueError:
                continue
            if line.get("build_job") != job:
                continue
            line["_file"] = str(path)
            if failed is not None and line.get("status") == "fail":
                failed.setdefault(line["id"], []).append(line)
            if line["id"] not in newest or str(line.get("run_at")) >= str(newest[line["id"]].get("run_at")):
                newest[line["id"]] = line
    return newest


def check_journeys(results_dir, job, sha):
    specs, problems = journeys.load_journeys()
    if problems:
        return [], [f"journeys: the journey files do not validate: {p}" for p in problems]
    p0 = [s for s in specs if s["priority"] == "P0"]
    failed = {}
    newest = newest_results(results_dir, job, failed)
    rows, refusals = [], []
    for spec in p0:
        line = newest.get(spec["id"])
        if line is None:
            rows.append((spec["id"], "not run", "no result for this build", None))
            refusals.append(f"journeys: P0 {spec['id']} has no result for build {job}")
            continue
        status, reason = line.get("status"), line.get("reason") or ""
        kinds = {e.get("kind") for e in line.get("evidence") or [] if e.get("pass")}
        failing = [e for e in line.get("evidence") or [] if not e.get("pass")]
        checks_on_disk = [c for c in line.get("checks") or [] if Path(c).is_file()]
        clip = line.get("clip")
        action_frames = line.get("clip_action_frames") or 0
        action_distinct = line.get("clip_action_distinct") or 0
        if status == "pass":
            if line.get("commit") != sha:
                status, reason = "fail", f"its result names commit {line.get('commit')}, not {sha}"
            elif any(k not in kinds for k in REQUIRED) or failing:
                status, reason = "fail", "its result lacks passing app, daemon and frame evidence"
            elif not checks_on_disk:
                status, reason = "fail", "its check frames are not on disk"
            elif not clip or not Path(clip).is_file():
                status, reason = "fail", f"it has no clip on disk ({clip or 'none'})"
            elif min(action_frames, action_distinct) < journeys.MIN_ACTION_FRAMES:
                # Results from before run.py counted action frames have neither field: they refuse too.
                status, reason = "fail", (f"its clip shows {action_frames} frame(s) of the action ({action_distinct} different; "
                                          f"needs {journeys.MIN_ACTION_FRAMES}): rerun it with this run.py")
            elif failed.get(spec["id"]):
                # A rerun that passes does not undo a failure: an intermittent P0 failure is a bug a person hits too.
                # A failure that was the harness's own fault is moved out of --results, with the reason, by the lead.
                first = failed[spec["id"]][0]
                status, reason = "flaky", (f"{len(failed[spec['id']])} failed attempt(s) on this build, e.g. {first.get('run_at')} "
                                           f"in {first.get('_file')}: {str(first.get('reason'))[:200]}")
        rows.append((spec["id"], status, reason, line.get("clip")))
        if status != "pass":
            refusals.append(f"journeys: P0 {spec['id']} is {status}: {reason}")
    return rows, refusals


# Severities of a QA bug that hold the build even when it names a journey.
BLOCKING_SEVERITIES = {"blocker", "critical", "high", "p0"}


def qa_bugs(verdict):
    """The QA file's bugs: "bugs" (what the QA agent writes), plus "failures" (the older README name)."""
    bugs = []
    for key in ("bugs", "failures"):
        value = verdict.get(key)
        if value is None:
            continue
        if not isinstance(value, list):
            raise ValueError(f"{key!r} is not a list")
        bugs += value
    return bugs


def check_qa(path, job, sha):
    """The QA verdict file as the QA agent writes it (README.md, "The dogfood gate"): verdict, tried,
    bugs, build_job, commit, qa_agent. Refusals for anything that does not say "ship this exact build"."""
    path = Path(path)
    if not path.is_file():
        return None, [f"qa: no verdict file at {path} (the independent QA agent writes it; README.md)"]
    try:
        verdict = json.loads(path.read_text())
    except ValueError as error:
        return None, [f"qa: {path} is not JSON: {error}"]
    if not isinstance(verdict, dict):
        return None, [f"qa: {path} is not a JSON object"]
    refusals = []
    named_job = verdict.get("build_job")
    if not named_job:
        refusals.append("qa: the verdict names no build (build_job), so it is not a verdict on this build")
    elif named_job != job:
        refusals.append(f"qa: the verdict names build {named_job!r}, not {job}")
    commit = str(verdict.get("commit") or "").lower()
    if not commit:
        refusals.append("qa: the verdict names no commit")
    elif not (re.fullmatch(r"[0-9a-f]{7,40}", commit) and sha.startswith(commit)):
        refusals.append(f"qa: the verdict names commit {commit!r}, not {sha}")
    if verdict.get("verdict") != "ship":
        refusals.append(f"qa: the verdict is {verdict.get('verdict')!r}, not \"ship\"")
    tried = verdict.get("tried")
    if not isinstance(tried, list) or not tried:
        refusals.append("qa: the verdict lists nothing it tried")
    qa_agent = verdict.get("qa_agent")
    if not qa_agent:
        refusals.append("qa: the verdict names no QA agent (qa_agent)")
    elif qa_agent == verdict.get("author_agent"):
        refusals.append("qa: the QA agent is the author; the author cannot judge its own build")
    try:
        bugs = qa_bugs(verdict)
    except ValueError as error:
        return verdict, refusals + [f"qa: {path}: {error}"]
    for bug in bugs:
        if not isinstance(bug, dict):
            refusals.append(f"qa: a bug entry is not an object: {str(bug)[:120]}")
            continue
        title = str(bug.get("title") or bug.get("what") or "?")[:120]
        severity = str(bug.get("severity") or "").lower()
        if severity in BLOCKING_SEVERITIES:
            refusals.append(f"qa: open {severity} bug: {title}")
        elif not bug.get("journey"):
            refusals.append(f"qa: a bug names no journey: {title}")
    verdict["_bugs"] = bugs
    return verdict, refusals


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("--build", required=True, help="the dogfood build's fleet job id")
    ap.add_argument("--results", default=str(ROOT / "artifacts" / "journeys"), help="where run.py wrote results.jsonl files")
    ap.add_argument("--qa", help="the QA verdict file (default <results>/qa/<JOB>.json)")
    ap.add_argument("--fixes", default=str(HERE / "dogfood-fixes.list"))
    ap.add_argument("--repo", default=str(ROOT), help="a clone that has (or can fetch) the build commit")
    opts = ap.parse_args(argv)

    record = build_record(opts.build)
    sha = record.get("ref") or record.get("commit") or ""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        print(f"dogfood-gate: build {opts.build} names no exact commit ({sha!r})", file=sys.stderr)
        return 2
    refusals = []
    if record.get("state") != "done":
        refusals.append(f"build: job {opts.build} is {record.get('state')}, not done")
    fix_rows, r = check_fixes(opts.repo, sha, opts.fixes)
    refusals += r
    journey_rows, r = check_journeys(opts.results, opts.build, sha)
    refusals += r
    verdict, r = check_qa(opts.qa or Path(opts.results) / "qa" / f"{opts.build}.json", opts.build, sha)
    refusals += r

    print(f"# Dogfood build report: {record.get('tag')} (job {opts.build})\n")
    print(f"commit {sha}, state {record.get('state')}, worker {record.get('worker')}\n")
    print("## Earlier dogfood fixes (every one must be an ancestor)\n")
    for state, commit, why in fix_rows:
        print(f"- {state:<7} {commit} {why}")
    print("\n## P0 journeys (on this exact build)\n")
    print("| journey | result | clip | note |\n| --- | --- | --- | --- |")
    for jid, status, reason, clip in journey_rows:
        print(f"| {jid} | {status} | {clip or '-'} | {reason or ''} |")
    print("\n## Independent QA\n")
    if verdict:
        bugs = verdict.get("_bugs") or []
        print(f"verdict {verdict.get('verdict')!r} by {verdict.get('qa_agent') or '?'} on build {verdict.get('build_job') or '?'} "
              f"commit {verdict.get('commit') or '?'}; tried {len(verdict.get('tried') or [])} things; bugs {len(bugs)}")
        for bug in bugs:
            if isinstance(bug, dict):
                print(f"- [{bug.get('severity') or '?'}] {str(bug.get('title') or bug.get('what') or '?')[:160]}")
    else:
        print("no verdict")
    print()
    if refusals:
        print("REFUSED: this build does not go to Lawrence:")
        for line in refusals:
            print(f"- {line}")
        return 1
    print("SHIP: every earlier fix is in, every P0 journey passed on this build, and QA says ship.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
