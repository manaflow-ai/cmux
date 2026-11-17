#!/usr/bin/env python3
"""Which pull-request CI jobs a change can affect, from the cmux-tui crate graph, not from path globs.

    affected_jobs.py route --base SHA [--head HEAD] [--event pull_request] [--labels JSON] [--workflow WF]
    affected_jobs.py inputs --workflow WF --job ID         # every input of one job, one per line
    affected_jobs.py check                                 # each workflow's `paths:` filter holds its jobs' inputs

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

Replay: scripts/ci/affected_jobs_replay.py replays recent merged pull requests through it. Test:
tests/test_ci_affected_jobs.py.
"""
from __future__ import annotations

import argparse
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
)
FULL_LABEL = "full-ci"
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


@dataclass
class Route:
    run: dict[tuple[str, str], bool] = field(default_factory=dict)
    why: dict[tuple[str, str], str] = field(default_factory=dict)
    everything: str = ""  # why every job runs, when it does
    router_changed: bool = False

    def lines(self) -> list[str]:
        out = [f"every job runs: {self.everything}"] if self.everything else []
        for key in sorted(self.run):
            out.append(f"{key[0]} {key[1]}={'true' if self.run[key] else 'false'}  {self.why[key]}")
        return out


def load_map(text: str) -> tuple[list[str], list[Job]]:
    data = json.loads(text)
    jobs = []
    for workflow, entry in data["workflows"].items():
        for job_id, spec in entry["jobs"].items():
            jobs.append(Job(workflow, job_id, spec.get("name", job_id), list(spec.get("crates", [])),
                            list(spec.get("features", [])), list(entry.get("inputs", [])) + list(spec.get("inputs", [])),
                            spec.get("compile_only") is not True))
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
        self._crates: dict[tuple[str, tuple[str, ...], bool], set[str]] = {}

    def inputs(self, job: Job) -> list[str]:
        key = (job.workflow, job.id)
        if key not in self._inputs:
            found = set(self.workspace_inputs) | set(job.inputs)
            for crate in job.crates:
                found |= self.crate(crate, tuple(job.features), job.references)
            self._inputs[key] = sorted({self.outside_submodule(entry) for entry in found})
        return self._inputs[key]

    def crate(self, crate: str, features: tuple[str, ...], references: bool = True) -> set[str]:
        key = (crate, features, references)
        if key not in self._crates:
            self._crates[key] = set(cargo_test_verdict.tested_crate_inputs(self.tree, crate, features, references))
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
        if not under(path, WORKSPACE) or path.endswith(DOC_SUFFIXES):
            return False
        if any(under(path, d) for d in self.packages() if d != WORKSPACE):
            return False
        return not any(under(path, entry) for job in self.jobs for entry in self.inputs(job))


def route(tree: git_tree.GitTree | None, changed: list[str] | None, *, event: str = "pull_request",
          labels: list[str] | None = None, map_text: str | None = None, workflow: str | None = None,
          base_tree: git_tree.GitTree | None = None) -> Route:
    """The jobs to run for CHANGED (None: git could not list the change), with the graph read from TREE (the head);
    BASE_TREE, when given, places the files of packages the change deletes."""
    if map_text is None:
        map_text = (ROOT / MAP).read_text(encoding="utf-8")
    workspace_inputs, jobs = load_map(map_text)
    if workflow:
        jobs_here = [job for job in jobs if job.workflow == workflow]
        if not jobs_here:
            raise SystemExit(f"affected_jobs: {MAP} lists no job of {workflow}")
    else:
        jobs_here = jobs
    result = Route()

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
    try:
        unknown = [path for path in changed if graph.unknown(path)]
        if unknown:
            return everything(f"{unknown[0]} is in no cmux-tui package and no job's input")
        for job in jobs_here:
            inputs = graph.inputs(job)
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


def changed_paths(root: Path, base: str, head: str) -> list[str] | None:
    """BASE..HEAD's paths, both sides of a rename; None when git cannot tell."""
    if not SHA.fullmatch(base or "") or set(base) == {"0"}:
        return None
    done = subprocess.run(["git", "-C", str(root), "diff", "--no-renames", "--name-only", base, head],
                          capture_output=True, text=True, check=False)
    return None if done.returncode else [p for p in done.stdout.splitlines() if p]


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


# A script or local action a job's steps run: an input of the job that its crates do not name.
JOB_REFERENCE = re.compile(r"(?<![\w/.-])(?:\./)?((?:scripts|\.github/actions|\.github/scripts|tests)/[A-Za-z0-9_./-]*[A-Za-z0-9_])")
ROUTED_IF = "outputs.{key} != 'false'"


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


def check(root: Path, tree: git_tree.GitTree) -> list[str]:
    """What keeps the routing whole, for every job the map lists:

    - its workflow's trigger, when it filters by `paths:` (push and pull_request alike), lists every input of the job:
      a path filter that misses an input never starts the job its change can break (hq
      docs/handbook/test-input-outside-the-path-filter.md); `affected_jobs.py paths --workflow WF` prints them;
    - the workflow has the job, and the job's `if:` reads the router's output for it (`outputs.KEY != 'false'`);
    - every script, test or local action its steps name is one of its inputs."""
    workspace_inputs, jobs = load_map((root / MAP).read_text(encoding="utf-8"))
    graph = Graph(tree, workspace_inputs, jobs)
    problems = []
    for job in jobs:
        text = (root / job.workflow).read_text(encoding="utf-8")
        inputs = graph.inputs(job)
        for event in ("pull_request", "push"):
            globs = workflow_paths(text, event)
            if globs is None:
                continue
            for entry in inputs:
                probe = entry.rstrip("/") + "/x" if is_directory(tree, entry) else entry
                if not any(glob_matches(glob, probe) for glob in globs):
                    problems.append(f'{job.workflow}: the {event} paths miss "{entry}"'
                                    f'{"/**" if probe != entry else ""}, an input of {job.name}')
        block = job_block(text, job.id)
        if block is None:
            problems.append(f"{job.workflow} has no job {job.id} ({MAP} routes it)")
            continue
        if_line = next((line for line in block.splitlines() if line.startswith("    if:")), "")
        if ROUTED_IF.format(key=output_key(job.id)) not in if_line:
            problems.append(f"{job.workflow}: job {job.id}'s `if:` does not read the router's "
                            f"`outputs.{output_key(job.id)} != 'false'`")
        for named in sorted(set(JOB_REFERENCE.findall(block))):
            if tree.resolve(named) is None:
                continue  # a path the job writes or a test binary's name, not a file of the tree
            if not any(under(named, entry) for entry in inputs):
                problems.append(f"{job.workflow}: job {job.id} runs {named}, which is not among its inputs: add it to "
                                f"the job's inputs in {MAP}")
    return sorted(set(problems))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=ROOT)
    sub = parser.add_subparsers(dest="command", required=True)
    one = sub.add_parser("route")
    one.add_argument("--base", default="")
    one.add_argument("--head", default="HEAD")
    one.add_argument("--event", default="pull_request")
    one.add_argument("--labels", default="[]", help="the pull request's label names, as a JSON list")
    one.add_argument("--workflow", help="only this workflow's jobs (and their $GITHUB_OUTPUT keys)")
    inputs = sub.add_parser("inputs")
    inputs.add_argument("--workflow", required=True)
    inputs.add_argument("--job", required=True)
    sub.add_parser("check")
    paths = sub.add_parser("paths", help="the paths: globs a workflow's trigger needs for its routed jobs")
    paths.add_argument("--workflow", required=True)
    args = parser.parse_args(argv)
    root = args.repo

    if args.command == "check":
        with git_tree.GitTree(root) as tree:
            problems = check(root, tree)
        for problem in problems:
            print(f"::error::{problem}")
        return 1 if problems else 0
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
        result = route(tree, changed, event=args.event, labels=labels, workflow=args.workflow, base_tree=base_tree)
    finally:
        for opened in (tree, base_tree):
            if opened is not None:
                opened.close()
    for line in result.lines():
        print(line)
    if "GITHUB_OUTPUT" in os.environ:
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
            out.write(f"router_changed={'true' if result.router_changed else 'false'}\n")
            for (_workflow, job_id), run in sorted(result.run.items()):
                out.write(f"{output_key(job_id)}={'true' if run else 'false'}\n")
    if "GITHUB_STEP_SUMMARY" in os.environ:
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as out:
            out.write("### Jobs this change can affect (scripts/ci/affected_jobs.py)\n\n")
            out.write("".join(f"- {line}\n" for line in result.lines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
