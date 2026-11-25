#!/usr/bin/env python3
"""ci-oops: classify a red CI job and swallow it as an oops (retry, fix, hand to an agent, soft-fail), or keep it red.

    oops.py classify --log FILE [--ctx JSON|@FILE]        print the verdict (and its CI_OOPS= line)
    oops.py act --verdict JSON|@FILE [--ctx JSON|@FILE] [--dry-run]
                                                          run the verdict's actor, act_<ACTORS[class]>.py's act(verdict,
                                                          ctx, dry_run), when that file exists, else the outcome is
                                                          "skipped" (no actor yet) or, for a panic, "blocking"
    oops.py replay --runs FILE [--json]                   classify past jobs: FILE is JSON lines, one ctx each (with
                                                          log_tail); prints one verdict per line and the class counts
    oops.py run --repo OWNER/NAME --run-id ID [--attempt N] [--dry-run]
                                                          one run (by hand; the sweep does the same per run): read its
                                                          failed jobs with `gh api`, classify each, act once per class
    oops.py sweep --repo OWNER/NAME [--repo ...] [--state DIR] [--dry-run] ...
                                                          fleet-reconciler-ci-oops.yml's pass: every failed run of the
                                                          last 2 h not judged yet, then the land re-queue (sweep())
    oops.py check-rules                                  every rules/*.json is sound (validate_rules)

Leo, 2026-11-19: "can the compile somehow be able to like not fail itself or whatever? Like, is there a way for us to do
that for like the more minor incidents". Every verdict and outcome prints one `CI_OOPS={json}` line (the ledger part 4
counts) and, under Actions, a row in the job summary. This tool never fails its own job on an oops: a red job here would
wake someone, and waking no one for an infra red is the point. Rules: rules/*.json (oops_core.py's docstring).
"""
from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import oops_core as core  # noqa: E402

RULES_DIR = Path(os.environ.get("CI_OOPS_RULES_DIR") or HERE / "rules")


def load_rules(rules_dir: Path = RULES_DIR) -> list[dict]:
    """Every rule of every rules/*.json, in file-name order (a file is a JSON list)."""
    rules: list[dict] = []
    for path in sorted(Path(rules_dir).glob("*.json")):
        data = json.loads(path.read_text())
        if isinstance(data, dict):  # {"_doc": ..., "rules": [...]} is allowed too
            data = data.get("rules") or []
        rules.extend(r for r in data if isinstance(r, dict))
    return rules


def read_json_arg(value: str | None) -> dict:
    if not value:
        return {}
    if value.startswith("@"):
        return json.loads(Path(value[1:]).read_text())
    return json.loads(value)


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def emit(record: dict) -> None:
    """The ledger: one CI_OOPS= line on stdout, and a job summary row under Actions."""
    print(core.ledger_line(record), flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        try:
            with open(summary, "a") as fh:
                fh.write(f"- `{record.get('class')}` `{record.get('rule')}` -> **{record.get('outcome', 'classified')}**"
                         f" {record.get('job') or ''} {record.get('note') or ''}\n")
        except OSError:
            pass


ACTORS = {"infra": "retry", "mechanical": "fixer", "real": "agent", "soft": "softfail"}  # class -> act_<name>.py


def load_actor(cls: str, actors_dir: Path = HERE):
    path = Path(actors_dir) / f"act_{ACTORS.get(cls, cls)}.py"
    if not path.is_file():
        return None
    spec = importlib.util.spec_from_file_location(f"ci_oops_act_{cls}", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return getattr(mod, "act", None)


def act(verdict: dict, ctx: dict, dry_run: bool, actors_dir: Path = HERE) -> dict:
    """The outcome of VERDICT's actor, never an exception: an actor that raises gives up (and stays red)."""
    cls = verdict.get("class")
    if cls == "panic" or not verdict.get("swallow"):
        return {"outcome": "blocking", "note": "not swallowed: stays red as today"}
    fn = load_actor(cls, actors_dir)
    if fn is None:
        return {"outcome": "skipped", "note": f"no act_{ACTORS.get(cls, cls)}.py yet"}
    try:
        got = fn(verdict, ctx, dry_run)
    except Exception as err:  # an actor's bug must not turn the oops job red
        return {"outcome": "gave_up", "note": f"act_{ACTORS.get(cls, cls)} raised {err.__class__.__name__}: {err}"[:300]}
    return got if isinstance(got, dict) and got.get("outcome") else {"outcome": "gave_up", "note": f"act_{cls} answered {got!r}"[:300]}


def record_for(verdict: dict, ctx: dict, outcome: dict | None = None) -> dict:
    rec = {"v": core.CI_OOPS_VERSION, "repo": ctx.get("repo"), "workflow": ctx.get("workflow"), "job": ctx.get("job"),
           "job_id": ctx.get("job_id"), "run_id": ctx.get("run_id"), "run_attempt": ctx.get("run_attempt"),
           "head_sha": ctx.get("head_sha"), "pr": ctx.get("pr"), "class": verdict.get("class"),
           "rule": verdict.get("rule"), "fixer": verdict.get("fixer"), "swallow": verdict.get("swallow"),
           "evidence": verdict.get("evidence"), "red_at": ctx.get("red_at"), "at": now_iso()}
    if outcome:
        rec.update(outcome)
    return rec


# ---- GitHub reads for `run` (gh api; GH_TOKEN is the caller's) ----

def gh_json(path: str, method: str = "GET", runner=subprocess.run):
    args = ["gh", "api", "-X", method, path]
    got = runner(args, capture_output=True, text=True, timeout=120)
    if got.returncode != 0:
        raise RuntimeError(f"gh api {method} {path}: {(got.stderr or got.stdout).strip()[:300]}")
    return json.loads(got.stdout) if got.stdout.strip() else {}


def gh_text(path: str, runner=subprocess.run) -> str:
    got = runner(["gh", "api", path], capture_output=True, text=True, timeout=180)
    if got.returncode != 0:
        raise RuntimeError(f"gh api {path}: {(got.stderr or got.stdout).strip()[:300]}")
    return got.stdout


def own_branch(head_ref: str, author: str | None, authors=None) -> bool:
    """A lane PR: its branch is lane/* and its author is an agent login (agent-authors.json), when the list is known."""
    if not str(head_ref or "").startswith("lane/"):
        return False
    if authors is None:
        return True
    return str(author or "").lower() in authors


def load_authors():
    for path in (HERE.parent / "fleet-reconcilers" / "agent-authors.json", HERE / "agent-authors.json"):
        try:
            return frozenset(a.lower() for a in json.loads(path.read_text())["authors"])
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return None


def run_contexts(repo: str, run_id: int, attempt: int | None = None, get_json=gh_json, get_text=gh_text) -> tuple[dict, list[dict]]:
    """The run and one ctx per failed job of ATTEMPT (default the run's latest), each with its log's tail."""
    run = get_json(f"repos/{repo}/actions/runs/{run_id}")
    attempt = attempt or run.get("run_attempt") or 1
    jobs = get_json(f"repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100").get("jobs") or []
    prs = run.get("pull_requests") or []
    pr = prs[0] if prs else {}
    authors = load_authors()
    author = (run.get("actor") or {}).get("login")
    out = []
    for job in jobs:
        if job.get("conclusion") != "failure":
            continue
        try:
            log = get_text(f"repos/{repo}/actions/jobs/{job['id']}/logs")
        except RuntimeError as err:
            log = f"ci-oops: job log unreadable: {err}"
        if not job.get("steps") or not job.get("runner_name"):
            # A job refused before it started has no log; GitHub says why in its check run's annotation ("The job was
            # not started because recent account payments have failed ..."). One read, only for such a job.
            try:
                notes = get_json(f"repos/{repo}/check-runs/{job['id']}/annotations")
                log += "\n" + "\n".join(str(n.get("message") or "") for n in notes if isinstance(n, dict))
            except Exception:  # noqa: BLE001  the steps alone still say no step ran
                pass
        ctx = {"repo": repo, "workflow": run.get("name"), "workflow_path": run.get("path"), "job": job.get("name"),
               "job_id": job.get("id"), "run_id": run_id, "run_attempt": attempt, "head_sha": run.get("head_sha"),
               "head_ref": run.get("head_branch"), "base_ref": ((pr.get("base") or {}).get("ref")),
               "event": run.get("event"), "pr": pr.get("number"), "pr_author": author,
               "own_branch": own_branch(run.get("head_branch"), author, authors), "required": None,
               "runner_name": job.get("runner_name"), "labels": job.get("labels") or [],
               "steps": [{"name": s.get("name"), "conclusion": s.get("conclusion"), "number": s.get("number")}
                         for s in job.get("steps") or []],
               "red_at": job.get("completed_at"), "log_tail": "\n".join(log.splitlines()[-core.LOG_TAIL_LINES:])}
        out.append(ctx)
    return run, out


def act_on_run(repo: str, run_id: int, attempt: int | None, dry_run: bool, rules=None, get_json=gh_json,
               get_text=gh_text, actors_dir: Path = HERE) -> list[dict]:
    """Classify every failed job of the run, then act once per class: the actor gets the first job's verdict and a ctx
    with `class_jobs` (every job id of that class) and `all_failed` (whether that class is every failed job)."""
    rules = load_rules() if rules is None else rules
    run, ctxs = run_contexts(repo, run_id, attempt, get_json, get_text)
    verdicts = [(core.classify(c, rules), c) for c in ctxs]
    records = []
    for v, c in verdicts:
        rec = record_for(v, c, {"outcome": "classified"})
        emit(rec)
        records.append(rec)
    done = set()
    for v, c in verdicts:
        cls = v["class"]
        if cls in done:
            continue
        done.add(cls)
        same = [cc for vv, cc in verdicts if vv["class"] == cls]
        ctx = {**c, "class_jobs": [cc["job_id"] for cc in same], "class_job_names": [cc["job"] for cc in same],
               "all_failed": len(same) == len(verdicts), "run": {k: run.get(k) for k in ("status", "conclusion", "run_attempt", "head_sha", "event", "name", "path")}}
        outcome = act(v, ctx, dry_run, actors_dir)
        rec = record_for(v, ctx, outcome)
        rec["jobs"] = ctx["class_job_names"]
        emit(rec)
        records.append(rec)
        if outcome.get("fallthrough") == "real" and cls != "real":
            # An actor that could not swallow it (a fixer that did not fix) hands the red to the agent actor (1c).
            real = dict(v, **{"class": "real", "rule": f"{v.get('rule')}>real", "swallow": core.SWALLOW["real"]})
            got = act(real, ctx, dry_run, actors_dir)
            rec = record_for(real, ctx, got)
            rec["jobs"] = ctx["class_job_names"]
            emit(rec)
            records.append(rec)
    if not ctxs:
        emit({"v": core.CI_OOPS_VERSION, "repo": repo, "run_id": run_id, "outcome": "skipped",
              "note": "no failed job in this attempt", "at": now_iso()})
    return records


SOFT_TITLE = "warnings (soft)"  # 0b's annotation title on a green job whose warnings it let pass (cmux#47358)


def soft_contexts(repo: str, run: dict, get_json=gh_json) -> list[dict]:
    """One ctx per job of a green PR RUN with a SOFT_TITLE annotation: the head's check runs (one call), then the
    annotations of only those with any (annotations_count). Each ctx carries the annotation's text as its log and the
    CI_OOPS fields 0b printed (rule, fixer) when its message holds the CI_OOPS= line."""
    sha = run.get("head_sha")
    checks = get_json(f"repos/{repo}/commits/{sha}/check-runs?per_page=100&filter=latest").get("check_runs") or []
    out = []
    for check in checks:
        if not ((check.get("output") or {}).get("annotations_count") or 0):
            continue
        notes = [n for n in get_json(f"repos/{repo}/check-runs/{check['id']}/annotations") or []
                 if isinstance(n, dict) and str(n.get("title") or "").startswith(SOFT_TITLE)]
        if not notes:
            continue
        text = "\n".join(str(n.get("message") or "") for n in notes)
        marked = core.log_lines(text)
        fields = {}
        for line in marked:
            if line.startswith("CI_OOPS="):
                try:
                    fields = json.loads(line.split("=", 1)[1])
                except ValueError:
                    pass
        prs = run.get("pull_requests") or []
        out.append({"repo": repo, "workflow": run.get("name"), "job": check.get("name"), "job_id": check.get("id"),
                    "run_id": run.get("id"), "run_attempt": run.get("run_attempt"), "head_sha": sha,
                    "head_ref": run.get("head_branch"), "pr": (prs[0] if prs else {}).get("number"),
                    "own_branch": own_branch(run.get("head_branch"), (run.get("actor") or {}).get("login"), load_authors()),
                    "required": None, "green": True, "log_tail": text,
                    "soft": {"rule": fields.get("rule") or "soft.warnings_as_errors", "fixer": fields.get("fixer")}})
    return out


def soft_sweep(repo: str, seen: dict, since: str, max_runs: int, dry_run: bool, get_json=gh_json, now=None,
               actors_dir: Path = HERE) -> int:
    """Green PR runs since SINCE with 0b's soft-warning annotations: each job's warning goes to the soft class's
    actor (act_softfail; its fixer, when 0b named one, is in the verdict for act_fixer to take). Marked in SEEN as
    `soft:RUN:ATTEMPT`. One list call, one check-runs call per new run, annotation reads only where any exist."""
    now = now or dt.datetime.now(dt.timezone.utc)
    runs = get_json(f"repos/{repo}/actions/runs?status=success&event=pull_request&per_page=50&created=%3E%3D{since}"
                    ).get("workflow_runs") or []
    done = 0
    for run in sorted(runs, key=lambda r: r.get("updated_at") or "")[:max_runs * 4]:
        key = f"soft:{run.get('id')}:{run.get('run_attempt') or 1}"
        if key in seen or done >= max_runs:
            continue
        seen[key] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
        try:
            ctxs = soft_contexts(repo, run, get_json)
        except Exception as err:  # noqa: BLE001
            emit({"v": core.CI_OOPS_VERSION, "repo": repo, "run_id": run.get("id"), "outcome": "skipped",
                  "note": f"soft unread: {err.__class__.__name__}: {err}"[:300], "at": now_iso()})
            continue
        done += 1
        for ctx in ctxs:
            v = core.verdict("soft", ctx["soft"]["rule"], core.log_lines(ctx["log_tail"])[-1][:core.EVIDENCE_MAX]
                             if ctx["log_tail"] else "", ctx["soft"]["fixer"], "warnings a green job let pass (0b)")
            outcome = act(v, {**ctx, "class_jobs": [ctx["job_id"]], "all_failed": False}, dry_run, actors_dir)
            emit(record_for(v, ctx, outcome))
    return done


SWEEP_SEEN_KEEP_H = 48
OUTBOX_SOURCE = "ci-oops"  # tools/fleet-reconcilers/outbox_relay.py SOURCES delivers its tells


def requeue_lands(repo: str, retried: dict, state_dir, get_json=gh_json, now=None) -> list[str]:
    """For each PR whose infra red this sweep re-ran (RETRIED, kept on the state branch): once that re-run attempt is
    green at the same head, one `tell` in the outbox (the relay delivers it to the coordinator) asking to re-queue its
    land, since merge_hold stopped it as own_red (hq#14387, hq#14433, 2026-11-19); the entry is then dropped. A re-run
    that went red again, or a PR whose head moved, is dropped too. Unreadable: kept for the next pass."""
    done = []
    for key in sorted(k for k in retried if k.startswith(repo + "#")):
        entry = retried[key]
        try:
            run = get_json(f"repos/{repo}/actions/runs/{entry['run']}")
        except Exception:  # noqa: BLE001
            continue
        if run.get("status") != "completed" or int(run.get("run_attempt") or 1) < int(entry.get("attempt") or 2):
            continue
        retried.pop(key)
        if run.get("conclusion") != "success" or (entry.get("head") and run.get("head_sha") != entry["head"]):
            continue
        text = (f"ci-oops: {key} run {entry['run']} went green on re-run after an infra red ({entry.get('rule')}); "
                f"re-queue its land: glaeda-gh land {key}")
        print("CI_OOPS_LAND=" + json.dumps({"pr": key, "run": entry["run"], "head": entry.get("head")}), flush=True)
        if state_dir:
            sys.path.insert(0, str(HERE.parent / "fleet-reconcilers"))
            try:
                import outbox  # noqa: PLC0415
                outbox.tell(Path(state_dir).parent, OUTBOX_SOURCE, text, now)
            except Exception as err:  # noqa: BLE001  the CI_OOPS_LAND line still says it
                print(f"::warning::ci-oops outbox: {err.__class__.__name__}: {err}"[:300], flush=True)
        done.append(key)
    return done


def sweep(repo: str, state_dir: Path | None, since_min: int, settle_min: int, max_runs: int, dry_run: bool,
          skip_workflows=(), get_json=gh_json, get_text=gh_text, now=None, actors_dir: Path = HERE,
          soft_runs: int = 0) -> dict:
    """The reconciler's pass: every failed run of REPO created in the last SINCE_MIN minutes, finished at least
    SETTLE_MIN ago (its jobs' logs are whole by then; act_retry caps the attempts itself), whose
    workflow is not in SKIP_WORKFLOWS, and whose run_id:attempt is not in STATE_DIR/seen.json, is run through
    act_on_run, oldest first, at most MAX_RUNS a pass. One list call, then the per-run reads act_on_run makes."""
    import act_retry  # noqa: PLC0415  (the cap lives with the actor)
    now = now or dt.datetime.now(dt.timezone.utc)
    seen_path = Path(state_dir) / "seen.json" if state_dir else None
    seen = {}
    if seen_path and seen_path.is_file():
        try:
            seen = json.loads(seen_path.read_text())
        except ValueError:
            seen = {}
    cutoff = now - dt.timedelta(hours=SWEEP_SEEN_KEEP_H)
    seen = {k: v for k, v in seen.items() if str(v) >= cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")}
    retried_path = Path(state_dir) / "retried.json" if state_dir else Path("/nonexistent/retried.json")
    try:
        retried = json.loads(retried_path.read_text()) if retried_path.is_file() else {}
    except ValueError:
        retried = {}
    retried = {k: v for k, v in retried.items() if isinstance(v, dict) and str(v.get("at")) >= cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")}
    since = (now - dt.timedelta(minutes=since_min)).strftime("%Y-%m-%dT%H:%M:%SZ")
    runs = get_json(f"repos/{repo}/actions/runs?status=failure&per_page=100&created=%3E%3D{since}").get("workflow_runs") or []
    skip = {s.lower() for s in skip_workflows}
    picked, why_not = [], {"seen": 0, "settling": 0, "skipped_workflow": 0, "protected": 0, "schedule": 0}
    for run in sorted(runs, key=lambda r: r.get("updated_at") or ""):
        key = f"{run.get('id')}:{run.get('run_attempt') or 1}"
        name = str(run.get("name") or "")
        if key in seen:
            why_not["seen"] += 1
        elif run.get("event") == "schedule":  # its next tick runs it again anyway
            why_not["schedule"] += 1
        elif name.lower() in skip:
            why_not["skipped_workflow"] += 1
        elif act_retry.PROTECTED.search(f"{name} {run.get('path') or ''}"):
            why_not["protected"] += 1
        elif (run.get("updated_at") or "") > (now - dt.timedelta(minutes=settle_min)).strftime("%Y-%m-%dT%H:%M:%SZ"):
            why_not["settling"] += 1
        else:
            picked.append(run)
    acted = []
    for run in picked[:max_runs]:
        key = f"{run['id']}:{run.get('run_attempt') or 1}"
        try:
            recs = act_on_run(repo, int(run["id"]), int(run.get("run_attempt") or 1), dry_run, None, get_json, get_text, actors_dir)
            acted.append({"run": run["id"], "outcomes": sorted({r.get("outcome") for r in recs})})
        except Exception as err:  # one unreadable run never ends the pass
            emit({"v": core.CI_OOPS_VERSION, "repo": repo, "run_id": run["id"], "outcome": "skipped",
                  "note": f"unread: {err.__class__.__name__}: {err}"[:300], "at": now_iso()})
            recs = []
        if any(r.get("pending") for r in recs):  # an actor asked for this red again next pass (act_fixer: busy)
            why_not.setdefault("pending", 0)
            why_not["pending"] += 1
            continue
        seen[key] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
        for rec in recs:
            if rec.get("outcome") == "retried" and rec.get("pr") and not rec.get("dry_run"):
                retried[f"{repo}#{rec['pr']}"] = {"run": rec.get("run_id"), "attempt": int(rec.get("run_attempt") or 1) + 1,
                                                  "head": rec.get("head_sha"), "rule": rec.get("rule"),
                                                  "at": now.strftime("%Y-%m-%dT%H:%M:%SZ")}
    landed = requeue_lands(repo, retried, state_dir, get_json, now)
    soft = 0
    if soft_runs:
        try:
            soft = soft_sweep(repo, seen, since, soft_runs, dry_run, get_json, now, actors_dir)
        except Exception as err:  # noqa: BLE001  the listing failed: the next pass reads it again
            print(f"::warning::ci-oops soft sweep {repo}: {err.__class__.__name__}: {err}"[:300], flush=True)
    if seen_path:
        seen_path.parent.mkdir(parents=True, exist_ok=True)
        seen_path.write_text(json.dumps(seen, indent=1, sort_keys=True) + "\n")
        retried_path.write_text(json.dumps(retried, indent=1, sort_keys=True) + "\n")
    summary = {"repo": repo, "listed": len(runs), "picked": len(picked), "acted": len(acted),
               "deferred": max(0, len(picked) - max_runs), "left": why_not, "lands_requeued": landed, "soft_runs": soft}
    print("CI_OOPS_SWEEP=" + json.dumps(summary, sort_keys=True), flush=True)
    return summary


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("classify")
    p.add_argument("--log")
    p.add_argument("--ctx")
    p = sub.add_parser("act")
    p.add_argument("--verdict", required=True)
    p.add_argument("--ctx")
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("replay")
    p.add_argument("--runs", required=True)
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("run")
    p.add_argument("--repo", required=True)
    p.add_argument("--run-id", type=int, required=True)
    p.add_argument("--attempt", type=int)
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("sweep")
    p.add_argument("--repo", action="append", required=True)
    p.add_argument("--state")
    p.add_argument("--since-min", type=int, default=120)
    p.add_argument("--settle-min", type=int, default=5)
    p.add_argument("--max-runs", type=int, default=12)
    p.add_argument("--skip-workflow", action="append", default=[])
    p.add_argument("--soft-runs", type=int, default=0, help="green PR runs a pass reads for soft warnings (0b)")
    p.add_argument("--dry-run", action="store_true")
    sub.add_parser("check-rules")
    a = ap.parse_args(argv)

    if a.cmd == "sweep":
        for repo in a.repo:
            try:
                sweep(repo, Path(a.state) / repo.replace("/", "__") if a.state else None, a.since_min, a.settle_min,
                      a.max_runs, a.dry_run, a.skip_workflow, soft_runs=a.soft_runs)
            except Exception as err:  # an unreadable listing: logged, never red; the next pass reads it again
                print(f"::warning::ci-oops sweep {repo}: {err.__class__.__name__}: {err}"[:400], flush=True)
        return 0

    if a.cmd == "check-rules":
        problems = core.validate_rules(load_rules())
        for line in problems:
            print(line)
        print(f"{len(load_rules())} rules, {len(problems)} problems")
        return 1 if problems else 0
    if a.cmd == "classify":
        ctx = read_json_arg(a.ctx)
        if a.log:
            ctx["log_tail"] = Path(a.log).read_text(errors="replace")
        v = core.classify(ctx, load_rules())
        print(json.dumps(v))
        emit(record_for(v, ctx, {"outcome": "classified"}))
        return 0
    if a.cmd == "act":
        v, ctx = read_json_arg(a.verdict), read_json_arg(a.ctx)
        outcome = act(v, ctx, a.dry_run)
        emit(record_for(v, ctx, outcome))
        return 0
    if a.cmd == "replay":
        rules, counts = load_rules(), {}
        for line in Path(a.runs).read_text().splitlines():
            if not line.strip():
                continue
            ctx = json.loads(line)
            v = core.classify(ctx, rules)
            counts[v["class"]] = counts.get(v["class"], 0) + 1
            row = {"run_id": ctx.get("run_id"), "job": ctx.get("job"), **v}
            print(json.dumps(row) if a.json else f"{v['class']:<10} {v['rule']:<28} {ctx.get('run_id')} {ctx.get('job')}: {v['evidence'][:100]}")
        print(json.dumps({"counts": counts}))
        return 0
    if a.cmd == "run":
        try:
            act_on_run(a.repo, a.run_id, a.attempt, a.dry_run)
        except Exception as err:  # unreadable run: logged, never red (the sweep picks it up again)
            emit({"v": core.CI_OOPS_VERSION, "repo": a.repo, "run_id": a.run_id, "outcome": "skipped",
                  "note": f"unread: {err.__class__.__name__}: {err}"[:300], "at": now_iso()})
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
