#!/usr/bin/env python3
"""The base's guard verdicts from feat-cmux-next's own push run, so a pull request re-runs fewer steps on the base.

    guard_base_verdicts.py --repo OWNER/NAME --base SHA --root BASE_CHECKOUT --steps FILE --out RESULTS
    guard_base_verdicts.py --merge RECORDED RERUN OUT

A feat-cmux-next push runs every guard step (cmux-next-guards.yml ci-guard-group) and uploads its results as the
artifact `guard-verdicts-<sha>` (run_ci_guards.py --results and its `.failures.json`). A pull request's guard group
re-runs the head's red steps on the base to tell the change's reds from the base's. That re-run took up to 8 of the
job's 17 minutes and often ran out of budget, which leaves those steps `unknown` and the job red (11-25: 87 of 89
pull request runs red). This reads the newest completed push run at the base, or at the nearest ancestor of the
base within MAX_BEHIND commits, and reuses its verdict for each step:

  - at the base itself: every step the push run has a result for;
  - at an ancestor: only the steps the ancestor..base diff cannot reach (guard_step_inputs.py, the selection
    run_ci_guards.py --affected uses: a step whose inputs a diff leaves as they were gives the same verdict).
    A diff the selection cannot read (too many paths, the selection itself changed, a compare listing cut at
    300 files) reuses nothing from an ancestor.

It writes the reused results (and their failures) to RESULTS, marked incomplete so a missing key stays unknown,
and prints the steps that still need the base re-run, one a line. Anything it cannot read (no token, no run, no
artifact, an API error) prints every step: the job re-runs them all, as before.

--merge puts the reused results and the re-run's into OUT, the base results guards_new_reds.py reads, with the
failures beside each. OUT is complete only when the re-run finished (or nothing was left to re-run), so the
decision rule is the one before: a red fails the job only when the base does not explain it.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

API = "https://api.github.com"
WORKFLOW = "cmux-next-guards.yml"
BRANCH = "feat-cmux-next"
ARTIFACT_PREFIX = "guard-verdicts-"
MAX_BEHIND = 60
RUNS_PAGE = 30
CHECK_SEPARATOR = " :: "
TIMEOUT_S = 20


class _NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    """Follow the artifact download's redirect without sending the token to the storage host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001, D401
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            new.headers.pop("Authorization", None)
            new.unredirected_hdrs.pop("Authorization", None)
        return new


def _request(url: str, token: str) -> bytes:
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    opener = urllib.request.build_opener(_NoAuthRedirect)
    with opener.open(req, timeout=TIMEOUT_S) as response:
        return response.read()


def api_json(path: str, token: str) -> dict:
    return json.loads(_request(f"{API}/{path}", token).decode("utf-8"))


def step_of(key: str) -> str:
    return key.split(CHECK_SEPARATOR, 1)[0]


def find_source(repo: str, base: str, token: str, get=api_json) -> tuple[dict, list[str] | None] | None:
    """(push run, ancestor..base changed paths or None at the base itself), the nearest completed one."""
    runs = get(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?branch={BRANCH}&event=push&status=completed"
               f"&per_page={RUNS_PAGE}", token).get("workflow_runs") or []
    for run in runs:
        if run.get("head_sha") == base:
            return run, None
    best: tuple[int, dict, list[str] | None] | None = None
    seen: set[str] = set()
    for run in runs:
        sha = run.get("head_sha") or ""
        if not sha or sha in seen:
            continue
        seen.add(sha)
        compare = get(f"repos/{repo}/compare/{sha}...{base}", token)
        # "ahead": base is ahead of the run's commit, which is then an ancestor of the base.
        if compare.get("status") != "ahead" or int(compare.get("behind_by") or 0) != 0:
            continue
        ahead = int(compare.get("ahead_by") or 0)
        if ahead > MAX_BEHIND or (best is not None and ahead >= best[0]):
            continue
        files = compare.get("files")
        # The compare lists at most 300 files: a full listing, or nothing is reused from this ancestor.
        paths = [f["filename"] for f in files] if isinstance(files, list) and len(files) < 300 else None
        best = (ahead, run, paths)
        if ahead <= 1:
            break
    if best is None:
        return None
    _ahead, run, paths = best
    return run, (paths if paths is not None else ["<unlisted>"] * 10_000)


def download_results(repo: str, run: dict, token: str, get=api_json, fetch=_request) -> tuple[dict, dict] | None:
    """The push run's (results, failures) from its guard-verdicts artifact."""
    name = ARTIFACT_PREFIX + (run.get("head_sha") or "")
    listing = get(f"repos/{repo}/actions/runs/{run['id']}/artifacts?name={name}", token).get("artifacts") or []
    live = [a for a in listing if a.get("name") == name and not a.get("expired")]
    if not live:
        return None
    blob = fetch(f"{API}/repos/{repo}/actions/artifacts/{live[0]['id']}/zip", token)
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        names = archive.namelist()
        results_name = next((n for n in names if n.endswith("guards-head.json")), None)
        if results_name is None:
            return None
        results = json.loads(archive.read(results_name).decode("utf-8"))
        failures_name = results_name + ".failures.json"
        failures = json.loads(archive.read(failures_name).decode("utf-8")) if failures_name in names else {}
    if not isinstance(results, dict) or not isinstance(failures, dict):
        return None
    return results, failures


def unreachable_steps(root: Path, steps: list[str], changed: list[str]) -> set[str]:
    """The steps (of STEPS) the CHANGED paths cannot reach, by guard_step_inputs.py's selection on ROOT."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import guard_step_inputs  # noqa: PLC0415 - the selection, beside this script

    if guard_step_inputs.everything_reason(changed):
        return set()
    known = {s[0]: s for s in guard_step_inputs.guard_steps(root)}
    wanted = [known[name] for name in steps if name in known]
    picked = guard_step_inputs.select(guard_step_inputs.Tree(root), wanted, changed)
    # A step the selection does not know (a routed group outside ci-guards.yml) is never reused from an ancestor.
    return {s[0] for s in wanted if s[0] not in picked}


def reuse(results: dict, failures: dict, steps: list[str], usable: set[str] | None) -> tuple[dict, dict, list[str]]:
    """(reused results, reused failures, steps left to re-run). USABLE None means every step may be reused."""
    by_step: dict[str, list[str]] = {}
    for key in results:
        if not str(key).startswith("_cmux_"):
            by_step.setdefault(step_of(str(key)), []).append(str(key))
    kept: dict = {}
    kept_failures: dict = {}
    left: list[str] = []
    for step in steps:
        keys = by_step.get(step)
        if not keys or (usable is not None and step not in usable):
            left.append(step)
            continue
        for key in keys:
            kept[key] = bool(results[key])
            if key in failures:
                kept_failures[key] = failures[key]
    return kept, kept_failures, left


def _read(path: Path) -> dict:
    try:
        found = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return found if isinstance(found, dict) else {}


def merge(recorded: Path, rerun: Path | None, out: Path) -> dict:
    """RECORDED's reused results under RERUN's (None: nothing re-ran), into OUT with the failures beside it."""
    kept = {k: v for k, v in _read(recorded).items() if not str(k).startswith("_cmux_")}
    failures = _read(Path(str(recorded) + ".failures.json"))
    if rerun is None:
        complete = True
        ran: dict = {}
    else:
        ran = _read(rerun)
        complete = bool(ran) and bool(ran.get("_cmux_complete", True))
        failures.update(_read(Path(str(rerun) + ".failures.json")))
    body = {**kept, **ran, "_cmux_complete": complete}
    out.write_text(json.dumps(body, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    Path(str(out) + ".failures.json").write_text(json.dumps(failures, indent=2) + "\n", encoding="utf-8")
    return body


def main(argv: list[str]) -> int:
    if argv[:1] == ["--merge"]:
        if len(argv) != 4:
            print("usage: guard_base_verdicts.py --merge RECORDED RERUN|- OUT", file=sys.stderr)
            return 2
        merge(Path(argv[1]), None if argv[2] == "-" else Path(argv[2]), Path(argv[3]))
        return 0
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--root", required=True, help="the base checkout")
    parser.add_argument("--steps", required=True, help="the head's red steps, one a line")
    parser.add_argument("--out", required=True, help="where the reused base results go")
    args = parser.parse_args(argv)
    steps = [s for s in Path(args.steps).read_text(encoding="utf-8").splitlines() if s.strip()]
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""

    def everything(why: str) -> int:
        print(f"base verdicts: none reused ({why}); the base re-runs all {len(steps)} red steps", file=sys.stderr)
        for step in steps:
            print(step)
        return 0

    if not steps:
        return 0
    if not token:
        return everything("no token")
    try:
        found = find_source(args.repo, args.base, token)
        if found is None:
            return everything(f"no completed {BRANCH} push run at {args.base[:12]} or within {MAX_BEHIND} commits before it")
        run, changed = found
        downloaded = download_results(args.repo, run, token)
        if downloaded is None:
            return everything(f"push run {run.get('id')} uploaded no {ARTIFACT_PREFIX}artifact")
        usable = None if changed is None else unreachable_steps(Path(args.root), steps, changed)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, urllib.error.URLError) as error:
        return everything(f"{type(error).__name__}: {error}")
    except Exception as error:  # noqa: BLE001 - a broken read fails open: every step re-runs on the base
        return everything(f"{type(error).__name__}: {error}")
    kept, kept_failures, left = reuse(*downloaded, steps, usable)
    out = Path(args.out)
    # Incomplete: a red step with no key here (left to the re-run, or new) is never read as new to the base.
    out.write_text(json.dumps({**kept, "_cmux_complete": False}, indent=2) + "\n", encoding="utf-8")
    Path(str(out) + ".failures.json").write_text(json.dumps(kept_failures, indent=2) + "\n", encoding="utf-8")
    where = "the base itself" if changed is None else f"an ancestor {run.get('head_sha', '')[:12]} ({len(changed)} paths behind)"
    print(f"base verdicts: {len(steps) - len(left)} of {len(steps)} red steps reused from push run {run.get('id')} at {where}; "
          f"{len(left)} re-run on the base", file=sys.stderr)
    for step in left:
        print(step)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
