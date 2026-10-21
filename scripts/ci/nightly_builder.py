#!/usr/bin/env python3
"""Dedicated cmux-next nightly builder (cmux22): runner admission hook, watch loop, status.

Design: plans/cmux-next/nightly-builder-DESIGN.md.

  nightly_builder.py admit [--role R] job-started hook; exit 1 refuses the job
                                      (R: nightly-app, the default, or next-gate)
  nightly_builder.py watch [--loop]   one health tick (or every 60 s)
  nightly_builder.py status [--json]  print the last tick
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import urllib.request

REPO = "manaflow-ai/cmux"
WORKFLOW = ".github/workflows/nightly.yml"
JOB = "build-nightly-app"
REF = "refs/heads/nightly-next"
# Each runner on cmux22 admits one job shape. The role comes from the runner's
# job-started hook script (an argument), never from the job's environment, so
# a workflow cannot pick its own role. next-gate is the cmux_next_ daemon tests
# that gate nightly-next promotion (a feat-cmux-next push's owner run).
ROLES = {
    "nightly-app": (WORKFLOW, JOB, REF, "cmux-next nightly app build"),
    "next-gate": (".github/workflows/cmux-tui-artifacts.yml", "cmux-next-daemon-tests",
                  "refs/heads/feat-cmux-next", "cmux-next nightly gate daemon tests"),
}
MIN_FREE_BYTES = 40 * 1024 ** 3
STALE_AFTER = dt.timedelta(minutes=75)
DIAG_KEEP_S = 7 * 86400
TEMP_KEEP_S = 86400
RUNS_EVERY_S = 300

HOME = Path.home()
RUNNER_DIR = Path(os.environ.get("NIGHTLY_BUILDER_RUNNER_DIR", HOME / "actions-runner-nightly-next"))
STATE_DIR = Path(os.environ.get("NIGHTLY_BUILDER_STATE_DIR", HOME / "Library/Application Support/nightly-builder"))
LOG_PATH = Path(os.environ.get("NIGHTLY_BUILDER_LOG", HOME / "Library/Logs/nightly-builder.log"))


def admit(env: dict, free_bytes: int, min_free: int = MIN_FREE_BYTES,
          role: str = "nightly-app") -> tuple[bool, str]:
    """Admit only the role's one job: by default nightly.yml's build-nightly-app for a
    push to nightly-next in manaflow-ai/cmux; next-gate admits cmux-tui-artifacts.yml's
    cmux-next-daemon-tests for a push to feat-cmux-next."""
    if role not in ROLES:
        return False, f"role {role or '<unset>'} is not one of {', '.join(sorted(ROLES))}"
    workflow, job, ref, what = ROLES[role]
    repo = env.get("GITHUB_REPOSITORY", "")
    workflow_ref = env.get("GITHUB_WORKFLOW_REF", "")
    want_workflow = f"{REPO}/{workflow}@"
    checks = [
        (repo == REPO, f"repository {repo or '<unset>'} is not {REPO}"),
        (workflow_ref.startswith(want_workflow), f"workflow {workflow_ref or '<unset>'} is not {workflow}"),
        (env.get("GITHUB_JOB", "") == job, f"job {env.get('GITHUB_JOB') or '<unset>'} is not {job}"),
        (env.get("GITHUB_EVENT_NAME", "") == "push", f"event {env.get('GITHUB_EVENT_NAME') or '<unset>'} is not push"),
        (env.get("GITHUB_REF", "") == ref, f"ref {env.get('GITHUB_REF') or '<unset>'} is not {ref}"),
        (free_bytes >= min_free, f"disk has {free_bytes / 1024 ** 3:.1f} GiB free, below {min_free / 1024 ** 3:.0f} GiB"),
    ]
    for ok, reason in checks:
        if not ok:
            return False, reason
    return True, f"admitted: {what}"


def _parse(stamp: str) -> dt.datetime:
    return dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))


def track_moves(prev: dict, heads: dict, now: dt.datetime) -> str:
    """When nightly-next last moved: now if its head changed (or is new), else the previous time."""
    old = (prev.get("heads") or {}).get("nightly-next")
    if old and old == heads.get("nightly-next") and prev.get("nightly_next_moved_at"):
        return prev["nightly_next_moved_at"]
    return now.isoformat()


def health(state: dict, now: dt.datetime) -> tuple[str, list[str]]:
    """Return ("ok", []) or ("alert", reasons) for one watch tick."""
    reasons = []
    if not state.get("runner_alive"):
        reasons.append("runner-down")
    if state.get("free_bytes", 0) < MIN_FREE_BYTES:
        reasons.append("disk-low")
    runs = [r for r in state.get("runs") or [] if r.get("conclusion") not in ("cancelled", "skipped")]
    if runs and runs[0].get("conclusion") == "failure":
        reasons.append("build-failed")
    head = (state.get("heads") or {}).get("nightly-next")
    moved_at = state.get("nightly_next_moved_at")
    if head and moved_at and now - _parse(moved_at) > STALE_AFTER:
        moved = _parse(moved_at)
        done = any(r.get("conclusion") == "success" and _parse(r["created_at"]) >= moved - dt.timedelta(minutes=5)
                   for r in runs)
        if not done:
            reasons.append("stale")
    return ("alert", reasons) if reasons else ("ok", [])


def prune(runner_dir: Path, now: float) -> list[str]:
    """Delete runner _diag logs older than 7 days and _work/_temp entries older than 1 day. Caches are kept."""
    removed = []
    for folder, keep in ((runner_dir / "_diag", DIAG_KEEP_S), (runner_dir / "_work/_temp", TEMP_KEEP_S)):
        if not folder.is_dir():
            continue
        for entry in folder.iterdir():
            try:
                if now - entry.lstat().st_mtime <= keep:
                    continue
                if entry.is_dir() and not entry.is_symlink():
                    shutil.rmtree(entry, ignore_errors=True)
                else:
                    entry.unlink()
                removed.append(str(entry))
            except OSError:
                continue
    return removed


# ---- host side (not unit tested: process, network and filesystem probes) ----

def _free_bytes(path: Path) -> int:
    return shutil.disk_usage(path).free


def _heads() -> dict:
    out = subprocess.run(["git", "ls-remote", f"https://github.com/{REPO}.git",
                          "refs/heads/feat-cmux-next", "refs/heads/nightly-next"],
                         capture_output=True, text=True, timeout=60, check=True).stdout
    heads = {}
    for line in out.splitlines():
        sha, ref = line.split("\t")
        heads[ref.rsplit("/", 1)[-1]] = sha
    return heads


def _runs() -> list[dict]:
    url = f"https://api.github.com/repos/{REPO}/actions/workflows/nightly.yml/runs?branch=nightly-next&event=push&per_page=10"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "nightly-builder"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)
    keep = ("id", "status", "conclusion", "head_sha", "created_at", "updated_at", "html_url")
    return [{k: r.get(k) for k in keep} for r in data.get("workflow_runs", [])]


def _runner_alive() -> bool:
    out = subprocess.run(["pgrep", "-f", f"{RUNNER_DIR}/bin/Runner.Listener"], capture_output=True, text=True)
    return out.returncode == 0


def _last_jobs(limit: int = 6) -> list[str]:
    diag = RUNNER_DIR / "_diag"
    logs = sorted(diag.glob("Runner_*.log"), key=lambda p: p.stat().st_mtime) if diag.is_dir() else []
    lines = []
    for log in logs[-2:]:
        for line in log.read_text(errors="replace").splitlines():
            if "Running job:" in line or "completed with result" in line:
                lines.append(line.split("WRITE LINE: ", 1)[-1])
    return lines[-limit:]


def _notify(text: str) -> None:
    subprocess.run(["osascript", "-e", f'display notification {json.dumps(text)} with title "cmux-next nightly builder"'],
                   capture_output=True, timeout=10)


def _log(event: dict) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a") as fh:
        fh.write(json.dumps(event, sort_keys=True) + "\n")


def tick() -> dict:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    status_path = STATE_DIR / "status.json"
    prev = json.loads(status_path.read_text()) if status_path.exists() else {}
    now = dt.datetime.now(dt.timezone.utc)
    state = {"time": now.isoformat(), "host": os.uname().nodename, "runner_dir": str(RUNNER_DIR)}
    try:
        state["heads"] = _heads()
    except Exception as error:  # network blips must not stop the loop
        state["heads"] = prev.get("heads", {})
        state["heads_error"] = str(error)
    state["nightly_next_moved_at"] = track_moves(prev, state["heads"], now)
    runs_at = prev.get("runs_at")
    if not runs_at or (now - _parse(runs_at)).total_seconds() >= RUNS_EVERY_S:
        try:
            state["runs"], state["runs_at"] = _runs(), now.isoformat()
        except Exception as error:
            state["runs"], state["runs_at"], state["runs_error"] = prev.get("runs", []), runs_at, str(error)
    else:
        state["runs"], state["runs_at"] = prev.get("runs", []), runs_at
    state["runner_alive"] = _runner_alive()
    state["free_bytes"] = _free_bytes(HOME)
    state["last_jobs"] = _last_jobs()
    state["pruned"] = len(prune(RUNNER_DIR, time.time()))
    state["status"], state["reasons"] = health(state, now)
    new_reasons = sorted(set(state["reasons"]) - set(prev.get("reasons", [])))
    if new_reasons:
        _notify("alert: " + ", ".join(new_reasons))
    changed = {k: state.get(k) for k in ("heads", "status", "reasons", "runner_alive")}
    if changed != {k: prev.get(k) for k in changed}:
        _log({"time": state["time"], **changed})
    tmp = status_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True))
    tmp.replace(status_path)
    return state


def print_status(as_json: bool) -> int:
    path = STATE_DIR / "status.json"
    if not path.exists():
        print("no status yet: the watch loop has not run")
        return 1
    state = json.loads(path.read_text())
    if as_json:
        print(json.dumps(state, indent=2, sort_keys=True))
        return 0
    age = (dt.datetime.now(dt.timezone.utc) - _parse(state["time"])).total_seconds()
    print(f"{state['status'].upper()} {' '.join(state['reasons'])}  (tick {int(age)} s ago on {state['host']})")
    heads = state.get("heads", {})
    print(f"feat-cmux-next {heads.get('feat-cmux-next', '?')[:12]}  nightly-next {heads.get('nightly-next', '?')[:12]}"
          f" (moved {state.get('nightly_next_moved_at', '?')})")
    print(f"runner {'up' if state.get('runner_alive') else 'DOWN'}, disk free {state.get('free_bytes', 0) / 1024 ** 3:.0f} GiB")
    for run in (state.get("runs") or [])[:5]:
        print(f"  run {run['id']} {run['status']}/{run.get('conclusion') or '-'} {run['head_sha'][:12]} {run['created_at']} {run['html_url']}")
    for line in state.get("last_jobs", []):
        print(f"  {line}")
    return 0 if state["status"] == "ok" else 2


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    admit_cmd = sub.add_parser("admit")
    admit_cmd.add_argument("--role", default="nightly-app", help=f"one of {', '.join(sorted(ROLES))}")
    watch = sub.add_parser("watch")
    watch.add_argument("--loop", action="store_true")
    watch.add_argument("--interval", type=int, default=60)
    status = sub.add_parser("status")
    status.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.cmd == "admit":
        ok, reason = admit(dict(os.environ), _free_bytes(Path(os.environ.get("GITHUB_WORKSPACE", HOME))),
                           role=args.role)
        print(f"nightly-builder: {reason}", file=sys.stderr if not ok else sys.stdout)
        _log({"time": dt.datetime.now(dt.timezone.utc).isoformat(), "admit": ok, "role": args.role, "reason": reason,
              "run": os.environ.get("GITHUB_RUN_ID"), "job": os.environ.get("GITHUB_JOB"),
              "workflow": os.environ.get("GITHUB_WORKFLOW_REF")})
        return 0 if ok else 1
    if args.cmd == "status":
        return print_status(args.json)
    while True:
        try:
            tick()
        except Exception as error:  # keep the loop alive; launchd restarts it if it dies anyway
            _log({"time": dt.datetime.now(dt.timezone.utc).isoformat(), "error": repr(error)})
        if not args.loop:
            return 0
        time.sleep(args.interval)  # the loop's poll period; launchd owns its lifetime


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
