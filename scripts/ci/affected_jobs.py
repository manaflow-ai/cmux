#!/usr/bin/env python3
"""Which pull-request CI jobs a change can affect, from the cmux-tui crate graph, not from path globs.

    affected_jobs.py route --base SHA [--head HEAD] [--event pull_request] [--labels JSON] [--workflow WF]
    affected_jobs.py inputs --workflow WF --job ID         # every input of one job, one per line
    affected_jobs.py check                                 # each workflow's `paths:` filter holds its jobs' inputs
    affected_jobs.py gate --base SHA --workflow WF         # whether the change needs route/check (the graph) at all

`route` prints one line per job (`job=true|false  why`) and, under GitHub Actions, writes `job=true|false` to
$GITHUB_OUTPUT for each job of --workflow (every workflow when it is not given). scripts/ci/affected-jobs.json
lists the jobs: each names the crates it builds or tests and its own inputs. A job's inputs are, read from the
head's tree by scripts/ci/cargo_test_verdict.py's crate_inputs (the same graph the acpmux tests verdict and
`cmux-ci test --affected` read through scripts/ci/affected_tests.py):

  - the directory of each of its crates and of every crate those reach by path dependency (normal, dev and build;
    target-specific ones too; optional ones when a feature the build turns on asks for them),
  - every file outside those directories that their sources name: include_str!/include_bytes!, and any "../"
    literal naming an existing path (a test's CARGO_MANIFEST_DIR join of a fixture),
  - the workspace's manifest, lockfile, toolchain and cargo configuration (workspace_inputs), its workflow's own
    inputs and its own.

It never trades a test for speed. Every job runs when:

  - the event is not a pull request (a push to feat-cmux-next is the safety net: it runs everything), or the pull
    request carries the full-ci label;
  - there is no usable base, or git cannot list the change, or the graph cannot be read;
  - the change touches this router, its map, or what it reads the graph with (SELF);
  - a changed path under cmux-tui/ is in no Cargo package, is no job's input, and is not a Markdown file: a path
    the graph cannot place (unknown) is never skipped.

A second list in the map, pull_request_skip, is the replay of the last merged pull requests (job reds read
against base reds, re-runs and later heads of the same pull request): the jobs that never went red for a pull
request's own change (Tier A), and the jobs that did a few times (Tier B: those are fixed forward on the
push, the rate accepted). A pull request skips them unless it carries the full-ci label; a push to feat-cmux-next runs
them, so a red the skip would have hidden still shows on the push that lands it. Their `if:` reads the event and the
label (PR_SKIP_IF), not this router's outputs; `check` holds each to that and to its push trigger.

Replay: scripts/ci/affected_jobs_replay.py replays recent merged pull requests through it. Test:
tests/test_ci_affected_jobs.py.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cargo_test_verdict  # noqa: E402
import git_tree  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
MAP = "scripts/ci/affected-jobs.json"
WORKSPACE = cargo_test_verdict.WORKSPACE
# A change to what decides the routing runs every job.
SELF = (
    MAP, "scripts/ci/affected_jobs.py", "scripts/ci/cargo_test_verdict.py", "scripts/ci/git_tree.py",
    "scripts/ci/affected_jobs_replay.py", "tests/test_ci_affected_jobs.py",
    "scripts/ci/tree_result.py", ".github/actions/tree-result/action.yml", "tests/test_ci_tree_result.py",
)
FULL_LABEL = "full-ci"
# The only base whose pull requests skip pull_request_skip jobs: its push runs them. A pull request into any other
# base (main) runs them, since no push of its base would.
SKIP_BASE = "feat-cmux-next"

# result_key's version: a change to what the key hashes bumps it, so no old green answers a new key.
KEY_VERSION = "tree-result-v1"
# Under cmux-tui/ but in no package and no job's input: a Markdown file is read by nothing unless a crate names it
# (then it is an input). Anything else there is unknown and runs every job.
DOC_SUFFIXES = (".md",)
SHA = re.compile(r"[0-9a-f]{40}")


@dataclass
class Job:
    workflow: str
    id: str
    name: str
    crates: list[str]
    features: list[str]
    inputs: list[str]
    references: bool = True
    # Set when another router decides the job: the output its `if:` reads (cmux-next.yml daemon-test: `daemon`).
    router_output: str = ""
    # The reuse-key file of the binaries the job fetches instead of building (check_binaries_key).
    binaries_key: str = ""
    # Scripts its steps run that its router routes by another rule (another tier it hosts, CI plumbing).
    routed_elsewhere: list[str] = field(default_factory=list)
    # Reuse-key inputs no binary it fetches reads (crate test and bench fixtures).
    key_only: list[str] = field(default_factory=list)
    # It uses only its crates' built libraries and binaries: their tests, benches and examples are not inputs.
    binaries_only: bool = False


@dataclass
class Route:
    run: dict[tuple[str, str], bool] = field(default_factory=dict)
    why: dict[tuple[str, str], str] = field(default_factory=dict)
    everything: str = ""  # why every job runs, when it does
    router_changed: bool = False
    # The pull_request_skip jobs: whether each runs (their `if:` reads the event and the label, not this router).
    pr_skip: dict[tuple[str, str], bool] = field(default_factory=dict)

    def lines(self) -> list[str]:
        out = [f"every job runs: {self.everything}"] if self.everything else []
        for key in sorted(self.run):
            out.append(f"{key[0]} {key[1]}={'true' if self.run[key] else 'false'}  {self.why[key]}")
        for key in sorted(self.pr_skip):
            out.append(f"{key[0]} {key[1]}={'true' if self.pr_skip[key] else 'false'}  "
                       + ("a push or the full-ci label runs it" if self.pr_skip[key] else
                          "skipped on a pull request (pull_request_skip: the replay record is in the map; "
                          "the feat-cmux-next push runs it)"))
        return out


# Tier A of the merged pull request replay: jobs whose reds on the last merged pull requests were never the pull
# request's own (base reds, flakes, infrastructure), and which a push to feat-cmux-next runs anyway. A pull request
# skips them, unless it carries the full-ci label; the push that lands it runs them (the safety net), and a red
# there names the pull requests in its range. `check` holds each one to that: the job's `if:` carries PR_SKIP_IF,
# its workflow starts on a feat-cmux-next push, and no job that needs it would be skipped with it.
PR_SKIP_IF = "(github.event_name != 'pull_request' || !startsWith(github.event.pull_request.base.ref, 'feat-cmux-next') || contains(github.event.pull_request.labels.*.name, 'full-ci'))"
# A job that runs on a pull request only when its change touches the push paths: the workflow's `changes` job runs
# cmux-tui-spec-changed.py, which reads the push trigger's own `paths:`, so the push covers every change it runs on.
PUSH_PATHS_GATE = "needs.changes.outputs.run == 'true'"
PUSH_PATHS_ROUTER = ".github/scripts/cmux-tui-spec-changed.py --workflow"


def load_pr_skip(text: str) -> list[tuple[str, str]]:
    """The (workflow, job id) pairs MAP's pull_request_skip lists."""
    data = json.loads(text).get("pull_request_skip", {})
    return [(workflow, job_id) for workflow, entry in data.get("workflows", {}).items() for job_id in entry]


def load_map(text: str) -> tuple[list[str], list[Job]]:
    data = json.loads(text)
    jobs = []
    for workflow, entry in data["workflows"].items():
        for job_id, spec in entry["jobs"].items():
            jobs.append(Job(workflow, job_id, spec.get("name", job_id), list(spec.get("crates", [])),
                            list(spec.get("features", [])), list(entry.get("inputs", [])) + list(spec.get("inputs", [])),
                            spec.get("compile_only") is not True, spec.get("router_output", ""),
                            spec.get("binaries_key", ""), list(spec.get("routed_elsewhere", [])),
                            list(spec.get("key_only", [])), spec.get("binaries_only") is True))
    return list(data.get("workspace_inputs", [])), jobs


def under(path: str, entry: str) -> bool:
    entry = entry.rstrip("/")
    return path == entry or path.startswith(entry + "/")


class Graph:
    """Each job's inputs at one commit, read once per crate set."""

    def __init__(self, tree: git_tree.GitTree, workspace_inputs: list[str], jobs: list[Job],
                 base_tree: git_tree.GitTree | None = None):
        self.tree = tree
        self.base_tree = base_tree
        self.workspace_inputs = workspace_inputs
        self.jobs = jobs
        self._inputs: dict[tuple[str, str], list[str]] = {}
        self._packages: list[str] | None = None
        self._crates: dict[tuple[str, tuple[str, ...], bool, bool], set[str]] = {}

    def inputs(self, job: Job) -> list[str]:
        key = (job.workflow, job.id)
        if key not in self._inputs:
            found = set(self.workspace_inputs) | set(job.inputs)
            for crate in job.crates:
                found |= self.crate(crate, tuple(job.features), job.references and not job.binaries_only,
                                    job.binaries_only)
            self._inputs[key] = sorted({self.outside_submodule(entry) for entry in found})
        return self._inputs[key]

    def crate(self, crate: str, features: tuple[str, ...], references: bool = True, binaries: bool = False) -> set[str]:
        key = (crate, features, references, binaries)
        if key not in self._crates:
            self._crates[key] = set(cargo_test_verdict.tested_crate_inputs(self.tree, crate, features, references,
                                                                           binaries))
        return self._crates[key]

    def outside_submodule(self, path: str) -> str:
        """PATH, or the submodule it is inside: a change to a submodule's files shows as its gitlink path."""
        parts = path.rstrip("/").split("/")
        entries = self.tree.entries()
        for at in range(1, len(parts)):
            prefix = "/".join(parts[:at])
            if entries.get(prefix, ("",))[0] == git_tree.SUBMODULE:
                return prefix
        return path

    def packages(self) -> list[str]:
        """Every directory under the workspace that holds a Cargo.toml (members and packages of their own), at the
        head or at the base: a file of a package the change deletes is that package's, and the crates that used it
        changed their manifests (or the lockfile) too."""
        if self._packages is None:
            found = set()
            for tree in (self.tree, self.base_tree):
                if tree is not None:
                    found |= {posixpath.dirname(p) for p in tree.files(WORKSPACE, "Cargo.toml")
                              if posixpath.basename(p) == "Cargo.toml"}
            self._packages = sorted(found)
        return self._packages

    def unknown(self, path: str) -> bool:
        return unplaced(path, self.packages(), (entry for job in self.jobs for entry in self.inputs(job)))


def unplaced(path: str, packages, entries) -> bool:
    """PATH is under cmux-tui/, in none of PACKAGES and under none of ENTRIES (every job's inputs), and not a doc."""
    if not under(path, WORKSPACE) or path.endswith(DOC_SUFFIXES):
        return False
    if any(under(path, d) for d in packages if d != WORKSPACE):
        return False
    return not any(under(path, entry) for entry in entries)


def route(tree: git_tree.GitTree | None, changed: list[str] | None, *, event: str = "pull_request",
          labels: list[str] | None = None, map_text: str | None = None, workflow: str | None = None,
          base_tree: git_tree.GitTree | None = None, base_ref: str = SKIP_BASE) -> Route:
    """The jobs to run for CHANGED (None: git could not list the change), with the graph read from TREE (the head);
    BASE_TREE, when given, places the files of packages the change deletes."""
    if map_text is None:
        map_text = (ROOT / MAP).read_text(encoding="utf-8")
    workspace_inputs, jobs = load_map(map_text)
    skipped_here = [key for key in load_pr_skip(map_text) if not workflow or key[0] == workflow]
    if workflow:
        jobs_here = [job for job in jobs if job.workflow == workflow]
        if not jobs_here and not skipped_here:
            raise SystemExit(f"affected_jobs: {MAP} lists no job of {workflow}")
    else:
        jobs_here = jobs
    result = Route()
    for key in skipped_here:
        result.pr_skip[key] = event != "pull_request" or not base_ref.startswith(SKIP_BASE) or FULL_LABEL in (labels or [])

    def everything(why: str) -> Route:
        result.everything = why
        for job in jobs_here:
            result.run[job.workflow, job.id] = True
            result.why[job.workflow, job.id] = why
        return result

    if event != "pull_request":
        return everything(f"a {event} runs every job (the safety net)")
    if FULL_LABEL in (labels or []):
        return everything(f"the {FULL_LABEL} label")
    if changed is None or tree is None:
        return everything("no usable base: the change cannot be listed")
    own = [path for path in changed if path in SELF]
    if own:
        result.router_changed = True
        return everything(f"the router changed ({own[0]})")
    graph = Graph(tree, workspace_inputs, jobs, base_tree)
    # The graph at the base too: a fixture a test reads at run time ("../" literal) counts only while it exists, so
    # a change that deletes it is no input of the head's graph, yet breaks the test that still names it.
    base_graph = Graph(base_tree, workspace_inputs, jobs) if base_tree is not None else None
    try:
        unknown = [path for path in changed if graph.unknown(path)]
        if unknown:
            return everything(f"{unknown[0]} is in no cmux-tui package and no job's input")
        for job in jobs_here:
            inputs = graph.inputs(job) + (base_graph.inputs(job) if base_graph is not None else [])
            hits = [path for path in changed if any(under(path, entry) for entry in inputs)]
            result.run[job.workflow, job.id] = bool(hits)
            result.why[job.workflow, job.id] = (
                f"{hits[0]}" + (f" and {len(hits) - 1} more" if len(hits) > 1 else "") + " is an input"
                if hits else f"none of {len(changed)} changed path(s) is an input")
    except (git_tree.Unreadable, ValueError, KeyError) as why:  # tomllib.TOMLDecodeError is a ValueError
        result.run.clear()
        result.why.clear()
        return everything(f"the crate graph could not be read ({str(why)[:200]})")
    return result


def result_key(graph: Graph, job: Job) -> str:
    """The job's input tree as one hash: the object id of each of its inputs at the graph's commit (a directory's tree
    id covers every file under it), its workflow file, the router's own files and KEY_VERSION. Two commits with the
    same key give the job the same files, so a green result for one is the result for the other (tree_result.py)."""
    entries = graph.tree.entries()
    digest = hashlib.sha256(f"{KEY_VERSION}\0{job.workflow}\0{job.id}\0".encode())
    for entry in sorted(set(graph.inputs(job)) | set(SELF) | {job.workflow}):
        path = entry.rstrip("/")
        found = entries.get(path)
        if found is not None and found[0] == git_tree.SYMLINK:
            found = graph.tree.resolve(path)  # the target's content, not the link's text
            found = found[1:] if found is not None else None
        digest.update(f"{path}\0{found[0] + ' ' + found[1] if found else 'absent'}\n".encode())
    return digest.hexdigest()


def result_keys(tree: git_tree.GitTree, workflow: str | None = None, map_text: str | None = None
                ) -> dict[tuple[str, str], str]:
    """result_key of each job (of WORKFLOW, when given) at TREE; {} when the graph cannot be read: no key, no reuse."""
    if map_text is None:
        map_text = (ROOT / MAP).read_text(encoding="utf-8")
    workspace_inputs, jobs = load_map(map_text)
    graph = Graph(tree, workspace_inputs, jobs)
    try:
        return {(job.workflow, job.id): result_key(graph, job) for job in jobs
                if workflow is None or job.workflow == workflow}
    except (git_tree.Unreadable, ValueError, KeyError):
        return {}


def changed_paths(root: Path, base: str, head: str) -> list[str] | None:
    """BASE..HEAD's paths, both sides of a rename; None when git cannot tell."""
    if not SHA.fullmatch(base or "") or set(base) == {"0"}:
        return None
    done = subprocess.run(["git", "-C", str(root), "diff", "--no-renames", "--name-only", base, head],
                          capture_output=True, text=True, check=False)
    return None if done.returncode else [p for p in done.stdout.splitlines() if p]


# What the graph is read from anywhere in the tree: a crate's manifest and its sources (path dependencies may sit
# outside cmux-tui/, and an include_str!, a "../" literal or a path module is named in a source).
GRAPH_GLOBS = ("**/Cargo.toml", "**/*.rs")
# What `check` reads besides the graph and the routed workflows (pull_request_skip's safety nets).
CHECK_FILES = (".github/post-merge-batch.json", "scripts/ci/pr_router.json")


def gate_globs(root: Path, workflow: str, map_text: str) -> list[str] | None:
    """The paths a change must touch for `route --workflow WORKFLOW` or `check` to answer anything but "no job of
    WORKFLOW runs, nothing is missing":

    - WORKFLOW's push `paths:` (the job's own trigger list, which `check` holds to every input of its jobs, so a
      change outside it is no input of them, and it adds none: a new input is named by a changed source or the map);
    - every manifest and Rust source (GRAPH_GLOBS: what each routed job's input list is read from);
    - every workflow the map routes or skips, CHECK_FILES, the map and the router (SELF): what `check` reads.

    None (gate nothing) when WORKFLOW has no push `paths:`."""
    try:
        own = workflow_paths((root / workflow).read_text(encoding="utf-8"), "push")
    except OSError:
        return None
    if not own:
        return None
    data = json.loads(map_text)
    listed = set(data["workflows"]) | {name for name, _job in load_pr_skip(map_text)}
    listed |= {name for name in data.get("pull_request_skip", {}).get("follows", {}) if name != "//"}
    return ([glob for glob in own if not glob.startswith("!")] + list(GRAPH_GLOBS) + sorted(listed)
            + list(CHECK_FILES) + [MAP] + list(SELF))


def gate(root: Path, changed: list[str] | None, workflow: str, *, event: str = "pull_request",
         labels: list[str] | None = None, map_text: str | None = None) -> tuple[bool, str]:
    """Whether the change needs the crate graph at all (`route` and `check` on a full checkout), and why. A pull
    request whose every changed path is outside gate_globs needs neither: every routed job of WORKFLOW is false and
    `check` reads the same files as at the base (the feat-cmux-next push still runs both). Everything else (a push, the full-ci label, an unlistable change) needs it."""
    if event != "pull_request":
        return True, f"a {event} reads the graph"
    if FULL_LABEL in (labels or []):
        return True, f"the {FULL_LABEL} label"
    if changed is None:
        return True, "no usable base: the change cannot be listed"
    globs = gate_globs(root, workflow, map_text if map_text is not None else (root / MAP).read_text(encoding="utf-8"))
    if globs is None:
        return True, f"{workflow} has no push paths: filter"
    hits = [path for path in changed if any(glob_matches(glob, path) for glob in globs)]
    if hits:
        return True, f"{hits[0]}" + (f" and {len(hits) - 1} more" if len(hits) > 1 else "") + " is on a routed path"
    return False, f"none of {len(changed)} changed path(s) is on {workflow}'s paths, a crate's sources or what check reads"


def workflow_paths(text: str, event: str) -> list[str] | None:
    """The `paths:` globs of EVENT's trigger in a workflow, read without a YAML parser; None when it has none."""
    found, current, inside = None, None, False
    for line in text.splitlines():
        if re.match(r"^\S", line):
            if current is not None or line.startswith("jobs:"):
                break
            current = "" if line.startswith("on:") else None
            continue
        if current is None:
            continue
        if match := re.match(r"^  ([a-z_]+):", line):
            current, inside = match.group(1), False
        elif current == event and re.match(r"^    paths:\s*$", line):
            inside, found = True, []
        elif inside and (match := re.match(r'^      - "?([^"#]+?)"?\s*(#.*)?$', line)):
            found.append(match.group(1))
        elif inside and not re.match(r"^\s*(#.*)?$", line):
            inside = False
    return found


def glob_matches(glob: str, path: str) -> bool:
    """GitHub's `paths:` glob: `**` crosses folders, `*` does not."""
    pattern = "".join(".*" if part == "**" else "[^/]*" if part == "*" else re.escape(part)
                      for part in re.split(r"(\*\*|\*)", glob))
    return re.fullmatch(pattern, path) is not None


def output_key(job_id: str) -> str:
    """The router's $GITHUB_OUTPUT key for a job: its id with `-` as `_`, so `needs.X.outputs.KEY` reads it."""
    return job_id.replace("-", "_")


def job_block(text: str, job_id: str) -> str | None:
    """The lines of JOB_ID's block under `jobs:` in a workflow, without its comment lines; None when it has none."""
    match = re.search(rf"(?m)^jobs:\n(?:.*\n)*?  {re.escape(job_id)}:\n((?:(?:    .*|\s*)\n)*)", text + "\n")
    if match is None:
        return None
    return "\n".join(line for line in match.group(1).splitlines() if not line.lstrip().startswith("#"))


@dataclass
class Placement:
    """One job's inputs and where every cmux-tui path falls, read once at a commit: for a router outside this file
    (scripts/ci/cmux_next_route.py's daemon tier), which asks it about many changes."""
    inputs: list[str]
    packages: list[str]
    every_input: list[str]

    def unknown(self, path: str) -> bool:
        """Graph.unknown: a path the graph cannot place, which runs the job."""
        return unplaced(path, self.packages, self.every_input)


def placement(job_id: str, tree: git_tree.GitTree, root: Path = ROOT, map_text: str | None = None) -> Placement:
    """JOB_ID's Placement at TREE's commit, with the map read from ROOT (or MAP_TEXT). Raises git_tree.Unreadable
    (ValueError on a manifest it cannot parse, KeyError on a job the map lacks) when the graph cannot be read: run the
    job then."""
    workspace_inputs, jobs = load_map(map_text if map_text is not None else (root / MAP).read_text(encoding="utf-8"))
    job = next((j for j in jobs if j.id == job_id), None)
    if job is None:
        raise KeyError(f"{MAP} lists no job {job_id}")
    graph = Graph(tree, workspace_inputs, jobs)
    return Placement(graph.inputs(job), graph.packages(),
                     sorted({entry for other in jobs for entry in graph.inputs(other)}))


def key_entries(text: str) -> list[str]:
    """The paths of a reuse-key file (`TYPE PATH` lines; a tree as DIR/), without the ones the current key version
    leaves out (scripts/ci/cmux_tui_tree_key.py V1_ONLY_INPUTS)."""
    found = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 2 or line.startswith("#") or tuple(parts) in V1_ONLY_KEY_INPUTS:
            continue
        found.append(parts[1] + ("/" if parts[0] == "tree" else ""))
    return found


V1_ONLY_KEY_INPUTS = frozenset({("gitlink", "ghostty")})


def named_by_rust(graph: Graph) -> set[str]:
    """Every file outside its crate that some cmux-tui package's sources name (include_str!, a "../" fixture)."""
    found: set[str] = set()
    for package in graph.packages():
        if package == WORKSPACE:
            continue
        try:
            found |= {entry for entry in graph.crate(package, (), True) if not under(entry, WORKSPACE)}
        except git_tree.Unreadable:
            continue
    return found


def check_binaries_key(graph: Graph, job: Job) -> list[str]:
    """A job that fetches binaries built under a reuse key (`binaries_key`) instead of building them is affected by
    every key input outside the crate graph: a build recipe, a profile, a gitlink. Each must be one of its inputs,
    unless it is a file a cmux-tui crate's source names (a fixture or an embedded file: the graph places it, and
    only for the crates that name it)."""
    entries = key_entries(graph.tree.text(job.binaries_key))
    inputs = graph.inputs(job)
    named = None
    problems = []
    for entry in entries:
        if under(entry, WORKSPACE) or any(under(entry.rstrip("/"), i) for i in inputs + job.key_only):
            continue
        if any(under(crate, entry.rstrip("/")) for crate in job.crates):
            continue  # a crate of the job (first-party-apps/cloud/server): the graph reads what of it is built
        if named is None:
            named = named_by_rust(graph)
        if entry in named:
            continue
        problems.append(f'{MAP}: "{entry}" is in {job.binaries_key} (the key of the binaries {job.name} fetches) '
                        f"but not among its inputs: add it to the job's inputs")
    return problems


# A script or local action a job's steps run: an input of the job that its crates do not name.
JOB_REFERENCE = re.compile(r"(?<![\w/.-])(?:\./)?((?:scripts|\.github/actions|\.github/scripts|tests)/[A-Za-z0-9_./-]*[A-Za-z0-9_])")
ROUTED_IF = "outputs.{key} != 'false'"
# A job another router decides reads that router's output (Job.router_output).
ROUTER_IF = "outputs.{key} == 'true'"


def is_directory(tree: git_tree.GitTree, entry: str) -> bool:
    try:
        found = tree.resolve(entry.rstrip("/"))
    except git_tree.Unreadable:
        return False
    return entry.endswith("/") or (found is not None and found[1] == git_tree.DIRECTORY)


def paths_for(graph: Graph, jobs: list[Job]) -> list[str]:
    """The `paths:` globs a workflow needs so that its trigger starts on every input of JOBS: a directory as DIR/**."""
    globs = set()
    for job in jobs:
        for entry in graph.inputs(job):
            globs.add(entry.rstrip("/") + "/**" if is_directory(graph.tree, entry) else entry)
    return sorted(globs)


TREE_RESULT_ACTION = "./.github/actions/tree-result"
TREE_RESULT_GATE = "steps.tree.outputs.hit != 'true'"


def tree_result_problems(job: Job, block: str) -> list[str]:
    """A job that reuses a green result for its input tree (.github/actions/tree-result) looks it up with its own key,
    skips every step after the lookup only on a hit, and records its green last: a step that ran on a hit would test
    nothing yet could fail or pass on its own, and one not gated would leave the verdict half reused."""
    if TREE_RESULT_ACTION not in block:
        return []
    where = f"{job.workflow}: job {job.id}"
    steps = re.split(r"(?m)^      - ", block)[1:]
    restore = next((i for i, s in enumerate(steps) if TREE_RESULT_ACTION in s and "mode: restore" in s), None)
    save = [i for i, s in enumerate(steps) if TREE_RESULT_ACTION in s and "mode: save" in s]
    if restore is None or not save:
        return [f"{where} uses {TREE_RESULT_ACTION} without both its restore and its save step"]
    problems = []
    key = f"outputs.{output_key(job.id)}_tree }}}}"
    for i in (restore, *save):
        if f"job: {job.id}\n" not in steps[i] + "\n" or key not in steps[i]:
            problems.append(f"{where}: its {TREE_RESULT_ACTION} steps must name job {job.id} and the router's "
                            f"`{output_key(job.id)}_tree` output")
    if "id: tree\n" not in steps[restore] + "\n":
        problems.append(f"{where}: its {TREE_RESULT_ACTION} restore step must have `id: tree`")
    if save != [len(steps) - 1]:
        problems.append(f"{where}: its {TREE_RESULT_ACTION} save step must be its last step")
    for step in steps[restore + 1:]:
        cond = next((line for line in step.splitlines() if line.startswith("        if:")), "")
        if TREE_RESULT_GATE not in cond:
            name = step.splitlines()[0].strip()
            problems.append(f"{where}: step `{name}` after the tree-result lookup runs on a hit: its `if:` must "
                            f"include `{TREE_RESULT_GATE}`")
    return problems


BATCH_SHORT = "its post-merge batch suite's paths (.github/post-merge-batch.json)"


def add_workflow_paths(text: str, event: str, globs: list[str]) -> str:
    """TEXT with GLOBS added after the last entry of EVENT's trigger `paths:` list, quoted as that entry is."""
    lines = text.splitlines(keepends=True)
    current, inside, last = None, False, None
    for i, line in enumerate(lines):
        if re.match(r"^\S", line):
            if current is not None or line.startswith("jobs:"):
                break
            current = "" if line.startswith("on:") else None
            continue
        if current is None:
            continue
        if match := re.match(r"^  ([a-z_]+):", line):
            current, inside = match.group(1), False
        elif current == event and re.match(r"^    paths:\s*$", line):
            inside = True
        elif inside and re.match(r"^      - ", line):
            last = i
        elif inside and not re.match(r"^\s*(#.*)?$", line):
            inside = False
    if last is None:
        return text
    quote = '"' if lines[last].startswith('      - "') else ""
    added = "".join(f"      - {quote}{glob}{quote}\n" for glob in globs)
    return "".join(lines[:last + 1]) + added + "".join(lines[last + 1:])


def add_batch_paths(text: str, paths: list[str], globs: list[str]) -> str:
    """The post-merge batch file's TEXT with GLOBS added at the end of the suite `paths` array that holds PATHS."""
    for match in re.finditer(r'(?s)"paths": \[(.*?)\]', text):
        if json.loads("[" + match.group(1) + "]") != paths:
            continue
        body = match.group(1)
        last = body.rstrip()
        indent = re.search(r"\n([ \t]*)\S[^\n]*$", last).group(1)
        added = "".join(f",\n{indent}{json.dumps(glob)}" for glob in globs)
        start = match.start(1)
        return text[:start] + last + added + body[len(last):] + text[match.end(1):]
    return text


def fix(root: Path, tree: git_tree.GitTree) -> list[str]:
    """What `check` asks of the paths, written: each input a routed job's workflow trigger misses is added to that
    trigger's `paths:`, then each pull_request path a workflow's post-merge batch suite does not start on is added to
    the suite. A new file a crate embeds (a skill an `include_str!` names) is otherwise a hand edit in four workflows
    and the batch file. Returns one line per path added."""
    workspace_inputs, jobs = load_map((root / MAP).read_text(encoding="utf-8"))
    graph = Graph(tree, workspace_inputs, jobs)
    missing: dict[str, dict[str, list[str]]] = {}
    for job in jobs:
        text = (root / job.workflow).read_text(encoding="utf-8")
        for event in ("pull_request", "push"):
            globs = workflow_paths(text, event)
            if globs is None:
                continue
            for entry in graph.inputs(job):
                probe = entry.rstrip("/") + "/x" if is_directory(tree, entry) else entry
                if not any(glob_matches(glob, probe) for glob in globs):
                    glob = entry.rstrip("/") + ("/**" if probe != entry else "")
                    wanted = missing.setdefault(job.workflow, {}).setdefault(event, [])
                    if glob not in wanted:
                        wanted.append(glob)
    added = []
    for workflow, events in sorted(missing.items()):
        path = root / workflow
        text = path.read_text(encoding="utf-8")
        for event, globs in events.items():
            text = add_workflow_paths(text, event, sorted(globs))
            added += [f"{workflow} {event}: {glob}" for glob in sorted(globs)]
        path.write_text(text, encoding="utf-8")
    batch = root / ".github/post-merge-batch.json"
    if batch.exists():
        short = {problem.split(":", 1)[0] for problem in check(root, tree) if BATCH_SHORT in problem}
        for workflow in sorted(short):
            batch_paths = post_merge_batch_paths(root, workflow)
            pulled = workflow_paths((root / workflow).read_text(encoding="utf-8"), "pull_request")
            if not batch_paths or pulled is None:
                continue
            gaps = sorted(uncovered_by_push(pulled, batch_paths))
            if gaps:
                batch.write_text(add_batch_paths(batch.read_text(encoding="utf-8"), batch_paths, gaps),
                                 encoding="utf-8")
                added += [f".github/post-merge-batch.json ({Path(workflow).name}): {glob}" for glob in gaps]
    return added


def check(root: Path, tree: git_tree.GitTree) -> list[str]:
    """What keeps the routing whole, for every job the map lists:

    - its workflow's trigger, when it filters by `paths:` (push and pull_request alike), lists every input of the job:
      a path filter that misses an input never starts the job its change can break (hq
      docs/handbook/test-input-outside-the-path-filter.md); `affected_jobs.py paths --workflow WF` prints them;
    - the workflow has the job, and the job's `if:` reads the router's output for it (`outputs.KEY != 'false'`), or
      the output of the router that decides it (`router_output`: `outputs.KEY == 'true'`);
    - every script, test or local action its steps name is one of its inputs, or one its router routes by another
      rule (`routed_elsewhere`);
    - a job that fetches binaries built under a reuse key (`binaries_key`) holds every key input outside the crate
      graph (check_binaries_key)."""
    workspace_inputs, jobs = load_map((root / MAP).read_text(encoding="utf-8"))
    graph = Graph(tree, workspace_inputs, jobs)
    problems = []
    for job in jobs:
        text = (root / job.workflow).read_text(encoding="utf-8")
        try:
            inputs = graph.inputs(job)
        except (git_tree.Unreadable, ValueError, KeyError) as why:  # tomllib.TOMLDecodeError is a ValueError
            # One job's unreadable crate graph is that job's problem: it used to end the whole check, so a base
            # whose Cargo.toml did not parse hid every other job's missing path (#53846 landed one that way).
            problems.append(f"{job.workflow}: the inputs of {job.name} could not be read: {why}")
            continue
        for event in ("pull_request", "push"):
            globs = workflow_paths(text, event)
            if globs is None:
                continue
            for entry in inputs:
                probe = entry.rstrip("/") + "/x" if is_directory(tree, entry) else entry
                if not any(glob_matches(glob, probe) for glob in globs):
                    problems.append(f'{job.workflow}: the {event} paths miss "{entry.rstrip("/")}'
                                    f'{"/**" if probe != entry else ""}", an input of {job.name} '
                                    f'(`python3 scripts/ci/affected_jobs.py fix` adds it)')
        block = job_block(text, job.id)
        if block is None:
            problems.append(f"{job.workflow} has no job {job.id} ({MAP} routes it)")
            continue
        if_line = next((line for line in block.splitlines() if line.startswith("    if:")), "")
        if job.router_output:
            if ROUTER_IF.format(key=job.router_output) not in if_line:
                problems.append(f"{job.workflow}: job {job.id}'s `if:` does not read its router's "
                                f"`outputs.{job.router_output} == 'true'`")
        elif ROUTED_IF.format(key=output_key(job.id)) not in if_line:
            problems.append(f"{job.workflow}: job {job.id}'s `if:` does not read the router's "
                            f"`outputs.{output_key(job.id)} != 'false'`")
        problems += tree_result_problems(job, block)
        if job.binaries_key:
            problems += check_binaries_key(graph, job)
        for named in sorted(set(JOB_REFERENCE.findall(block))):
            if tree.resolve(named) is None:
                continue  # a path the job writes or a test binary's name, not a file of the tree
            if any(under(named, step) for step in job.routed_elsewhere):
                continue
            if not any(under(named, entry) for entry in inputs):
                problems.append(f"{job.workflow}: job {job.id} runs {named}, which is not among its inputs: add it to "
                                f"the job's inputs in {MAP}")
    problems += check_pr_skip(root, load_pr_skip((root / MAP).read_text(encoding="utf-8")),
                              {(job.workflow, job.id) for job in jobs})
    problems += check_follows(root, (root / MAP).read_text(encoding="utf-8"))
    return sorted(set(problems))


def pushes_feat(text: str) -> bool:
    """Whether a push to feat-cmux-next starts the workflow: an `on: push:` whose branches name it (or list none)."""
    on = re.search(r"(?ms)^on:[ \t]*\n(.*?)(?=^\S)", text + "\nend:\n")
    push = on and re.search(r"(?ms)^  push:[ \t]*\n((?:    .*\n|[ \t]*\n)*)", on.group(1))
    if not push:
        return False
    branches = re.search(r"(?ms)^    branches:(.*?)(?=^    \S|\Z)", push.group(1))
    return branches is None or "feat-cmux-next" in branches.group(1)


def job_ids(text: str) -> list[str]:
    jobs = re.search(r"(?ms)^jobs:\n(.*)", text)
    return re.findall(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", jobs.group(1)) if jobs else []


def job_needs(block: str) -> list[str]:
    """The ids a job block's `needs:` names (inline `[a, b]`, a bare id, or a list)."""
    match = re.search(r"(?m)^    needs:[ \t]*(.*)$((?:\n      - .*)*)", block)
    if match is None:
        return []
    inline = match.group(1).strip().strip("[]")
    listed = re.findall(r"- *([A-Za-z0-9_-]+)", match.group(2))
    return [n.strip() for n in inline.split(",") if n.strip()] + listed


def job_if(block: str) -> str:
    """A job block's `if:` expression, a folded or literal `if: >-` block joined into one line."""
    match = re.search(r"(?m)^    if:[ \t]*(.*)$((?:\n      .*)*)", block)
    if match is None:
        return ""
    head = match.group(1).strip()
    if head.startswith((">", "|")):
        return " ".join(line.strip() for line in match.group(2).splitlines() if line.strip())
    return head


def uncovered_by_push(pulled: list[str], pushed: list[str]) -> set[str]:
    """The pull_request patterns the push list does not start on. An exclude (`!x`) only narrows the pull request,
    so it is never a gap, and a pattern under a pushed `dir/**` is covered by it (a plan doc the docs-only block puts
    back by name, under a push that keeps plans/cmux-next/** whole)."""
    pushed_set = set(pushed)
    prefixes = [p[:-2] for p in pushed if p.endswith("/**") and not p.startswith("!")]
    return {p for p in pulled
            if p not in pushed_set and not p.startswith("!")
            and not any(p.startswith(prefix) for prefix in prefixes)}


def router_affects(root: Path, workflow: str) -> list[str] | None:
    """The paths pr-router.yml calls WORKFLOW on for a feat-cmux-next pull request (scripts/ci/pr_router.json), or None."""
    path = root / "scripts/ci/pr_router.json"
    if not path.exists():
        return None
    callee = json.loads(path.read_text(encoding="utf-8")).get("callees", {}).get(Path(workflow).name)
    return list(callee["affects"]) if callee and "affects" in callee else None


def post_merge_batch_paths(root: Path, workflow: str) -> list[str] | None:
    """The paths of the post-merge batch suite that calls WORKFLOW (.github/post-merge-batch.json; empty: every
    batch run calls it), or None when no suite does."""
    path = root / ".github/post-merge-batch.json"
    if not path.exists():
        return None
    for suite in json.loads(path.read_text(encoding="utf-8")).get("suites", {}).values():
        if suite.get("workflow") == Path(workflow).name:
            return list(suite.get("paths") or [])
    return None


def check_follows(root: Path, map_text: str) -> list[str]:
    """Each pull_request_skip.follows gate: the job it follows is in pull_request_skip, and its workflow sets the gate,
    every time, to that job's skip clause (PR_SKIP_IF) verbatim, so the repair and the check run on the same heads."""
    data = json.loads(map_text).get("pull_request_skip", {})
    listed = {(workflow, job_id) for workflow, entry in data.get("workflows", {}).items() for job_id in entry}
    problems = []
    for workflow, gates in data.get("follows", {}).items():
        if workflow == "//":
            continue
        path = root / workflow
        if not path.exists():
            problems.append(f"{MAP} pull_request_skip.follows names {workflow}, which does not exist")
            continue
        text = path.read_text(encoding="utf-8")
        for gate, followed in gates.items():
            target = tuple(followed.split(" ", 1))
            if target not in listed:
                problems.append(f"{workflow}: {gate} follows {followed}, which pull_request_skip does not list")
            values = re.findall(rf"(?m)^\s+{re.escape(gate)}:\s*(.*?)\s*$", text)
            if not values:
                problems.append(f"{workflow} never sets {gate} ({MAP} pull_request_skip.follows)")
            for value in values:
                if value != "${{ " + PR_SKIP_IF + " }}":
                    problems.append(f"{workflow}: {gate} is {value}, not {followed}'s skip clause "
                                    f"${{{{ {PR_SKIP_IF} }}}}, so the two would run on different heads")
    return problems


def fail_open_reads(if_text: str, job_id: str) -> list[str]:
    """The parts of IF_TEXT that run when JOB_ID was skipped: `needs.JOB_ID.outputs.Y != 'false'` (an empty
    output is not 'false') and `needs.JOB_ID.result != 'success'`."""
    j = re.escape(job_id)
    pattern = rf"needs\.{j}\.(?:outputs\.[\w-]+\s*!=\s*['\"]false['\"]|result\s*!=\s*['\"]success['\"])"
    return [m.group(0) for m in re.finditer(pattern, if_text)]


def check_pr_skip(root: Path, skipped: list[tuple[str, str]], routed: set[tuple[str, str]] = frozenset()) -> list[str]:
    """Each pull_request_skip job: its `if:` carries PR_SKIP_IF; its workflow is a post-merge batch suite (on every
    path its pull_request trigger starts on) or starts on a feat-cmux-next push, on every
    path its pull_request trigger starts on (the push is the safety net that runs it), or, for a job the crate graph
    routes too (ROUTED), on every input of the job, which `check` already holds the push paths to, or, for a job
    that runs only when its change touches the push paths (PUSH_PATHS_GATE), on those; and every job of
    the workflow that needs it still decides for itself when it is skipped (an `if:` with !cancelled(), always() or
    failure(): the default success() would skip it too), never runs on a pull request, or is skipped with it."""
    problems = []
    names = set(skipped)
    for workflow, job_id in skipped:
        path = root / workflow
        if not path.exists():
            problems.append(f"{MAP} pull_request_skip names {workflow}, which does not exist")
            continue
        text = path.read_text(encoding="utf-8")
        block = job_block(text, job_id)
        if block is None:
            problems.append(f"{workflow} has no job {job_id} ({MAP} pull_request_skip lists it)")
            continue
        if_line = next((line for line in block.splitlines() if line.startswith("    if:")), "")
        if PR_SKIP_IF not in if_line:
            problems.append(f"{workflow}: job {job_id}'s `if:` does not carry {PR_SKIP_IF}, so a pull request still "
                            f"runs it ({MAP} pull_request_skip)")
        batch_paths = post_merge_batch_paths(root, workflow)
        if batch_paths is not None:
            # The post-merge batch tier calls it after merges into feat-cmux-next: that is its safety net. A suite
            # with no paths runs on every batch; one with paths must start on every path its pull request does.
            pulled = workflow_paths(text, "pull_request")
            if pulled is None:
                pulled = router_affects(root, workflow)
            if batch_paths and (pulled is None or uncovered_by_push(pulled, batch_paths)) \
                    and (workflow, job_id) not in routed:
                problems.append(f"{workflow}: {BATCH_SHORT} start "
                                f"on fewer paths than its pull_request paths, so a change the batch skips would run "
                                f"{job_id} nowhere ({MAP} pull_request_skip)")
        elif not pushes_feat(text):
            problems.append(f"{workflow}: no push to feat-cmux-next starts it, so nothing would run {job_id} once "
                            f"a pull request skips it ({MAP} pull_request_skip)")
        else:
            pushed, pulled = workflow_paths(text, "push"), workflow_paths(text, "pull_request")
            if pulled is None:
                # A pr-router callee has no pull_request trigger: its pull request paths are the router's `affects`.
                pulled = router_affects(root, workflow)
            narrower = pushed is not None and (pulled is None or bool(uncovered_by_push(pulled, pushed)))
            gated = PUSH_PATHS_GATE in if_line and "needs: changes" in block and PUSH_PATHS_ROUTER in text
            if narrower and (workflow, job_id) not in routed and not gated:
                problems.append(f"{workflow}: its push paths start on fewer paths than its pull_request paths, so a "
                                f"change the push skips would run {job_id} nowhere ({MAP} pull_request_skip)")
        for other in job_ids(text):
            other_block = job_block(text, other) or ""
            if job_id not in job_needs(other_block) or (workflow, other) in names:
                continue
            other_if = job_if(other_block)
            # A skipped job's outputs are empty and its result is `skipped`: a gate that runs unless they say
            # otherwise (`needs.X.outputs.Y != 'false'`, `needs.X.result != 'success'`) runs on every pull request
            # the skip reaches. conformance did, behind contract: 148 of 154 runs on 11-21 needed nothing. Read
            # before the next test: `github.event_name != 'pull_request' || needs.X...` runs on a pull request.
            if PR_SKIP_IF not in other_if and "github.event_name != 'pull_request' &&" not in other_if \
                    and fail_open_reads(other_if, job_id):
                problems.append(f"{workflow}: job {other} runs unless {job_id} says otherwise "
                                f"({', '.join(fail_open_reads(other_if, job_id))}), and a pull request skips {job_id}, "
                                f"so {other} runs on every pull request: carry {PR_SKIP_IF} (list it in {MAP} "
                                f"pull_request_skip) or read the output as == 'true'")
                continue
            # A job that never runs on a pull request loses nothing when the pull request skips what it needs.
            if "github.event_name != 'pull_request'" in other_if:
                continue
            if not any(status in other_if for status in ("!cancelled()", "always()", "failure()")):
                problems.append(f"{workflow}: job {other} needs {job_id}, which a pull request skips, and its `if:` "
                                f"has no !cancelled(), always() or failure(), so it would be skipped too")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=ROOT)
    sub = parser.add_subparsers(dest="command", required=True)
    one = sub.add_parser("route")
    one.add_argument("--base", default="")
    one.add_argument("--head", default="HEAD")
    one.add_argument("--event", default="pull_request")
    one.add_argument("--labels", default="[]", help="the pull request's label names, as a JSON list")
    one.add_argument("--base-ref", default=SKIP_BASE, help="the pull request's base branch")
    one.add_argument("--workflow", help="only this workflow's jobs (and their $GITHUB_OUTPUT keys)")
    inputs = sub.add_parser("inputs")
    inputs.add_argument("--workflow", required=True)
    inputs.add_argument("--job", required=True)
    gated = sub.add_parser("gate", help="whether the change needs the crate graph (route, check) at all")
    gated.add_argument("--base", default="")
    gated.add_argument("--head", default="HEAD")
    gated.add_argument("--event", default="pull_request")
    gated.add_argument("--labels", default="[]", help="the pull request's label names, as a JSON list")
    gated.add_argument("--workflow", required=True, help="the routed workflow; its job outputs read `false` when the "
                       "graph is not needed")
    sub.add_parser("check")
    sub.add_parser("fix", help="add every input a routed job's workflow paths miss to them, and every pull_request "
                   "path its post-merge batch suite misses to the suite, then print what it added")
    paths = sub.add_parser("paths", help="the paths: globs a workflow's trigger needs for its routed jobs")
    paths.add_argument("--workflow", required=True)
    args = parser.parse_args(argv)
    root = args.repo

    if args.command == "fix":
        with git_tree.GitTree(root) as tree:
            for line in fix(root, tree):
                print(line)
        return 0
    if args.command == "check":
        with git_tree.GitTree(root) as tree:
            problems = check(root, tree)
        for problem in problems:
            print(f"::error::{problem}")
        return 1 if problems else 0
    if args.command == "gate":
        try:
            labels = json.loads(args.labels or "[]")
        except json.JSONDecodeError:
            labels = [FULL_LABEL]
        changed = changed_paths(root, args.base, args.head) if args.event == "pull_request" else None
        needed, why = gate(root, changed, args.workflow, event=args.event, labels=labels)
        print(f"graph={'needed' if needed else 'not needed'}  {why}")
        if "GITHUB_OUTPUT" in os.environ:
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
                out.write(f"needed={'true' if needed else 'false'}\n")
                if not needed:
                    # What `route` writes when nothing is an input: never empty, which a routed `if:` reads as run.
                    out.write("router_changed=false\n")
                    _inputs, jobs = load_map((root / MAP).read_text(encoding="utf-8"))
                    for job in jobs:
                        if job.workflow == args.workflow:
                            out.write(f"{output_key(job.id)}=false\n")
        return 0
    if args.command == "paths":
        workspace_inputs, jobs = load_map((root / MAP).read_text(encoding="utf-8"))
        with git_tree.GitTree(root) as tree:
            graph = Graph(tree, workspace_inputs, jobs)
            print("\n".join(paths_for(graph, [j for j in jobs if j.workflow == args.workflow])))
        return 0
    if args.command == "inputs":
        workspace_inputs, jobs = load_map((root / MAP).read_text(encoding="utf-8"))
        job = next((j for j in jobs if j.workflow == args.workflow and j.id == args.job), None)
        if job is None:
            raise SystemExit(f"affected_jobs: no job {args.job} of {args.workflow} in {MAP}")
        with git_tree.GitTree(root) as tree:
            print("\n".join(Graph(tree, workspace_inputs, jobs).inputs(job)))
        return 0

    try:
        labels = json.loads(args.labels or "[]")
    except json.JSONDecodeError:
        labels = [FULL_LABEL]  # unreadable labels: as if full-ci, never fewer jobs
    changed = changed_paths(root, args.base, args.head) if args.event == "pull_request" else None
    try:
        tree = git_tree.GitTree(root, args.head)
    except git_tree.Unreadable:
        tree = None
    base_tree = git_tree.GitTree(root, args.base) if changed is not None else None
    try:
        result = route(tree, changed, event=args.event, labels=labels, workflow=args.workflow, base_tree=base_tree,
                       base_ref=args.base_ref)
        keys = result_keys(tree, args.workflow) if tree is not None else {}
    finally:
        for opened in (tree, base_tree):
            if opened is not None:
                opened.close()
    for line in result.lines():
        print(line)
    for (workflow, job_id), key in sorted(keys.items()):
        print(f"{workflow} {job_id} input tree {key}")
    if "GITHUB_OUTPUT" in os.environ:
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
            out.write(f"router_changed={'true' if result.router_changed else 'false'}\n")
            for (_workflow, job_id), run in sorted(result.run.items()):
                out.write(f"{output_key(job_id)}={'true' if run else 'false'}\n")
            for (_workflow, job_id), key in sorted(keys.items()):
                out.write(f"{output_key(job_id)}_tree={key}\n")
    if "GITHUB_STEP_SUMMARY" in os.environ:
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as out:
            out.write("### Jobs this change can affect (scripts/ci/affected_jobs.py)\n\n")
            out.write("".join(f"- {line}\n" for line in result.lines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
