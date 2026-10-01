#!/usr/bin/env python3
"""Screenshots and a GIF of each app pull request's build, in its dogfood comment.

pr-media.yml runs this from the default branch for every same-repository pull
request CI run, next to CI and never inside it:

- `plan` waits for the CI run's app build (and its dogfood build job, when
  the dev-build label runs one), then picks the dogfood tours (dogfood/scenarios/*.json at the
  head) whose `paths` globs match the changed files. A `Dogfood-tours:` line in
  the pull request body overrides the pick; `Dogfood-tours: none` turns media
  off. With no match it takes DEFAULT_TOUR. Tours already published for this
  head are not run again.
- `tour` runs one tour through scripts/run-e2e.sh with --adopt-only, so it loads
  the app and UI test bundle the pull request's CI compiled (or, when CI reused
  main's build, main's build of the same inputs). It never compiles unless a
  manual dispatch passes allow_compile. It turns the tour's frames into a few
  PNGs and a captioned GIF. A tour that could not run is noted with why.
- `publish` uploads them to the `pr-media` branch at <pr>/<sha8>/<tour>/ and
  writes a media section into the sticky dogfood comment (DOGFOOD_MARKER),
  unless a newer push has moved the head since.

Nothing here decides a merge: the workflow is not a required check.
"""

from __future__ import annotations

import argparse
import base64
import fnmatch
import html
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
from typing import Any, Callable, Iterable

ROOT = Path(__file__).resolve().parents[2]
CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
# ci.yml's dogfood-build job. It runs only for same-repository app pull
# requests (not docs or web only), so its presence is the media gate.
DOGFOOD_JOB_PREFIX = "Dogfood build #"
DOGFOOD_MARKER = "<!-- cmux:dogfood-build -->"
SECTION_START = "<!-- cmux:pr-media:start -->"
SECTION_END = "<!-- cmux:pr-media:end -->"
MEDIA_BRANCH = "pr-media"
SCENARIOS_DIR = "dogfood/scenarios"
DEFAULT_TOUR = "sidebar-and-chrome-tour"
MAX_TOURS = 2
TOUR_NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,63}")
SHA = re.compile(r"[0-9a-f]{40}")
OVERRIDE_LINE = re.compile(r"^\s*dogfood-tours\s*:\s*(.*?)\s*$", re.IGNORECASE | re.MULTILINE)
RUN_LINE = re.compile(r"^Run: https://github\.com/[^/]+/[^/]+/actions/runs/(\d+)")
# dispatch-focused-test.py --adopt-only: no CI product this run could load.
NO_PRODUCT_EXIT = 3
# dispatch-focused-test.py --adopt-only: CI's product is on a pool the tour's runner cannot load.
UNLOADABLE_PRODUCT_EXIT = 4
# How a tour gets its app: adopt the build a CI run of the pull request made
# (ADOPT_CI), adopt main's build of the same inputs when CI reused it
# (ADOPT_MAIN), or compile one (COMPILE_NOW, only for a manual allow_compile).
ADOPT_CI, ADOPT_MAIN, COMPILE_NOW = "ci", "main", "now"
COMPILE_MODES = (ADOPT_CI, ADOPT_MAIN, COMPILE_NOW)
# Product inputs no tour shows (the CLI lane, the app-host unit tests): a
# pull request that only changes these never compiles an app for its tours.
NON_TOUR_PRODUCT_PREFIXES = ("CLI/", "cmuxCLITests/", "cmuxCLITestSupport/", "cmuxTests/")
GATE_WAIT_SECONDS = 25 * 60
# Reads share the repository's token budget with the dispatcher, so waits poll slowly.
GATE_POLL_SECONDS = 60
RUN_POLL_SECONDS = 120
RUN_WAIT_SECONDS = 90 * 60
ADMISSION_JOB_SUFFIX = "macOS compile admission"
# test-e2e.yml's step that fails a require_adopted_product run whose reuse missed.
REFUSE_STEP = "Refuse to compile for a dispatch that requires an adopted product"
# ... and the one that fails it when reuse errored (no evidence either way).
REUSE_ERROR_STEP = "Fail a dispatch that requires an adopted product when reuse errored"
MERGE_REF = re.compile(r"refs/pull/\d+/merge")
TESTED_LINE = re.compile(r"^Testing \S+ at ([0-9a-f]{40}) \(request ")
MAX_KEY_SHOTS = 4
GIF_WIDTHS = (720, 560, 440)
# Under scripts/pr-media.py's INLINE_MAX_BYTES: GitHub stops rendering a larger gif inline.
GIF_MAX_BYTES = 4 * 1024 * 1024
FRAME_MS, LAST_FRAME_MS = 1600, 3200
# Frames every tour takes that show no change of its own. 99-final-screen is
# the whole display, which on a CI Mac is mostly other windows.
SKIP_IN_GIF = {"99-final-screen"}
SKIP_AS_KEY = {"00-launched", "99-final", "99-final-screen"}


# ---------------------------------------------------------------------------
# GitHub


def gh_json(args: list[str], *, allow_missing: bool = False, attempts: int = 4,
            sleep: Callable[[float], None] = time.sleep) -> Any:
    """A GET through gh. READ_TOKEN (the route App's own budget), when the
    workflow minted one, carries reads; transient failures are retried."""
    env = {**os.environ, "GH_TOKEN": os.environ["READ_TOKEN"]} if os.environ.get("READ_TOKEN") else None
    for attempt in range(attempts):
        done = subprocess.run(["gh", "api", *args], capture_output=True, text=True, env=env)
        if done.returncode == 0:
            return json.loads(done.stdout) if done.stdout.strip() else None
        if allow_missing and ("HTTP 404" in done.stderr or "Not Found" in done.stderr):
            return None
        if env and re.search(r"HTTP 401|Bad credentials", done.stderr):
            # The read token lives an hour and a tour can outlast it: fall back to the job token.
            env = None
            continue
        transient = re.search(r"HTTP 5\d\d|timeout|connection|EOF", done.stderr, re.IGNORECASE)
        if not transient or attempt == attempts - 1:
            raise RuntimeError(f"gh api {' '.join(args)}: {done.stderr.strip()[:300]}")
        sleep(5 * (attempt + 1))
    return None


def write_outputs(values: dict[str, str]) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    lines = [f"{key}={value}" for key, value in values.items()]
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    print("\n".join(lines), flush=True)


# ---------------------------------------------------------------------------
# Tour selection


def parse_override(body: str | None) -> list[str] | None:
    """The tours a `Dogfood-tours:` line names, [] for `none`, None without one."""
    match = OVERRIDE_LINE.search(body or "")
    if not match:
        return None
    names = [name.strip().removesuffix(".json") for name in re.split(r"[,\s]+", match.group(1)) if name.strip()]
    if any(name.casefold() == "none" for name in names):
        return []
    return list(dict.fromkeys(names))


def tour_globs(scenario: object) -> list[str]:
    if not isinstance(scenario, dict):
        return []
    paths = scenario.get("paths")
    if not isinstance(paths, list):
        return []
    return [path for path in paths if isinstance(path, str) and path.strip()]


def select_tours(scenarios: dict[str, object], changed: Iterable[str], body: str | None,
                 default: str = DEFAULT_TOUR, limit: int = MAX_TOURS) -> tuple[list[str], str]:
    """Tour names to run, most matched files first, and why.

    A glob is fnmatch style (`*` crosses directories). A pull request that edits
    a tour's own file always shows that tour.
    """
    override = parse_override(body)
    if override is not None:
        if not override:
            return [], "the pull request body says Dogfood-tours: none"
        known = [name for name in override if name in scenarios]
        unknown = [name for name in override if name not in scenarios]
        reason = "named in the pull request body"
        if unknown:
            reason += f" (no such tour: {', '.join(unknown)})"
        return known[:limit], reason
    changed = list(changed)
    scores: dict[str, int] = {}
    for name, scenario in scenarios.items():
        own = f"{SCENARIOS_DIR}/{name}.json"
        globs = tour_globs(scenario)
        hits = sum(1 for path in changed if path == own or any(fnmatch.fnmatchcase(path, glob) for glob in globs))
        if hits:
            scores[name] = hits
    if scores:
        ranked = sorted(scores, key=lambda name: (-scores[name], name))
        return ranked[:limit], "matched the changed files"
    if default in scenarios:
        return [default], "no tour's paths matched, so the default tour"
    return [], "no tour matched and the default tour is missing"


def reaches_app(path: str) -> bool:
    """Whether a changed path can change the app a tour shows: an input of the
    app-host product (product_input_identity.reaches_product, what CI keys its
    build on) outside NON_TOUR_PRODUCT_PREFIXES."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("product_input_identity",
                                                  ROOT / "scripts/ci/product_input_identity.py")
    assert spec and spec.loader
    identity = sys.modules.get(spec.name)
    if identity is None:
        identity = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = identity
        spec.loader.exec_module(identity)
    return identity.reaches_product(path) and not path.startswith(NON_TOUR_PRODUCT_PREFIXES)


def head_scenarios(head_sha: str) -> dict[str, object]:
    """Tours at the head commit, read from git objects (never checked out or run)."""
    listing = subprocess.run(["git", "ls-tree", "--name-only", head_sha, f"{SCENARIOS_DIR}/"],
                             cwd=ROOT, check=True, capture_output=True, text=True).stdout.split()
    scenarios: dict[str, object] = {}
    for path in listing:
        name = Path(path).name.removesuffix(".json")
        if not path.endswith(".json") or not TOUR_NAME.fullmatch(name):
            continue
        raw = subprocess.run(["git", "show", f"{head_sha}:{path}"], cwd=ROOT, check=True,
                             capture_output=True, text=True).stdout
        try:
            scenarios[name] = json.loads(raw)
        except json.JSONDecodeError:
            print(f"::warning::{path} is not valid JSON; skipping it", flush=True)
    return scenarios


def media_prefix(pr: int | str, head_sha: str) -> str:
    return f"{pr}/{head_sha[:8]}"


def published(repository: str, pr: int | str, head_sha: str, tour: str) -> dict | None:
    """The manifest a finished tour of this head left on the media branch."""
    found = gh_json([f"repos/{repository}/contents/{media_prefix(pr, head_sha)}/{tour}/manifest.json?ref={MEDIA_BRANCH}"],
                    allow_missing=True)
    if not isinstance(found, dict) or not found.get("content"):
        return None
    try:
        manifest = json.loads(base64.b64decode(found["content"]))
    except (ValueError, json.JSONDecodeError):
        return None
    # Only a tour that ran counts; a skipped one runs again on the next attempt.
    return manifest if isinstance(manifest, dict) and manifest.get("run_url") else None


BUILT, REUSED, NO_BUILD = "built", "reused", ""
# ci.yml static-preflight, which `macos` needs.
STATIC_JOB = "Fast static checks"


def app_build_gate(repository: str, run_id: str, attempt: str, pr: int,
                   sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic) -> str:
    """How the CI attempt of an app pull request provides an app build.

    BUILT: its compile admission ran. REUSED: it skipped the macOS caller
    because an earlier run already compiled the same build inputs (a push that
    only edits a tour, docs or tests). NO_BUILD: anything else.

    It reads a finished attempt (pr-media.yml starts when CI completes), so
    it waits only in tests. The dogfood build job is opt-in (the dev-build
    label); when it runs it rewrites the whole sticky comment, and publish
    then edits that; when it is skipped, media posts the comment itself.
    """
    deadline = clock() + GATE_WAIT_SECONDS
    name = f"{DOGFOOD_JOB_PREFIX}{pr}"
    while True:
        jobs = (gh_json([f"repos/{repository}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100"])
                or {}).get("jobs", [])
        dogfood = next((job for job in jobs if job.get("name") == name), None)
        # The job lists once `changes` is done, which admission needs too.
        dogfood_done = dogfood is None or dogfood.get("status") == "completed"
        admission = next((job for job in jobs if str(job.get("name", "")).endswith(ADMISSION_JOB_SUFFIX)), None)
        # A skipped `macos` caller lists no admission job: this push changed
        # nothing the app is built from (dispatch-focused-test.py skips_macos).
        skipped = any(job.get("name") == "macos" and job.get("conclusion") == "skipped" for job in jobs)
        if dogfood_done and (skipped or admission):
            if skipped:
                # `macos` also skips when the static checks fail; that is no build to reuse.
                static = next((job for job in jobs if job.get("name") == STATIC_JOB), {})
                return REUSED if static.get("conclusion") == "success" else NO_BUILD
            if admission:
                # A skipped admission (macos ran for packages or the CLI only)
                # leaves the fingerprint lookup to find the build.
                return BUILT if admission.get("conclusion") != "skipped" else REUSED
        run = gh_json([f"repos/{repository}/actions/runs/{run_id}"]) or {}
        if run.get("status") == "completed":
            return NO_BUILD
        if clock() > deadline:
            print(f"::warning::CI showed no app build within {GATE_WAIT_SECONDS // 60} minutes", flush=True)
            return NO_BUILD
        sleep(GATE_POLL_SECONDS)


def built_merge(run: dict) -> str:
    """The merge commit a pull request CI run compiled (app_host_test_rerun.built_revision)."""
    merges = {item.get("sha") for item in run.get("referenced_workflows") or []
              if isinstance(item, dict) and MERGE_REF.fullmatch(str(item.get("ref", ""))) and item.get("sha")}
    merge = merges.pop() if len(merges) == 1 else ""
    return merge if SHA.fullmatch(merge or "") else ""


FINGERPRINT_ARTIFACT = re.compile(r"build-inputs-(.+)-(\d+)")


def admitted_build_run(repository: str, run: dict, attempt: str) -> dict:
    """The earlier CI run of this pull request that compiled the build inputs
    `run` skipped compiling, found as ci.yml found it (find_admitted_build.py):
    by the fingerprint artifact `run` published. {} when there is none, as when
    the pull request changes no app input at all and main's build stands in."""
    listing = gh_json([f"repos/{repository}/actions/runs/{run['id']}/artifacts?per_page=100"]) or {}
    # A "re-run failed jobs" attempt does not re-run `changes`, so the newest
    # fingerprint no later than this attempt is the one it uses.
    found = sorted((int(match.group(2)), match.group(1)) for artifact in listing.get("artifacts") or []
                   if (match := FINGERPRINT_ARTIFACT.fullmatch(str(artifact.get("name", ""))))
                   and int(match.group(2)) <= int(attempt))
    fingerprints = [found[-1][1]] if found else []
    if not fingerprints:
        return {}
    import importlib.util
    spec = importlib.util.spec_from_file_location("find_admitted_build", ROOT / "scripts/ci/find_admitted_build.py")
    assert spec and spec.loader
    finder = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = finder
    spec.loader.exec_module(finder)
    def read(path: str) -> dict:
        # The finder's contract is that any API error means not found; here an
        # error must not pass for "main's build" (which compiles), so it raises.
        try:
            return gh_json([path]) or {}
        except RuntimeError as error:
            raise LookupError(str(error)) from error

    try:
        url = finder.admitted_run(read, repository, run.get("head_branch") or "", fingerprints[0], int(run["id"]))
    except LookupError:
        return {"unknown": True}
    match = re.search(r"/actions/runs/(\d+)", url or "")
    return (gh_json([f"repos/{repository}/actions/runs/{match.group(1)}"]) or {}) if match else {}


def latest_ci_run(repository: str, head_sha: str) -> dict:
    listing = gh_json([f"repos/{repository}/actions/workflows/ci.yml/runs?head_sha={head_sha}&event=pull_request&per_page=5"])
    runs = (listing or {}).get("workflow_runs") or []
    return max(runs, key=lambda run: run.get("created_at", ""), default={})


def plan(repository: str) -> int:
    run_id = os.environ.get("SOURCE_RUN_ID", "")
    attempt = os.environ.get("SOURCE_RUN_ATTEMPT", "1")
    if run_id:
        run = gh_json([f"repos/{repository}/actions/runs/{run_id}"]) or {}
        if (run.get("path") != CI_WORKFLOW_PATH or run.get("event") != "pull_request"
                or str((run.get("head_repository") or {}).get("full_name", "")).casefold() != repository.casefold()):
            write_outputs({"tours": "[]", "run": "[]"})
            print("Not a same-repository pull request CI run.", flush=True)
            return 0
        head_sha = run["head_sha"]
        numbers = [p.get("number") for p in run.get("pull_requests") or [] if p.get("number")]
        if not numbers:
            pulls = gh_json([f"repos/{repository}/commits/{head_sha}/pulls"]) or []
            numbers = [p["number"] for p in pulls if p.get("state") == "open"]
        if not numbers:
            write_outputs({"tours": "[]", "run": "[]"})
            print(f"No open pull request has head {head_sha}.", flush=True)
            return 0
        pr = int(numbers[0])
    else:
        pr = int(os.environ["PR"])
    pull = gh_json([f"repos/{repository}/pulls/{pr}"]) or {}
    if str(((pull.get("head") or {}).get("repo") or {}).get("full_name", "")).casefold() != repository.casefold():
        write_outputs({"tours": "[]", "run": "[]"})
        print("Fork pull requests get no media.", flush=True)
        return 0
    head_sha = pull["head"]["sha"]
    if run_id and head_sha != run["head_sha"]:
        write_outputs({"tours": "[]", "run": "[]"})
        print(f"#{pr} moved on to {head_sha}; its own run makes media.", flush=True)
        return 0
    if not run_id:
        run = latest_ci_run(repository, head_sha)
        run_id, attempt = str(run.get("id") or ""), str(run.get("run_attempt") or 1)
        if run_id and run.get("status") != "completed":
            write_outputs({"tours": "[]", "run": "[]"})
            print(f"CI run {run_id} for {head_sha} is still running; media starts by itself when it completes.",
                  flush=True)
            return 0
    mode = app_build_gate(repository, run_id, attempt, pr) if run_id else NO_BUILD
    # The run whose app a tour loads: this one, or the earlier run of the same
    # build inputs when this push changed no app input (only a tour, say).
    build_run = run if mode == BUILT else admitted_build_run(repository, run, attempt) if mode == REUSED else {}
    if build_run.get("unknown"):
        write_outputs({"tours": "[]", "run": "[]"})
        print("Could not tell which build CI reused for this head; a CI re-run or `gh workflow run pr-media.yml -f pr=<n>` tries again.", flush=True)
        return 0
    mains_build = mode == REUSED and not build_run
    if mains_build:
        # CI reused main's build (this pull request changes no build input
        # main lacks): the tour adopts main's build of the same inputs
        # (dispatch-focused-test.py --adopt-main).
        build_run = {"head_sha": head_sha}
    if not build_run and not os.environ.get("SOURCE_RUN_ID"):
        # A manual dispatch still runs: the tour reports that no product was
        # found, or compiles one with allow_compile.
        build_run = run or {"head_sha": head_sha}
    if not build_run:
        write_outputs({"tours": "[]", "run": "[]"})
        print("CI has no app build for this head (not an app change, CLI only, or no earlier build "
              "of the same inputs).", flush=True)
        return 0
    build_sha = build_run.get("head_sha") or head_sha
    if build_sha != head_sha:
        print(f"{head_sha} changed no app input; tours load the build of {build_sha} "
              f"({build_run.get('html_url')}).", flush=True)
    # Main's build stands in for the merge CI tested, so that merge is what a
    # tour of main's build dispatches (its inputs are the ones CI matched).
    merge_sha = built_merge(run if mains_build else build_run)
    pages = gh_json([f"repos/{repository}/pulls/{pr}/files?per_page=100", "--paginate", "--slurp"]) or []
    changed = [entry["filename"] for page in pages for entry in page if isinstance(entry, dict)]
    subprocess.run(["git", "fetch", "--no-tags", "--depth=1", "origin", head_sha], cwd=ROOT, check=True)
    scenarios = head_scenarios(head_sha)
    # A head that predates a tour's `paths` is still picked by main's globs.
    for name, scenario in scenarios.items():
        main_copy = ROOT / SCENARIOS_DIR / f"{name}.json"
        if not tour_globs(scenario) and isinstance(scenario, dict) and main_copy.is_file():
            try:
                scenario["paths"] = tour_globs(json.loads(main_copy.read_text()))
            except json.JSONDecodeError:
                pass
    tours, reason = select_tours(scenarios, changed, pull.get("body"))
    app_change = any(reaches_app(path) for path in changed)
    if not app_change and not parse_override(pull.get("body")):
        # No dogfood job to say so any more (it is opt-in): a pull request
        # that changes nothing a tour shows gets no media section.
        write_outputs({"tours": "[]", "run": "[]"})
        print(f"#{pr} changes nothing a tour shows.", flush=True)
        return 0
    force = os.environ.get("FORCE", "").lower() == "true"
    pending = [tour for tour in tours if force or published(repository, pr, head_sha, tour) is None]
    print(f"#{pr} at {head_sha}: tours {tours or 'none'} ({reason}); to run: {pending or 'none'}", flush=True)
    compile_mode = ADOPT_MAIN if mains_build else ADOPT_CI
    write_outputs({"pr": str(pr), "head_sha": head_sha, "build_sha": build_sha, "merge_sha": merge_sha,
                   "compile": compile_mode,
                   "tours": json.dumps(tours),
                   "run": json.dumps(pending)})
    return 0


# ---------------------------------------------------------------------------
# Running a tour


class Dispatch:
    """Runs the dispatcher and cancels what it started if this job is cancelled.

    The dispatcher runs in its own session: a cancel interrupts it (so its
    own cancellation scope stops a run it is still looking for), then cancels
    the run it printed.
    """

    def __init__(self, repository: str) -> None:
        self.repository = repository
        self.run_id: str | None = None
        self.tested: str | None = None
        self.process: subprocess.Popen | None = None
        self.completed: dict | None = None

    def stop(self) -> None:
        """Cancel the run this dispatch started, if any."""
        if self.run_id:
            subprocess.run(["gh", "run", "cancel", str(self.run_id), "--repo", self.repository], check=False)

    def cancel(self, *_: object) -> None:
        if self.process and self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGINT)
                self.process.wait(timeout=60)
            except (OSError, subprocess.TimeoutExpired):
                pass
        if self.run_id:
            subprocess.run(["gh", "run", "cancel", self.run_id, "--repo", self.repository], check=False)
        sys.exit(130)

    def start(self, command: list[str]) -> int:
        self.process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        text=True, start_new_session=True)
        assert self.process.stdout is not None
        for line in self.process.stdout:
            print(line, end="", flush=True)
            if match := RUN_LINE.match(line.strip()):
                self.run_id = match.group(1)
            if match := TESTED_LINE.match(line.strip()):
                self.tested = match.group(1)
        return self.process.wait()

    def wait(self, sleep: Callable[[float], None] = time.sleep) -> dict:
        # On a developer machine, the shared glaeda-gh poller answers without
        # spending the account's API quota.
        glaeda = shutil.which("glaeda-gh")
        if glaeda:
            subprocess.run([glaeda, "wait", "run", f"{self.repository}/{self.run_id}",
                            "--timeout", str(RUN_WAIT_SECONDS)], check=False)
        deadline = time.monotonic() + RUN_WAIT_SECONDS
        while True:
            run = gh_json([f"repos/{self.repository}/actions/runs/{self.run_id}"]) or {}
            if run.get("status") == "completed":
                return run
            if time.monotonic() > deadline:
                # Uncached, so the next attempt dispatches again: stop this one.
                subprocess.run(["gh", "run", "cancel", str(self.run_id), "--repo", self.repository], check=False)
                return run
            sleep(RUN_POLL_SECONDS)


def refused_after(dispatch: "Dispatch", repository: str) -> bool:
    """Wait for an adopt-only tour run; whether it stopped because it could
    not load CI's build. The finished run is kept on `dispatch.completed`;
    a run whose reuse errored is kept with conclusion "reuse_error"."""
    run = dispatch.wait()
    if run.get("conclusion") != "failure":
        dispatch.completed = run
        return False
    if refused_to_compile(repository, str(dispatch.run_id)):
        return True
    errored = REUSE_ERROR_STEP in failed_steps(repository, str(dispatch.run_id))
    dispatch.completed = {**run, "conclusion": "reuse_error"} if errored else run
    return False


def failed_steps(repository: str, run_id: str) -> set[str]:
    jobs = (gh_json([f"repos/{repository}/actions/runs/{run_id}/jobs?per_page=100"]) or {}).get("jobs", [])
    return {str(step.get("name")) for job in jobs for step in job.get("steps") or []
            if step.get("conclusion") == "failure"}


def refused_to_compile(repository: str, run_id: str) -> bool:
    """Whether the tour run stopped because it could not load CI's build."""
    return REFUSE_STEP in failed_steps(repository, run_id)


def frames_of(run_id: str, out: Path, repository: str) -> list[dict]:
    done = subprocess.run([sys.executable, str(ROOT / "scripts/ci/e2e-frames.py"), run_id, "--out", str(out),
                           "--repo", repository, "--test", "DogfoodScenarioUITests", "--json"],
                          cwd=ROOT, capture_output=True, text=True)
    if done.returncode != 0:
        print(done.stdout[-2000:], done.stderr[-2000:], flush=True)
        return []
    return json.loads(done.stdout or "[]")


def shot_name(title: str) -> str | None:
    """A tour's `shot` becomes step "capture: <name>" (e2e-frames.py)."""
    return title[len("capture: "):] if title.startswith("capture: ") else None


def pick_key_shots(names: list[str], limit: int = MAX_KEY_SHOTS) -> list[str]:
    """The tour's own shots, evenly spaced, failures always kept."""
    failed = [name for name in names if name.endswith("-failed")]
    own = [name for name in names if name not in SKIP_AS_KEY and name not in failed]
    if not own:
        own = [name for name in names if name == "99-final"]
    room = max(limit - len(failed[:2]), 1)
    if len(own) > room:
        step = (len(own) - 1) / max(room - 1, 1)
        own = [own[round(index * step)] for index in range(room)]
    chosen = set(own) | set(failed[:2])
    return [name for name in names if name in chosen]


def safe_file(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-.")[:80] or "shot"


def render(shots: list[tuple[str, Path]], out: Path, caption: str) -> dict:
    """Key PNGs and a captioned GIF from the tour's frames (JPEGs, about 960 px wide)."""
    from PIL import Image, ImageDraw, ImageFont

    out.mkdir(parents=True, exist_ok=True)
    names = [name for name, _ in shots]
    keys = []
    for name in pick_key_shots(names):
        path = dict(shots)[name]
        with Image.open(path) as image:
            file = f"{safe_file(name)}.png"
            image.convert("RGB").quantize(colors=256).save(out / file, optimize=True)
            keys.append({"name": name, "file": file})

    def scaled(path: Path, width: int) -> Image.Image:
        with Image.open(path) as source:
            image = source.convert("RGB")
        return image.resize((width, max(1, round(image.height * width / image.width))), Image.LANCZOS)

    def frames_at(width: int) -> list[Image.Image]:
        # GIF frames share the first frame's size: letterbox every shot onto
        # the tallest one, with the caption bar at one height.
        images = [(name, scaled(path, width)) for name, path in moving]
        height = max(image.height for _, image in images)
        bar = 28
        try:
            font = ImageFont.load_default(size=15)
        except TypeError:  # Pillow before 10.1
            font = ImageFont.load_default()
        frames = []
        for name, image in images:
            canvas = Image.new("RGB", (width, height + bar), (24, 24, 27))
            canvas.paste(image, (0, (height - image.height) // 2))
            ImageDraw.Draw(canvas).text((10, height + 6), f"{name}   {caption}", fill=(235, 235, 240), font=font)
            frames.append(canvas.quantize(colors=256))
        return frames

    gif = None
    moving = [(name, path) for name, path in shots if name not in SKIP_IN_GIF]
    if len(moving) >= 2:
        for width in GIF_WIDTHS:
            frames = frames_at(width)
            durations = [FRAME_MS] * (len(frames) - 1) + [LAST_FRAME_MS]
            frames[0].save(out / "tour.gif", save_all=True, append_images=frames[1:], duration=durations,
                           loop=0, optimize=True, disposal=1)
            if (out / "tour.gif").stat().st_size <= GIF_MAX_BYTES:
                gif = "tour.gif"
                break
        else:
            (out / "tour.gif").unlink()
    return {"shots": keys, "gif": gif, "frames": len(moving)}


def tour_media(run_id: str, name: str, head_sha: str, out: Path, repository: str) -> dict:
    """The failures, key shots and GIF of a finished tour run."""
    summary = frames_of(run_id, out.parent / f".frames-{name}", repository)
    item = summary[0] if summary else {}
    found: dict[str, Any] = {"failures": [failure[:200] for failure in item.get("failures", [])[:3]]}
    shots = [(shot_name(step["title"]), Path(step["frame"])) for step in item.get("steps", [])
             if shot_name(step["title"])]
    if shots:
        found.update(render(shots, out, f"{name} @ {head_sha[:8]}"))
    else:
        found["note"] = "the run left no frames (see the run log)"
    return found


UNLOADABLE_NOTE = ("skipped: CI built this head on a runner pool whose products the UI test Macs cannot "
                   "load, and media never compiles one; `gh workflow run pr-media.yml -f pr=<n> "
                   "-f allow_compile=true` does")


def tour(repository: str, name: str, scenario: Path, head_sha: str, out: Path, compile_mode: str = ADOPT_CI,
         build_sha: str = "", merge_sha: str = "") -> int:
    """Run one tour and write its manifest.

    A tour only ever adopts a build: the one a CI run of the pull request made
    (ADOPT_CI), or main's build of the same inputs when CI reused it
    (ADOPT_MAIN). When neither loads on the UI test Macs the tour is skipped
    with a note; only a manual allow_compile (COMPILE_NOW) compiles.
    """
    if not TOUR_NAME.fullmatch(name) or not SHA.fullmatch(head_sha):
        raise ValueError("bad tour name or head")
    manifest: dict[str, Any] = {"tour": name, "head_sha": head_sha, "result": "not run", "shots": [], "gif": None}
    out.mkdir(parents=True, exist_ok=True)
    dispatch = Dispatch(repository)
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, dispatch.cancel)
    build_sha = build_sha if SHA.fullmatch(build_sha or "") else head_sha
    if build_sha != head_sha:
        manifest["build_sha"] = build_sha
    base = [str(ROOT / "scripts/run-e2e.sh"), "--scenario", str(scenario), "--ref", build_sha, "--no-video"]
    if compile_mode == COMPILE_NOW:
        manifest["compiled"] = True
        manifest.pop("build_sha", None)
        status: int | None = dispatch.start([*base[:4], head_sha, *base[5:]])
    elif compile_mode == ADOPT_MAIN:
        # CI reused main's build for the merge it tested; dispatch that merge
        # so test-e2e.yml looks main's product up by the merge's inputs.
        ref = merge_sha if SHA.fullmatch(merge_sha or "") else head_sha
        if ref != head_sha:
            manifest["tested_sha"] = ref
        status = dispatch.start([*base[:4], ref, *base[5:], "--adopt-only", "--adopt-main"])
    else:
        status = dispatch.start([*base, "--adopt-only"])
    if compile_mode != COMPILE_NOW:
        if status == 0 and dispatch.run_id:
            try:
                if refused_after(dispatch, repository):
                    manifest["note"] = UNLOADABLE_NOTE if compile_mode == ADOPT_CI else (
                        "skipped: main's build of these inputs is gone or does not load on the UI test Macs, "
                        "and media never compiles one")
                    status = None
            except Exception as error:
                dispatch.stop()
                manifest["note"] = f"skipped: could not follow the tour run ({str(error)[:160]})"
                status = None
        elif status == UNLOADABLE_PRODUCT_EXIT:
            manifest["note"] = UNLOADABLE_NOTE
            status = None
        elif status == NO_PRODUCT_EXIT:
            manifest["note"] = "skipped: CI left no app build for this head (its compile failed or was cancelled)"
            status = None
    if status is None:
        pass
    elif status != 0 or not dispatch.run_id:
        manifest["note"] = f"skipped: the tour dispatcher failed (exit {status}); see the run log"
    else:
        if dispatch.tested and dispatch.tested not in (head_sha, build_sha):
            manifest["tested_sha"] = dispatch.tested
        manifest["run_url"] = f"https://github.com/{repository}/actions/runs/{dispatch.run_id}"
        try:
            run = dispatch.completed if dispatch.completed is not None else dispatch.wait()
            conclusion = run.get("conclusion")
            if conclusion in ("success", "failure"):
                manifest["result"] = "passed" if conclusion == "success" else "failure"
                manifest.update(tour_media(dispatch.run_id, name, head_sha, out, repository))
            elif conclusion == "reuse_error":
                manifest["note"] = ("skipped: the tour run could not check CI's build (a reuse error); "
                                    "a CI re-run or `gh workflow run pr-media.yml -f pr=<n>` tries again")
            else:
                manifest["note"] = (f"skipped: the tour run ended {conclusion or 'unfinished'}; "
                                    "a CI re-run or `gh workflow run pr-media.yml -f pr=<n>` tries again")
        except Exception as error:  # a manifest with the run link beats no media section at all
            manifest["note"] = f"media could not be made: {str(error)[:200]}"
        # Only a verdict with media is cached (published() keys on run_url),
        # plus any compiled verdict; anything else runs again next attempt.
        concluded = manifest["result"] != "not run"
        if not (manifest.get("compiled") and concluded) and (
                not concluded or not (manifest.get("gif") or manifest.get("shots"))):
            manifest["log_url"] = manifest.pop("run_url")
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2), flush=True)
    return 0


# ---------------------------------------------------------------------------
# Publishing


def raw_url(repository: str, path: str) -> str:
    return f"https://raw.githubusercontent.com/{repository}/{MEDIA_BRANCH}/{path}"


def uploader():
    """scripts/pr-media.py, the tool people use to put a clip on a PR; its
    put_file writes one file to the media branch (sha-aware, retried on a race)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("pr_media_tool", ROOT / "scripts/pr-media.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # its dataclasses look their module up
    spec.loader.exec_module(module)
    return module


def upload(tool, repository: str, path: str, local: Path, message: str, attempts: int = 4,
           sleep: Callable[[float], None] = time.sleep) -> None:
    """put_file, retried: publish jobs of several PRs and people's uploads move
    the media branch at once, so a lost race or a 5xx is routine."""
    for attempt in range(attempts):
        try:
            tool.put_file(repository, MEDIA_BRANCH, path, local, message)
            return
        except tool.MediaError:
            if attempt == attempts - 1:
                raise
            sleep(3 + 4 * attempt)


def section(repository: str, pr: int | str, head_sha: str, manifests: list[dict]) -> str:
    prefix = media_prefix(pr, head_sha)
    lines = [SECTION_START, f"### Dogfood tours of `{head_sha[:8]}`", ""]
    for manifest in manifests:
        tour_name = manifest["tour"]
        base = f"{prefix}/{tour_name}"
        link = manifest.get("run_url") or manifest.get("log_url")
        run = f" ([run]({link}))" if link else ""
        tested = manifest.get("tested_sha") or ""
        built = str(manifest.get("build_sha") or "")
        merge = ""
        if manifest.get("compiled"):
            merge = ", on an app compiled for the tour"
        elif SHA.fullmatch(built):
            merge = f", on the app CI built for `{built[:8]}`"
            merge += f" (merge `{tested[:8]}`)" if SHA.fullmatch(tested) else ""
            merge += "; this push changed no app input"
        elif SHA.fullmatch(tested):
            merge = f", on its merge `{tested[:8]}` that CI built"
        result = html.escape(str(manifest.get("result", "not run")))
        lines.append(f"**{tour_name}** at `{head_sha[:8]}`{merge}: {result}{run}")
        if manifest.get("note"):
            lines.append(f"<br>{html.escape(str(manifest['note']))}")
        for failure in manifest.get("failures") or []:
            lines.append(f"<br>Failed: <code>{html.escape(str(failure))}</code>")
        lines.append("")
        if manifest.get("gif"):
            lines.append(f'<img src="{raw_url(repository, base + "/" + manifest["gif"])}" width="720" '
                         f'alt="{tour_name} at {head_sha[:8]}">')
            lines.append("")
        if manifest.get("shots"):
            lines.append(f"<details><summary>Key frames of {tour_name} at {head_sha[:8]}</summary>")
            lines.append("")
            for shot in manifest["shots"]:
                label = html.escape(str(shot["name"]), quote=True)
                lines.append(f'<img src="{raw_url(repository, base + "/" + shot["file"])}" width="420" '
                             f'alt="{label}" title="{tour_name} {label} at {head_sha[:8]}">')
            lines.append("")
            lines.append("</details>")
            lines.append("")
    lines.append("<sub>Tours are picked by the `paths` globs in dogfood/scenarios/*.json; a "
                 "`Dogfood-tours: a, b` line in the description picks them instead (`none` turns this off). "
                 "Look at every frame before merging: a green tour only means no step failed.</sub>")
    lines.append(SECTION_END)
    return "\n".join(lines)


def merge_section(body: str, new_section: str) -> str:
    """Replace the media section in a comment body, or append one."""
    start, end = body.find(SECTION_START), body.find(SECTION_END)
    if start != -1 and end > start:
        return body[:start] + new_section + body[end + len(SECTION_END):]
    return body.rstrip() + "\n\n" + new_section + "\n"


def publish(repository: str, pr: int, head_sha: str, tours: list[str], media: Path) -> int:
    prefix = media_prefix(pr, head_sha)
    tool = uploader()
    manifests = []
    for tour_name in tours:
        if not TOUR_NAME.fullmatch(tour_name):
            continue
        folder = media / tour_name
        manifest_path = folder / "manifest.json"
        if manifest_path.is_file():
            manifest = json.loads(manifest_path.read_text())
            names = [shot.get("file") for shot in manifest.get("shots", [])] + [manifest.get("gif")]
            # A tour that never ran leaves no manifest, so the next attempt runs it.
            names += ["manifest.json"] if manifest.get("run_url") else []
            for file in [name for name in names if name]:
                if not re.fullmatch(r"[A-Za-z0-9._-]+", file) or not (folder / file).is_file():
                    continue
                upload(tool, repository, f"{prefix}/{tour_name}/{file}", folder / file,
                       f"pr-media: {tour_name} at {head_sha[:8]}")
        else:
            manifest = published(repository, pr, head_sha, tour_name)
        if not manifest:
            # The tour job died before writing a manifest (cancelled, timed out).
            here = os.environ.get("GITHUB_RUN_ID")
            manifest = {"tour": tour_name, "result": "not run",
                        "note": "skipped: the tour job left no result; a CI re-run or `gh workflow run pr-media.yml -f pr=<n>` tries again"}
            if here:
                manifest["log_url"] = f"https://github.com/{repository}/actions/runs/{here}"
        # Every picked tour gets a line: its media, or why it was skipped.
        manifests.append(manifest)
    if not manifests:
        print("No tour left media.", flush=True)
        return 0
    new_section = section(repository, pr, head_sha, manifests)
    comments = gh_json([f"repos/{repository}/issues/{pr}/comments?per_page=100", "--paginate", "--slurp"]) or []
    comments = [c for page in comments for c in (page if isinstance(page, list) else [page])]
    ours = [c for c in comments if (c.get("user") or {}).get("login") == "github-actions[bot]"
            and DOGFOOD_MARKER in (c.get("body") or "")]
    # Checked last, just before the write: a newer push's dogfood job owns the comment then.
    pull = gh_json([f"repos/{repository}/pulls/{pr}"]) or {}
    if (pull.get("head") or {}).get("sha") != head_sha:
        print(f"#{pr} moved past {head_sha}; not touching its comment.", flush=True)
        return 0
    if ours:
        body = merge_section(ours[0]["body"], new_section)
        subprocess.run(["gh", "api", "-X", "PATCH", f"repos/{repository}/issues/comments/{ours[0]['id']}",
                        "-F", "body=@-"], input=body, check=True, capture_output=True, text=True)
    else:
        body = f"{DOGFOOD_MARKER}\n{new_section}\n"
        subprocess.run(["gh", "api", "-X", "POST", f"repos/{repository}/issues/{pr}/comments", "-F", "body=@-"],
                       input=body, check=True, capture_output=True, text=True)
    print(new_section, flush=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("plan", help="pick the tours for SOURCE_RUN_ID (or PR)")
    run = sub.add_parser("tour", help="run one tour and render its media")
    run.add_argument("--name", required=True)
    run.add_argument("--scenario", type=Path, required=True)
    run.add_argument("--out", type=Path, required=True)
    run.add_argument("--compile", choices=COMPILE_MODES, default=ADOPT_CI,
                     help="how the tour gets its app: adopt CI's build, main's, or compile now (default: ci)")
    post = sub.add_parser("publish", help="upload media and update the dogfood comment")
    post.add_argument("--media", type=Path, required=True)
    args = parser.parse_args(argv)
    repository = os.environ["REPOSITORY"]
    if args.command == "plan":
        return plan(repository)
    head_sha = os.environ["HEAD_SHA"]
    if not SHA.fullmatch(head_sha):
        raise SystemExit(f"HEAD_SHA {head_sha!r} is not a full commit SHA")
    if args.command == "tour":
        return tour(repository, args.name, args.scenario, head_sha, args.out, args.compile,
                    os.environ.get("BUILD_SHA", ""), os.environ.get("MERGE_SHA", ""))
    return publish(repository, int(os.environ["PR"]), head_sha, json.loads(os.environ.get("TOURS") or "[]"),
                   args.media)


if __name__ == "__main__":
    sys.exit(main())
