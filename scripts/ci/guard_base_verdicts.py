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
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

API = "https://api.github.com"
WORKFLOW = "cmux-next-guards.yml"
BRANCH = "feat-cmux-next"
ARTIFACT_PREFIX = "guard-verdicts-"
# Finished push runs come about every 20 minutes and 40 commits (11-26: 82 commits between two of them), and a pull
# request's base lags the tip: 60 commits back missed the nearest finished run for one of three sampled bases.
MAX_BEHIND = 120
RUNS_PAGE = 100
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


# A push run that never ran the guard group has no artifact. The push concurrency group keeps one pending run, so with
# a merge about a minute apart 98 of the newest 100 completed push runs were `cancelled` (2026-11-26); the newest
# real run was about 40 commits back, below a first page of 30 cancelled ones. Every one of those got a compare call:
# up to 31 GITHUB_TOKEN reads per pull request run against the repository's shared budget, and 5 of 8 sampled runs
# then failed with HTTP 403 and re-ran every red step on the base (270-500 s of a ~12 minute step).
SKIPPED_CONCLUSIONS = frozenset({"cancelled", "skipped"})
MAX_SOURCES = 3  # candidate push runs main tries when the nearest one uploaded no artifact


def sources(repo: str, base: str, token: str, get=api_json):
    """Each (push run, ancestor..base changed paths or None at the base itself) that may hold the base's verdicts,
    nearest first. The runs come newest first and feat-cmux-next only moves forward, so the first ancestor is the
    nearest and every older run is further: no compare is read past the first ancestor until it is needed."""
    runs = get(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?branch={BRANCH}&event=push&status=completed"
               f"&per_page={RUNS_PAGE}", token).get("workflow_runs") or []
    runs = [run for run in runs if run.get("conclusion") not in SKIPPED_CONCLUSIONS]
    exact = [run for run in runs if run.get("head_sha") == base]
    if exact:
        yield exact[0], None
    seen: set[str] = {base}
    for run in runs:
        sha = run.get("head_sha") or ""
        if not sha or sha in seen:
            continue
        seen.add(sha)
        compare = get(f"repos/{repo}/compare/{sha}...{base}", token)
        # "ahead": base is ahead of the run's commit, which is then an ancestor of the base.
        if compare.get("status") != "ahead" or int(compare.get("behind_by") or 0) != 0:
            continue
        if int(compare.get("ahead_by") or 0) > MAX_BEHIND:
            return  # every older run is further back still
        files = compare.get("files")
        # The compare lists at most 300 files: a full listing, or nothing is reused from this ancestor.
        paths = [f["filename"] for f in files] if isinstance(files, list) and len(files) < 300 else None
        yield run, (paths if paths is not None else ["<unlisted>"] * 10_000)


def find_source(repo: str, base: str, token: str, get=api_json) -> tuple[dict, list[str] | None] | None:
    """The nearest of sources(), or None."""
    return next(sources(repo, base, token, get=get), None)


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


# The push run's verdicts in the CI cache bucket too (the ci-guard-verdicts-r2 job): its public URL answers with no
# token, so this read spends none of the repository's REST quota. 2026-11-26: 3 of 3 sampled pull request guard
# groups read HTTP 403 from the artifact API (the hourly quota spent), re-ran 48-52 red steps on the base for
# 301-406 s, and every one of them was red on the base too.
R2_NAMESPACE = "guard-verdicts"
R2_EXTENSIONS = ("tar.zst", "tar.gz")


def ancestors(root: Path, base: str, depth: int = MAX_BEHIND) -> list[str]:
    """BASE and its first-parent ancestors, nearest first, from ROOT's git (deepened blobless when shallow)."""
    def git(*args: str) -> str:
        return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True,
                              timeout=60).stdout
    try:
        listed = git("rev-list", "--first-parent", f"--max-count={depth + 1}", base).split()
    except (subprocess.SubprocessError, OSError):
        listed = []
    if len(listed) <= depth:
        try:
            git("fetch", "--no-tags", "--quiet", "--filter=blob:none", f"--depth={depth + 1}", "origin", base)
            listed = git("rev-list", "--first-parent", f"--max-count={depth + 1}", base).split()
        except (subprocess.SubprocessError, OSError):
            pass
    return listed or [base]


def changed_between(root: Path, older: str, newer: str) -> list[str] | None:
    try:
        out = subprocess.run(["git", "-C", str(root), "diff", "--no-renames", "--name-only", older, newer],
                             check=True, capture_output=True, text=True, timeout=60).stdout
    except (subprocess.SubprocessError, OSError):
        return None
    return [line for line in out.splitlines() if line]


def _fetch_public(url: str) -> bytes | None:
    try:
        with urllib.request.urlopen(urllib.request.Request(url), timeout=TIMEOUT_S) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code in (403, 404):
            return None  # the bucket answers 403 or 404 for a key it does not hold
        raise


def _unpack(blob: bytes, extension: str) -> tuple[dict, dict] | None:
    if extension == "tar.zst":
        try:
            blob = subprocess.run(["zstd", "-dc"], input=blob, check=True, capture_output=True, timeout=60).stdout
        except (subprocess.SubprocessError, OSError):
            return None
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:*") as archive:
        members = {Path(m.name).name: m for m in archive.getmembers() if m.isfile()}

        def read(name: str) -> dict | None:
            member = members.get(name)
            handle = archive.extractfile(member) if member is not None else None
            found = json.loads(handle.read().decode("utf-8")) if handle is not None else None
            return found if isinstance(found, dict) else None

        results = read("guards-head.json")
        if results is None:
            return None
        return results, read("guards-head.json.failures.json") or {}


def r2_results(public_url: str, sha: str, fetch=_fetch_public) -> tuple[dict, dict] | None:
    for extension in R2_EXTENSIONS:
        blob = fetch(f"{public_url.rstrip('/')}/v1/{R2_NAMESPACE}/objects/{ARTIFACT_PREFIX}{sha}.{extension}")
        if blob is not None:
            found = _unpack(blob, extension)
            if found is not None:
                return found
    return None


def r2_source(public_url: str, root: Path, base: str, fetch=_fetch_public, shas: list[str] | None = None):
    """(sha, (results, failures), ancestor..base changed paths or None at the base) of the nearest verdicts in R2."""
    for sha in shas if shas is not None else ancestors(root, base):
        found = r2_results(public_url, sha, fetch=fetch)
        if found is None:
            continue
        if sha == base:
            return sha, found, None
        changed = changed_between(root, sha, base)
        return sha, found, (changed if changed is not None else ["<unlisted>"] * 10_000)
    return None


# A change to these changes how every step runs (the runner, its shell, its expressions): nothing is reused across it.
# ci-guards.yml and the selection are left out of it here: a step whose own definition (step_definitions) and whose
# inputs are the same at the ancestor and the base gives the same verdict, whatever else the workflow changed.
# 11-26: ci-guards.yml changed in every 40-commit window between two finished push runs, so the whole-run rule
# reused nothing from any ancestor and every pull request re-ran 48-52 base-red steps (301-406 s).
RUNNER_INPUTS = frozenset({
    "scripts/ci/run_ci_guards.py",
    "scripts/ci/guards-local.sh",
    "scripts/ci/gh_expressions.py",
    "scripts/cmux-next/safe_log.py",
})
WORKFLOW_PATH = ".github/workflows/ci-guards.yml"
ANCESTOR_MAX_CHANGED = 2000  # a diff past this reuses nothing: a bound on the selection's cost, not its truth


def step_definitions(workflow: dict) -> dict[str, str]:
    """{step name: what its verdict depends on besides its inputs}: the workflow's env, the step's job (all but
    its steps), the job's setup steps run_ci_guards.py leaves to Actions, the steps before it that hand it state,
    and the step itself, for every group it runs in."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import hashlib  # noqa: PLC0415
    import run_ci_guards  # noqa: PLC0415

    jobs = workflow.get("jobs") or {}
    found: dict[str, list[str]] = {}
    for unit in run_ci_guards.plan(workflow, "BASE_SHA", "HEAD"):
        job = jobs.get(unit.job) or {}
        setup = [raw for raw in job.get("steps") or []
                 if "uses" in raw or str(raw.get("name")) in run_ci_guards.DEPENDENCY_STEPS
                 or str(raw.get("name")) in run_ci_guards.WORKSPACE_STEPS]
        context = {"env": workflow.get("env"), "job": {k: v for k, v in job.items() if k != "steps"}, "setup": setup}
        handed: list = []
        for step in unit.steps:
            own = [step.name, step.run, step.working_directory, sorted(step.env.items())]
            text = json.dumps([context, unit.group, handed, own], sort_keys=True, default=str)
            found.setdefault(step.name, []).append(hashlib.sha256(text.encode("utf-8")).hexdigest())
            if run_ci_guards.hands_state(step):
                handed.append(own)
    return {name: ",".join(sorted(hashes)) for name, hashes in found.items()}


def workflow_at(git_root: Path, sha: str) -> dict | None:
    """ci-guards.yml as it was at SHA, from GIT_ROOT's git (a blobless clone fetches the one blob)."""
    try:
        import yaml  # type: ignore  # noqa: PLC0415

        text = subprocess.run(["git", "-C", str(git_root), "show", f"{sha}:{WORKFLOW_PATH}"], check=True,
                              capture_output=True, text=True, timeout=120).stdout
        loaded = yaml.safe_load(text)
    except Exception:  # noqa: BLE001 - an unreadable ancestor workflow reuses nothing
        return None
    return loaded if isinstance(loaded, dict) else None


def unreachable_steps(root: Path, steps: list[str], changed: list[str], git_root: Path | None = None,
                      ancestor: str | None = None) -> set[str]:
    """The steps (of STEPS) whose verdict at the ancestor is the base's: the CHANGED paths (ancestor..base) reach
    none of their inputs by guard_step_inputs.py's selection on ROOT (the base), and their definition in
    ci-guards.yml is the same at ANCESTOR as at the base when the diff touches it."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import guard_step_inputs  # noqa: PLC0415 - the selection, beside this script
    import run_ci_guards  # noqa: PLC0415

    if len(changed) > ANCESTOR_MAX_CHANGED or RUNNER_INPUTS.intersection(changed):
        return set()
    known = {s[0]: s for s in guard_step_inputs.guard_steps(root)}
    wanted = [known[name] for name in steps if name in known]
    if WORKFLOW_PATH in changed:
        older = workflow_at(git_root or root, ancestor) if ancestor else None
        if older is None:
            return set()
        try:
            before = step_definitions(older)
        except Exception:  # noqa: BLE001 - an ancestor workflow the runner cannot plan reuses nothing
            return set()
        now = step_definitions(run_ci_guards.load_yaml(root / WORKFLOW_PATH))
        wanted = [s for s in wanted if before.get(s[0]) is not None and before.get(s[0]) == now.get(s[0])]
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
    parser.add_argument("--git-root", default=".", help="a checkout whose git holds the base (deepened when shallow)")
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
    public_url = os.environ.get("CI_CACHE_R2_PUBLIC_URL") or ""
    if public_url:
        try:
            hit = r2_source(public_url, Path(args.git_root), args.base)
        except Exception as error:  # noqa: BLE001 - an R2 read that breaks falls to the artifact API
            print(f"base verdicts: the CI cache read failed ({type(error).__name__}: {error})", file=sys.stderr)
            hit = None
        if hit is not None:
            sha, downloaded, changed = hit
            usable = None if changed is None else unreachable_steps(Path(args.root), steps, changed, Path(args.git_root), sha)
            return write_reused(Path(args.out), downloaded, steps, usable,
                                f"the CI cache at {'the base itself' if changed is None else f'an ancestor {sha[:12]} ({len(changed)} paths behind)'}")
    if not token:
        return everything("no token")
    try:
        downloaded = None
        tried: list[str] = []
        for run, changed in sources(args.repo, args.base, token):
            downloaded = download_results(args.repo, run, token)
            if downloaded is not None:
                break
            tried.append(str(run.get("id")))
            if len(tried) >= MAX_SOURCES:
                break
        if downloaded is None and not tried:
            return everything(f"no completed {BRANCH} push run at {args.base[:12]} or within {MAX_BEHIND} commits before it")
        if downloaded is None:
            return everything(f"push runs {', '.join(tried)} uploaded no {ARTIFACT_PREFIX}artifact")
        usable = None if changed is None else unreachable_steps(Path(args.root), steps, changed, Path(args.git_root),
                                                                 run.get("head_sha"))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, urllib.error.URLError) as error:
        return everything(f"{type(error).__name__}: {error}")
    except Exception as error:  # noqa: BLE001 - a broken read fails open: every step re-runs on the base
        return everything(f"{type(error).__name__}: {error}")
    where = "the base itself" if changed is None else f"an ancestor {run.get('head_sha', '')[:12]} ({len(changed)} paths behind)"
    return write_reused(Path(args.out), downloaded, steps, usable, f"push run {run.get('id')} at {where}")


def write_reused(out: Path, downloaded: tuple[dict, dict], steps: list[str], usable: set[str] | None, where: str) -> int:
    kept, kept_failures, left = reuse(*downloaded, steps, usable)
    # Incomplete: a red step with no key here (left to the re-run, or new) is never read as new to the base.
    out.write_text(json.dumps({**kept, "_cmux_complete": False}, indent=2) + "\n", encoding="utf-8")
    Path(str(out) + ".failures.json").write_text(json.dumps(kept_failures, indent=2) + "\n", encoding="utf-8")
    print(f"base verdicts: {len(steps) - len(left)} of {len(steps)} red steps reused from {where}; "
          f"{len(left)} re-run on the base", file=sys.stderr)
    for step in left:
        print(step)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
