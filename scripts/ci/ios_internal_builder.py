#!/usr/bin/env python3
"""cmux-next INTERNAL iOS TestFlight builder: trigger decision, build number, runner admission, watch loop.

Design: plans/cmux-next/ios-testflight-builder-DESIGN.md.

  ios_internal_builder.py plan --head SHA [--repo DIR]   decide (GitHub Actions, needs GH_TOKEN)
  ios_internal_builder.py stamp [--project-yml FILE]     print MARKETING_VERSION and the build number
  ios_internal_builder.py admit                          runner job-started hook; exit 1 refuses
  ios_internal_builder.py watch [--loop]                 one health tick on the builder mini
  ios_internal_builder.py status [--json]                print the last tick
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import urllib.request

REPO = "manaflow-ai/cmux"
BUILD_WORKFLOW = ".github/workflows/ios-internal-nightly.yml"
BUILD_JOB = "archive"
BUILDER_REF = "refs/heads/rc/cnx-ios-builder"
MIN_FREE_BYTES = 40 * 1024 ** 3
FALLBACK_AFTER = dt.timedelta(hours=12)
PACKAGE_SWIFT = "cnx-ios/CnxKit/Package.swift"
PROJECT_YML = "cnx-ios/project.yml"

# Paths that change the iPhone app besides the local packages CnxKit names.
STATIC_PREFIXES = (
    "cnx-ios/",
    "AppIcon.icon/",
    "cmux-tui/crates/cmux-wg/",
    "cmux-tui/crates/cmux-transport/",
    ".github/workflows/ios-internal-nightly.yml",
    ".github/workflows/ios-internal-nightly-trigger.yml",
    "scripts/ci/ios_internal_builder.py",
)


# ---- pure logic (tests/test_ios_internal_builder.py) ----

def next_build_number(now: dt.datetime, last: str | None) -> str:
    """CFBundleVersion: the UTC timestamp yyyyMMddHHmmss, or one past `last` if the clock is not ahead of it."""
    stamp = int(now.astimezone(dt.timezone.utc).strftime("%Y%m%d%H%M%S"))
    if last is not None:
        if not str(last).isdigit():
            raise ValueError(f"last build number {last!r} is not digits")
        stamp = max(stamp, int(last) + 1)
    return str(stamp)


def marketing_version(project_yml: str) -> str:
    """MARKETING_VERSION from cnx-ios/project.yml; X.Y or X.Y.Z."""
    match = re.search(r"^\s*MARKETING_VERSION:\s*(\S+)\s*$", project_yml, re.M)
    if not match or not re.fullmatch(r"\d+\.\d+(\.\d+)?", match.group(1)):
        raise ValueError("cnx-ios/project.yml has no X.Y.Z MARKETING_VERSION")
    return match.group(1)


def package_paths(package_swift: str) -> list[str]:
    """Repo-relative directories of the local packages cnx-ios/CnxKit/Package.swift depends on."""
    base = Path("cnx-ios/CnxKit")
    out = []
    for rel in re.findall(r'\.package\(\s*path:\s*"([^"]+)"', package_swift):
        parts: list[str] = list(base.parts)
        for piece in Path(rel).parts:
            if piece == "..":
                if parts:
                    parts.pop()
            elif piece != ".":
                parts.append(piece)
        out.append("/".join(parts) + "/")
    return out


def relevant_prefixes(package_swift: str | None) -> tuple[str, ...]:
    return STATIC_PREFIXES + tuple(package_paths(package_swift or ""))


def touches_ios(paths: list[str], prefixes: tuple[str, ...]) -> bool:
    return any(p == pre or (pre.endswith("/") and p.startswith(pre)) for p in paths for pre in prefixes)


def _parse(stamp: str) -> dt.datetime:
    return dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))


@dataclasses.dataclass
class Decision:
    build: bool
    reason: str
    base: str | None  # last uploaded SHA: the "What to Test" range starts here


def plan(head: str, runs: list[dict], changed: list[str] | None, has_cnx_ios: bool,
         now: dt.datetime, prefixes: tuple[str, ...]) -> Decision:
    """Whether to dispatch a build of `head`.

    runs: this builder's runs, newest first: {id, sha, status, conclusion, created_at}.
    changed: files changed from the last uploaded SHA to head; None when unknown.
    """
    runs = sorted((r for r in runs if r.get("conclusion") not in ("cancelled", "skipped")),
                  key=lambda r: (_parse(r["created_at"]), r.get("id", 0)), reverse=True)
    last_ok = next((r for r in runs if r.get("conclusion") == "success"), None)
    base = last_ok["sha"] if last_ok else None
    if not has_cnx_ios:
        return Decision(False, "cnx-ios/ is not on feat-cmux-next yet (a191's merge)", base)
    if base == head:
        return Decision(False, f"{head[:12]} is already in cmux INTERNAL", base)
    if any(r["sha"] == head and r.get("status") != "completed" for r in runs):
        return Decision(False, f"a build of {head[:12]} is already queued or running", base)
    stale = last_ok is None or now - _parse(last_ok["created_at"]) >= FALLBACK_AFTER
    failed = next((r for r in runs if r["sha"] == head and r.get("conclusion") == "failure"), None)
    if failed and now - _parse(failed["created_at"]) < FALLBACK_AFTER:
        return Decision(False, f"{head[:12]} already failed in run {failed.get('id')}; waiting for a new head", base)
    if last_ok is None:
        return Decision(True, "no upload yet from this builder", base)
    if changed is None:
        return Decision(True, "change since the last upload is unknown; building (fail open)", base)
    if touches_ios(changed, prefixes):
        return Decision(True, f"iOS change since {base[:12]}", base)
    if stale:
        return Decision(True, f"periodic fallback: last upload is over {FALLBACK_AFTER} old", base)
    return Decision(False, f"no iOS change since {base[:12]}", base)


def admit(env: dict, free_bytes: int, min_free: int = MIN_FREE_BYTES) -> tuple[bool, str]:
    """Admit only the builder's archive job, dispatched on rc/cnx-ios-builder in manaflow-ai/cmux."""
    workflow_ref = env.get("GITHUB_WORKFLOW_REF", "")
    checks = [
        (env.get("GITHUB_REPOSITORY", "") == REPO, f"repository {env.get('GITHUB_REPOSITORY') or '<unset>'} is not {REPO}"),
        (workflow_ref.startswith(f"{REPO}/{BUILD_WORKFLOW}@"), f"workflow {workflow_ref or '<unset>'} is not {BUILD_WORKFLOW}"),
        (env.get("GITHUB_JOB", "") == BUILD_JOB, f"job {env.get('GITHUB_JOB') or '<unset>'} is not {BUILD_JOB}"),
        (env.get("GITHUB_EVENT_NAME", "") == "workflow_dispatch",
         f"event {env.get('GITHUB_EVENT_NAME') or '<unset>'} is not workflow_dispatch"),
        (env.get("GITHUB_REF", "") == BUILDER_REF, f"ref {env.get('GITHUB_REF') or '<unset>'} is not {BUILDER_REF}"),
        (free_bytes >= min_free, f"disk has {free_bytes / 1024 ** 3:.1f} GiB free, below {min_free / 1024 ** 3:.0f} GiB"),
    ]
    for ok, reason in checks:
        if not ok:
            return False, reason
    return True, "admitted: cmux-next INTERNAL iOS archive"


# ---- GitHub Actions side: plan ----

def _gh_json(args: list[str]):
    out = subprocess.run(["gh", "api", *args], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def builder_runs() -> list[dict]:
    """Recent builds; each run's title is "cnx-ios INTERNAL <sha> ..." (the workflow's run-name)."""
    try:
        data = _gh_json([f"repos/{REPO}/actions/workflows/ios-internal-nightly.yml/runs?per_page=50"])
    except subprocess.CalledProcessError as error:
        # GitHub answers 404 until the workflow's first run registers it.
        if "404" in (error.stdout or "") + (error.stderr or ""):
            return []
        raise
    runs = []
    for r in data.get("workflow_runs", []):
        m = re.search(r"\b([0-9a-f]{40})\b", r.get("display_title") or "")
        if m:
            runs.append({"id": r["id"], "sha": m.group(1), "status": r["status"],
                         "conclusion": r.get("conclusion"), "created_at": r["created_at"]})
    return runs


def _git(repo: str, *args: str) -> str:
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True).stdout


def _show(repo: str, sha: str, path: str) -> str | None:
    try:
        return _git(repo, "show", f"{sha}:{path}")
    except subprocess.CalledProcessError:
        return None


def changed_files(repo: str, base: str | None, head: str) -> list[str] | None:
    if not base:
        return None
    try:
        subprocess.run(["git", "-C", repo, "fetch", "-q", "--no-tags", "origin", base], capture_output=True, timeout=300)
        return [line for line in _git(repo, "diff", "--name-only", base, head).splitlines() if line]
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None


def cmd_plan(head: str, repo: str) -> int:
    has_cnx_ios = _show(repo, head, PROJECT_YML) is not None
    runs = builder_runs()
    first = plan(head, runs, [], has_cnx_ios, dt.datetime.now(dt.timezone.utc), STATIC_PREFIXES)
    changed = changed_files(repo, first.base, head) if first.base else None
    decision = plan(head, runs, changed, has_cnx_ios, dt.datetime.now(dt.timezone.utc),
                    relevant_prefixes(_show(repo, head, PACKAGE_SWIFT)))
    print(f"{'BUILD' if decision.build else 'skip'}: {decision.reason}")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write(f"build={'true' if decision.build else 'false'}\n")
            fh.write(f"base={decision.base or ''}\n")
            fh.write(f"reason={decision.reason}\n")
    return 0


def cmd_stamp(project_yml: Path, last: str | None) -> int:
    version = marketing_version(project_yml.read_text())
    number = next_build_number(dt.datetime.now(dt.timezone.utc), last)
    print(f"marketing={version}")
    print(f"build_number={number}")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write(f"marketing={version}\nbuild_number={number}\n")
    return 0


# ---- builder mini side: watch loop (process, network and filesystem probes) ----

HOME = Path.home()
RUNNER_DIR = Path(os.environ.get("IOS_BUILDER_RUNNER_DIR", HOME / "actions-runner-ios-internal"))
STATE_DIR = Path(os.environ.get("IOS_BUILDER_STATE_DIR", HOME / "Library/Application Support/ios-internal-builder"))
LOG_PATH = Path(os.environ.get("IOS_BUILDER_LOG", HOME / "Library/Logs/ios-internal-builder.log"))
BUILDS_ROOT = Path(os.environ.get("CNX_BUILDS_ROOT", HOME / "cnx-ios-builds"))
RUNS_EVERY_S = 300
KEEP = {"_diag": 7 * 86400, "_work/_temp": 86400}
OUTPUT_KEEP_S = 3 * 86400


def _log(event: dict) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a") as fh:
        fh.write(json.dumps(event, sort_keys=True) + "\n")


def _prune(now: float) -> int:
    removed = 0
    targets = [(RUNNER_DIR / sub, keep) for sub, keep in KEEP.items()]
    targets += [(BUILDS_ROOT, OUTPUT_KEEP_S), (BUILDS_ROOT / ".work", OUTPUT_KEEP_S)]
    for folder, keep in targets:
        if not folder.is_dir():
            continue
        for entry in folder.iterdir():
            if entry.name.startswith("."):  # .cache and .work stay; .work's children are pruned above
                continue
            try:
                if now - entry.lstat().st_mtime <= keep:
                    continue
                if entry.is_dir() and not entry.is_symlink():
                    shutil.rmtree(entry, ignore_errors=True)
                else:
                    entry.unlink()
                removed += 1
            except OSError:
                continue
    return removed


def _public_runs() -> list[dict]:
    url = f"https://api.github.com/repos/{REPO}/actions/workflows/ios-internal-nightly.yml/runs?per_page=10"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "ios-internal-builder"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)
    keep = ("id", "status", "conclusion", "display_title", "created_at", "html_url")
    return [{k: r.get(k) for k in keep} for r in data.get("workflow_runs", [])]


def tick() -> dict:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    path = STATE_DIR / "status.json"
    prev = json.loads(path.read_text()) if path.exists() else {}
    now = dt.datetime.now(dt.timezone.utc)
    state = {"time": now.isoformat(), "host": os.uname().nodename}
    try:
        line = subprocess.run(["git", "ls-remote", f"https://github.com/{REPO}.git", "refs/heads/feat-cmux-next"],
                              capture_output=True, text=True, timeout=60, check=True).stdout.split()
        state["feat_cmux_next"] = line[0] if line else None
    except Exception as error:  # network blips must not stop the loop
        state["feat_cmux_next"], state["heads_error"] = prev.get("feat_cmux_next"), str(error)
    runs_at = prev.get("runs_at")
    if not runs_at or (now - _parse(runs_at)).total_seconds() >= RUNS_EVERY_S:
        try:
            state["runs"], state["runs_at"] = _public_runs(), now.isoformat()
        except Exception as error:
            state["runs"], state["runs_at"], state["runs_error"] = prev.get("runs", []), runs_at, str(error)
    else:
        state["runs"], state["runs_at"] = prev.get("runs", []), runs_at
    state["runner_alive"] = subprocess.run(["pgrep", "-f", f"{RUNNER_DIR}/bin/Runner.Listener"],
                                           capture_output=True).returncode == 0
    state["free_bytes"] = shutil.disk_usage(HOME).free
    state["pruned"] = _prune(time.time())
    reasons = []
    if not state["runner_alive"]:
        reasons.append("runner-down")
    if state["free_bytes"] < MIN_FREE_BYTES:
        reasons.append("disk-low")
    done = [r for r in state["runs"] if r.get("conclusion") not in (None, "cancelled", "skipped")]
    if done and done[0].get("conclusion") == "failure":
        reasons.append("build-failed")
    state["status"], state["reasons"] = ("alert" if reasons else "ok"), reasons
    changed = {k: state.get(k) for k in ("feat_cmux_next", "status", "reasons", "runner_alive")}
    if changed != {k: prev.get(k) for k in changed}:
        _log({"time": state["time"], **changed})
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True))
    tmp.replace(path)
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
    print(f"feat-cmux-next {(state.get('feat_cmux_next') or '?')[:12]}; runner {'up' if state.get('runner_alive') else 'DOWN'};"
          f" disk free {state.get('free_bytes', 0) / 1024 ** 3:.0f} GiB")
    for run in (state.get("runs") or [])[:5]:
        print(f"  {run['status']}/{run.get('conclusion') or '-'} {run['created_at']} {run['display_title']} {run['html_url']}")
    return 0 if state["status"] == "ok" else 2


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--head", required=True)
    p.add_argument("--repo", default=".")
    s = sub.add_parser("stamp")
    s.add_argument("--project-yml", type=Path, default=Path(PROJECT_YML))
    s.add_argument("--last", default=None)
    sub.add_parser("admit")
    w = sub.add_parser("watch")
    w.add_argument("--loop", action="store_true")
    w.add_argument("--interval", type=int, default=60)
    st = sub.add_parser("status")
    st.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.cmd == "plan":
        return cmd_plan(args.head, args.repo)
    if args.cmd == "stamp":
        return cmd_stamp(args.project_yml, args.last)
    if args.cmd == "admit":
        ok, reason = admit(dict(os.environ), shutil.disk_usage(os.environ.get("GITHUB_WORKSPACE", str(HOME))).free)
        print(f"ios-internal-builder: {reason}", file=sys.stdout if ok else sys.stderr)
        _log({"time": dt.datetime.now(dt.timezone.utc).isoformat(), "admit": ok, "reason": reason,
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
