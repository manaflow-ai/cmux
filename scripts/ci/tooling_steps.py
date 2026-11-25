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
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gh_expressions  # noqa: E402
from workflow_paths_cover_inputs import (  # noqa: E402
    INTERPRETERS, Repo, Walker, declared_runs, glob_regex, is_test, literal_env, load_yaml, mapping, python_facts,
    rooted_run, run_targets, shell_words,
)

# Declared inputs for steps whose run text the walker cannot read whole (a shell `runs $t` loop, a run text that names
# no test file): scripts/ci/tooling-step-inputs.json. A change to it runs every step, as a change to this router does.
DECLARED = "scripts/ci/tooling-step-inputs.json"
ROUTER_FILES = ("scripts/ci/tooling_steps.py", "scripts/ci/workflow_paths_cover_inputs.py",
                "scripts/ci/gh_expressions.py", DECLARED)
SETUP_ID = "setup-"
# Imports no repository file can satisfy: what the job pip-installs (PyYAML, pytest) and Pillow. Any other import the
# walker cannot resolve may be a repository module it missed, so the step runs.
THIRD_PARTY = {"yaml", "pytest", "_pytest", "xdist", "PIL"}
EXPR = "$__EXPR"
POSITIONAL = re.compile(r"\$(?:[@*0-9]|\{(?:[@*0-9]|[0-9]+|@:[0-9]+(?::[0-9]+)?)\})")
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
    try:
        own_text = Path(repo.abs(rel)).read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        own_text = ""
    declared = declared_runs(repo, own_text) is not None
    shell = rel.endswith((".sh", ".bash")) or walker.shebang(rel) == "shell"
    here = rel.rpartition("/")[0]
    for what in sorted(walker.unknown.get(rel, ())):
        if what.startswith("runs ") and (declared or (shell and here)):
            continue  # declared, or read below as reaching the script's own directory
        if what.startswith("source $") and shell and here:
            reach.dirs.append(here)  # a library found by a computed name, as a command run from a variable
            continue
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
                    if words[index + 1] in ("-c", "-e", "-E", "-m", "-s"):  # a module, a program in the argument or on stdin
                        continue
                    rest = [w for w in words[index + 1:] if not w.startswith("-")]
                    targets.extend(rest[:1])
            for target in targets:
                if "\n" in target:  # a quoted string over several lines is text, not a path
                    continue
                if declared or rooted_run(repo, target):
                    continue
                if ("$" in target or "`" in target) and not POSITIONAL.fullmatch(target):
                    # A command from a variable runs a system tool or a file the script finds by a computed name,
                    # in practice a sibling (`"$dir/$name.sh"`, `bash "$t"` over `$tests/*`): it reaches the
                    # script's own directory. A script that runs files elsewhere declares them
                    # (`# tooling-steps runs:`); a script at the repository root stays unresolved.
                    if here:
                        reach.dirs.append(here)
                    else:
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


def load_declared(root: Path, workflow: str, job: str) -> dict[str, list[str]]:
    """{step id: input globs} for WORKFLOW's JOB from DECLARED. A missing, unreadable or malformed file declares
    nothing: every step it would have narrowed runs, as before (fails open)."""
    try:
        doc = json.loads((Path(root) / DECLARED).read_text(encoding="utf-8"))
        steps = doc[workflow][job]
        out = {}
        for key, entry in steps.items():
            inputs = entry["inputs"]
            if not isinstance(inputs, list) or not inputs or not all(isinstance(g, str) and g for g in inputs):
                return {}
            if not isinstance(entry.get("why"), str) or not entry["why"].strip():
                return {}
            out[str(key)] = list(inputs)
        return out
    except (OSError, UnicodeError, ValueError, KeyError, TypeError, AttributeError):
        return {}


def load_traced(root: Path, workflow: str, job: str) -> set[str]:
    """Step ids whose DECLARED entry says `"traced": true`: its globs and the inputs the walker resolved are every path
    a traced run of it read (`verify` checks that), so they alone decide it. The walker's guesses past them (a folder
    a script names, a whole-tree list, a file name spelled out) are what the trace settled, and are not consulted.
    Only steps load_declared accepts count; anything malformed traces nothing (fails open)."""
    declared = load_declared(root, workflow, job)
    try:
        steps = json.loads((Path(root) / DECLARED).read_text(encoding="utf-8"))[workflow][job]
        return {str(k) for k, e in steps.items() if str(k) in declared and e.get("traced") is True}
    except (OSError, UnicodeError, ValueError, KeyError, TypeError, AttributeError):
        return set()


def declared_hit(declared: list[str], changed: set[str]) -> tuple[str, str] | None:
    """(changed path, glob) for the first changed path a declared input glob matches."""
    regexes = [(g, glob_regex(g)) for g in declared]
    for name in sorted(changed):
        for pattern, regex in regexes:
            if regex.match(name):
                return name, pattern
    return None


def judge_step(repo: Repo, walker: Walker, step: dict, env: dict[str, str], workdir: str,
               changed: set[str], declared: list[str] | None = None,
               added_deleted: set[str] | None = None, traced: bool = False) -> tuple[bool, str]:
    """(run, reason) for one selectable step. DECLARED (its tooling-step-inputs.json globs) stands in for what the
    walker cannot resolve: with it, a step whose run text names no test or whose closure runs a file from a variable
    runs when a changed path matches a declared glob or any input the walker did resolve, and is skipped otherwise.
    Every other check (named files, listed globs, read directories, whole-tree lists, spelled-out names) still runs."""
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
    unresolved = ""
    if not tests:
        if not declared:
            return True, "its run text names no test the walker resolves"
        unresolved = "its run text names no test the walker resolves"
    roots = list(dict.fromkeys([*tests, *(p for p in named if is_code(repo, walker, p))]))
    inputs: set[str] = set(named)
    for root in roots:
        inputs.update(str(p) for p in walker.closure(root, cwd))
    code = sorted(p for p in inputs if is_code(repo, walker, p))
    reaches = {p: reach_of(repo, walker, p) for p in code}
    unknown = [(p, r.unknown) for p, r in reaches.items() if r.unknown]
    if unknown:
        what = "; ".join(f"{p}: {', '.join(u[:3])}" for p, u in unknown[:3])
        if not declared:
            return True, f"unresolved inputs ({what})"
        unresolved = unresolved or f"unresolved inputs ({what})"
    if declared:
        found = declared_hit(declared, changed)
        if found:
            return True, f"{found[0]} matches its declared input {found[1]} ({DECLARED})"
    hit = sorted(changed & inputs)
    if hit:
        return True, f"reads {hit[0]}" + (f" and {len(hit) - 1} more" if len(hit) > 1 else "")
    if traced and declared:
        return False, (f"none of its traced inputs changed (its declared globs {', '.join(declared[:3])}"
                       f"{' ...' if len(declared) > 3 else ''} and {len(inputs)} resolved files; {DECLARED}, traced)")
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
    # A diff that only edits files leaves that list as it was, so the rule needs the added and deleted files
    # (renames are an add and a delete under --no-renames); with no such list it holds for every diff.
    if added_deleted is None or added_deleted:
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
    if unresolved:
        return False, (f"none of its declared inputs ({', '.join(declared[:3])}{' ...' if len(declared) > 3 else ''}; "
                       f"{DECLARED}) nor its {len(inputs)} resolved inputs changed; declared because {unresolved}")
    return False, f"none of its {len(inputs)} inputs changed ({', '.join(tests[:2])}{' ...' if len(tests) > 2 else ''})"


def route(root: Path, workflow: str, job_name: str, changed: list[str] | None, event: str,
          added_deleted: list[str] | None = None) -> Decision:
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
    declared = load_declared(repo.root, workflow, job_name)
    traced = load_traced(repo.root, workflow, job_name)
    verdicts = []
    for key, step in zip(keys, steps):
        name = str(step.get("name") or key)
        if not key:
            verdicts.append(StepVerdict(key, name, True, "no id: it carries no selection and always runs"))
            continue
        run, reason = judge_step(repo, walker, step, env, workdir, changed_set, declared.get(key),
                                 None if added_deleted is None else set(added_deleted), key in traced)
        verdicts.append(StepVerdict(key, name, run, reason))
    return Decision(False, f"{len(changed_set)} changed file(s)", verdicts)


STRACE_CALL = re.compile(r'^(\d+)\s+(?:<\.\.\. )?(\w+)\((.*)\)\s+=\s+(-?\d+(?: \w+)?|\?)')
# `strace -y` prints a dirfd with its path (`openat(5</tmp/x>, "a", ...)`): a relative path is read from there.
DIRFD = re.compile(r'^\d+(?:<([^>]*)>)?,')
STRACE_PATH = re.compile(r'"((?:[^"\\]|\\.)*)"')
PATH_CALLS = {"open", "openat", "openat2", "stat", "lstat", "newfstatat", "statx", "access", "faccessat", "faccessat2",
              "execve", "readlink", "readlinkat"}
FORKS = {"clone", "clone3", "fork", "vfork"}
# A git command run inside the checkout that reads the tree, the index or history: no glob list can stand for it.
GLOB_CHARS = re.compile(r"[*?\[]")
GIT_TREE_READS = {"ls-files", "ls-tree", "grep", "log", "diff", "show", "blame", "rev-list", "cat-file", "archive",
                  "status", "diff-index", "diff-tree", "stash"}


@dataclass
class Trace:
    files: set[str] = field(default_factory=set)  # tracked files the step opened, stat'ed or ran
    dirs: set[str] = field(default_factory=set)  # checkout folders it opened (a listing reads any file below)
    git: list[str] = field(default_factory=list)  # git tree reads it ran inside the checkout
    probes: set[str] = field(default_factory=set)  # checkout paths it looked for and did not find
    exit: int = 0


def git_tree_read(repo: Repo, cwd: str, argv: list[str]) -> str:
    """Why a git command (argv after the program) reads the checkout's tree, index or history, or "" when it runs in
    another repository or reads none of those. `ls-files -- A B` names its pathspecs as `ls-files A/ B/` so verify can
    ask whether the step's inputs cover them; any other tree read is reported whole."""
    words, where = list(argv), cwd
    while words and words[0].startswith("-"):
        flag = words.pop(0)
        if flag == "-C" and words:
            where = os.path.normpath(os.path.join(where, words.pop(0)))
        elif flag in ("--git-dir", "--work-tree", "-c") and words:
            if flag != "-c":
                return ""  # another repository's git dir: a fixture's, judged by where it points
            words.pop(0)
        elif flag.startswith(("--git-dir=", "--work-tree=")):
            return ""
    if repo.rel(where) is None or not words or words[0] not in GIT_TREE_READS:
        return ""
    sub, rest = words[0], words[1:]
    if sub == "ls-files":
        specs = [w for w in rest if not w.startswith("-")]
        if specs and not any(GLOB_CHARS.search(w) for w in specs):
            base = repo.rel(where) or ""
            return "ls-files " + " ".join(os.path.normpath(os.path.join(base, w)) + "/" for w in specs)
    return f"{' '.join(words[:5])} (in {repo.rel(where) or '.'})"


def trace_step(repo: Repo, run: str, env: dict[str, str], timeout: int = 900) -> Trace:
    """Run a step's run text under strace -f from the checkout root and collect every checkout path it touched."""
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "trace")
        cmd = ["strace", "-f", "-y", "-qq", "-s", "4096", "-o", out,
               "-e", "trace=" + ",".join(sorted(PATH_CALLS | FORKS | {"chdir", "fchdir"})),
               "bash", "-eo", "pipefail", "-c", run]
        full_env = {**os.environ, "GITHUB_WORKSPACE": str(repo.root), "GITHUB_EVENT_NAME": "pull_request", **env}
        full_env.pop("BASH_ENV", None)
        try:
            done = subprocess.run(cmd, cwd=repo.root, env=full_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  timeout=timeout, check=False)
            code = done.returncode
        except subprocess.TimeoutExpired:
            code = 124
        lines = Path(out).read_text(encoding="utf-8", errors="replace").splitlines() if os.path.exists(out) else []
    trace = parse_trace(repo, lines)
    trace.exit = code
    return trace


def parse_trace(repo: Repo, lines: list[str]) -> Trace:
    """What an `strace -f` log touched in the checkout. Each process's calls are read in its own order, and a child
    starts in the folder its parent was in when its clone returned (strace may print the child's first calls before
    that line, so the log is not read top to bottom). A process whose start is never seen is read from the root."""
    calls: dict[str, list[tuple[str, str, str]]] = {}
    pending: dict[str, str] = {}
    first = None
    for raw in lines:
        head = raw.split(None, 1)
        if len(head) != 2:
            continue
        pid, rest = head
        if rest.endswith("<unfinished ...>"):
            pending[pid] = rest[: -len("<unfinished ...>")]
            continue
        if rest.startswith("<... ") and pid in pending:
            end = rest.find(" resumed>")
            rest = pending.pop(pid) + (rest[end + len(" resumed>"):] if end > 0 else "")
        match = STRACE_CALL.match(pid + " " + rest)
        if not match:
            continue
        first = first or pid
        calls.setdefault(pid, []).append(match.groups()[1:])
    trace, root = Trace(), str(repo.root)
    todo, seen = [(first, root)] if first else [], set()
    while todo or len(seen) < len(calls):
        if not todo:  # a process whose clone line was never seen: read it from the root
            todo.append((next(p for p in calls if p not in seen), root))
        pid, cwd = todo.pop()
        if pid in seen:
            continue
        seen.add(pid)
        for call, args, result in calls.get(pid, ()):
            if call in FORKS:
                if result.isdigit():
                    todo.append((result, cwd))
                continue
            if result == "?":
                continue
            paths = STRACE_PATH.findall(args)
            if result.startswith("-") and call in ("chdir", "fchdir", "execve"):
                continue
            if call == "chdir" and paths:
                cwd = os.path.normpath(os.path.join(cwd, paths[0]))
                continue
            if call == "fchdir" or not paths:
                continue
            if call == "execve" and os.path.basename(paths[0]) == "git" and not result.startswith("-"):
                read = git_tree_read(repo, cwd, paths[2:])  # paths: the program, argv[0], then its arguments
                if read:
                    trace.git.append(read)
            if not paths[0]:
                continue  # an fstat of an open fd (AT_EMPTY_PATH): its open was read already
            dirfd = DIRFD.match(args)
            if dirfd and not dirfd.group(1) and not paths[0].startswith("/"):
                continue  # relative to an fd whose folder strace did not print: not a read of the checkout
            base = dirfd.group(1) if dirfd and dirfd.group(1) else cwd
            rel = repo.rel(os.path.normpath(os.path.join(base, paths[0])))
            if not rel or rel == ".git" or rel.startswith(".git/"):
                continue
            if result.startswith("-"):
                # A probe of a path that is not there (an exists() check, an import search): adding a file there
                # can change the step. A folder the step lists already covers its own children.
                if call in ("stat", "lstat", "newfstatat", "statx", "access", "faccessat", "faccessat2", "open",
                            "openat", "openat2") and result.endswith("ENOENT"):
                    if "/" in rel:  # a bare name at the root is a PATH search with a relative entry, not a read
                        trace.probes.add(rel)
                continue
            if rel in repo.tracked:
                trace.files.add(rel)
            elif repo.is_dir(rel) and call in ("open", "openat", "openat2") and "O_DIRECTORY" in args:
                trace.dirs.add(rel)
    return trace


def verify(root: Path, workflow: str, job_name: str, only: list[str] | None = None) -> list[str]:
    """Problems: for each step with declared inputs (or ONLY), what its traced run touched that neither its declared
    globs nor the inputs the walker resolved for it cover. Empty when every read is covered."""
    repo = Repo.load(root)
    document = load_yaml(repo.root / workflow)
    job = mapping(mapping(document.get("jobs")).get(job_name))
    declared = load_declared(repo.root, workflow, job_name)
    traced = load_traced(repo.root, workflow, job_name)
    env = {**literal_env(document.get("env")), **literal_env(job.get("env"))}
    env.pop("BASH_ENV", None)
    walker = Walker(repo)
    problems = []
    for step in job.get("steps") or []:
        key = str(mapping(step).get("id") or "")
        if key not in declared or (only and key not in only):
            continue
        run = str(step["run"])
        if "${{" in run:
            problems.append(f"{key}: its run text has a ${{{{ }}}} expression; it cannot be traced as written")
            continue
        globs = declared[key]
        trace = trace_step(repo, run, {**env, **literal_env(step.get("env"))})
        # Covered means the router would run the step for a change to that path alone: a declared glob matches it, or
        # the walker resolved it (judge_step with the path as the whole change).
        for path in sorted(trace.files):
            if declared_hit(globs, {path}):
                continue
            ran, _ = judge_step(repo, walker, step, env, "", {path}, globs, traced=key in traced)
            if not ran:
                problems.append(f"{key}: read {path}, outside its declared inputs and its resolved inputs")
        for folder in sorted(trace.dirs):
            if any(f.endswith(".py") and f.rsplit("/", 1)[0] == folder for f in trace.files):
                continue  # Python lists a folder on sys.path when it imports a module from it: the module's read counts
            probe = folder + "/__tooling_steps_probe__"
            if not declared_hit(globs, {probe}):
                ran, _ = judge_step(repo, walker, step, env, "", {probe}, globs, traced=key in traced)
                if not ran:
                    problems.append(f"{key}: listed folder {folder}/, which its declared inputs do not cover")
        ignored = set(subprocess.run(["git", "-C", str(repo.root), "check-ignore", "--stdin"], input="\n".join(
            sorted(trace.probes)), capture_output=True, text=True).stdout.split()) if trace.probes else set()
        for path in sorted(trace.probes - ignored):  # a git-ignored path (.build/) is no pull request's change
            if not declared_hit(globs, {path}) and not any(path.startswith(d + "/") for d in trace.dirs) \
                    and not judge_step(repo, walker, step, env, "", {path}, globs, traced=key in traced)[0]:
                problems.append(f"{key}: looked for {path} (not there), outside its declared inputs")
        for read in sorted(set(trace.git)):
            if read.startswith("ls-files ") and "(in " not in read:
                for folder in read.split()[1:]:
                    if not declared_hit(globs, {folder + "__tooling_steps_probe__"}):
                        problems.append(f"{key}: `git ls-files` lists {folder}, which its declared inputs do not cover")
            else:
                problems.append(f"{key}: ran `git {read}` on the checkout (a tree read no glob covers)")
        if trace.exit != 0:
            problems.append(f"{key}: exited {trace.exit} under the trace; its reads may be incomplete")
        print(f"{key}: traced {len(trace.files)} files, {len(trace.dirs)} folders, exit {trace.exit}", file=sys.stderr)
    return problems


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
    cmd.add_argument("--added-deleted", type=Path,
                     help="the diff's added and deleted files (git diff --no-renames --diff-filter=AD); "
                          "given, a step that lists every tracked file runs only when this list is non-empty")
    cmd.add_argument("--event", required=True)
    cmd.add_argument("--github-output", type=Path)
    cmd.add_argument("--summary", type=Path)
    cmd.add_argument("--json", action="store_true")
    ver = sub.add_parser("verify", help="trace each declared step (strace -f) and fail on a read its inputs miss")
    ver.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    ver.add_argument("--workflow", required=True)
    ver.add_argument("--job", required=True)
    ver.add_argument("--step", action="append")
    args = parser.parse_args(argv)
    if args.command == "verify":
        problems = verify(Path(args.root), args.workflow, args.job, args.step)
        for problem in problems:
            print(problem)
        return 1 if problems else 0
    changed = None
    if args.changed_files and args.changed_files.is_file():
        changed = [line.strip() for line in args.changed_files.read_text(encoding="utf-8").splitlines()
                   if line.strip()]
    added_deleted = None
    if args.added_deleted and args.added_deleted.is_file():
        added_deleted = [line.strip() for line in args.added_deleted.read_text(encoding="utf-8").splitlines()
                         if line.strip()]
    decision = route(Path(args.root), args.workflow, args.job, changed, args.event, added_deleted)
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
