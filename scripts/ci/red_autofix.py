#!/usr/bin/env python3
"""red-autofix: one autofix path for every red on the base branches and in the nightly.

    red_autofix.py triage --run ID [--repo-dir DIR] --out report.json     what broke, which merge, what to do
    red_autofix.py prompt --report report.json --out prompt.txt           the fixer's brief
    red_autofix.py open --report report.json --kind fix|revert ...        push the branch, open the pull request
    red_autofix.py verify --report report.json --repo-dir DIR             the red's own check on a candidate tree
    red_autofix.py land --report report.json --kind fix|revert --pr N --sha SHA   merge the first green, close the other

Leo, 2026-11-25, after the NEXT nightly was red for 5 h on three breaks nothing fixed: "what about autofix? and faster
autofixes". And 2026-11-22: "if the fix is clear i think you guys should be able to unilaterally push commits
directly." The rule (cmuxterm-hq docs/handbook/base-red-nobody-is-handed.md): a deterministic red on the base or the
nightly gets, within minutes and unasked, either the fixer's patch or the revert of its first red commit.

.github/workflows/red-autofix.yml runs this on the completion of every watched workflow (workflow_run, which GitHub
fires only from the default branch's copy, for runs on any branch) when the run failed on main, feat-cmux-next or
nightly-next. nightly-next is only ever moved to a green feat-cmux-next commit, so its reds are fixed on
feat-cmux-next.

triage   reads the failed run's jobs and failed-step logs.
         infra: no file of the repository is named and a known transient matches (a signal, a lost runner, a network
                error): rerun the failed jobs once (attempt 1 only).
         code:  the red names files of the repository (or a known check). The range is the head of the newest run of
                the same workflow on the same branch whose same jobs passed, up to the red head. One commit in the
                range, or exactly one commit that touched a file the red names, is the culprit (confirmed); else the
                commits that touched those files' directories are suspects and the revert waits.
         none:  the branch's newest run of this workflow is already green, or a pull request for this red exists
                (open, merged or closed: a person who closed one said no).
prompt   the fixer's brief: the errors, the range, the culprit's diff. The fixer (a Claude run that may only read and
         edit files) makes the smallest mechanical fix-forward.
open     commits the fix (at most MAX_FILES files and MAX_LINES lines) or the culprit's revert on the target's tip
         and opens its pull request with the App token, so its CI runs. A revert's branch is revert/pr-N, the name the
         post-merge batch and fixit-handoff use, so the three never open two.
verify   runs the red's own check on the candidate tree, by what the red named: TypeScript (the package's bun scripts
         the log ran: typecheck, check:design-tokens, ...), Rust (cargo check of each crate an error names),
         workflows (actionlint), Python (py_compile). Green: the command passes and none of the red's errors remain.
         A red with no local check (Swift) verifies by the pull request's own checks (verify --pr-checks).
land     the first candidate verified green merges (squash, pinned to the verified head); the other is closed with a
         link. A core teammate's revert opens held and never merges by itself (post_merge_batch.TEAMMATES).

vars.RED_AUTOFIX: 0 turns it off; `pr` opens the pull requests but never merges. On by default.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

BASES = ("main", "feat-cmux-next")
NIGHTLY = "nightly-next"
# A nightly-next head is a green feat-cmux-next commit (nightly.yml promote-nightly-next), so its fix goes there.
TARGET = {"main": "main", "feat-cmux-next": "feat-cmux-next", NIGHTLY: "feat-cmux-next"}
# Fixed elsewhere: the main compile's own attribution (ci-compile-attribution.yml) and this workflow itself.
SKIP_WORKFLOWS = {"Seed DerivedData", "Main compile probe", "red-autofix", "CI compile attribution"}
MAX_FILES = 8
MAX_LINES = 120
MAX_RANGE = 300
LOG_TAIL = 400
TEAMMATES = frozenset({"austinywang", "azooz2003-bit", "lawrencecchen", "lucasr1b"})
TEAMMATE_HOLD = ("HOLD: {login}'s merge. This revert is ready for {login} to land or close; no agent merges it "
                 "(a teammate's PR is never merged, labelled or closed by an agent).")
LABEL = "red-autofix"
REPORTER = re.compile(r"\breport|notify|summar|failure issue|\bverdict\b", re.I)
BOT = ("cmux red-autofix", "41898282+github-actions[bot]@users.noreply.github.com")

INFRA = re.compile(
    r"died of signal \d+|killed by signal|signal (?:6|9|11)\b|The runner has received a shutdown signal"
    r"|lost communication with the server|The hosted runner (?:lost|encountered)|No space left on device"
    r"|ECONNRESET|ETIMEDOUT|EAI_AGAIN|Could not resolve host|fatal: early EOF|RPC failed|unexpected disconnect"
    r"|HTTP (?:500|502|503|504)\b|50[234] (?:Bad Gateway|Service Unavailable|Gateway Time-?out)"
    r"|secondary rate limit|API rate limit exceeded|The operation was canceled|exceeded the maximum execution time"
    r"|Resource temporarily unavailable|Connection reset by peer|TLS handshake timeout|i/o timeout", re.I)
# Paths a log names: `path:line`, Rust's `--> path:line:col`, tsc's `path(line,col)`, or a bare path with an extension.
PATH = re.compile(r"(?<![\w/.-])((?:\.{0,2}/)?[\w@.-]+(?:/[\w@.+-]+)+\.(?:tsx?|mts|cts|jsx?|mjs|cjs|rs|swift|py|ya?ml"
                  r"|json|css|scss|toml|sh|go|kt|m|mm|h|c|cc|cpp|md|html))(?::(\d+)|\((\d+),\d+\))?")
ERROR_LINE = re.compile(r"error(?:\[E\d+\])?[:\s]|error TS\d+|\berror\b:|✖|✗|FAIL\b|ERR!|##\[error\]", re.I)
RUST_CODE = re.compile(r"error\[(E\d{4})\]")
TS_CODE = re.compile(r"\b(TS\d{4,5})\b")
STAMP = re.compile(r"^(?:[^\t]*\t[^\t]*\t)?\d{4}-\d\d-\d\dT[\d:.]+Z ")
ANSI = re.compile(r"\x1b?\[[0-9;]*m")
# The first line of one error: rustc's `error[E0063]:`, tsc's `error TS2339` and oxc's `typescript(TS2339)`, a
# `##[error]` annotation, a failed bun script. Warnings and the shell's echo of a script (`[36;1m`) are not.
ERROR_START = re.compile(r"^\s*(?:error(?:\[E\d+\])?:|error TS\d+|.*\berror TS\d+:|.*typescript\(TS\d+\)|##\[error\]"
                         r"|.*: error:|×|✖|FAIL\b|.*\bERR!)")
BLOCK = 8
# Deterministic fixers, tried before any model call. A red job whose name matches carries its own fix: the
# artifact holds the regenerated files at their repository paths plus `.paths` (cmux-next.yml "Regenerate stale
# files"). Only paths matching the globs are copied; their diff has no size cap (generated output).
REGEN = [{"job": re.compile(r"generated files", re.I), "artifact": "cmux-next-generated-patch",
          "globs": ("plans/cmux-next/*.json", "plans/cmux-next/*.md", "schemas/settings/settings-schema.json",
                    "docs/mdm/*", "schemas/defaults/cmux-next.json")}]


# ---------------------------------------------------------------- GitHub and git


API_WAIT_BUDGET_S = int(os.environ.get("RED_AUTOFIX_API_WAIT_S") or 240)
_api_waited = 0.0


def _api_wait(seconds: float, what: str, stderr: str) -> None:
    """Sleep for a retry, logged, out of the process-wide API_WAIT_BUDGET_S; raise once the budget is spent."""
    global _api_waited
    left = API_WAIT_BUDGET_S - _api_waited
    if left <= 0:
        raise RuntimeError(f"gh api {what}: wait budget of {API_WAIT_BUDGET_S}s spent; {stderr.strip()[-300:]}")
    seconds = min(seconds, left)
    _api_waited += seconds
    print(f"red-autofix: {what}; waiting {seconds:.0f}s ({_api_waited:.0f}/{API_WAIT_BUDGET_S}s of the budget)",
          file=sys.stderr, flush=True)
    time.sleep(seconds)


def gh_api(path: str, *, method: str = "GET", fields: dict | None = None, raw: bool = False, run=subprocess.run):
    """One GitHub API call through gh (GH_TOKEN). Fields go as JSON on stdin. A 5xx is retried; the installation's
    rate limit (shared with every workflow) is waited out, but every wait in this process draws on one budget
    (API_WAIT_BUDGET_S, env RED_AUTOFIX_API_WAIT_S, default 240 s) and is logged to stderr: per-call waits of up to
    15 minutes, silent, ran triage past its 10-minute job timeout (run 45612343778, killed after 6 min). A raw read
    (a job log) passes --allow-escape-sequences: a log holds ANSI colour, and gh 2.80+ refuses to print it without
    the flag, which left every log unread (the 2026-11-25 nightly duplicate-key red, run 45589942841)."""
    argv = ["gh", "api", "-X", method, path]
    if fields is not None:
        argv += ["--input", "-"]
    if raw:
        argv += ["-H", "Accept: application/vnd.github.raw", "--allow-escape-sequences"]
    limited = 0
    for attempt in range(8):
        out = run(argv, input=json.dumps(fields) if fields is not None else None, capture_output=True, text=True)
        if out.returncode == 0:
            if raw:
                return out.stdout
            return json.loads(out.stdout) if out.stdout.strip() else None
        if raw and "--allow-escape-sequences" in argv and re.search(r"unknown flag: --allow-escape", out.stderr):
            argv.remove("--allow-escape-sequences")  # a gh older than the flag prints escapes as they are
            continue
        wait = re.search(r"retry after (\d+)s", out.stderr)
        if re.search(r"API rate limit exceeded|secondary rate limit", out.stderr, re.I) and limited < 4:
            limited += 1
            _api_wait(int(wait.group(1)) + 1 if wait else 30 * 2 ** limited, f"{method} {path}: rate-limited",
                      out.stderr)  # 60, 120, 240 s, then 480, within the budget
            continue
        transient = re.search(r"HTTP 5\d\d|timeout|connection reset", out.stderr, re.I)
        if not transient or attempt >= 3:
            raise RuntimeError(f"gh api {method} {path}: {out.stderr.strip()[-400:]}")
        _api_wait(min(int(wait.group(1)) + 1, 90) if wait else 5 * (attempt + 1), f"{method} {path}: transient",
                  out.stderr)
    raise RuntimeError(f"gh api {method} {path}: still refused after 8 tries")


def git(*argv: str, cwd: Path, check: bool = True) -> str:
    out = subprocess.run(["git", *argv], cwd=cwd, capture_output=True, text=True)
    if check and out.returncode:
        raise RuntimeError(f"git {' '.join(argv)}: {out.stderr.strip()[-400:]}")
    return out.stdout


def say(text: str) -> None:
    print(text)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text + "\n\n")


def write_outputs(values: dict) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    lines = [f"{k}={' '.join(str(v).split())}" for k, v in values.items()]
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines))


def mode() -> str:
    value = (os.environ.get("RED_AUTOFIX") or "on").strip().lower()
    return "off" if value in {"0", "off", "false"} else "pr" if value == "pr" else "on"


# ---------------------------------------------------------------- reading a red


def strip_log(text: str) -> list[str]:
    return [ANSI.sub("", STAMP.sub("", line.rstrip("\r"))) for line in text.splitlines()]


def error_blocks(lines: list[str]) -> list[str]:
    """Each error's first line and the BLOCK lines after it (where rustc's `-->` and oxc's `╭─[file:line]` sit),
    stopping at the next warning; in order, deduplicated. The whole log: a cargo build's error can sit 100k lines
    before its end."""
    out: list[str] = []
    seen: set[int] = set()
    for i, line in enumerate(lines):
        if "[36;1m" in line or not ERROR_START.match(line):
            continue
        for k in range(i, min(len(lines), i + BLOCK + 1)):
            if k > i and re.match(r"^\s*warning\b", lines[k]):
                break
            if k not in seen:
                seen.add(k)
                out.append(lines[k])
    return out


def error_excerpt(lines: list[str], limit: int = 120) -> list[str]:
    """The error lines with two lines of context each, in order, at most LIMIT lines; else the log's tail."""
    keep: list[int] = []
    for i, line in enumerate(lines):
        if ERROR_LINE.search(line) and "##[group]" not in line:
            keep.extend(range(max(0, i - 2), min(len(lines), i + 3)))
    seen: set[int] = set()
    picked = [lines[i] for i in keep if not (i in seen or seen.add(i))]
    return (picked or lines[-60:])[:limit]


def named_paths(lines: list[str], tree: list[str]) -> list[str]:
    """Repository files the red names, in order of first mention. TREE is every file of the red's tree. A logged
    path is often absolute (a runner's workspace) or relative to its package (tsc's `src/x.tsx(1,2)`, cargo's
    `src/lib.rs` inside a crate): it names the one tree file it is a suffix of, path component by component."""
    by_name: dict[str, list[str]] = {}
    for f in tree:
        by_name.setdefault(f.rsplit("/", 1)[-1], []).append(f)
    found: list[str] = []
    for line in lines:
        for m in PATH.finditer(line):
            raw = m.group(1)
            while raw.startswith(("./", "../")):
                raw = raw.split("/", 1)[1]
            hit = resolve(raw, by_name)
            if hit and hit not in found:
                found.append(hit)
    return found


def resolve(raw: str, by_name: dict[str, list[str]]) -> str:
    parts = raw.strip("/").split("/")
    same = by_name.get(parts[-1], [])
    # The longest suffix of RAW that is the tail of some file: it names that file when it names only one.
    for i in range(len(parts)):
        suffix = "/".join(parts[i:])
        hits = [f for f in same if f == suffix or f.endswith("/" + suffix)]
        if hits:
            return hits[0] if len(hits) == 1 else ""
    return ""


def error_keys(lines: list[str], paths: list[str]) -> list[str]:
    """Stable identities of the red's errors (file + code, no line numbers), so a candidate can be checked for them."""
    keys = []
    for line in lines:
        code = RUST_CODE.search(line) or TS_CODE.search(line)
        if not code:
            continue
        for p in paths:
            if p.rsplit("/", 1)[-1] in line:
                keys.append(f"{p}:{code.group(1)}")
                break
        else:
            keys.append(code.group(1))
    return sorted(set(keys))


def classify(lines: list[str], paths: list[str]) -> str:
    text = "\n".join(lines[-LOG_TAIL:])
    if paths:
        return "code"
    if INFRA.search(text):
        return "infra"
    if ERROR_LINE.search(text):
        return "code"
    return "unknown"


def language(paths: list[str], lines: list[str]) -> str:
    """By the files the errors point at, then by what the log says."""
    text = "\n".join(lines)
    exts = [p.rsplit(".", 1)[-1] for p in paths]
    if any(e == "rs" for e in exts) or RUST_CODE.search(text):
        return "rust"
    if any(e in {"ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "css"} for e in exts) or TS_CODE.search(text) \
            or re.search(r"check:design-tokens|bun run|eslint|oxlint|vp fmt|biome", text):
        return "ts"
    if any(e == "swift" for e in exts):
        return "swift"
    if any(p.startswith(".github/workflows/") for p in paths):
        return "workflow"
    if any(e == "py" for e in exts):
        return "python"
    return "other"


def bun_scripts(lines: list[str]) -> list[str]:
    """The package scripts that failed in the red's log (bun's `script "X" exited with code 1`), in order."""
    out: list[str] = []
    for line in lines:
        for m in re.finditer(r'script "([\w:.-]+)" exited with code', line):
            if m.group(1) not in out:
                out.append(m.group(1))
    return out


def pr_of(subject: str) -> str:
    m = re.search(r"\(#(\d+)\)\s*$", subject) or re.search(r"^Merge pull request #(\d+)", subject)
    return m.group(1) if m else ""


def range_commits(repo_dir: Path, good: str, red: str) -> list[dict]:
    """First-parent commits good..red, oldest first, with the files each touched; the newest MAX_RANGE of them
    (range_truncated says whether that cut any)."""
    return all_range_commits(repo_dir, good, red)[-MAX_RANGE:]


def range_truncated(repo_dir: Path, good: str, red: str) -> bool:
    return bool(good) and len(git("rev-list", "--first-parent", f"{good}..{red}", cwd=repo_dir,
                                  check=False).split()) > MAX_RANGE


def all_range_commits(repo_dir: Path, good: str, red: str) -> list[dict]:
    if not good:
        return []
    out = git("log", "--first-parent", "--reverse", "--format=%x00%H%x01%s%x01%an", "--name-only", "-m",
              f"{good}..{red}", cwd=repo_dir, check=False)
    commits = []
    for chunk in out.split("\x00")[1:]:
        head, _, files = chunk.partition("\n")
        sha, subject, author = (head.split("\x01") + ["", ""])[:3]
        commits.append({"sha": sha, "subject": subject, "author": author, "pr": pr_of(subject),
                        "files": sorted({f for f in files.split("\n") if f.strip()})})
    return commits


def pick_culprit(commits: list[dict], paths: list[str], repo_dir: Path | None = None,
                 names: list[str] | None = None, truncated: bool = False) -> tuple[dict | None, bool, list[dict]]:
    """(culprit, confirmed, suspects). One commit in the range, or one commit that touched a named file, is
    confirmed. Otherwise the commits that touched a named file's directory are suspects. A TRUNCATED range (longer
    than MAX_RANGE, so COMMITS is only its newest part) confirms nothing: an older commit may touch the file too."""
    if not commits:
        return None, False, []
    if len(commits) == 1:
        return commits[0], not truncated, commits
    hits = [c for c in commits if set(c["files"]) & set(paths)]
    if repo_dir is not None and names:
        hits = narrow(repo_dir, hits, paths, names)
    if len(hits) == 1:
        return hits[0], not truncated, hits
    if hits:
        return hits[-1], False, hits
    dirs = {p.rsplit("/", 1)[0] for p in paths if "/" in p}
    near = [c for c in commits if any(f.rsplit("/", 1)[0] in dirs for f in c["files"])]
    return (near[-1] if len(near) == 1 else None), False, near


def error_names(lines: list[str]) -> list[str]:
    """The identifiers the errors quote (`overlay`, 'rollingSummary'): a commit whose diff mentions one is the
    likelier culprit."""
    names: list[str] = []
    for line in lines:
        if not (RUST_CODE.search(line) or TS_CODE.search(line) or ERROR_START.match(line)):
            continue
        for m in re.finditer(r"[`'\"]([A-Za-z_][\w]{3,})[`'\"]", line):
            if m.group(1) not in names and m.group(1) not in {"string", "number", "undefined", "boolean"}:
                names.append(m.group(1))
    return names[:8]


def narrow(repo_dir: Path, hits: list[dict], paths: list[str], names: list[str]) -> list[dict]:
    """The HITS whose own diff of PATHS mentions one of NAMES."""
    if not names or len(hits) < 2:
        return hits
    out = []
    for c in hits:
        files = sorted(set(c["files"]) & set(paths))
        diff = git("show", "--format=", "-m", "--first-parent", c["sha"], "--", *files, cwd=repo_dir, check=False)
        changed = "\n".join(ln for ln in diff.splitlines() if ln[:1] in "+-" and ln[:3] not in ("+++", "---"))
        if any(re.search(rf"\b{re.escape(n)}\b", changed) for n in names):
            out.append(c)
    return out or hits


def red_key(workflow: str, jobs: list[str], target: str, culprit: dict | None, errors: list[str]) -> str:
    basis = culprit["sha"] if culprit else "|".join(errors) or "|".join(jobs)
    return hashlib.sha256(f"{workflow}|{target}|{basis}".encode()).hexdigest()[:10]


def last_green(repo: str, workflow_id: int, branch: str, before: str, failed_jobs: list[str], api=gh_api) -> str:
    """The head of the newest run of the workflow on BRANCH, created before BEFORE, whose run succeeded or whose
    failed jobs (by name) all succeeded."""
    runs = (api(f"repos/{repo}/actions/workflows/{workflow_id}/runs?branch={branch}&per_page=40") or {}) \
        .get("workflow_runs", [])
    for run in runs:
        if run.get("created_at", "") >= before or run.get("status") != "completed":
            continue
        if run.get("conclusion") == "success":
            return run["head_sha"]
        if run.get("conclusion") != "failure":
            continue
        jobs = (api(f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100") or {}).get("jobs", [])
        by_name = {j.get("name"): j.get("conclusion") for j in jobs}
        if failed_jobs and all(by_name.get(n) == "success" for n in failed_jobs):
            return run["head_sha"]
    return ""


def newest_is_green(repo: str, workflow_id: int, branch: str, created: str, api=gh_api) -> str:
    runs = (api(f"repos/{repo}/actions/workflows/{workflow_id}/runs?branch={branch}&per_page=10") or {}) \
        .get("workflow_runs", [])
    for run in runs:
        if run.get("created_at", "") > created and run.get("status") == "completed":
            return run["html_url"] if run.get("conclusion") == "success" else ""
    return ""


def existing_prs(repo: str, branches: list[str], api=gh_api) -> list[dict]:
    owner = repo.split("/")[0]
    found = []
    for b in branches:
        for pr in api(f"repos/{repo}/pulls?state=all&head={owner}:{b}&per_page=5") or []:
            found.append({"number": pr["number"], "state": pr["state"], "merged": bool(pr.get("merged_at")),
                          "url": pr["html_url"], "branch": b, "sha": (pr.get("head") or {}).get("sha", ""),
                          "base": (pr.get("base") or {}).get("ref", "")})
    return found


def target_tip(repo: str, target: str, api=gh_api) -> str:
    return ((api(f"repos/{repo}/git/ref/heads/{target}") or {}).get("object") or {}).get("sha", "")


# ---------------------------------------------------------------- elapsed receipts (ask-05f15b4519)

# (from, to, name): the seconds between two stamps of report["times"].
STAGES = (("detected", "triaged", "detected_to_triage"), ("triaged", "pushed", "triage_to_fix_pushed"),
          ("pushed", "verified", "fix_to_verify"), ("verified", "landed", "verify_to_land"))
STAGE_LABEL = {"detected_to_triage": "detected→triage", "triage_to_fix_pushed": "triage→fix pushed",
               "fix_to_verify": "fix→verify", "verify_to_land": "verify→land"}


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(text: str) -> datetime | None:
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return None


def stamp(report: dict, stage: str, at: str = "") -> dict:
    """Record STAGE's time in report["times"] (AT, else now) and every stage's elapsed seconds in report["elapsed"]."""
    times = report.setdefault("times", {})
    times[stage] = at or now_iso()
    elapsed = report.setdefault("elapsed", {})
    for a, b, name in STAGES:
        ta, tb = parse_iso(times.get(a, "")), parse_iso(times.get(b, ""))
        if ta and tb:
            elapsed[name] = max(0, int((tb - ta).total_seconds()))
    return elapsed


def receipt(report: dict) -> str:
    elapsed = report.get("elapsed") or {}
    parts = [f"{STAGE_LABEL[n]} {elapsed[n]} s" for _, _, n in STAGES if n in elapsed]
    return "Elapsed: " + (", ".join(parts) if parts else "none recorded")


def triage(repo: str, run_id: str, repo_dir: Path, api=gh_api, fetch=None, replay: bool = False,
           attempt: str = "", now: str = "") -> dict:
    """REPLAY reads an old red as if it had just failed (a demo): no "already green", no "already open".
    ATTEMPT pins every read to the run attempt that fired the trigger, not whatever attempt is newest now."""
    latest = api(f"repos/{repo}/actions/runs/{run_id}") or {}
    run = (api(f"repos/{repo}/actions/runs/{run_id}/attempts/{attempt}") or {}) if attempt else latest
    branch = run.get("head_branch") or ""
    workflow = run.get("name") or ""
    report = {"repo": repo, "run": run_id, "run_url": run.get("html_url", ""), "workflow": workflow,
              "workflow_path": run.get("path", ""), "branch": branch, "red": run.get("head_sha", ""),
              "attempt": run.get("run_attempt", 1), "created": run.get("created_at", ""), "action": "none",
              "why": "", "jobs": [], "paths": [], "sites": [], "errors": [], "excerpt": [], "commits": [], "suspects": [],
              "culprit": None, "confirmed": False, "target": TARGET.get(branch, ""), "lang": "other",
              "scripts": [], "key": "", "existing": [], "truncated": False}
    stamp(report, "detected", run.get("updated_at") or "")
    stamp(report, "triaged", now)
    if mode() == "off":
        report["why"] = "vars.RED_AUTOFIX is 0"
        return report
    if branch not in TARGET or run.get("event") == "pull_request":
        report["why"] = f"{branch} is not a base or the nightly"
        return report
    if run.get("conclusion") not in {"failure", "timed_out"}:
        report["why"] = f"the run concluded {run.get('conclusion')}"
        return report
    if workflow in SKIP_WORKFLOWS:
        report["why"] = f"{workflow} has its own fixer"
        return report
    if attempt and not replay and int(latest.get("run_attempt") or 0) > int(attempt):
        report["why"] = f"attempt {latest.get('run_attempt')} of this run supersedes attempt {attempt}"
        return report
    jobs_path = f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100" if attempt else \
        f"actions/runs/{run_id}/jobs?filter=latest&per_page=100"
    jobs = (api(f"repos/{repo}/{jobs_path}") or {}).get("jobs", [])
    failed = [j for j in jobs if j.get("conclusion") in {"failure", "timed_out"}]
    # A job that only reports the red (report-nightly-failure, a summary) is not the red.
    real = [j for j in failed if not REPORTER.search(j.get("name") or "")]
    failed = real or failed
    if not failed:
        report["why"] = "no failed job"
        return report
    lines: list[str] = []
    tails: list[str] = []
    for job in failed[:6]:
        step = next((s["name"] for s in job.get("steps") or [] if s.get("conclusion") == "failure"), "")
        try:
            log = strip_log(api(f"repos/{repo}/actions/jobs/{job['id']}/logs", raw=True) or "")
        except RuntimeError as err:
            log = [f"(log unread: {err})"]
        blocks = error_blocks(log)
        lines.extend(blocks or log[-60:])
        tails.extend(log[-LOG_TAIL:])
        report["jobs"].append({"id": job["id"], "name": job.get("name", ""), "step": step,
                               "url": job.get("html_url", ""), "excerpt": (blocks or log[-60:])[:60]})
    if all(j["excerpt"][:1] and j["excerpt"][0].startswith("(log unread:") for j in report["jobs"]):
        # No log, no error to hand a fixer: a blind fix run spends a model call and opens nothing.
        report["action"], report["why"] = "report", "no failed job's log could be read: " + report["jobs"][0]["excerpt"][0]
        return report
    red = report["red"]
    if fetch:
        fetch(red)
    tree = git("ls-tree", "-r", "--name-only", red, cwd=repo_dir, check=False).splitlines()
    paths = named_paths(lines, tree)[:20]
    report["sites"] = error_sites(lines, tree)[:20]
    report.update(paths=paths, errors=error_keys(lines, report["sites"] or paths), excerpt=lines[:120],
                  lang=language(report["sites"] or paths, lines), scripts=bun_scripts(lines))
    kind = classify(lines + tails, paths)
    green = "" if replay else newest_is_green(repo, run["workflow_id"], branch, report["created"], api=api)
    if green:
        report["why"] = f"a newer {workflow} run on {branch} is green ({green})"
        return report
    if kind == "infra":
        if workflow == "Nightly macOS build":
            report["action"] = "report"
            report["why"] = "an infrastructure red; the nightly's own retry-nightly-next reruns it"
        elif int(report["attempt"]) > 1:
            report["why"] = "an infrastructure red that its rerun repeated; left for fleet repair"
            report["action"] = "report"
        else:
            report["action"], report["why"] = "rerun", "an infrastructure red (no repository file named)"
        return report
    good = last_green(repo, run["workflow_id"], branch, report["created"], [j["name"] for j in failed], api=api)
    if fetch and good:
        fetch(good)
    commits = range_commits(repo_dir, good, red)
    truncated = range_truncated(repo_dir, good, red)
    report["names"] = error_names(lines)
    culprit, confirmed, suspects = pick_culprit(commits, report["sites"] or paths, repo_dir, report["names"],
                                                truncated=truncated)
    report.update(good=good, commits=commits, culprit=culprit, confirmed=confirmed, truncated=truncated,
                  suspects=[s["sha"] for s in suspects])
    report["key"] = red_key(workflow, [j["name"] for j in failed], report["target"], culprit, report["errors"])
    branches = [f"autofix/red-{report['key']}"]
    if culprit:
        branches.append(revert_branch(culprit))
    report["existing"] = [] if replay else existing_prs(repo, branches, api=api)
    stop = stale_or_stop(repo, report, api=api)
    if stop:
        report["why"] = stop
        return report
    regen = next((r for r in REGEN if any(r["job"].search(j.get("name") or "") for j in failed)), None)
    if regen:
        report["regen"] = regen["artifact"]
    report["action"] = "fix"
    report["why"] = (f"{'regen' if regen else kind} red; culprit {'#' + culprit['pr'] if culprit and culprit['pr'] else (culprit or {}).get('sha', 'unknown')[:12]}"
                     f" ({'confirmed' if confirmed else 'suspected'}) in {len(commits)} commits since {good[:12] or 'no known green'}")
    return report


def stale_or_stop(repo: str, report: dict, api=gh_api) -> str:
    """Why an existing red-autofix pull request for this red stops a new fix ("" when none does). A closed or merged
    one always does (a person said no, or it landed). An open one does while it sits on the target's current tip
    (it is in flight); one on an older tip is stale (land refused it because the base moved), and the new fix
    refreshes it on the current tip (report["refresh"])."""
    mine = [p for p in report["existing"] if p["branch"].startswith("autofix/")]
    if not mine:
        return ""
    urls = ", ".join(p["url"] for p in mine)
    if any(p["state"] != "open" for p in mine):
        return "a red-autofix pull request for this red already exists: " + urls
    tip = target_tip(repo, report["target"], api=api)
    for p in mine:
        parents = (api(f"repos/{repo}/commits/{p['sha']}") or {}).get("parents") or [{}] if p.get("sha") else [{}]
        if not tip or parents[0].get("sha") == tip:
            return "a red-autofix pull request for this red is in flight on the current tip: " + urls
    report["refresh"] = mine[0]["number"]
    return ""


def revert_branch(culprit: dict) -> str:
    return f"revert/pr-{culprit['pr']}" if culprit.get("pr") else f"revert/red-{culprit['sha'][:12]}"


# ---------------------------------------------------------------- the fixer's brief


def prompt(report: dict, repo_dir: Path) -> str:
    culprit = report.get("culprit") or {}
    diff = ""
    if culprit:
        diff = git("show", "--stat", "--patch", "--format=%H %s%n%an", "-m", "--first-parent", culprit["sha"],
                   cwd=repo_dir, check=False)[:24000]
    commits = "\n".join(f"- {c['sha'][:12]} {c['subject']} ({', '.join(c['files'][:8])})"
                        for c in report.get("commits", [])[-30:])
    jobs = "\n\n".join(f"### {j['name']} / step {j['step'] or '?'}\n```\n" + "\n".join(j["excerpt"]) + "\n```"
                       for j in report["jobs"])
    return f"""You are fixing a red on {report['branch']} of {report['repo']}: the workflow "{report['workflow']}"
({report['workflow_path']}) failed at {report['red']}. The working tree is {report['target']}'s current tip.

The failed jobs and their errors:

{jobs}

Files the red names: {', '.join(report['paths']) or '(none)'}
Commits since the last green run ({(report.get('good') or 'unknown')[:12]}):
{commits or '(unknown range)'}

The likely culprit ({'confirmed' if report['confirmed'] else 'suspected'}):
```
{diff or '(not named)'}
```

Make the smallest fix-forward that makes this check green again on the tip, the way the culprit's author would have
if the check had run before the merge: a missing field or argument, a renamed symbol, a type, a lint or format fix,
a design token, a dependency line, a stale generated file. Read the files first; the tip may already differ from the
log. Rules: do not delete or skip tests, do not disable, loosen or weaken a check, do not add ignores or `any` or
`#[allow]`, do not revert the culprit (a revert runs beside you), touch at most {MAX_FILES} files and {MAX_LINES}
lines, and touch nothing unrelated to these errors. If the right fix is not mechanical (a design decision, a
behaviour change, or you cannot see the cause), change nothing and answer mechanical=false.
Answer with mechanical (true when you made the fix) and a one-paragraph summary of what you changed and why."""


# ---------------------------------------------------------------- opening and landing


def pr_body(report: dict, kind: str, summary: str, held: str) -> str:
    culprit = report.get("culprit") or {}
    who = f"#{culprit['pr']}" if culprit.get("pr") else f"`{culprit.get('sha', '?')[:12]}`"
    jobs = ", ".join(f"[{j['name']}]({j['url']})" for j in report["jobs"])
    parts = ([TEAMMATE_HOLD.format(login=held)] if held else []) + [
        f"**{report['workflow']}** went red on `{report['branch']}` at `{report['red'][:12]}` "
        f"([run]({report['run_url']}); {jobs}).",
        (f"Fix-forward by the red-autofix fixer: {summary}" if kind == "fix" else
         f"Reverts {who} ({'confirmed' if report['confirmed'] else 'suspected'} culprit: "
         f"{len(report.get('commits', []))} commits since the last green `{(report.get('good') or '?')[:12]}`)."),
        "The fix-forward and the revert race: red-autofix runs the red's own check on each, and the first green "
        "one merges; the other is closed." + ("" if held else " Close this to say no; it is never reopened."),
        "Errors:\n\n```\n" + "\n".join(report["excerpt"][:40]) + "\n```",
        f"Base-red-job: {report['workflow']} / {report['jobs'][0]['name'] if report['jobs'] else '?'}",
        "Opened by .github/workflows/red-autofix.yml (scripts/ci/red_autofix.py). Leo, 2026-11-25: "
        "\"what about autofix? and faster autofixes\".",
    ]
    return "\n\n".join(parts)


def teammate_of(repo: str, culprit: dict, api=gh_api) -> str:
    """The core teammate whose change the culprit is ("" when nobody's). Unreadable counts as a teammate's."""
    try:
        if culprit.get("pr"):
            pr = api(f"repos/{repo}/pulls/{culprit['pr']}") or {}
            logins = [(pr.get("user") or {}).get("login", "")]
        else:
            c = api(f"repos/{repo}/commits/{culprit['sha']}") or {}
            logins = [(c.get("author") or {}).get("login", ""), (c.get("committer") or {}).get("login", "")]
    except RuntimeError:
        return "the culprit's author (unread)"
    return next((login for login in logins if login in TEAMMATES), "")


def open_pr(report: dict, kind: str, repo_dir: Path, push_url: str, summary: str = "", api=gh_api) -> dict:
    """Commit the candidate on the target tip checked out in REPO_DIR, push its branch, open the pull request."""
    culprit = report.get("culprit") or {}
    ident = ["-c", f"user.name={BOT[0]}", "-c", f"user.email={BOT[1]}"]
    held = ""
    if kind == "fix":
        numstat = git("diff", "--numstat", "HEAD", cwd=repo_dir)
        files = [ln.split("\t")[2] for ln in numstat.splitlines() if ln.count("\t") >= 2]
        lines = sum(int(a) + int(b) for a, b, *_ in (ln.split("\t") for ln in numstat.splitlines())
                    if a.isdigit() and b.isdigit())
        if not files:
            return {"action": "none", "why": "the fixer changed nothing"}
        # A pushed branch runs its own workflow files with the repository's secrets: the fixer may touch one only
        # when it is the workflow the red named.
        named = set(report.get("paths") or []) if report.get("lang") == "workflow" else set()
        ci = [f for f in files if f.startswith(".github/") and f not in named]
        if ci:
            git("reset", "--quiet", "--hard", cwd=repo_dir)
            return {"action": "none", "why": f"the fixer's diff touches {ci[0]}, which the red did not name"}
        if report.get("regen_applied") and all(regen_allowed(report["regen"], f) for f in files):
            pass
        elif len(files) > MAX_FILES or lines > MAX_LINES:
            git("reset", "--quiet", "--hard", cwd=repo_dir)
            return {"action": "none", "why": f"the fixer's diff is {len(files)} files, {lines} lines: too large"}
        branch = f"autofix/red-{report['key']}"
        title = f"fix({report['target']}): {report['workflow']} red since {culprit_label(report)} (red-autofix)"
        git(*ident, "commit", "--quiet", "-am", title + f"\n\n{summary}\n\nRed: {report['run_url']}", cwd=repo_dir)
    else:
        if not culprit or not report.get("confirmed"):
            return {"action": "none", "why": "no confirmed culprit to revert"}
        branch = revert_branch(culprit)
        if any(p["branch"] == branch for p in report.get("existing", [])):
            pr = next(p for p in report["existing"] if p["branch"] == branch)
            return {"action": "exists", "number": pr["number"], "url": pr["url"], "state": pr["state"],
                    "sha": "", "branch": branch}
        parents = git("rev-list", "--parents", "-n1", culprit["sha"], cwd=repo_dir).split()[1:]
        mainline = ["-m", "1"] if len(parents) > 1 else []
        done = subprocess.run(["git", *ident, "revert", "--no-edit", *mainline, culprit["sha"]], cwd=repo_dir,
                              capture_output=True, text=True)
        if done.returncode:
            subprocess.run(["git", "revert", "--abort"], cwd=repo_dir, capture_output=True)
            return {"action": "none", "why": f"the revert of {culprit['sha'][:12]} conflicts with the tip"}
        held = teammate_of(report["repo"], culprit, api=api)
        title = f'Revert "{culprit["subject"]}" (red-autofix: {report["workflow"]} red on {report["branch"]})'
    sha = git("rev-parse", "HEAD", cwd=repo_dir).strip()
    pushed = subprocess.run(["git", "push", "--force", "--quiet", push_url, f"HEAD:refs/heads/{branch}"],
                            cwd=repo_dir, capture_output=True, text=True)
    if pushed.returncode:
        return {"action": "none", "why": "push refused: " + redact(pushed.stderr)[-600:]}
    try:
        created = api(f"repos/{report['repo']}/pulls", method="POST",
                      fields={"head": branch, "base": report["target"], "title": title[:250],
                              "body": pr_body(report, kind, summary, held)}) or {}
    except RuntimeError as err:
        created, why = {}, str(err)
    else:
        why = "the create answered no number"
    if not created.get("number"):
        # An ambiguous answer (a timeout after GitHub made it, or "already exists" for a refreshed branch): the
        # pull request of this head and base is ours when its head is the commit just pushed.
        created = find_pr(report["repo"], branch, report["target"], sha, api=api)
        if not created:
            return {"action": "none", "why": f"pull request create failed and none of {branch} is at "
                    f"{sha[:12]}: {redact(why)[-300:]}", "sha": sha, "branch": branch}
    number = created.get("number")
    try:
        api(f"repos/{report['repo']}/issues/{number}/labels", method="POST", fields={"labels": [LABEL]})
    except RuntimeError:
        pass
    return {"action": "held" if held else "opened", "number": number, "url": created.get("html_url", ""),
            "sha": sha, "branch": branch, "held": held}


def find_pr(repo: str, branch: str, base: str, sha: str, api=gh_api) -> dict:
    """The open pull request from BRANCH onto BASE whose head is SHA ({} when none)."""
    owner = repo.split("/")[0]
    try:
        prs = api(f"repos/{repo}/pulls?state=open&head={owner}:{branch}&base={base}&per_page=5") or []
    except RuntimeError:
        return {}
    return next((pr for pr in prs if (pr.get("head") or {}).get("sha") == sha
                 and (pr.get("base") or {}).get("ref") == base), {})


def regen_fresh(report: dict, repo_dir: Path) -> tuple[bool, str]:
    """The red's regenerated files fit the tip in REPO_DIR when the red ran on the tip itself, or when nothing but
    generated output changed between the red's head and the tip (their generator inputs are the same). Else the
    model fixer, which reads the tip, makes the fix."""
    red = report.get("red", "")
    tip = git("rev-parse", "HEAD", cwd=repo_dir, check=False).strip()
    if red and red == tip:
        return True, "the red ran on the tip"
    if not red or git("cat-file", "-t", red, cwd=repo_dir, check=False).strip() != "commit":
        return False, f"the red's head {red[:12] or '?'} is not in the checkout"
    changed = [f for f in git("diff", "--name-only", red, "HEAD", cwd=repo_dir, check=False).splitlines() if f]
    inputs = [f for f in changed if not regen_allowed(report.get("regen", ""), f)]
    if inputs:
        return False, (f"the tip moved past the red's head {red[:12]} and changed {len(inputs)} non-generated "
                       f"files (e.g. {inputs[0]}): the artifact may be stale")
    return True, f"the tip moved past {red[:12]} only in generated files"


def regen_allowed(artifact: str, path: str) -> bool:
    spec = next((r for r in REGEN if r["artifact"] == artifact), None)
    return bool(spec) and ".." not in Path(path).parts and not path.startswith("/") and \
        any(fnmatch.fnmatchcase(path, g) for g in spec["globs"])


def apply_regen(report: dict, files_dir: Path, repo_dir: Path) -> tuple[int, str]:
    """Copy the red's regenerated files (FILES_DIR, the downloaded artifact) onto the tip in REPO_DIR."""
    listing = files_dir / ".paths"
    if not report.get("regen") or not listing.is_file():
        return 0, "no regenerated files"
    fresh, why = regen_fresh(report, repo_dir)
    if not fresh:
        return 0, why
    copied = 0
    for path in listing.read_text().split("\n"):
        path = path.strip()
        src = files_dir / path
        if not path or not regen_allowed(report["regen"], path) or src.is_symlink() or not src.is_file():
            continue
        dest = repo_dir / path
        if dest.is_symlink():
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(src.read_bytes())
        # Staged, so a new generated file survives the open step's `git clean` and lands in the commit.
        git("add", "--", path, cwd=repo_dir)
        copied += 1
    return copied, f"copied {copied} regenerated files from {report['regen']}"


def culprit_label(report: dict) -> str:
    c = report.get("culprit") or {}
    return f"#{c['pr']}" if c.get("pr") else (c.get("sha", "")[:12] or "an unknown merge")


def redact(text: str) -> str:
    return re.sub(r"x-access-token:[^@\s]+@", "x-access-token:***@", text)


def sibling_pr(repo: str, branch: str, base: str, api=gh_api) -> dict:
    """The other candidate for this red: BRANCH's pull request onto the same BASE (a revert/pr-N onto another base
    is another red's). The branch name carries the incident: autofix/red-KEY, or revert/pr-N of this culprit."""
    if not branch:
        return {}
    owner = repo.split("/")[0]
    prs = api(f"repos/{repo}/pulls?state=all&head={owner}:{branch}&base={base}&per_page=5") or []
    same = [pr for pr in prs if (pr.get("base") or {}).get("ref") == base
            and (pr.get("head") or {}).get("ref", branch) == branch]
    # An open one first, else the newest.
    return next((pr for pr in same if pr.get("state") == "open"), same[0] if same else {})


def land(report: dict, kind: str, number: int, sha: str, sibling_branch: str, base: str = "", api=gh_api,
         run=subprocess.run) -> dict:
    """Merge NUMBER (verified green at SHA on the target tip BASE) unless its sibling merged or is armed to; close
    the sibling first. The two land jobs share one concurrency group, and a candidate armed for auto-merge blocks
    its sibling, so the two never both merge. A target that moved past BASE since the verdict refuses: the merged
    tree was never checked (the red's next run refreshes the fix on the new tip, stale_or_stop)."""
    repo = report["repo"]
    if mode() != "on":
        return {"action": "none", "why": f"vars.RED_AUTOFIX is {mode()}: never merges"}
    pr = api(f"repos/{repo}/pulls/{number}") or {}
    if pr.get("state") != "open":
        return {"action": "none", "why": f"#{number} is {pr.get('state')}"}
    if (pr.get("head") or {}).get("sha") != sha:
        return {"action": "none", "why": f"#{number}'s head moved past the verified {sha[:12]}"}
    if "HOLD:" in (pr.get("body") or ""):
        return {"action": "held", "why": f"#{number} is held for its author"}
    if not base:
        return {"action": "none", "why": "no verified base recorded: refusing an unchecked merge"}
    tip = target_tip(repo, report["target"], api=api)
    if tip != base:
        return {"action": "none", "why": f"{report['target']} moved from the verified {base[:12]} to "
                f"{tip[:12] or '?'}: the merged tree is unchecked; the red's next run refreshes the candidate"}
    other = sibling_pr(repo, sibling_branch, report["target"], api=api)
    if other.get("merged_at"):
        close(repo, number, f"#{other['number']} merged first and fixed this red.", api=api)
        return {"action": "closed", "why": f"#{other['number']} merged first"}
    if other.get("state") == "open" and other.get("auto_merge"):
        return {"action": "none", "why": f"#{other['number']} is armed to merge first; #{number} waits"}
    title = pr.get("title", "")
    try:
        api(f"repos/{repo}/pulls/{number}/merge", method="PUT",
            fields={"merge_method": "squash", "sha": sha, "commit_title": f"{title} (#{number})"})
    except RuntimeError as err:
        # A base whose ruleset still waits on a required check (main's CLA checks): merge when they pass.
        armed = run(["gh", "pr", "merge", str(number), "--repo", repo, "--auto", "--squash",
                     "--match-head-commit", sha], capture_output=True, text=True)
        if armed.returncode:
            return {"action": "none", "why": f"merge refused ({err}); auto-merge refused too: "
                    + armed.stderr.strip()[-300:]}
        return {"action": "armed", "why": f"#{number} merges when the base's required checks pass ({err})"}
    if other.get("state") == "open" and "HOLD:" not in (other.get("body") or ""):
        close(repo, other["number"], f"#{number} ({kind}) went green first and merged; this one is no longer "
              "needed.", api=api)
    return {"action": "merged", "why": f"#{number} merged at {sha[:12]}"}


def close(repo: str, number: int, why: str, api=gh_api) -> None:
    """Close first (the winner may already have merged, and nothing else closes the loser); the comment saying why
    is best-effort."""
    api(f"repos/{repo}/pulls/{number}", method="PATCH", fields={"state": "closed"})
    try:
        api(f"repos/{repo}/issues/{number}/comments", method="POST", fields={"body": f"red-autofix: {why}"})
    except RuntimeError as err:
        print(f"red-autofix: closed #{number}; its comment failed: {err}")


# ---------------------------------------------------------------- verify


def nearest(repo_dir: Path, path: str, marker: str) -> Path | None:
    d = (repo_dir / path).parent
    while True:
        if (d / marker).exists():
            return d
        if d == repo_dir or repo_dir not in d.parents and d != repo_dir:
            return None
        d = d.parent


SITE = re.compile(r"-->\s|╭─\[|\(\d+,\d+\)|:\d+:\d+|error\[E\d+\]|\bTS\d{4}")


def error_sites(lines: list[str], tree: list[str]) -> list[str]:
    """The files the errors point at (rustc's `-->`, tsc's `file(line,col)`, oxc's `╭─[file:line:col]`), not the
    harness scripts a log also names."""
    return named_paths([ln for ln in lines if SITE.search(ln)], tree)


def verify_commands(report: dict, repo_dir: Path) -> tuple[list[tuple[str, str]], list[tuple[str, str, str]]]:
    """(setup, checks): setup is (directory, command) pairs run once per tree; checks are (name, directory,
    command) triples, each the red's own check. REPO_DIR is the target's tip, so a candidate cannot drop or rename
    the check it is judged by. A red that named its bun scripts runs exactly those, never a stand-in: typecheck
    is the check only when the red named no script."""
    lang = report["lang"]
    paths = report.get("sites") or report["paths"]
    setup: list[tuple[str, str]] = []
    checks: list[tuple[str, str, str]] = []
    if lang == "ts":
        pkgs: list[Path] = []
        for p in paths:
            d = nearest(repo_dir, p, "package.json")
            if d and d not in pkgs and d != repo_dir:
                pkgs.append(d)
        if not pkgs and (repo_dir / "webviews/package.json").exists():
            pkgs.append(repo_dir / "webviews")
        named = report.get("scripts") or []
        for d in pkgs[:2]:
            where = str(d.relative_to(repo_dir))
            scripts = json.loads((d / "package.json").read_text()).get("scripts", {})
            wanted = [x for x in named if x in scripts] if named else [x for x in ("typecheck",) if x in scripts]
            if not wanted:
                continue
            setup.append((where, "bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null; "
                          "[ ! -f scripts/pages/gen-strings.mjs ] || bun scripts/pages/gen-strings.mjs --best-effort "
                          ">/dev/null 2>&1 || true"))
            checks += [(f"{where}: {x}", where, f"bun run {x}") for x in wanted]
    elif lang == "rust":
        crates: list[str] = []
        for p in paths:
            if p.endswith(".rs"):
                d = nearest(repo_dir, p, "Cargo.toml")
                if d and str(d.relative_to(repo_dir)) not in crates:
                    crates.append(str(d.relative_to(repo_dir)))
        checks += [(f"cargo check {c}", c, "cargo check --all-targets --quiet") for c in crates[:3]]
    elif lang == "workflow":
        files = " ".join(p for p in paths if p.startswith(".github/workflows/"))
        checks.append(("actionlint", ".", f"actionlint {files}"))
    elif lang == "python":
        files = " ".join(p for p in paths if p.endswith(".py"))
        checks.append(("py_compile", ".", f"python3 -m py_compile {files}"))
    return setup, checks


class IsolationError(RuntimeError):
    """The sandbox could not be set up: verify is red, never a run outside it."""


SANDBOX_USER = "red-autofix-verify"


class Sandbox:
    """Where a candidate's own code runs (bun install, package scripts, build scripts, the check itself): trees
    exported from the checkout without .git, owned by a separate uid (USER, through sudo -n), run under env -i
    with an allowlisted environment. That uid cannot write the runner's control files (GITHUB_OUTPUT, GITHUB_ENV),
    the workspace or the supervisor, and holds no token, so only the supervisor, reading exit codes, writes the
    verdict. USER None runs as the caller and is for the tests alone; Sandbox.isolated() never builds one."""

    def __init__(self, root: Path, user: str | None):
        self.root, self.user = root, user

    @classmethod
    def isolated(cls, lang: str, run=subprocess.run, which=shutil.which) -> "Sandbox":
        def must(argv: list[str], what: str) -> str:
            try:
                done = run(argv, capture_output=True, text=True, timeout=900)
            except (OSError, subprocess.SubprocessError) as err:
                raise IsolationError(f"{what}: {err}") from err
            if done.returncode:
                raise IsolationError(f"{what}: {(done.stderr or '').strip()[-200:]}")
            return done.stdout or ""

        must(["sudo", "-n", "true"], "no passwordless sudo to run the candidate as another uid")
        if run(["id", "-u", SANDBOX_USER], capture_output=True, text=True).returncode:
            must(["sudo", "-n", "useradd", "--system", "--no-create-home", "--shell", "/usr/sbin/nologin",
                  SANDBOX_USER], f"useradd {SANDBOX_USER}")
        # Under /tmp, not RUNNER_TEMP: the uid must reach it without the runner's home.
        root = Path(tempfile.mkdtemp(prefix="red-verify-", dir="/tmp"))
        root.chmod(0o755)
        (root / "bin").mkdir()
        # The toolchains, copied where that uid can run them (the runner's home is not its to read).
        for tool in ("bun", "actionlint"):
            found = which(tool)
            if found:
                shutil.copy2(os.path.realpath(found), root / "bin" / tool)
        if lang == "rust":
            sysroot = must(["rustc", "--print", "sysroot"], "rustc --print sysroot").strip()
            try:
                shutil.copytree(sysroot, root / "rust", symlinks=True)
            except OSError as err:
                raise IsolationError(f"copy the rust toolchain: {err}") from err
            cargo = which("cargo")
            if cargo and not (root / "rust/bin/cargo").exists():
                shutil.copy2(os.path.realpath(cargo), root / "bin" / "cargo")
        return cls(root, SANDBOX_USER)

    def env(self) -> dict:
        home = self.root / "home"
        return {"PATH": f"{self.root}/bin:{self.root}/rust/bin:/usr/local/bin:/usr/bin:/bin", "HOME": str(home),
                "TMPDIR": str(home), "CARGO_HOME": str(home / ".cargo"), "LANG": "C.UTF-8", "CI": "1",
                "TERM": "dumb"}

    def prepare(self, repo_dir: Path) -> tuple[Path, Path]:
        """(candidate tree, tip tree): HEAD and HEAD~1 of REPO_DIR, exported, owned by the sandbox uid."""
        trees = []
        for name, rev in (("cand", "HEAD"), ("tip", "HEAD~1")):
            dest = self.root / name
            dest.mkdir()
            archive = subprocess.run(["git", "archive", "--format=tar", rev], cwd=repo_dir, capture_output=True)
            if archive.returncode:
                raise IsolationError(f"git archive {rev}: {archive.stderr.decode(errors='replace')[-200:]}")
            untar = subprocess.run(["tar", "-x", "-C", str(dest)], input=archive.stdout, capture_output=True)
            if untar.returncode:
                raise IsolationError(f"untar {rev}: {untar.stderr.decode(errors='replace')[-200:]}")
            trees.append(dest)
        (self.root / "home").mkdir()
        if self.user:
            done = subprocess.run(["sudo", "-n", "chown", "-R", f"{self.user}:", str(self.root / "home"),
                                   *map(str, trees)], capture_output=True, text=True)
            if done.returncode:
                raise IsolationError(f"chown to {self.user}: {done.stderr.strip()[-200:]}")
        return trees[0], trees[1]

    def run(self, cmd: str, cwd: Path) -> subprocess.CompletedProcess:
        argv = ["env", "-i", *(f"{k}={v}" for k, v in self.env().items()), "bash", "-c", cmd]
        if self.user:
            argv = ["sudo", "-n", "-u", self.user, "--", *argv]
        try:
            return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=1800)
        except (OSError, subprocess.SubprocessError) as err:
            return subprocess.CompletedProcess(argv, 1, "", f"{cmd}: {err}")


def run_checks(report: dict, tree: Path, commands, runner) -> dict:
    """{check name: (passed, output tail, printed the red's errors)} on TREE. A check that passes but still prints
    one of the red's error codes fails."""
    setup, checks = commands
    for where, cmd in setup:
        runner(cmd, tree / where)
    out = {}
    for name, where, cmd in checks:
        done = runner(cmd, tree / where)
        text = ANSI.sub("", (done.stdout or "") + (done.stderr or ""))
        left = [k for k in report.get("errors", []) if re.search(rf"\b{re.escape(k.split(':')[-1])}\b", text)]
        out[name] = (done.returncode == 0 and not left, "\n".join(text.splitlines()[-30:]), bool(left))
    return out


def verify(report: dict, repo_dir: Path, sandbox: Sandbox | None = None) -> tuple[bool, str]:
    """The candidate is HEAD in REPO_DIR, one commit on the target's tip (HEAD~1); both run the red's checks in
    SANDBOX (Sandbox.isolated() when none, which raises IsolationError when it cannot be set up). Green: the red
    reproduces on the tip, every one of its failures there (a failing check that prints the red's errors, or
    every failing check when the red named none) passes on the candidate, and the candidate fails no check the
    tip passed. A tip failure of another cause may stay red."""
    sandbox = sandbox or Sandbox.isolated(report["lang"])
    cand_dir, tip_dir = sandbox.prepare(repo_dir)
    commands = verify_commands(report, tip_dir)
    if not commands[1]:
        return False, f"no local check for a {report['lang']} red: the pull request's own checks decide"
    tip = run_checks(report, tip_dir, commands, sandbox.run)
    tip_failed = {n for n, (ok, _, _) in tip.items() if not ok}
    if not tip_failed:
        return False, ("the red no longer reproduces on the tip (" + ", ".join(f"`{n}`" for n in tip) +
                       " passed there), so this candidate fixes nothing")
    incident = {n for n in tip_failed if tip[n][2]} if report.get("errors") else tip_failed
    if not incident:
        return False, ("the red's errors no longer reproduce on the tip (" +
                       ", ".join(f"`{n}`" for n in sorted(tip_failed)) + " fail there for another reason)")
    cand = run_checks(report, cand_dir, commands, sandbox.run)
    failed = {n for n, (ok, _, _) in cand.items() if not ok}
    new = failed - tip_failed
    if new:
        name = sorted(new)[0]
        return False, f"`{name}` fails on the candidate and passed on the tip:\n" + cand[name][1]
    unresolved = incident & failed
    if unresolved:
        name = sorted(unresolved)[0]
        return False, f"`{name}`, one of the red's own failures, still fails on the candidate:\n" + cand[name][1]
    rest = sorted(failed)
    return True, ("fixed " + ", ".join(f"`{n}`" for n in sorted(incident)) +
                  ("; still red on the tip too, not this red's: " + ", ".join(f"`{n}`" for n in rest) if rest else ""))


def pr_checks_green(repo: str, sha: str, expected: list[str], api=gh_api, wait_min: int = 45, sleep=time.sleep,
                    clock=time.time, self_name: str = "red-autofix") -> tuple[bool, str]:
    """Poll the check runs on SHA: green when every EXPECTED check (the red's own failed jobs) is present and
    passed and none failed. An expected check not reported yet is pending, never a pass."""
    want = [n for n in dict.fromkeys(expected) if n]
    if not want:
        return False, "the red named no check to wait for"
    deadline = clock() + wait_min * 60
    while True:
        runs = (api(f"repos/{repo}/commits/{sha}/check-runs?per_page=100") or {}).get("check_runs", [])
        runs = [r for r in runs if self_name not in (r.get("name") or "")]
        bad = [r["name"] for r in runs if r.get("conclusion") in {"failure", "timed_out", "cancelled",
                                                                  "action_required"}]
        if bad:
            return False, "red checks: " + ", ".join(bad[:8])
        by_name: dict[str, list[dict]] = {}
        for r in runs:
            by_name.setdefault(r.get("name") or "", []).append(r)
        waiting = [n for n in want if not by_name.get(n) or not all(
            r.get("status") == "completed" and r.get("conclusion") == "success" for r in by_name[n])]
        if not waiting:
            return True, "the red's checks passed: " + ", ".join(f"`{n}`" for n in want)
        if clock() > deadline:
            return False, f"still pending or absent after {wait_min} min: " + ", ".join(f"`{n}`" for n in waiting[:8])
        sleep(30)


# ---------------------------------------------------------------- CLI


def cmd_triage(args) -> int:
    repo_dir = Path(args.repo_dir).resolve()

    def fetch(sha: str) -> None:
        subprocess.run(["git", "fetch", "--quiet", "--filter=blob:none", "origin", sha], cwd=repo_dir,
                       capture_output=True)

    report = triage(args.repo, args.run, repo_dir, fetch=fetch, replay=args.replay, attempt=args.attempt)
    Path(args.out).write_text(json.dumps(report, indent=1))
    say(f"red-autofix: **{report['action']}** for {report['workflow'] or '?'} on {report['branch'] or '?'} "
        f"({report['run_url']}): {report['why']}")
    if report["jobs"]:
        say("Failed: " + ", ".join(f"{j['name']} / {j['step']}" for j in report["jobs"]) +
            f"\n\nFiles named: {', '.join(report['paths']) or 'none'}; language {report['lang']}")
    if report.get("truncated"):
        say(f"The range past the last green run is longer than {MAX_RANGE} commits: no culprit is confirmed.")
    write_outputs({"action": report["action"], "target": report["target"], "key": report["key"],
                   "lang": report["lang"], "revert": "true" if report.get("confirmed") else "false",
                   "red": report["red"], "regen": report.get("regen", ""), "run": report["run"]})
    return 0


def cmd_prompt(args) -> int:
    report = json.loads(Path(args.report).read_text())
    Path(args.out).write_text(prompt(report, Path(args.repo_dir).resolve()))
    return 0


def cmd_open(args) -> int:
    report_path = Path(args.report)
    report = json.loads(report_path.read_text())
    out = open_pr(report, args.kind, Path(args.repo_dir).resolve(), args.push_url, args.summary or "")
    pushed_at = ""
    if out.get("number"):
        pushed_at = now_iso()
        stamp(report, "pushed", pushed_at)
        report_path.write_text(json.dumps(report, indent=1))
    say(f"red-autofix {args.kind}: {out['action']} {out.get('url', '')} {out.get('why', '')}".strip())
    if pushed_at:
        say(receipt(report))
    write_outputs({**{k: v for k, v in out.items() if k in {"action", "number", "url", "sha", "branch"}},
                   "pushed_at": pushed_at})
    return 0


def cmd_diff(args) -> int:
    """The fixer's change as a patch: FIXER_TREE (a plain copy of the tracked files, no .git) against the HEAD of
    REPO_DIR, read with a throwaway index and no config, hooks or fsmonitor from either tree."""
    repo_dir = Path(args.repo_dir).resolve()
    tree = Path(args.tree).resolve()
    with tempfile.TemporaryDirectory(prefix="red-diff-") as tmp:
        index = Path(tmp) / "index"
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env.update({"GIT_DIR": str(repo_dir / ".git"), "GIT_WORK_TREE": str(tree), "GIT_INDEX_FILE": str(index),
                    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"})
        safe = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=" + os.devnull, "-c", "diff.external=",
                "-c", "core.attributesFile=" + os.devnull]
        for argv in (["read-tree", "HEAD"], ["add", "--all", "--", "."]):
            done = subprocess.run(["git", *safe, *argv], cwd=tree, env=env, capture_output=True, text=True)
            if done.returncode:
                say(f"red-autofix diff: git {argv[0]} failed: {done.stderr.strip()[-300:]}")
                return 1
        done = subprocess.run(["git", *safe, "diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv",
                               "HEAD"], cwd=tree, env=env, capture_output=True)
        if done.returncode:
            say(f"red-autofix diff: git diff failed: {done.stderr.decode(errors='replace').strip()[-300:]}")
            return 1
    Path(args.out).write_bytes(done.stdout)
    write_outputs({"changed": "true" if done.stdout.strip() else "false"})
    return 0


def cmd_regen(args) -> int:
    report_path = Path(args.report)
    report = json.loads(report_path.read_text())
    repo_dir = Path(args.repo_dir).resolve()
    copied, why = apply_regen(report, Path(args.files), repo_dir)
    changed = bool(git("status", "--porcelain", cwd=repo_dir).strip()) if copied else False
    if changed:
        report["regen_applied"] = True
        report_path.write_text(json.dumps(report, indent=1))
        if args.patch_out:
            Path(args.patch_out).write_bytes(subprocess.run(
                ["git", "diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "HEAD"], cwd=repo_dir,
                capture_output=True, check=True).stdout)
    say(f"red-autofix regen: {why}; {'the tip changes' if changed else 'nothing applied'}")
    write_outputs({"applied": "true" if changed else "false",
                   "summary": f"Regenerated files copied from the red run's {report.get('regen')} artifact."})
    return 0


def cmd_verify(args) -> int:
    report = json.loads(Path(args.report).read_text())
    repo_dir = Path(args.repo_dir).resolve()
    expected = [j["name"] for j in report.get("jobs", [])]
    base = git("rev-parse", "HEAD~1", cwd=repo_dir, check=False).strip() if (repo_dir / ".git").exists() else ""
    if args.pr_checks:
        ok, why = pr_checks_green(report["repo"], args.sha, expected, wait_min=args.wait)
    else:
        try:
            ok, why = verify(report, repo_dir)
        except IsolationError as err:
            ok, why = False, f"isolation could not be set up, so the candidate did not run: {err}"
        if not ok and why.startswith("no local check"):
            ok, why = pr_checks_green(report["repo"], args.sha, expected, wait_min=args.wait)
    verified_at = now_iso() if ok else ""
    if args.pushed_at:
        stamp(report, "pushed", args.pushed_at)
    if verified_at:
        stamp(report, "verified", verified_at)
    say(f"red-autofix verify {args.kind} at `{args.sha[:12]}` on base `{base[:12]}`: "
        f"{'green' if ok else 'red'}: {why}\n\n{receipt(report)}")
    write_outputs({"green": "true" if ok else "false", "base": base if ok else "", "verified_at": verified_at})
    return 0


def cmd_land(args) -> int:
    report_path = Path(args.report)
    report = json.loads(report_path.read_text())
    if args.kind == "fix":
        sibling = revert_branch(report["culprit"]) if report.get("culprit") else ""
    else:
        sibling = f"autofix/red-{report['key']}"
    out = land(report, args.kind, int(args.pr), args.sha, sibling, base=args.base)
    for stage, at in (("pushed", args.pushed_at), ("verified", args.verified_at)):
        if at:
            stamp(report, stage, at)
    if out["action"] in {"merged", "armed"}:
        stamp(report, "landed")
    report["land"] = out
    report_path.write_text(json.dumps(report, indent=1))
    say(f"red-autofix land {args.kind} #{args.pr}: {out['action']}: {out['why']}\n\n{receipt(report)}")
    return 0


MARKER_AUTHOR = "github-actions[bot]"


def own_marker(comments: list[dict], key: str) -> dict | None:
    """This workflow's comment for KEY: posted by the Actions bot and opening with the marker, never a comment
    anyone else wrote that quotes it."""
    marker = f"<!-- red-autofix:{key} -->"
    return next((c for c in comments if (c.get("user") or {}).get("login") == MARKER_AUTHOR
                 and (c.get("body") or "").startswith(marker)), None)


def cmd_comment(args, api=gh_api) -> int:
    """Tell the culprit's pull request what broke and which pull requests fix it (one comment, edited)."""
    report = json.loads(Path(args.report).read_text())
    culprit = report.get("culprit") or {}
    if not culprit.get("pr") or not report.get("confirmed"):
        return 0
    links = " ".join(x for x in (args.fix, args.revert) if x)
    body = (f"<!-- red-autofix:{report['key']} -->\nred-autofix: this merge broke **{report['workflow']}** on "
            f"`{report['branch']}` ([run]({report['run_url']})). Fix-forward and revert race: {links or 'none opened'}"
            ".\n\n```\n" + "\n".join(report["excerpt"][:25]) + "\n```")
    repo = report["repo"]
    comments = api(f"repos/{repo}/issues/{culprit['pr']}/comments?per_page=100") or []
    mine = own_marker(comments, report["key"])
    if mine:
        api(f"repos/{repo}/issues/comments/{mine['id']}", method="PATCH", fields={"body": body})
    else:
        api(f"repos/{repo}/issues/{culprit['pr']}/comments", method="POST", fields={"body": body})
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    repo = os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux")
    t = sub.add_parser("triage")
    t.add_argument("--run", required=True)
    t.add_argument("--attempt", default="", help="the red's run_attempt: read that attempt, not the latest")
    t.add_argument("--out", required=True)
    t.add_argument("--replay", action="store_true", help="read an old red as if it had just failed (a demo)")
    for s in (t,):
        s.add_argument("--repo", default=repo)
    for name in ("prompt", "open", "verify", "land", "comment", "regen"):
        s = sub.add_parser(name)
        s.add_argument("--report", required=True)
    d = sub.add_parser("diff", help="the fixer tree's change against REPO_DIR's HEAD, as a binary patch")
    d.add_argument("--tree", required=True)
    d.add_argument("--out", required=True)
    for s in (t, d, sub.choices["prompt"], sub.choices["open"], sub.choices["verify"], sub.choices["regen"]):
        s.add_argument("--repo-dir", default=".")
    sub.choices["prompt"].add_argument("--out", required=True)
    sub.choices["regen"].add_argument("--files", required=True, help="the downloaded regen artifact")
    sub.choices["regen"].add_argument("--patch-out", default="", help="write the applied change here as a patch")
    o = sub.choices["open"]
    o.add_argument("--kind", choices=["fix", "revert"], required=True)
    o.add_argument("--push-url", required=True)
    o.add_argument("--summary", default="")
    v = sub.choices["verify"]
    v.add_argument("--kind", default="fix")
    v.add_argument("--sha", required=True)
    v.add_argument("--pr-checks", action="store_true")
    v.add_argument("--wait", type=int, default=40)
    v.add_argument("--pushed-at", default="")
    la = sub.choices["land"]
    la.add_argument("--kind", choices=["fix", "revert"], required=True)
    la.add_argument("--pr", required=True)
    la.add_argument("--sha", required=True)
    la.add_argument("--base", default="", help="the target tip the candidate was verified on")
    la.add_argument("--pushed-at", default="")
    la.add_argument("--verified-at", default="")
    c = sub.choices["comment"]
    c.add_argument("--fix", default="")
    c.add_argument("--revert", default="")
    args = p.parse_args(argv)
    return {"triage": cmd_triage, "prompt": cmd_prompt, "open": cmd_open, "verify": cmd_verify, "land": cmd_land,
            "comment": cmd_comment, "regen": cmd_regen, "diff": cmd_diff}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
