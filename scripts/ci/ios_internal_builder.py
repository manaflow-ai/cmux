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
PACKAGE_SWIFT = "cmux-next-ios/CmuxMobileKit/Package.swift"
PROJECT_YML = "cmux-next-ios/project.yml"
BUILDER_SCRIPT = "cmux-next-ios/scripts/testflight-build.sh"
# testflight-build.sh runs this before it builds and refuses to archive on drift, so the plan runs the same
# comparison on Linux first (package_drift): a drifted head would only fail ~25 Mac minutes later.
SYNC_SCRIPT = "cmux-next-ios/scripts/check-tabskit-sync.sh"
# A failing builder backs off instead of building every new head: after the second failure in a row it waits
# FAILURE_BACKOFF_START, doubling per failure up to FAILURE_BACKOFF_MAX, and the same iOS input as the newest
# failure waits FAILURE_BACKOFF_MAX (one retry for an infra failure). A success resets it.
FAILURE_BACKOFF_START = dt.timedelta(minutes=30)
FAILURE_BACKOFF_MAX = dt.timedelta(hours=6)

# Paths that change the iPhone app besides the local packages CmuxMobileKit names.
STATIC_PREFIXES = (
    "cmux-next-ios/",
    "AppIcon.icon/",
    "cmux-tui/crates/cmux-wg/",
    "cmux-tui/crates/cmux-transport/",
    ".github/workflows/ios-internal-nightly.yml",
    ".github/workflows/ios-internal-nightly-trigger.yml",
    "scripts/ci/ios_internal_builder.py",
    "scripts/cmux-next/check-app-store-rules.py",
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
    """MARKETING_VERSION from cmux-next-ios/project.yml; X.Y or X.Y.Z."""
    match = re.search(r"^\s*MARKETING_VERSION:\s*(\S+)\s*$", project_yml, re.M)
    if not match or not re.fullmatch(r"\d+\.\d+(\.\d+)?", match.group(1)):
        raise ValueError("cmux-next-ios/project.yml has no X.Y.Z MARKETING_VERSION")
    return match.group(1)


def package_paths(package_swift: str) -> list[str]:
    """Repo-relative directories of the local packages cmux-next-ios/CmuxMobileKit/Package.swift depends on."""
    base = Path("cmux-next-ios/CmuxMobileKit")
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


def failure_streak(runs: list[dict]) -> tuple[int, dict | None]:
    """Completed runs that failed since the newest success (newest first), and the newest of them."""
    done = [r for r in runs if r.get("status") == "completed" and r.get("conclusion") not in ("cancelled", "skipped")]
    streak = 0
    for r in done:
        if r.get("conclusion") == "success":
            break
        streak += 1
    return streak, (done[0] if streak else None)


def failure_backoff(streak: int) -> dt.timedelta:
    """How long after the newest failure the next head may build: none after one failure, then 30 min doubling to 6 h."""
    if streak < 2:
        return dt.timedelta(0)
    return min(FAILURE_BACKOFF_MAX, FAILURE_BACKOFF_START * 2 ** min(streak - 2, 16))


def plan(head: str, runs: list[dict], changed: list[str] | None, has_cmux_next_ios: bool,
         now: dt.datetime, prefixes: tuple[str, ...], builder_ready: bool = True,
         since_failure: list[str] | None = None, drift: str | None = None, force: bool = False) -> Decision:
    """Whether to dispatch a build of `head`.

    runs: this builder's runs, newest first: {id, sha, status, conclusion, created_at}.
    changed: files changed from the last uploaded SHA to head; None when unknown.
    since_failure: files changed from the newest failed run's SHA to head; None when unknown or not failing.
    drift: why head's shared iOS packages differ from upstream (testflight-build.sh refuses those); None if not.
    force: a person dispatched the trigger; the failure backoff does not apply.
    """
    runs = sorted((r for r in runs if r.get("conclusion") not in ("cancelled", "skipped")),
                  key=lambda r: (_parse(r["created_at"]), r.get("id", 0)), reverse=True)
    last_ok = next((r for r in runs if r.get("conclusion") == "success"), None)
    base = last_ok["sha"] if last_ok else None
    if not has_cmux_next_ios:
        return Decision(False, "cmux-next-ios/ is not on feat-cmux-next yet (a191's merge)", base)
    if not builder_ready:
        return Decision(False, f"{BUILDER_REF} has no {BUILDER_SCRIPT} (it predates the cnx-ios -> cmux-next-ios "
                               "rename): an admin fast-forwards it to feat-cmux-next "
                               "(plans/cmux-next/ios-testflight-builder-DESIGN.md, Operations)", base)
    if base == head:
        return Decision(False, f"{head[:12]} is already in cmux INTERNAL", base)
    if any(r["sha"] == head and r.get("status") != "completed" for r in runs):
        return Decision(False, f"a build of {head[:12]} is already queued or running", base)
    if drift:
        return Decision(False, f"BLOCKED: {drift}; testflight-build.sh refuses to archive that, so no Mac build "
                               f"until the packages match again ({SYNC_SCRIPT})", base)
    stale = last_ok is None or now - _parse(last_ok["created_at"]) >= FALLBACK_AFTER
    failed = next((r for r in runs if r["sha"] == head and r.get("conclusion") == "failure"), None)
    if failed and now - _parse(failed["created_at"]) < FALLBACK_AFTER:
        return Decision(False, f"{head[:12]} already failed in run {failed.get('id')}; waiting for a new head", base)
    streak, newest_failure = failure_streak(runs)
    if newest_failure and not force:
        failed_at, run_id = _parse(newest_failure["created_at"]), newest_failure.get("id")
        if any(r.get("status") != "completed" for r in runs):
            # A dispatch now would start the moment the running build ends, before the plan sees how it ended.
            return Decision(False, f"BLOCKED: the builder is failing (run {run_id}) and a build is still running; "
                                   "the next push after it ends plans again", base)
        if since_failure is not None and not touches_ios(since_failure, prefixes) \
                and now - failed_at < FAILURE_BACKOFF_MAX:
            return Decision(False, f"BLOCKED: run {run_id} failed on {newest_failure['sha'][:12]} and nothing the app "
                                   f"builds from changed since; it retries after {FAILURE_BACKOFF_MAX} (an infra "
                                   "failure) or on an iOS change", base)
        wait = failure_backoff(streak)
        if now - failed_at < wait:
            return Decision(False, f"BLOCKED: {streak} builds failed in a row (newest run {run_id}); backing off "
                                   f"{wait} after it, until {(failed_at + wait).isoformat()}", base)
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

class GitHubUnavailable(RuntimeError):
    """The GitHub API stayed rate-limited or down through every retry."""


# A transient answer is worth a retry: rate limits (primary and secondary), 5xx, network drops.
# A plain 403 ("Resource not accessible by integration") is a real permission error and is not.
_TRANSIENT = re.compile(r"rate limit|HTTP 429|HTTP 5\d\d|timed out|timeout|connection reset|"
                        r"unexpected EOF|Bad Gateway|Service Unavailable", re.IGNORECASE)


def _gh_json(args: list[str], runner=subprocess.run, sleep=time.sleep, attempts: int = 4):
    """`gh api ARGS` as JSON; retries transient failures, then raises GitHubUnavailable.

    Other failures raise CalledProcessError with gh's stderr attached and printed.
    """
    detail = ""
    for attempt in range(attempts):
        r = runner(["gh", "api", *args], capture_output=True, text=True)
        if r.returncode == 0:
            return json.loads(r.stdout)
        detail = (r.stderr or r.stdout or "").strip()
        if not _TRANSIENT.search(detail):
            print(f"gh api {' '.join(args)}: {detail}", file=sys.stderr)
            raise subprocess.CalledProcessError(r.returncode, r.args, r.stdout, r.stderr)
        if attempt + 1 < attempts:
            wait = 10 * 2 ** attempt  # 10 s, 20 s, 40 s: inside a secondary limit's usual window
            print(f"::warning::gh api {args[0]}: {detail}; retry {attempt + 1}/{attempts - 1} in {wait}s",
                  file=sys.stderr)
            sleep(wait)
    raise GitHubUnavailable(detail)


def builder_runs(runner=subprocess.run, sleep=time.sleep) -> list[dict]:
    """Recent builds; each run's title is "cmux-next-ios INTERNAL <sha> ..." (the workflow's run-name)."""
    try:
        data = _gh_json([f"repos/{REPO}/actions/workflows/ios-internal-nightly.yml/runs?per_page=50"],
                        runner=runner, sleep=sleep)
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
        # --depth only in an already-shallow checkout; it would make a full clone shallow.
        depth = ["--depth=1"] if _git(repo, "rev-parse", "--is-shallow-repository").strip() == "true" else []
        subprocess.run(["git", "-C", repo, "fetch", "-q", "--no-tags", *depth, "--filter=blob:none", "origin", base], capture_output=True, timeout=300)
        return [line for line in _git(repo, "diff", "--no-renames", "--name-only", base, head).splitlines() if line]
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None


def sync_pairs(sync_script: str | None) -> list[tuple[str, str]]:
    """(package path, upstream branch) pairs from check-tabskit-sync.sh's `pairs=( "PATH BRANCH" ... )` list."""
    block = re.search(r"^pairs=\((.*?)^\)", sync_script or "", re.M | re.S)
    return re.findall(r'"(\S+) (\S+)"', block.group(1)) if block else []


def package_drift(repo: str, head: str, pairs: list[tuple[str, str]]) -> str | None:
    """What check-tabskit-sync.sh would call drift at head (a package tree that differs from its upstream branch's).

    Reads trees only: a depth-1 blobless fetch of each upstream branch. None when every package matches, or when
    an upstream cannot be fetched (unknown: the Mac build then runs the check itself).
    """
    try:
        depth = ["--depth=1"] if _git(repo, "rev-parse", "--is-shallow-repository").strip() == "true" else []
    except (subprocess.CalledProcessError, OSError):
        return None
    drifted = []
    for path, branch in pairs:
        ref = f"refs/ios-internal-upstream/{branch}"
        try:
            fetched = subprocess.run(["git", "-C", repo, "fetch", "-q", "--no-tags", *depth, "--filter=blob:none",
                                      "origin", f"+refs/heads/{branch}:{ref}"], capture_output=True, timeout=300)
        except subprocess.TimeoutExpired:
            return None
        if fetched.returncode != 0:
            return None
        ours = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "-q", f"{head}:{path}"],
                              capture_output=True, text=True).stdout.strip()
        theirs = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "-q", f"{ref}:{path}"],
                                capture_output=True, text=True).stdout.strip()
        if ours != theirs:
            drifted.append(f"{path} differs from origin/{branch}")
    return "; ".join(drifted) or None


def builder_has_script() -> bool:
    """Whether the signing branch carries this layout's testflight-build.sh (fails open on API errors)."""
    branch = BUILDER_REF.removeprefix("refs/heads/")
    repo = os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux")
    r = subprocess.run(["gh", "api", "-X", "GET", f"repos/{repo}/contents/{BUILDER_SCRIPT}", "-f", f"ref={branch}",
                        "--jq", ".path"], capture_output=True, text=True)
    if r.returncode == 0:
        return True
    return "Not Found" not in (r.stderr + r.stdout)


def _write_outputs(decision: Decision) -> None:
    print(f"{'BUILD' if decision.build else 'skip'}: {decision.reason}")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write(f"build={'true' if decision.build else 'false'}\n")
            fh.write(f"base={decision.base or ''}\n")
            fh.write(f"reason={decision.reason}\n")


def cmd_plan(head: str, repo: str, runner=subprocess.run, sleep=time.sleep, force: bool = False) -> int:
    has_cmux_next_ios = _show(repo, head, PROJECT_YML) is not None
    try:
        runs = builder_runs(runner=runner, sleep=sleep)
    except GitHubUnavailable as error:
        # Without the run list the plan cannot tell a new head from one already uploaded, so it
        # dispatches nothing; the next feat-cmux-next push plans again.
        print(f"::warning::GitHub API unavailable after retries: {error}")
        _write_outputs(Decision(False, "GitHub API rate-limited or down; the next push re-plans", None))
        return 0
    ready = builder_has_script()
    first = plan(head, runs, [], has_cmux_next_ios, dt.datetime.now(dt.timezone.utc), STATIC_PREFIXES, ready)
    changed = changed_files(repo, first.base, head) if first.base else None
    _, newest_failure = failure_streak(sorted(runs, key=lambda r: (_parse(r["created_at"]), r.get("id", 0)),
                                              reverse=True))
    since_failure = changed_files(repo, newest_failure["sha"], head) if newest_failure else None
    drift = package_drift(repo, head, sync_pairs(_show(repo, head, SYNC_SCRIPT))) if has_cmux_next_ios else None
    decision = plan(head, runs, changed, has_cmux_next_ios, dt.datetime.now(dt.timezone.utc),
                    relevant_prefixes(_show(repo, head, PACKAGE_SWIFT)), ready,
                    since_failure=since_failure, drift=drift, force=force)
    _write_outputs(decision)
    if decision.reason.startswith("BLOCKED"):
        # An annotation on the decide run; the builder's own newest run stays red, which is what alerts read.
        print(f"::error title=cmux INTERNAL builder held::{decision.reason}")
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
BUILDS_ROOT = Path(os.environ.get("CMUX_MOBILE_BUILDS_ROOT", HOME / "cmux-mobile-builds"))
RUNS_EVERY_S = 300
KEEP = {"_diag": 7 * 86400, "_work/_temp": 86400}
OUTPUT_KEEP_S = 3 * 86400
KEEP_OUTPUTS = 5  # newest *-testflight build folders; older ones beyond these go too (3-day rule aside)
# The pre-rename build root (cnx -> cmux-mobile, 2026-10-20). Nothing reads it any more, but its
# cargo target, xcframeworks and SwiftPM checkouts stayed on disk (cmux23 fell to 39.9 GiB free
# on 2026-10-22 and refused every archive job).
LEGACY_ROOTS = (HOME / "cnx-ios-builds",)
# Below this, an idle builder also trims its caches: failed builds' .work (source and DerivedData),
# xcframeworks beyond the newest KEEP_XCFRAMEWORKS keys, and the cargo target (rebuilt only on an
# xcframework cache miss). SwiftPM checkouts stay. 20 GiB above the admission floor.
PRESSURE_FREE_BYTES = 60 * 1024 ** 3
KEEP_XCFRAMEWORKS = 3


def _log(event: dict) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a") as fh:
        fh.write(json.dumps(event, sort_keys=True) + "\n")


def _remove(entry: Path) -> bool:
    try:
        if entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry, ignore_errors=True)
        else:
            entry.unlink()
        return True
    except OSError:
        return False


def _discard(entry: Path) -> bool:
    """Move entry into BUILDS_ROOT/.trash (one atomic rename on the same volume), then delete it there.

    A build that starts while a slow delete runs then gets a fresh directory instead of a half-deleted one.
    """
    trash = BUILDS_ROOT / ".trash"
    try:
        trash.mkdir(parents=True, exist_ok=True)
        moved = trash / f"{entry.name}-{os.getpid()}-{time.time_ns()}"
        entry.rename(moved)
    except OSError:
        return False
    return _remove(moved)


def _by_age(folder: Path, suffix: str = "") -> list[Path]:
    """Folder's non-dot children (ending in suffix), newest first. A symlinked folder is not followed."""
    if not folder.is_dir() or folder.is_symlink():
        return []
    entries = []
    for entry in folder.iterdir():
        if entry.name.startswith(".") or not entry.name.endswith(suffix):
            continue
        try:
            entries.append((entry.lstat().st_mtime, entry))
        except OSError:
            continue
    return [e for _, e in sorted(entries, key=lambda pair: pair[0], reverse=True)]


# Any of these means a build may be using the caches. `Runner.Worker` is matched anywhere: after a
# self-update the runner starts it from `bin.<version>/`, not `bin/`, and cmux23 has no other runner.
BUSY_PATTERNS = ("Runner.Worker", "testflight-build.sh", "build-xcframework.sh")


def job_running() -> bool:
    """A runner job or a manual build is in progress: its caches and .work must not move under it."""
    return any(subprocess.run(["pgrep", "-f", pattern], capture_output=True).returncode == 0
               for pattern in BUSY_PATTERNS)


def prune_caches() -> int:
    """Disk-pressure trim, only while no build runs (the concurrency group allows one build)."""
    removed = sum(_remove(root) for root in LEGACY_ROOTS if root.exists() and not root.is_symlink())
    removed += sum(_discard(entry) for entry in _by_age(BUILDS_ROOT / ".work"))
    removed += sum(_discard(entry) for entry in _by_age(BUILDS_ROOT / ".cache/xcframework")[KEEP_XCFRAMEWORKS:])
    target = BUILDS_ROOT / ".cache/cmux-mobile-rust-target"
    if target.is_dir() and not target.is_symlink():
        removed += _discard(target)
    return removed


def _prune(now: float) -> int:
    removed = sum(_remove(entry) for entry in _by_age(BUILDS_ROOT / ".trash"))  # an interrupted _discard
    removed += sum(_remove(entry) for entry in _by_age(BUILDS_ROOT, "-testflight")[KEEP_OUTPUTS:])
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
            except OSError:
                continue
            removed += _remove(entry)
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
    state["pruned"] = _prune(time.time())
    state["free_bytes"] = shutil.disk_usage(HOME).free
    if state["free_bytes"] < PRESSURE_FREE_BYTES and not job_running():
        state["pruned"] += prune_caches()
        state["free_bytes"] = shutil.disk_usage(HOME).free
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
    p.add_argument("--force", action="store_true", help="a person asked: skip the failure backoff")
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
        return cmd_plan(args.head, args.repo, force=args.force)
    if args.cmd == "stamp":
        return cmd_stamp(args.project_yml, args.last)
    if args.cmd == "admit":
        env, disk = dict(os.environ), os.environ.get("GITHUB_WORKSPACE", str(HOME))
        ok, reason = admit(env, shutil.disk_usage(disk).free)
        if not ok and admit(env, MIN_FREE_BYTES)[0]:
            # Only the disk refused an admitted archive job, and that job has not started building
            # (the hook runs first; the concurrency group allows one build): trim caches, re-check.
            try:
                prune_caches()
            except OSError as error:  # a trim error still ends in the plain disk refusal below
                _log({"time": dt.datetime.now(dt.timezone.utc).isoformat(), "error": repr(error)})
            ok, reason = admit(env, shutil.disk_usage(disk).free)
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
