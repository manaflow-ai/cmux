#!/usr/bin/env python3
"""Path-scoped skips for the fast per-PR checks: a check runs on a pull request only when its diff touches an input.

    fast_check_route.py route --workflow WF [--base REV --head REV | --changed FILE] [--event E] [--labels L]
    fast_check_route.py check                     # the detector: declared inputs exist and hold what each job reads
    fast_check_route.py inputs --workflow WF --job ID

scripts/ci/fast-check-inputs.json lists, per workflow, the fast checks (jobs) that skip and each one's inputs: a path
ending in "/" is a folder, one with * or ? a GitHub `paths:` glob (`**` crosses folders), anything else one file. The
workflow file itself is an input of every one of its checks. A check may also take:

  "added_files": true   any file the pull request adds (a guard that reads every new file's header);
  "generated": true     any path the generated files guard treats as generated (scripts/ci/generated-files.json
                        outputs, a "generated" path segment or name);
  "router": "guard_groups"  the paths the cmux-next CI guard group routes (detect_linux_guard_changes.classify_feat
                        and the `ci` group's owners, workflow_guard_groups.groups_for_path): it runs when any group
                        would run beside the declared inputs;
  "push_cover"          for a workflow no feat-cmux-next push starts: the workflows (each with a push trigger on
                        feat-cmux-next) that run the same checks on the push that lands the pull request.

`route` writes KEY=true|false to $GITHUB_OUTPUT for each listed job of --workflow (KEY: the job id, "-" as "_"). The
workflow's `fast-check-route` job (the 2-vCPU pool, a blob-less checkout of the merge commit) runs it, and each listed
job's `if:` carries `needs.fast-check-route.outputs.KEY != 'false'`: a skipped job reports skipped, which a required
check reads as passed, and an empty output (the router failed, or a push or dispatch where the route job does not run)
runs the job. Every check runs when:

  - the event is not a pull request (the feat-cmux-next push runs everything: a miss is a fix-forward on base),
    or the pull request carries the full-ci label;
  - the diff cannot be read;
  - the change touches this router, its map or its test (SELF).

`check` is the detector (tests/test_ci_fast_check_route.py runs it on the tree):

  - every workflow and job the map lists exists, and every declared input names a tracked path;
  - each listed job needs fast-check-route and its `if:` reads the route; the route job lists the job's output and
    runs on the 2-vCPU pool (ROUTE_RUNS_ON);
  - the workflow runs on a feat-cmux-next push, or each push_cover workflow does;
  - what the job reads is inside its inputs: every repository path its steps name, followed into each Python or shell
    script it names (a Python script's local imports and its string literals naming a tracked path, a shell script's
    path words), must be under a declared input or listed in the check's "not_inputs" with the reason.
"""
from __future__ import annotations

import argparse
import ast
import fnmatch
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAP = "scripts/ci/fast-check-inputs.json"
SELF = (MAP, "scripts/ci/fast_check_route.py", "tests/test_ci_fast_check_route.py")
FULL_LABEL = "full-ci"
# The smallest pool runner: no GitHub-hosted label (the runner-label policy refuses one).
ROUTE_RUNS_ON = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-2vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_2 }}"
ROUTE_JOB = "fast-check-route"
BRANCH = "feat-cmux-next"


def output_key(job_id: str) -> str:
    return job_id.replace("-", "_")


def routed_if(job_id: str) -> str:
    return f"needs.{ROUTE_JOB}.outputs.{output_key(job_id)} != 'false'"


def glob_matches(glob: str, path: str) -> bool:
    """GitHub's `paths:` glob: `**` crosses folders, `*` and `?` do not."""
    pattern = "".join(".*" if part == "**" else "[^/]*" if part == "*" else "[^/]" if part == "?" else re.escape(part)
                      for part in re.split(r"(\*\*|\*|\?)", glob))
    if glob.startswith("**/"):
        pattern = "(?:.*/)?" + pattern[len(".*/"):]
    return re.fullmatch(pattern, path) is not None


def covered(path: str, entry: str) -> bool:
    """Whether PATH is under input ENTRY (a folder "x/", a glob, or one file; a folder read as a whole is covered by
    an input inside it only when that input is the folder itself)."""
    if any(ch in entry for ch in "*?"):
        return glob_matches(entry, path)
    if entry.endswith("/"):
        return path.startswith(entry) or path == entry.rstrip("/")
    return path == entry


def load(root: Path = ROOT) -> dict:
    return json.loads((root / MAP).read_text(encoding="utf-8"))


def checks_of(data: dict, workflow: str | None = None) -> list[tuple[str, str, dict]]:
    return [(wf, job_id, spec) for wf, jobs in data["workflows"].items() if workflow in (None, wf)
            for job_id, spec in jobs.items()]


# --- route ----------------------------------------------------------------------------------------------------------

GENERATED_MANIFEST = "scripts/ci/generated-files.json"
GENERATED_BASELINE = "scripts/ci/generated-files-baseline.txt"
GENERATED_OUTPUTS = "scripts/cmux-next/generated_outputs.py"
_generated_cache: dict[Path, tuple[list[str], list[re.Pattern[str]]] | None] = {}


def _generated_rules(root: Path) -> tuple[list[str], list[re.Pattern[str]]] | None:
    """The globs and regexes the generated files guard and the generated merge audit judge a path by: the manifest's
    conventions, committed paths and each generator (its script, outputs and inputs), the baseline's files, and
    generated_outputs.py OUTPUTS (each output pattern and its inputs). None when one cannot be read."""
    if root in _generated_cache:
        return _generated_cache[root]
    try:
        manifest = json.loads((root / GENERATED_MANIFEST).read_text(encoding="utf-8"))
        baseline = (root / GENERATED_BASELINE).read_text(encoding="utf-8").splitlines()
        spec = importlib.util.spec_from_file_location("_fast_check_generated_outputs", root / GENERATED_OUTPUTS)
        outputs = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(outputs)
        globs = [*manifest.get("conventions", [])]
        for entry in manifest.get("committed", []):
            globs += entry.get("paths", [])
        for gen in manifest.get("generators", []):
            globs += [gen.get("generator", ""), *gen.get("outputs", []), *gen.get("inputs", [])]
        globs += [line.strip() for line in baseline if line.strip() and not line.startswith("#")]
        regexes = []
        for patterns, inputs, _how in outputs.OUTPUTS:
            regexes += [re.compile(fnmatch.translate(pattern)) for pattern in patterns]
            regexes.append(re.compile(inputs))
        rules = ([glob for glob in globs if glob], regexes)
    except Exception:  # noqa: BLE001 - any unreadable rule: every path may be generated
        rules = None
    _generated_cache[root] = rules
    return rules


def generated_path(path: str, root: Path) -> bool:
    """Whether the generated files guard or the generated merge audit can judge PATH: a generated output, a generator
    or one of its inputs."""
    rules = _generated_rules(root)
    if rules is None:
        return True
    globs, regexes = rules
    return any(covered(path, glob) for glob in globs) or any(regex.search(path) for regex in regexes)


def guard_groups_route(paths: list[str]) -> str | None:
    """Why the cmux-next CI guard group runs for PATHS (a routed group, or the `ci` group's input), or None."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import detect_linux_guard_changes as detect  # noqa: PLC0415
    import workflow_guard_groups as groups  # noqa: PLC0415

    routed = detect.classify_feat(paths)
    if routed:
        return f"routes guard groups {', '.join(routed)}"
    for path in paths:
        owners = groups.groups_for_path(path)
        if owners is not None and "ci" in owners:
            return f"{path} is read by the ci guard group"
        if owners is None and not path.startswith(detect.FEAT_PRODUCT_AREAS) and not detect.plain_documentation(path):
            return f"{path} has no known guard owner"
    return None


def decide(workflow: str, job_id: str, spec: dict, changed: list[tuple[str, str]], root: Path) -> tuple[bool, str]:
    """Whether a pull request that changes CHANGED ((status, path) pairs) runs JOB_ID, and why."""
    for status, path in changed:
        if path == workflow:
            return True, f"changes {workflow}"
        for entry in spec.get("inputs", []):
            if covered(path, entry):
                return True, f"{path} is an input ({entry})"
        if spec.get("added_files") and status.startswith("A"):
            return True, f"adds {path}"
        if spec.get("generated") and generated_path(path, root):
            return True, f"{path} may be a generated output"
    if spec.get("router") == "guard_groups":
        why = guard_groups_route([path for _, path in changed])
        if why:
            return True, why
    return False, "the change touches none of its inputs (the feat-cmux-next push runs it)"


def changed_paths(root: Path, base: str, head: str) -> list[tuple[str, str]] | None:
    result = subprocess.run(["git", "-C", str(root), "diff", "--name-status", "--no-renames", base, head],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None
    pairs = []
    for line in result.stdout.splitlines():
        status, _, path = line.partition("\t")
        if path:
            pairs.append((status, path))
    return pairs


def route(workflow: str, changed: list[tuple[str, str]] | None, *, event: str, labels: list[str],
          root: Path = ROOT, data: dict | None = None) -> dict[str, tuple[bool, str]]:
    data = data if data is not None else load(root)
    checks = checks_of(data, workflow)
    if not checks:
        raise SystemExit(f"fast_check_route: {MAP} lists no job of {workflow}")
    everything = None
    if event != "pull_request":
        everything = f"a {event} runs every check"
    elif FULL_LABEL in labels:
        everything = f"the {FULL_LABEL} label runs every check"
    elif changed is None:
        everything = "the diff could not be read"
    elif any(path in SELF for _, path in changed):
        everything = "the change touches the router"
    result = {}
    for wf, job_id, spec in checks:
        result[job_id] = (True, everything) if everything else decide(wf, job_id, spec, changed, root)
    return result


# --- check (the detector) -------------------------------------------------------------------------------------------

def tracked(root: Path) -> list[str]:
    return subprocess.run(["git", "-C", str(root), "ls-files"], capture_output=True, text=True,
                          check=True).stdout.splitlines()


class Tree:
    def __init__(self, files: list[str]):
        self.files = set(files)
        self.dirs = {"/".join(f.split("/")[:i]) for f in files for i in range(1, f.count("/") + 1)}

    def exists(self, path: str) -> bool:
        path = path.rstrip("/")
        return path in self.files or path in self.dirs

    def any_match(self, entry: str) -> bool:
        if any(ch in entry for ch in "*?"):
            return any(glob_matches(entry, f) for f in self.files)
        return self.exists(entry)


def job_block(text: str, job_id: str) -> str | None:
    """JOB_ID's lines under `jobs:` without its comment lines; None when the workflow has no such job."""
    match = re.search(rf"(?m)^jobs:\n(?:.*\n)*?  {re.escape(job_id)}:\n((?:(?:    .*|\s*)\n)*)", text + "\n")
    if match is None:
        return None
    return "\n".join(line for line in match.group(1).splitlines() if not line.lstrip().startswith("#"))


def job_field(block: str, field: str) -> str:
    match = re.search(rf"(?m)^    {field}:(.*(?:\n      .*)*)", block)
    return match.group(1) if match else ""


def pushes_branch(text: str) -> bool:
    """Whether a push to feat-cmux-next starts the workflow (an `on: push:` naming the branch, or naming none)."""
    on = re.search(r"(?ms)^on:[ \t]*\n(.*?)(?=^\S)", text + "\nend:\n")
    push = on and re.search(r"(?ms)^  push:[ \t]*\n((?:    .*\n|[ \t]*\n)*)", on.group(1))
    if not push:
        return False
    branches = re.search(r"(?ms)^    branches:(.*?)(?=^    \S|\Z)", push.group(1))
    return branches is None or BRANCH in branches.group(1)


# A repository path a workflow step or a script names: a top-level folder of the tree and what follows.
PATH_WORD = re.compile(r"(?<![\w/.$-])(?:\./)?([A-Za-z0-9_.][A-Za-z0-9_.-]*/[A-Za-z0-9_./*-]*[A-Za-z0-9_*])")
DOCSTRING_PARENTS = (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)


def python_reads(path: Path, rel: str, tree: Tree) -> tuple[set[str], set[str]]:
    """What a Python script reads by name: (its local imports, beside it or in scripts/ci or scripts/; its string
    literals that name a tracked path, docstrings aside)."""
    try:
        module = ast.parse(path.read_text(encoding="utf-8"))
    except (OSError, SyntaxError, UnicodeError):
        return set(), set()
    docstrings = set()
    for node in ast.walk(module):
        if isinstance(node, DOCSTRING_PARENTS) and node.body and isinstance(node.body[0], ast.Expr) \
                and isinstance(node.body[0].value, ast.Constant):
            docstrings.add(id(node.body[0].value))
    here = rel.rsplit("/", 1)[0] if "/" in rel else ""
    imports, literals = set(), set()
    for node in ast.walk(module):
        names = []
        if isinstance(node, ast.Import):
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
            names = [node.module]
        for name in names:
            stem = name.split(".")[0]
            for folder in (here, "scripts/ci", "scripts"):
                candidate = f"{folder}/{stem}.py" if folder else f"{stem}.py"
                if candidate in tree.files:
                    imports.add(candidate)
                    break
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in docstrings:
            value = node.value.strip()
            if "\n" in value or len(value) > 200:
                continue
            for word in [value, *PATH_WORD.findall(value)]:
                word = word[2:] if word.startswith("./") else word
                if "/" in word and tree.exists(word):
                    literals.add(word.rstrip("/") + ("/" if word.rstrip("/") in tree.dirs else ""))
    return imports, literals


def text_reads(text: str, tree: Tree) -> set[str]:
    reads = set()
    for word in PATH_WORD.findall(text):
        word = word[2:] if word.startswith("./") else word
        if "*" in word:
            continue
        if tree.exists(word):
            reads.add(word.rstrip("/") + ("/" if word.rstrip("/") in tree.dirs else ""))
    return reads


# How far a script named by another script's text (an argv, a path word) is opened. Imports are always followed. A
# path further away is recorded as read but not opened: a script that only names a path (in a message, or a table of
# other jobs' files) does not run it.
FOLLOW_DEPTH = 1
SCRIPT_SUFFIXES = (".py", ".sh")


def reads_of(block: str, root: Path, tree: Tree, skip: frozenset[str] = frozenset()) -> dict[str, str]:
    """Each path the job's steps reach (path -> the file that names it): the paths its steps name, and in each script
    it runs (FOLLOW_DEPTH steps of named scripts, any depth of Python imports) the paths that script names. A path in
    SKIP (the check's not_inputs) is not opened."""
    found: dict[str, str] = {}
    queue = [(p, "the workflow job", 0) for p in sorted(text_reads(block, tree))]
    seen = set()
    while queue:
        path, by, depth = queue.pop(0)
        found.setdefault(path, by)
        if path in seen or path.endswith("/") or not path.endswith(SCRIPT_SUFFIXES):
            continue
        seen.add(path)
        if path in skip:
            continue
        file = root / path
        if path.endswith(".py"):
            imports, named = python_reads(file, path, tree)
            queue.extend((n, path, depth) for n in sorted(imports) if n not in seen)
        else:
            try:
                named = text_reads("\n".join(line for line in file.read_text(encoding="utf-8").splitlines()
                                             if not line.lstrip().startswith("#")), tree)
            except (OSError, UnicodeError):
                named = set()
        for n in sorted(named):
            found.setdefault(n, path)
            if depth < FOLLOW_DEPTH and n not in seen:
                queue.append((n, path, depth + 1))
    return found


def check(root: Path = ROOT, files: list[str] | None = None) -> list[str]:
    data = load(root)
    tree = Tree(files if files is not None else tracked(root))
    problems = []
    texts: dict[str, str] = {}
    for workflow, job_id, spec in checks_of(data):
        where = f"{MAP} {workflow} {job_id}"
        if workflow not in texts:
            if not (root / workflow).is_file():
                problems.append(f"{where}: {workflow} does not exist")
                continue
            texts[workflow] = (root / workflow).read_text(encoding="utf-8")
        text = texts[workflow]
        for entry in spec.get("inputs", []):
            if not tree.any_match(entry):
                problems.append(f"{where}: input {entry} names no tracked path")
        for entry in spec.get("not_inputs", {}):
            if not tree.any_match(entry):
                problems.append(f"{where}: not_inputs {entry} names no tracked path")
        block = job_block(text, job_id)
        if block is None:
            problems.append(f"{where}: {workflow} has no job {job_id}")
            continue
        if ROUTE_JOB not in job_field(block, "needs"):
            problems.append(f"{where}: the job does not need {ROUTE_JOB}")
        if routed_if(job_id) not in job_field(block, "if"):
            problems.append(f"{where}: the job's `if:` does not read `{routed_if(job_id)}`")
        route_block = job_block(text, ROUTE_JOB)
        if route_block is None:
            problems.append(f"{where}: {workflow} has no {ROUTE_JOB} job")
        else:
            if f"{output_key(job_id)}: ${{{{ steps.route.outputs.{output_key(job_id)} }}}}" not in route_block:
                problems.append(f"{where}: {ROUTE_JOB} does not output {output_key(job_id)}")
            if job_field(route_block, "runs-on").strip() != ROUTE_RUNS_ON:
                problems.append(f"{where}: {ROUTE_JOB} runs on {job_field(route_block, 'runs-on').strip()!r}, "
                                f"not the 2-vCPU pool (ROUTE_RUNS_ON): the decision takes no heavy runner")
        covers = spec.get("push_cover")
        if covers is None and not pushes_branch(text):
            problems.append(f"{where}: no {BRANCH} push starts {workflow} and the check names no push_cover, so a "
                            f"pull request's skip would run it nowhere")
        for cover in covers or []:
            if not (root / cover).is_file() or not pushes_branch((root / cover).read_text(encoding="utf-8")):
                problems.append(f"{where}: push_cover {cover} is not a workflow a {BRANCH} push starts")
        inputs = [*spec.get("inputs", []), workflow]
        not_inputs = frozenset(spec.get("not_inputs", {}))
        if spec.get("router") == "guard_groups":
            # The guard groups' own reads are held by workflow_guard_groups' ownership and its tests; here only
            # what the job's steps name.
            reads = {p: "the workflow job" for p in text_reads(block, tree)}
        else:
            reads = reads_of(block, root, tree, not_inputs)
        for path, by in sorted(reads.items()):
            if path in not_inputs or (spec.get("generated") and generated_path(path, root)):
                continue
            if not any(covered(path, entry) or (path.endswith("/") and covered(path.rstrip("/"), entry))
                       for entry in inputs):
                problems.append(f"{where}: {by} reads {path}, which is not among its inputs: add it to the check's "
                                f"inputs (or to not_inputs with the reason)")
    return sorted(set(problems))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=ROOT)
    sub = parser.add_subparsers(dest="command", required=True)
    one = sub.add_parser("route")
    one.add_argument("--workflow", required=True)
    one.add_argument("--base", default="HEAD^1")
    one.add_argument("--head", default="HEAD")
    one.add_argument("--changed", type=Path, help="`git diff --name-status` output instead of --base/--head")
    one.add_argument("--event", default=os.environ.get("GITHUB_EVENT_NAME", "pull_request"))
    one.add_argument("--labels", default="", help="the pull request's labels, comma-separated")
    one.add_argument("--github-output", type=Path, default=os.environ.get("GITHUB_OUTPUT") or None)
    sub.add_parser("check")
    inputs = sub.add_parser("inputs")
    inputs.add_argument("--workflow", required=True)
    inputs.add_argument("--job", required=True)
    args = parser.parse_args(argv)
    root = args.repo

    if args.command == "check":
        problems = check(root)
        for problem in problems:
            print(f"::error::{problem}")
        print(f"fast_check_route check: {len(problems)} problem(s)")
        return 1 if problems else 0
    if args.command == "inputs":
        spec = load(root)["workflows"].get(args.workflow, {}).get(args.job)
        if spec is None:
            raise SystemExit(f"fast_check_route: {MAP} lists no job {args.job} of {args.workflow}")
        print("\n".join([args.workflow, *spec.get("inputs", [])]))
        return 0

    labels = [label.strip() for label in args.labels.split(",") if label.strip()]
    if args.event != "pull_request":
        changed = []
    elif args.changed:
        try:
            changed = [tuple(line.split("\t", 1)) for line in args.changed.read_text(encoding="utf-8").splitlines()
                       if "\t" in line]
        except (OSError, UnicodeError):
            changed = None
    else:
        changed = changed_paths(root, args.base, args.head)
    result = route(args.workflow, changed, event=args.event, labels=labels, root=root)
    lines = [f"{job_id}={'true' if run else 'false'}  {why}" for job_id, (run, why) in sorted(result.items())]
    print("\n".join(lines))
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as out:
            out.write("".join(f"{output_key(job_id)}={'true' if run else 'false'}\n"
                              for job_id, (run, _) in sorted(result.items())))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as out:
            out.write("### Fast checks this change runs (scripts/ci/fast_check_route.py)\n\n")
            out.write("".join(f"- {line}\n" for line in lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
