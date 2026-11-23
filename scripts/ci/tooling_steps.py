#!/usr/bin/env python3
"""Which steps of a test job a pull request's diff can fail, and so which ones it runs.

Leo, 2026-11-19: "only meaningful tests ... not just there for ticky tack". cmux-next guards / tooling-tests ran
about 50 script test suites on every pull request whatever it changed: a webviews/-only change ran the App Store
listing, Mach-O thinning and iOS simulator runtime tests, which read none of its files. tooling-tests' own setup-tooling-route step runs this on
the merge commit's diff, and each selectable step of the job runs only when this selects it.

A step runs when a changed file is an input of a test its run text runs (the test itself and what it imports,
sources, runs or reads, transitively: workflow_paths_cover_inputs.Walker, the walker the path-filter coverage check
uses), a file the run text itself names (its own script, and that script's inputs), a file matching a glob a file
of that closure lists, a file below a directory one of them names by a path, or a file whose path or name one of
them spells out. It fails open and never trades a test for speed. Every step runs when the event is not
pull_request, the changed-file list is missing or empty, or one of these changed: the workflow file, this router,
workflow_paths_cover_inputs.py, gh_expressions.py, a local action the job uses or a repository file the workflow's
or job's env names (BASH_ENV). A step always runs when its run text names no test the walker can resolve, when any
file of its closure has an input the walker could not resolve (`Walker.unknown`: an import of no repository module
other than PyYAML, pytest or Pillow, a `source` it cannot follow) or runs a command from a variable (`bash "$t"`;
the script's own "$@" is its caller's, which is in the closure), when a `${{ }}` stands where its command or
script is, or when its working directory is not literal. Steps with no `run:`
(checkout, Bun, Rust and Python setup, caches) and run steps whose id starts with `setup-` always run and are not
selectable.

Outputs (`--github-output`): `tooling_steps= tt-a tt-b ` (selected step ids, space-padded, so a workflow tests
`contains(..., ' tt-a ')`) and `tooling_all=true|false`. A workflow step tests both, and an empty `tooling_all` (the
routing step did not run or failed) is != 'false', so it runs everything. `--summary` writes the verdict and one line
per skipped step with why.

    python3 tooling_steps.py route --workflow .github/workflows/cmux-next-guards.yml --job tooling-tests \\
        --changed-files FILE --event EVENT [--github-output F] [--summary F] [--root DIR] [--json]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gh_expressions  # noqa: E402
from workflow_paths_cover_inputs import (  # noqa: E402
    INTERPRETERS, Repo, Walker, glob_regex, is_test, literal_env, load_yaml, mapping, python_facts, run_targets,
    shell_words,
)

ROUTER_FILES = ("scripts/ci/tooling_steps.py", "scripts/ci/workflow_paths_cover_inputs.py",
                "scripts/ci/gh_expressions.py")
SETUP_ID = "setup-"
# Imports no repository file can satisfy: what the job pip-installs (PyYAML, pytest) and Pillow. Any other import the
# walker cannot resolve may be a repository module it missed, so the step runs.
THIRD_PARTY = {"yaml", "pytest", "_pytest", "xdist", "PIL"}
EXPR = "$__EXPR"
POSITIONAL = re.compile(r"\$(?:[@*0-9]|\{(?:[@*0-9]|[0-9]+)\})")
# `git ls-files` with no pathspec, in a Python argument list (`["git", "-C", root, "ls-files", "-z"]`) or a shell
# command (`git ls-files | grep`): the whole tracked tree is an input.
WHOLE_TREE_LIST = re.compile(r"""["']ls-files["']\s*(?:,\s*["']-[\w=-]+["']\s*)*[\])]"""
                             r"""|\bgit(?:\s+-C\s+\S+)?\s+ls-files(?:\s+-[\w=-]+)*\s*(?:$|[|;&)>])""", re.M)
WORKSPACE_PATH = re.compile(r"^\$\{?GITHUB_WORKSPACE(?::-[^}]*)?\}?/(.+)$")
# The same path inside a longer value: the API call log's BASH_ENV is one $( ) that echoes the checkout's file.
WORKSPACE_PATH_IN = re.compile(r"\$\{?GITHUB_WORKSPACE(?::-[^}]*)?\}?/([^\s\"';)]+)")


@dataclass
class StepVerdict:
    key: str
    name: str
    run: bool
    reason: str


@dataclass
class Decision:
    all: bool
    reason: str
    steps: list[StepVerdict] = field(default_factory=list)

    @property
    def selected(self) -> list[str]:
        return [s.key for s in self.steps if s.run]

    @property
    def skipped(self) -> list[StepVerdict]:
        return [s for s in self.steps if not s.run]


def selectable(step) -> bool:
    """A run step that is not setup: it carries the selection condition and an id."""
    return isinstance(step, dict) and "run" in step and not str(step.get("id") or "").startswith(SETUP_ID)


def env_files(repo: Repo, *envs) -> list[str]:
    """Repository files an env block names by path (BASH_ENV=${GITHUB_WORKSPACE}/scripts/...): every bash step reads
    them, so a change to one runs everything."""
    out = []
    for env in envs:
        for value in mapping(env).values():
            text = str(value).strip()
            match = WORKSPACE_PATH.match(text) or WORKSPACE_PATH_IN.search(text)
            rel = match.group(1) if match else text
            if repo.is_file(rel):
                out.append(rel)
    return out


def named_files(walker: Walker, run: str, cwd: str, env: dict[str, str]) -> tuple[list[str], bool]:
    """(tracked files the run text runs or names as a command's script, whether a `${{ }}` stands in a command or
    script position)."""
    hidden, out = False, []
    for words in shell_words(run, None, {"GITHUB_WORKSPACE": str(walker.repo.root), **env}, []):
        targets = run_targets(words)
        if any(EXPR in w for w in targets):
            hidden = True
        for target in targets:
            out.extend(walker.word_paths(target, cwd))
        out.extend(walker.command_entries(words, cwd))
        for word in words:  # any file a command names: `python3 -m unittest tests/a.py`, `pytest tests/b.py`
            out.extend(walker.word_paths(word, cwd))
    return list(dict.fromkeys(out)), hidden


def is_code(repo: Repo, walker: Walker, rel: str) -> bool:
    return rel.endswith((".py", ".sh", ".bash", ".go")) or walker.shebang(rel) in ("python", "shell")


@dataclass
class Reach:
    """What a code file reaches beyond Walker.closure's files: globs it lists (`Walker.unknown`'s `lists P`),
    directories it names, and what it reads that nobody can resolve."""
    globs: list[str] = field(default_factory=list)
    dirs: list[str] = field(default_factory=list)
    unknown: list[str] = field(default_factory=list)


def reach_of(repo: Repo, walker: Walker, rel: str) -> Reach:
    """A file of a closure, read once more for what Walker.closure records as unknown or leaves out because it only
    misses a path-filter gap (never a reason to skip a test here): a Python path built from `__file__` that is a
    directory (an os.walk, iterdir or `git ls-files DIR` reads any file below it), a shell word naming a directory,
    and a shell command run from a variable (`bash "$t"` in a `for t in DIR/*` loop)."""
    reach = Reach()
    for what in sorted(walker.unknown.get(rel, ())):
        if what.startswith("lists "):
            reach.globs.append(what[len("lists "):])
        elif what.split(".")[0] not in THIRD_PARTY:
            reach.unknown.append(what)
    if rel.endswith(".py") or walker.shebang(rel) == "python":
        facts = python_facts(repo.abs(rel))
        for path in facts.paths if facts else []:
            directory = repo.rel(path)
            if directory and repo.is_dir(directory):
                reach.dirs.append(directory)
    elif rel.endswith((".sh", ".bash")) or walker.shebang(rel) == "shell":
        try:
            text = Path(repo.abs(rel)).read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            text = ""
        script_dir = os.path.dirname(repo.abs(rel))
        for words in shell_words(text, script_dir, {"GITHUB_WORKSPACE": str(repo.root)}, []):
            # What a command runs, and the word after an interpreter anywhere in it (`timeout 600 bash "$t"`): one
            # left with a variable may run any file. The script's own arguments ("$@", $1) run what its caller
            # names, and the caller is in the closure.
            targets = list(run_targets(words))
            for index, word in enumerate(words[:-1]):
                if word in ("source", ".", "exec") or INTERPRETERS.match(word.rsplit("/", 1)[-1]):
                    rest = [w for w in words[index + 1:] if not w.startswith("-")]
                    targets.extend(rest[:1])
            for target in targets:
                if ("$" in target or "`" in target) and not POSITIONAL.fullmatch(target):
                    reach.unknown.append(f"runs {target}")
            for word in words:
                if "$" in word or word.startswith("-"):
                    continue
                for base in (str(repo.root), script_dir):
                    directory = repo.rel(os.path.normpath(os.path.join(base, word)))
                    if directory and repo.is_dir(directory):
                        reach.dirs.append(directory)
    return reach


def read_text(repo: Repo, rel: str) -> str:
    """A file's text, or "" for a directory, a binary file or one that is gone."""
    try:
        data = Path(repo.abs(rel)).read_bytes()
    except OSError:
        return ""
    return "" if b"\0" in data[:8192] else data.decode("utf-8", errors="replace")


def judge_step(repo: Repo, walker: Walker, step: dict, env: dict[str, str], workdir: str,
               changed: set[str]) -> tuple[bool, str]:
    """(run, reason) for one selectable step."""
    workdir = str(step.get("working-directory") or workdir)
    if "$" in workdir:
        return True, f"working directory {workdir} is not literal"
    cwd = repo.abs(os.path.normpath(workdir)) if workdir and workdir != "." else str(repo.root)
    try:
        run = gh_expressions.EXPRESSION.sub(EXPR, str(step["run"]))
    except gh_expressions.Unterminated:
        return True, "a ${{ in its run text never ends"
    env = {**env, **literal_env(step.get("env"))}
    named, hidden = named_files(walker, run, cwd, env)
    if hidden:
        return True, "a ${{ }} stands where its command or script is"
    tests = list(dict.fromkeys([*walker.entries(run, cwd, env), *(p for p in named if is_test(p))]))
    if not tests:
        return True, "its run text names no test the walker resolves"
    roots = list(dict.fromkeys([*tests, *(p for p in named if is_code(repo, walker, p))]))
    inputs: set[str] = set(named)
    for root in roots:
        inputs.update(str(p) for p in walker.closure(root, cwd))
    code = sorted(p for p in inputs if is_code(repo, walker, p))
    reaches = {p: reach_of(repo, walker, p) for p in code}
    unknown = [(p, r.unknown) for p, r in reaches.items() if r.unknown]
    if unknown:
        what = "; ".join(f"{p}: {', '.join(u[:3])}" for p, u in unknown[:3])
        return True, f"unresolved inputs ({what})"
    hit = sorted(changed & inputs)
    if hit:
        return True, f"reads {hit[0]}" + (f" and {len(hit) - 1} more" if len(hit) > 1 else "")
    for path, reach in reaches.items():
        for pattern in reach.globs:
            regex = glob_regex(pattern)
            for name in sorted(changed):
                if regex.match(name):
                    return True, f"{path} lists {pattern}, which matches {name}"
        for directory in reach.dirs:
            for name in sorted(changed):
                if name.startswith(directory + "/"):
                    return True, f"{path} reads directory {directory}, which holds {name}"
    # A code file that lists every tracked file (`git ls-files` with no pathspec) can fail on any added, deleted or
    # renamed file: tests/test_check_paths.py checks each pattern of scripts/ci/check-paths.txt still matches one.
    for path in code:
        if WHOLE_TREE_LIST.search(read_text(repo, path)):
            return True, f"{path} lists every tracked file"
    # A path the walker does not follow: a changed file any input of the closure spells out by path or file name,
    # a data file (scripts/ci/check-paths.txt naming a script) as much as code.
    for path in sorted(inputs):
        text = read_text(repo, path)
        for name in sorted(changed):
            if name in text or name.rsplit("/", 1)[-1] in text:
                return True, f"{path} names {name.rsplit('/', 1)[-1]}"
    return False, f"none of its {len(inputs)} inputs changed ({', '.join(tests[:2])}{' ...' if len(tests) > 2 else ''})"


def route(root: Path, workflow: str, job_name: str, changed: list[str] | None, event: str) -> Decision:
    repo = Repo.load(root)
    document = load_yaml(repo.root / workflow)
    job = mapping(mapping(document.get("jobs")).get(job_name))
    steps = [s for s in job.get("steps") or [] if selectable(s)]
    keys = [str(s.get("id") or "") for s in steps]

    def everything(reason: str) -> Decision:
        return Decision(True, reason, [StepVerdict(k, str(s.get("name") or k), True, reason)
                                       for k, s in zip(keys, steps) if k])

    if event != "pull_request":
        return everything(f"event {event} is not pull_request")
    if not changed:
        return everything("no changed-file list")
    changed_set = set(changed)
    triggers = {workflow, *ROUTER_FILES}
    for step in job.get("steps") or []:
        uses = str(mapping(step).get("uses") or "")
        if uses.startswith("./"):
            triggers.update(p for p in repo.tracked if p.startswith(uses[2:].rstrip("/") + "/"))
    triggers.update(env_files(repo, document.get("env"), job.get("env")))
    hit = sorted(changed_set & triggers)
    if hit:
        return everything(f"{hit[0]} changed")
    env = {**literal_env(document.get("env")), **literal_env(job.get("env"))}
    workdir = str(mapping(mapping(job.get("defaults")).get("run")).get("working-directory")
                  or mapping(mapping(document.get("defaults")).get("run")).get("working-directory") or "")
    walker = Walker(repo)
    verdicts = []
    for key, step in zip(keys, steps):
        name = str(step.get("name") or key)
        if not key:
            verdicts.append(StepVerdict(key, name, True, "no id: it carries no selection and always runs"))
            continue
        run, reason = judge_step(repo, walker, step, env, workdir, changed_set)
        verdicts.append(StepVerdict(key, name, run, reason))
    return Decision(False, f"{len(changed_set)} changed file(s)", verdicts)


def write_outputs(decision: Decision, github_output: Path | None, summary: Path | None, job: str) -> None:
    selected = " ".join(k for k in decision.selected if k)
    if github_output:
        with github_output.open("a", encoding="utf-8") as stream:
            stream.write(f"tooling_steps= {selected} \n")
            stream.write(f"tooling_all={'true' if decision.all else 'false'}\n")
    if summary:
        lines = [f"### {job}: step selection", ""]
        if decision.all:
            lines.append(f"Every step runs: {decision.reason}.")
        else:
            lines.append(f"{len(decision.selected)} of {len(decision.steps)} steps run ({decision.reason}).")
            if decision.skipped:
                lines += ["", "Skipped:"]
                lines += [f"- `{s.key}` {s.name}: {s.reason}" for s in decision.skipped]
        with summary.open("a", encoding="utf-8") as stream:
            stream.write("\n".join(lines) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    cmd = sub.add_parser("route")
    cmd.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    cmd.add_argument("--workflow", required=True)
    cmd.add_argument("--job", required=True)
    cmd.add_argument("--changed-files", type=Path)
    cmd.add_argument("--event", required=True)
    cmd.add_argument("--github-output", type=Path)
    cmd.add_argument("--summary", type=Path)
    cmd.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    changed = None
    if args.changed_files and args.changed_files.is_file():
        changed = [line.strip() for line in args.changed_files.read_text(encoding="utf-8").splitlines()
                   if line.strip()]
    decision = route(Path(args.root), args.workflow, args.job, changed, args.event)
    write_outputs(decision, args.github_output, args.summary, args.job)
    if args.json:
        print(json.dumps({"all": decision.all, "reason": decision.reason,
                          "steps": [s.__dict__ for s in decision.steps]}, indent=1))
    else:
        verdict = "all" if decision.all else f"{len(decision.selected)}/{len(decision.steps)}"
        print(f"{args.job}: {verdict} steps run ({decision.reason})")
        for s in decision.steps:
            print(f"  {'run ' if s.run else 'skip'} {s.key or '(no id)'}: {s.reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
