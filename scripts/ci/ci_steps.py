#!/usr/bin/env python3
"""Route a diff to the step table's steps and run one job's steps (ci/steps.toml).

  ci/run route --paths-file F            the routed steps by job, as JSON
  ci/run run --job JOB [--paths-file F] [--label NAME] [--only NAMES] [--pr-scope] [--tier pr|full]
  ci/run step NAME                       run that one step here, whatever routes it, and exit with its verdict

`ci/run` is the entry (it calls this file). `run` starts the job's routed steps, as many at
once as the machine has CPUs, each as `bash -euo pipefail -c RUN` in the current directory
with the caller's environment, and prints each one's output in a log group when it ends.
When the table has a `[setup]` command for the job it runs first, once, and only when a step
is routed: it fills `$CI_TOOLS` (a directory of this run; `$CI_TOOLS/bin` leads the steps'
PATH) with what the job's steps share, where a warm machine would already hold it. A step that
lists `needs = ["bun"]` also gets that `[tools]` command run first (bun, node: a tool only the
routed steps that need it pay for), all of them at once after the setup, each in `$CI_TOOLS`. A
setup or tool that fails fails the job. It exits 1 only when a step with `blocks = true` failed. A step with
`blocks = false` that fails or runs past its timeout is a warning annotation: an advisory
step never turns its job red. A step with `alone = true` runs by itself, after the others, in table order,
and is skipped (a notice, not a failure) once a step with `blocks = true` has failed: the job is red
already, and the re-run that fixes it runs the step anyway. `--alone-on-red` (or CI_RUN_ALONE_ON_RED=1) runs it all the same: the
post-merge batch has no re-run, so a base that stays red would otherwise never run its alone steps.
`--label NAME` says the event is a label change of NAME;
then only the steps that list NAME in `labels` run. `--only NAMES` (comma or space separated)
runs only those of the routed steps; empty means every routed step. A name the table does
not have is a notice and is skipped, never an error: the pull request that adds a step runs
against a base whose table lacks it. Two workflows run steps of the `advisory` job, each its
own (pr-body-checks.yml the description lints, pr-checks.yml the rest), so each names them.

`step NAME` runs one step by name, as its job runs it (the job's setup, the tools it needs, its timeout), with no
diff (routing never skips it), the full tier, the step's first label as the event when it lists labels, and no step
results (it always runs). Unlike `run` it exits 1 when the step fails whether or not it blocks, and 2 when the table
has no such step or the step's job runs on another OS (STEP_JOB_OS). This is the build fleet's entry for any step
(`cmux-ci run --step NAME --ref SHA`, through scripts/ci/run-step.sh; Leo, 2026-11-19: "can't you... just be able to
run whatever ci steps?").

The table's rules (checked on load): every step names one of the table's jobs, there are
at most 8 jobs, and a step that does not block runs in the `advisory` job in class `idle`.

A step's `inputs` are path globs (`**` crosses `/`, `*` and `?` do not). A change routes the
step when it touches one of them; a step with no inputs, an unknown change, and a change to
the pipeline itself (PIPELINE_PATHS: the table, this runner, the entry, the workflow) route it
always.

`--pr-scope` (a pull request's linux job, pr-pipeline.yml) routes a step only by the inputs that name its files:
a literal path or a one-directory glob (`*`, `?`, no `**`). A step a change reaches only through a whole-directory
glob (`dir/**`, `**`) or a change to the pipeline itself is left to the post-merge batch, which runs every linux
step at the merged tip (cmux-next-pr-pipeline-linux-batch.yml) and bisects a new red there. A step with
`pr_scope = false` keeps its whole route on a pull request. An unknown diff still routes every step.

`nightly` names the nightly.yml steps (`nightly.yml:<job>:<step>`) a step runs the same check as: a red there stops
the nightly's publish or reds its run, found hours after the merge (Leo, 2026-11-27: "shouldn't a build check fail
beforehand fast like fast-fail is useful ci all stuff"). Such a step keeps its whole route under `--pr-scope`, and
pr_router.py starts it on a landing head of the affected tier (nightly_gate_steps), so the landing fails, not the
nightly. .github/nightly-step-coverage.json maps the nightly step back to it ({"table": NAME};
tests/test_nightly_step_coverage.py checks both directions).

Step results by input hash (the CI v2 design, "Caches: three, content-addressed", item 3). Before a
routed step runs, `run` keys it: sha256 over the step's own table entry, the job's setup and the
tools it needs, this runner, its entry and the workflow, the machine kind (RUNNER_OS, RUNNER_ARCH,
ImageOS, DEVELOPER_DIR), every tracked file of the checkout its `inputs` match (path, mode, blob
id; a step with no inputs keys on the whole tree) and the changed paths its inputs match. It asks the
fleet controller (GET /v1/ci/step-results) for a pass under that key; a pass is reported as the step's
result ("reused", with the run that passed it) and the step does not run. When every routed step is
reused the job's setup and tools do not run either. A step that passes posts its result under its key
(POST); a fork's pull request never writes. AUDIT_PERCENT of hits run anyway and post their outcome:
a fail evicts the key on the controller, and the step's real result is the job's. The key is never
weaker than routing: the runner already skips a step whose inputs a change does not touch, which
trusts the same `inputs` with the same tree. Steps that read the event (the advisory job, a step with
`labels`, a run that names one of EVENT_VARS) or set `reuse = false` always run. Any controller error
is a miss. Off: CI_STEP_RESULTS=off; controller: CI_STEP_RESULTS_URL (default the fleet's). Outside Actions it
is off unless CI_STEP_RESULTS=on (a build fleet job: CI_STEP_RESULTS_REPO, _SHA, _RUN_URL, _RUNNER name the
run, CI_STEP_RESULTS_WRITE=0 makes it read only).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Mapping
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TABLE = ROOT / "ci" / "steps.toml"
MAX_JOBS = 8
SETUP_TIMEOUT = 600
# Each `[tools]` command, all started together after the setup: a download and a checksum, not a build.
TOOL_TIMEOUT = 180
# The pipeline's own definition: a change to any of them routes every step, so the change runs what it moved.
CONTROLLER = "http://100.89.225.106:18765"
PUBLIC_CONTROLLER = "https://gh-events.cmux.com"  # the controller's public listener (hq build-fleet/cmd/controller)
OIDC_AUDIENCE = "cmux-ci-step-results"
USER_AGENT = "cmux-ci-steps/1"
STEP_KEY_VERSION = 1
AUDIT_PERCENT = 5
# A run that reads one of these depends on the event, not only on the tree: it is never reused.
EVENT_VARS = (
    "PR", "HEAD_SHA", "BODY", "MERGE_SHA", "BASE_SHA", "PATHS_LISTED", "HEAD_REF", "BASE_REF", "LABELS", "URL",
    "TREE_LISTED", "CAPTURE_LISTED", "TITLE", "GITHUB_EVENT_PATH", "DELETIONS", "ADDITIONS", "REPOSITORY",
    "GITHUB_ENV", "GITHUB_PATH", "GITHUB_OUTPUT", "SERVER", "FEED_URL", "GITHUB_SHA", "GITHUB_RUN_ID",
)
MACHINE_VARS = ("RUNNER_OS", "RUNNER_ARCH", "ImageOS", "DEVELOPER_DIR")
PIPELINE_PATHS = ("ci/steps.toml", "ci/run", "scripts/ci/ci_steps.py", ".github/workflows/pr-pipeline.yml")
ADVISORY_JOB = "advisory"
# The OS (platform.system()) a job's steps run on, for `step`; a job not listed runs on Linux. `verdict` has no
# machine, so `step` refuses its steps.
STEP_JOB_OS = {"mac": "Darwin", "ios": "Darwin"}
NO_MACHINE_JOBS = ("verdict",)
LOG_LOCK = threading.Lock()
CLASSES = ("feed", "named", "pr", "batch", "idle")


class TableError(ValueError):
    pass


@dataclass(frozen=True)
class Step:
    name: str
    job: str
    run: str
    blocks: bool = True
    klass: str = "pr"
    inputs: tuple[str, ...] = ()
    # Globs a path of `inputs` may still match and route nothing (notes beside the code a step builds); a later
    # `!glob` takes a path back, as in a workflow's `paths` (the last glob that matches decides).
    ignore: tuple[str, ...] = ()
    labels: tuple[str, ...] = ()
    timeout: int = 600
    title: str = ""
    about: str = ""
    needs: tuple[str, ...] = ()
    alone: bool = False
    reuse: bool = True
    # False: a pull request's --pr-scope route keeps every input of this step (security-holes: a secret or a
    # workflow hole must not land to be found post-merge).
    pr_scope: bool = True
    # "push": the pull request's own run leaves the step to the push tier (`--tier pr` skips it, `full` runs it).
    tier: str = "pr"
    # The nightly.yml steps this step runs the same check as (`nightly.yml:<job>:<step>`; the module's docs).
    nightly: tuple[str, ...] = ()


TIERS = ("pr", "push")


@dataclass
class Table:
    jobs: dict[str, str]
    steps: dict[str, Step]
    setup: dict[str, str]
    tools: dict[str, str] = field(default_factory=dict)


def glob_pattern(glob: str) -> re.Pattern[str]:
    """A path glob: ** crosses '/', * and ? do not."""
    out: list[str] = []
    i = 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif glob[i] == "*":
            out.append("[^/]*")
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def parse(doc: dict) -> Table:
    jobs = doc.get("jobs") or {}
    if not jobs or not all(isinstance(v, str) for v in jobs.values()):
        raise TableError("[jobs] names each job with a one-line description")
    if len(jobs) > MAX_JOBS:
        raise TableError(f"[jobs] has {len(jobs)} jobs; the PR pipeline has at most {MAX_JOBS}")
    setup = doc.get("setup") or {}
    for job, command in setup.items():
        if job not in jobs:
            raise TableError(f"[setup] {job!r} is not one of [jobs] {sorted(jobs)}")
        if not isinstance(command, str) or not command.strip():
            raise TableError(f"[setup] {job}: a command")
    tools = doc.get("tools") or {}
    for tool, command in tools.items():
        if not isinstance(command, str) or not command.strip():
            raise TableError(f"[tools] {tool}: a command")
    steps: dict[str, Step] = {}
    known = set(Step.__dataclass_fields__) - {"name", "klass"} | {"class"}
    for name, raw in (doc.get("step") or {}).items():
        unknown = set(raw) - known
        if unknown:
            raise TableError(f"step {name}: unknown keys {sorted(unknown)}")
        for key in ("job", "run"):
            if not isinstance(raw.get(key), str) or not raw[key].strip():
                raise TableError(f"step {name}: `{key}` is required")
        step = Step(
            name=name,
            job=raw["job"],
            run=raw["run"],
            blocks=raw.get("blocks", True),
            klass=raw.get("class", "pr"),
            inputs=tuple(raw.get("inputs", ())),
            ignore=tuple(raw.get("ignore", ())),
            labels=tuple(raw.get("labels", ())),
            timeout=raw.get("timeout", 600),
            title=raw.get("title", ""),
            about=raw.get("about", ""),
            needs=tuple(raw.get("needs", ())),
            alone=raw.get("alone", False),
            reuse=raw.get("reuse", True),
            pr_scope=raw.get("pr_scope", True),
            tier=raw.get("tier", "pr"),
            nightly=tuple(raw.get("nightly", ())),
        )
        if step.tier not in TIERS:
            raise TableError(f"step {name}: `tier` is one of {TIERS}")
        if step.job not in jobs:
            raise TableError(f"step {name}: job {step.job!r} is not one of [jobs] {sorted(jobs)}")
        if not isinstance(step.blocks, bool):
            raise TableError(f"step {name}: `blocks` is true or false")
        if not isinstance(step.alone, bool):
            raise TableError(f"step {name}: `alone` is true or false")
        if not isinstance(step.reuse, bool):
            raise TableError(f"step {name}: `reuse` is true or false")
        if not isinstance(step.pr_scope, bool):
            raise TableError(f"step {name}: `pr_scope` is true or false")
        if not all(isinstance(n, str) and re.fullmatch(r"nightly\.yml:[^:]+:.+", n) for n in step.nightly) or (
                step.nightly and not step.blocks):
            raise TableError(f"step {name}: `nightly` lists a blocking step's nightly.yml:<job>:<step> counterparts")
        if step.klass not in CLASSES:
            raise TableError(f"step {name}: class {step.klass!r} is not one of {CLASSES}")
        if not step.blocks and (step.job != ADVISORY_JOB or step.klass != "idle"):
            raise TableError(f"step {name}: a step that does not block runs in job {ADVISORY_JOB!r}, class 'idle'")
        if step.blocks and step.job == ADVISORY_JOB:
            raise TableError(f"step {name}: job {ADVISORY_JOB!r} holds only steps that do not block")
        if not all(isinstance(t, str) and t in tools for t in step.needs):
            raise TableError(f"step {name}: `needs` names tools of [tools] {sorted(tools)}")
        if not isinstance(step.timeout, int) or step.timeout <= 0:
            raise TableError(f"step {name}: `timeout` is a positive number of seconds")
        if not all(isinstance(g, str) and g and not g.startswith(("/", "!")) for g in step.inputs):
            raise TableError(f"step {name}: `inputs` are repo-relative path globs")
        if not all(isinstance(g, str) and g.lstrip("!") and not g.lstrip("!").startswith("/") for g in step.ignore) or (
                step.ignore and (not step.inputs or step.ignore[0].startswith("!"))):
            raise TableError(f"step {name}: `ignore` holds repo-relative path globs, beside `inputs`")
        steps[name] = step
    return Table(jobs=dict(jobs), steps=steps, setup=dict(setup), tools=dict(tools))


def load(path: Path = TABLE) -> Table:
    return parse(tomllib.loads(path.read_text(encoding="utf-8")))


def named_input(glob: str) -> bool:
    """An input that names the step's own files: a literal path or a glob inside one directory (no `**`). A `**`
    glob reaches a whole directory tree, so a pull request leaves a step it alone routes to the post-merge batch."""
    return "**" not in glob


def routed(step: Step, paths: list[str] | None, pr_scope: bool = False) -> bool:
    """Whether a diff of `paths` needs the step. No inputs, or an unknown diff, routes it. PR_SCOPE: only the step's
    named inputs route it, and a change to the pipeline does not route every step (see the module's `--pr-scope`)."""
    narrow = pr_scope and step.pr_scope and not step.nightly
    if not step.inputs or paths is None or (not narrow and any(p in PIPELINE_PATHS for p in paths)):
        return True
    patterns = [glob_pattern(g) for g in step.inputs if not narrow or named_input(g)]
    ignored = [(g.startswith("!"), glob_pattern(g.lstrip("!"))) for g in reversed(step.ignore)]

    def kept(path: str) -> bool:
        return next((back for back, i in ignored if i.match(path)), True)

    return any(p.match(path) and kept(path) for path in paths for p in patterns)


def nightly_gate_steps(table: Table, paths: list[str] | None, jobs: tuple[str, ...] | list[str] = ()) -> list[str]:
    """The steps with a `nightly` counterpart a diff of PATHS routes (every input kept), in JOBS when given."""
    return [step.name for step in table.steps.values()
            if step.nightly and (not jobs or step.job in jobs) and routed(step, paths, pr_scope=True)]


def route(table: Table, paths: list[str] | None, label: str | None = None,
          pr_scope: bool = False, tier: str = "full") -> dict[str, list[str]]:
    """Each job's routed steps. TIER "pr" leaves out the steps marked `tier = "push"`; "full" keeps every step."""
    jobs: dict[str, list[str]] = {}
    for step in table.steps.values():
        if tier == "pr" and step.tier == "push":
            continue
        if label is not None and label not in step.labels:
            continue
        if routed(step, paths, pr_scope):
            jobs.setdefault(step.job, []).append(step.name)
    return jobs


@dataclass
class Result:
    step: Step
    code: int | None  # None: ran past its timeout
    seconds: float
    output: str
    reused: str = ""  # the run whose pass this step reused; empty when it ran
    skipped: bool = False  # an alone step not started: a blocking step had failed

    @property
    def ok(self) -> bool:
        return self.skipped or self.code == 0


def reusable(step: Step) -> bool:
    """Whether the step's result is a function of the tree alone (see the module's "Step results")."""
    if not step.reuse or step.job == ADVISORY_JOB or step.labels or not step.blocks:
        return False
    return not any(re.search(r"\$\{?" + var + r"\b", step.run) for var in EVENT_VARS)


def tracked_files(root: Path) -> list[tuple[str, str, str]] | None:
    """(path, mode, object id) of every tracked path of the checkout's HEAD; None when git cannot say."""
    try:
        out = subprocess.run(["git", "ls-tree", "-r", "-z", "--full-tree", "HEAD"], cwd=root, capture_output=True,
                             timeout=60, check=True).stdout.decode("utf-8", "surrogateescape")
    except (OSError, subprocess.SubprocessError):
        return None
    files = []
    for entry in out.split("\0"):
        if not entry:
            continue
        meta, _, path = entry.partition("\t")
        mode, _kind, oid = meta.split(" ", 2)
        files.append((path, mode, oid))
    return files


def head_tree(root: Path) -> str | None:
    try:
        return subprocess.run(["git", "rev-parse", "HEAD^{tree}"], cwd=root, capture_output=True, text=True,
                              timeout=30, check=True).stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def step_key(step: Step, table: Table, files: list[tuple[str, str, str]], tree: str, paths: list[str] | None,
             env: dict[str, str]) -> str:
    """The step's input hash: what it runs, where, and every tracked file its inputs match."""
    oids = {path: oid for path, _mode, oid in files}
    if step.inputs:
        pattern = re.compile("|".join(f"(?:{glob_pattern(g).pattern})" for g in step.inputs))
        matched: list | str = [[path, mode, oid] for path, mode, oid in files if pattern.match(path)]
        changed = None if paths is None else sorted(p for p in paths if pattern.match(p))
    else:
        matched = tree
        changed = None if paths is None else sorted(paths)
    doc = {
        "v": STEP_KEY_VERSION,
        "step": {f: getattr(step, f) for f in Step.__dataclass_fields__ if f not in ("title", "about", "pr_scope")},
        "setup": table.setup.get(step.job, ""),
        "tools": {t: table.tools[t] for t in sorted(step.needs)},
        "pipeline": {p: oids.get(p, "") for p in PIPELINE_PATHS if p != "ci/steps.toml"},
        "machine": {v: env.get(v, "") for v in MACHINE_VARS},
        "files": matched,
        "changed": changed,
    }
    raw = json.dumps(doc, sort_keys=True, separators=(",", ":"), default=list)
    return hashlib.sha256(raw.encode("utf-8", "surrogateescape")).hexdigest()


class StepResults:
    """The fleet controller's step-result store. Every error is a miss and a write that did not happen."""

    def __init__(self, url: str, write: bool, meta: dict[str, str], timeout: float = 4.0,
                 oidc: tuple[str, str] | None = None) -> None:
        # With oidc (the job's ACTIONS_ID_TOKEN_REQUEST_URL and _TOKEN) the store is the controller's public route,
        # which takes a GitHub Actions OIDC token: the Linux runner pool is off the tailnet, so the tailnet route
        # timed out there and nothing was ever stored (2026-11-25).
        self.oidc = oidc
        self.url = url.rstrip("/") + ("/github/step-results" if oidc else "/v1/ci/step-results")
        self.write = write
        self.meta = meta
        self.timeout = timeout
        self.error = ""  # the first failed call, for the job's summary line: a silent miss hides a refusal
        self.down = False  # an unreachable store costs one timeout, not one per step and write

    def failed(self, what: str, err: Exception) -> None:
        if not self.error:
            code = getattr(err, "code", None)
            reason = getattr(err, "reason", None) or err
            self.error = f"{what} {'HTTP ' + str(code) if code else 'failed'}: {str(reason)[:160]}"

    def headers(self) -> dict[str, str]:
        """A fresh OIDC token per call: one lives minutes, and a job's writes come at its end.

        Always a named User-Agent: Cloudflare in front of gh-events.cmux.com refuses Python's default
        one ("Python-urllib/3.x") with 403, error code 1010, before the controller sees the request."""
        if not self.oidc:
            return {"User-Agent": USER_AGENT}
        url, bearer = self.oidc
        sep = "&" if "?" in url else "?"
        req = urllib.request.Request(f"{url}{sep}audience={OIDC_AUDIENCE}", headers={"Authorization": f"bearer {bearer}"})
        # user-agent: GitHub's OIDC token URL, no CDN of ours
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            token = json.loads(resp.read()).get("value") or ""
        if not token:
            raise ValueError("the OIDC token request returned no token")
        return {"Authorization": f"Bearer {token}", "User-Agent": USER_AGENT}

    @classmethod
    def from_env(cls, env: dict[str, str]) -> "StepResults | None":
        switch = env.get("CI_STEP_RESULTS", "").lower()
        if switch in ("off", "0", "false"):
            return None
        if env.get("GITHUB_ACTIONS") != "true":
            # Off Actions only when asked: the build fleet's pool runs a pull request's fast tier as a controller
            # job (cmuxterm-hq fast_verdict.sh), on the tailnet, and names its run and whether it may write.
            if switch not in ("on", "1", "true"):
                return None
            meta = {"repo": env.get("CI_STEP_RESULTS_REPO", ""), "sha": env.get("CI_STEP_RESULTS_SHA", ""),
                    "run_url": env.get("CI_STEP_RESULTS_RUN_URL", ""),
                    "runner": env.get("CI_STEP_RESULTS_RUNNER", "") or os.uname().nodename}
            write = env.get("CI_STEP_RESULTS_WRITE", "1").lower() not in ("off", "0", "false")
            return cls(env.get("CI_STEP_RESULTS_URL") or CONTROLLER, write, meta)
        if env.get("RUNNER_ENVIRONMENT") == "github-hosted":
            return None  # a GitHub VM is not on the tailnet: every lookup would wait to fail
        write = True
        if env.get("GITHUB_EVENT_NAME", "").startswith("pull_request"):
            try:
                event = json.loads(Path(env.get("GITHUB_EVENT_PATH", "")).read_text(encoding="utf-8"))
                head_repo = event["pull_request"]["head"]["repo"]["full_name"]
            except (OSError, ValueError, KeyError, TypeError):
                head_repo = ""
            write = head_repo == env.get("GITHUB_REPOSITORY")  # a fork's pull request reads, never writes
        server = env.get("GITHUB_SERVER_URL", "https://github.com")
        run_url = f"{server}/{env.get('GITHUB_REPOSITORY', '')}/actions/runs/{env.get('GITHUB_RUN_ID', '')}"
        if env.get("GITHUB_RUN_ATTEMPT"):
            run_url += f"/attempts/{env['GITHUB_RUN_ATTEMPT']}"
        meta = {"repo": env.get("GITHUB_REPOSITORY", ""), "sha": env.get("GITHUB_SHA", ""), "run_url": run_url,
                "runner": env.get("RUNNER_NAME", "")}
        oidc = (env.get("ACTIONS_ID_TOKEN_REQUEST_URL", ""), env.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN", ""))
        if all(oidc):
            return cls(env.get("CI_STEP_RESULTS_PUBLIC_URL") or PUBLIC_CONTROLLER, write, meta, oidc=oidc)
        return cls(env.get("CI_STEP_RESULTS_URL") or CONTROLLER, write, meta)

    def lookup(self, key: str, step: str, audit: bool = False) -> dict | None:
        if self.down:
            return None
        query = urllib.parse.urlencode({"key": key, "step": step, **({"audit": "1"} if audit else {})})
        try:
            req = urllib.request.Request(f"{self.url}?{query}", headers=self.headers())
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                found = json.loads(resp.read())
        except urllib.error.HTTPError as err:
            if err.code != 404:  # 404 is the store's plain miss
                self.failed("lookup", err)
            return None
        except (OSError, ValueError) as err:
            self.failed("lookup", err)
            self.down = isinstance(err, OSError)
            return None
        return found if isinstance(found, dict) and found.get("key") == key else None

    def post(self, key: str, step: str, outcome: str, seconds: float, audit: bool = False) -> None:
        if not self.write or self.down:
            return
        body = json.dumps({"key": key, "step": step, "outcome": outcome, "seconds": round(seconds, 1),
                           "audit": audit, **self.meta}).encode()
        try:
            req = urllib.request.Request(self.url, data=body, method="POST",
                                         headers={"Content-Type": "application/json", **self.headers()})
            urllib.request.urlopen(req, timeout=self.timeout).close()
        except urllib.error.HTTPError as err:
            self.failed("write", err)
        except (OSError, ValueError) as err:
            self.failed("write", err)
            self.down = isinstance(err, OSError)


def audited(key: str, env: dict[str, str]) -> bool:
    """AUDIT_PERCENT of hits run anyway, seeded by the key and the run so a rerun does not re-roll it."""
    seed = f"{key}:{env.get('GITHUB_RUN_ID', '')}".encode()
    return int(hashlib.sha256(seed).hexdigest()[:8], 16) % 100 < AUDIT_PERCENT


def run_step(step: Step, env: dict[str, str] | None = None) -> Result:
    start = time.monotonic()
    proc = subprocess.Popen(
        ["bash", "-euo", "pipefail", "-c", step.run],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        env=env, start_new_session=True,
    )
    try:
        out, _ = proc.communicate(timeout=step.timeout)
        code: int | None = proc.returncode
    except subprocess.TimeoutExpired:
        # The step's own process group, which start_new_session made: its children go with it. A group that is
        # gone (ESRCH), or on macOS one whose processes are all zombies (EPERM), has nothing left to stop.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        out, _ = proc.communicate()
        code = None
    return Result(step, code, time.monotonic() - start, out or "")


def print_log(r: Result, out=sys.stdout) -> None:
    """One step's output as one log group, whole: steps end on several threads."""
    with LOG_LOCK:
        print(f"::group::{r.step.name}\n{r.output.rstrip(chr(10))}\n::endgroup::", file=out, flush=True)


def report(results: list[Result], job: str, out=sys.stdout, logs: bool = True) -> str:
    """Print each step's log (unless it was printed as the step ended) and annotation; return the
    summary table's Markdown."""
    rows = [f"### Job `{job}`", "", "| Step | Blocks | Class | Result | Seconds |", "|---|---|---|---|---|"]
    for r in results:
        if logs:
            print_log(r, out)
        result = ("skipped" if r.skipped else "reused" if r.reused else "passed" if r.ok
                  else ("timed out" if r.code is None else f"exit {r.code}"))
        if not r.ok:
            level = "error" if r.step.blocks else "warning"
            what = f"ran past its {r.step.timeout} s" if r.code is None else f"exited {r.code}"
            note = "" if r.step.blocks else " (advisory: never blocks)"
            print(f"::{level} title={r.step.title or r.step.name}::step {r.step.name} {what}{note}; see its log group", file=out)
        rows.append(f"| {r.step.name} | {'yes' if r.step.blocks else 'no'} | {r.step.klass} | {result} | {r.seconds:.1f} |")
    return "\n".join(rows) + "\n"


def parse_only(text: str | None) -> list[str]:
    """`--only`'s names, comma or space separated, in order; empty means no filter."""
    return [name for name in re.split(r"[\s,]+", text or "") if name]


def reuse_passes(table: Table, steps: list[Step], paths: list[str] | None, store: StepResults,
                 env: dict[str, str], root: Path, out=sys.stdout) -> tuple[list[Result], dict[str, str], set[str]]:
    """Ask the store for each reusable step's key: the reused results, every step's key, the audited names."""
    candidates = [s for s in steps if reusable(s)]
    files = tracked_files(root) if candidates else None
    tree = head_tree(root) if files is not None else None
    if files is None or tree is None:
        return [], {}, set()
    keys = {s.name: step_key(s, table, files, tree, paths, env) for s in candidates}
    with ThreadPoolExecutor(max_workers=min(16, len(candidates))) as pool:
        found = dict(zip(keys, pool.map(lambda s: store.lookup(keys[s.name], s.name, audited(keys[s.name], env)),
                                        candidates)))
    reused, audit = [], set()
    for name, hit in found.items():
        if not hit:
            continue
        if audited(keys[name], env):
            audit.add(name)
            print(f"Step {name}: a pass under its key ({hit.get('run_url', '?')}); audited, so it runs anyway.",
                  file=out)
            continue
        where = f"ran {hit.get('at', '?')} on {hit.get('runner') or '?'}, {hit.get('seconds', '?')} s"
        reused.append(Result(table.steps[name], 0, 0.0,
                             f"Reused: this step's inputs (key {keys[name][:16]}) passed in {hit.get('run_url', '?')} "
                             f"({where}); it did not run again.", reused=hit.get("run_url") or "?"))
    return reused, keys, audit


def step_env(base: Mapping[str, str], tools: str) -> dict[str, str]:
    """The environment every step of a job runs with: the caller's, `$CI_TOOLS/bin` first on PATH, and on a
    GitHub Actions Linux runner CARGO_INCREMENTAL=0 unless the caller set it.

    Each Linux job builds into a fresh workspace's target, so rustc's incremental state (target/*/incremental, a
    copy of every workspace crate's query cache and object files, written for every lib, bin and test target) is
    never read again. It filled a pool VM's disk in run 45531606824 (the cmux_next_ daemon tests, "No space left on
    device" writing cmux-tui/target/debug/incremental), and sccache refuses to cache an incremental compile.
    A laptop or lane keeps cargo's default."""
    env = dict(base, CI_TOOLS=tools, PATH=f"{tools}/bin{os.pathsep}{base.get('PATH', '')}")
    if base.get("GITHUB_ACTIONS") == "true" and base.get("RUNNER_OS") == "Linux":
        env.setdefault("CARGO_INCREMENTAL", "0")
    return env


def run_job(table: Table, job: str, paths: list[str] | None, label: str | None = None, out=sys.stdout,
            workers: int | None = None, only: list[str] | None = None, store: StepResults | None = None,
            root: Path = ROOT, pr_scope: bool = False, tier: str = "full", tools_only: bool = False,
            alone_on_red: bool = False, strict: bool = False) -> int:
    names = route(table, paths, label, pr_scope=pr_scope, tier=tier).get(job, [])
    if pr_scope:
        deferred = [n for n in route(table, paths, label, tier=tier).get(job, []) if n not in names]
        if deferred:
            print(f"--pr-scope: {len(deferred)} step(s) this change reaches only through a whole-directory input or the "
                  f"pipeline's own files run in the post-merge batch, not here: {', '.join(deferred)}", file=out)
    if only:
        for name in only:
            if name not in table.steps:
                print(f"::notice title=Step table::no step {name} in this table (a base from before it); skipped",
                      file=out)
        names = [n for n in names if n in only]
    steps = [table.steps[n] for n in names]
    if not steps:
        print(f"No step of job {job} is routed for this change.", file=out)
        return 0
    results: list[Result] = []
    keys: dict[str, str] = {}
    audit: set[str] = set()
    if store is not None:
        reused, keys, audit = reuse_passes(table, steps, paths, store, dict(os.environ), root, out)
        for r in reused:
            print_log(r, out)
        results += reused
        done = {r.step.name for r in reused}
        steps = [s for s in steps if s.name not in done]
        print(f"Step results: {len(done)} of {len(done) + len(steps)} routed steps reused, {len(keys)} keyed.",
              file=out)
    if not steps:
        return finish(results, job, out)
    # A tool a step leaves unremovable (a root-owned install) must not turn a job of green steps red at cleanup.
    with tempfile.TemporaryDirectory(prefix="ci-tools-", dir=os.environ.get("RUNNER_TEMP") or None,
                                     ignore_cleanup_errors=True) as tools:
        env = step_env(os.environ, tools)
        # The change's paths, one a line, for a step whose own router is finer than path globs (a web subarea):
        # unset when the change is unknown, which a step reads as "everything changed".
        env.pop("CI_PATHS_FILE", None)
        if paths is not None:
            listed = Path(tools) / "changed-paths.txt"
            listed.write_text("".join(f"{p}\n" for p in paths), encoding="utf-8")
            env["CI_PATHS_FILE"] = str(listed)
        ready = True
        if job in table.setup:
            setup = run_step(Step(name=f"setup ({job})", job=job, run=table.setup[job], timeout=SETUP_TIMEOUT,
                                  title=f"{job} setup"), env)
            print_log(setup, out)
            results.append(setup)
            ready = setup.ok
        needed = sorted({t for step in steps for t in step.needs})
        if ready and needed:
            # Each tool is a download: all at once, and the steps wait for the slowest.
            with ThreadPoolExecutor(max_workers=len(needed)) as pool:
                def make_tool(tool: str) -> Result:
                    result = run_step(Step(name=f"tool ({tool})", job=job, run=table.tools[tool],
                                           timeout=TOOL_TIMEOUT, title=f"{tool} for {job}"), env)
                    print_log(result, out)
                    return result
                made = list(pool.map(make_tool, needed))
            results += made
            ready = all(r.ok for r in made)
        if ready and tools_only:
            # A warm only (a pool image bake): the tools are where a later job finds them (RUNNER_TOOL_CACHE,
            # CARGO_HOME, ZIG_TARBALL_CACHE_DIR); no step runs.
            pass
        elif ready:
            # Advisory steps wait on the network, not a CPU: they all start at once, as before.
            limit = len(steps) if job == ADVISORY_JOB else min(len(steps), workers or max(2, os.cpu_count() or 1))
            with ThreadPoolExecutor(max_workers=limit) as pool:
                # A step's log prints when it ends, so a job cut by its own timeout still shows the steps
                # that finished and which one was running.
                def run_and_print(step: Step) -> Result:
                    result = run_step(step, env)
                    print_log(result, out)
                    return result
                results += pool.map(run_and_print, [s for s in steps if not s.alone])
            # An `alone` step takes the whole machine: it runs by itself, after the others, in table order.
            # Once a blocking step failed the job is red, and the re-run runs every step again: an alone step
            # (the long ones: 15 to 65 minutes) would only spend the machine, so it is skipped. `alone_on_red`
            # (the post-merge batch, which nothing re-runs) runs it anyway: it is that commit's only run of it.
            for s in steps:
                if not s.alone:
                    continue
                failed = next((r.step.name for r in results if not r.ok and r.step.blocks), None)
                if failed is None or alone_on_red:
                    results.append(run_and_print(s))
                    continue
                print(f"::notice title=Step table::step {s.name} skipped: blocking step {failed} failed", file=out)
                results.append(Result(s, 0, 0.0, "", skipped=True))
    if store is not None:
        for r in results:
            key = keys.get(r.step.name)
            if not key or r.reused or r.skipped or r.code is None:
                continue
            if r.ok or r.step.name in audit:
                store.post(key, r.step.name, "pass" if r.ok else "fail", r.seconds, audit=r.step.name in audit)
            if r.step.name in audit and not r.ok:
                print(f"::error title=Step results::step {r.step.name} failed its audit: a stored pass of the same "
                      f"inputs did not hold (the key is evicted)", file=out)
        if store.error:
            print(f"::warning title=Step results::{store.url} {store.error}; nothing reused or stored", file=out)
    return finish(results, job, out, strict=strict)


def finish(results: list[Result], job: str, out=sys.stdout, strict: bool = False) -> int:
    summary = report(results, job, out, logs=False)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(summary)
    # STRICT (`step`): the one step's own verdict, a step that does not block included.
    return 1 if any(not r.ok and (r.step.blocks or strict) for r in results) else 0


def run_named_step(table: Table, name: str, out=sys.stdout, workers: int | None = None, root: Path = ROOT,
             system: str | None = None) -> int:
    """`step NAME`: the one step, as its job runs it, with its own verdict (the module's docs). 2: no such step, or
    its job runs on another OS (a Linux step on a Mac would say nothing about the Linux check)."""
    step = table.steps.get(name)
    if step is None:
        print(f"ci/run step: no step {name!r} in {TABLE.relative_to(ROOT)} at this commit", file=out)
        return 2
    if step.job in NO_MACHINE_JOBS:
        print(f"ci/run step: step {name} is in job {step.job}, which runs on no machine", file=out)
        return 2
    want = STEP_JOB_OS.get(step.job, "Linux")
    here = system or platform.system()
    if here != want:
        print(f"ci/run step: step {name} is in job {step.job}, which runs on {want}; this machine is {here}", file=out)
        return 2
    label = step.labels[0] if step.labels else None
    print(f"ci/run step: {name} (job {step.job}{', label ' + label if label else ''})", file=out, flush=True)
    code = run_job(table, step.job, None, label, out=out, workers=workers, only=[name], store=None, root=root,
                   tier="full", alone_on_red=True, strict=True)
    return code


def read_paths(path: str | None) -> list[str] | None:
    if not path:
        return None
    try:
        text = Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    # `git diff -z` ends each path with a NUL and quotes none; a list with no NUL is one path a line.
    return [p for p in (text.split("\0") if "\0" in text else text.splitlines()) if p]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--table", default=str(TABLE))
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("route")
    r.add_argument("--paths-file")
    r.add_argument("--pr-scope", action="store_true", help="route by named inputs only (see the module's docs)")
    r.add_argument("--tier", choices=("pr", "full"), default="full",
                   help="pr: leave the steps marked `tier = \"push\"` to the push tier; full (default): every routed step")
    one = sub.add_parser("step", help="run one step by name here and exit with its verdict (the module's docs)")
    one.add_argument("name")
    one.add_argument("--workers", type=int, default=0)
    x = sub.add_parser("run")
    x.add_argument("--job", required=True)
    x.add_argument("--paths-file")
    x.add_argument("--label", default="", help="the label of a labeled or unlabeled event; empty for other events")
    x.add_argument("--workers", type=int, default=0, help="steps at once (default: the machine's CPUs)")
    x.add_argument("--tier", choices=("pr", "full"), default="full",
                   help="pr: leave the steps marked `tier = \"push\"` to the push tier; full (default): every routed step")
    x.add_argument("--only", default="", help="run only these routed steps (comma or space separated); empty: all")
    x.add_argument("--tools-only", action="store_true",
                   help="run the job's setup and the tools its routed steps need, then no step (a cache warm)")
    x.add_argument("--pr-scope", action="store_true",
                   help="a pull request's route: a step reached only by a whole-directory input or the pipeline's own "
                        "files is left to the post-merge batch")
    x.add_argument("--alone-on-red", action="store_true", default=os.environ.get("CI_RUN_ALONE_ON_RED") == "1",
                   help="run the `alone` steps even after a blocking step failed (the post-merge batch: no re-run); "
                        "CI_RUN_ALONE_ON_RED=1 says the same")
    args = parser.parse_args(argv)
    table = load(Path(args.table))
    paths = read_paths(getattr(args, "paths_file", None))
    if args.command == "route":
        print(json.dumps(route(table, paths, pr_scope=args.pr_scope, tier=args.tier), indent=1, sort_keys=True))
        return 0
    if args.command == "step":
        return run_named_step(table, args.name, workers=args.workers or None, root=Path.cwd())
    if args.job not in table.jobs:
        parser.error(f"--job {args.job!r} is not one of {sorted(table.jobs)}")
    # A label event runs only the steps that name the label: those read the event, so none is reused.
    store = None if args.label or args.tools_only else StepResults.from_env(dict(os.environ))
    return run_job(table, args.job, paths, args.label or None, workers=args.workers or None,
                   only=parse_only(args.only), store=store, root=Path.cwd(), pr_scope=args.pr_scope, tier=args.tier,
                   tools_only=args.tools_only, alone_on_red=args.alone_on_red)


if __name__ == "__main__":
    sys.exit(main())
