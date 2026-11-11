#!/usr/bin/env python3
"""Every file a path-filtered workflow's tests read starts that workflow.

A workflow with `paths:` or `paths-ignore:` on `pull_request` or `push` runs only for the files its filter admits. A
test it runs that reads a file outside the filter (an import from a sibling tool, a sourced shell library, a fixture
it opens by a path built from `__file__`) misses every change to that file: the PR that breaks it merges green and
the next PR that touches a listed path inherits the red (2026-11-10: a suite imported a sibling tool's module that
its workflow did not list, and two PRs broke it unseen).

For each filtered event this reads the steps that event can run (a step or job whose `if:` names only another event
is left out; reusable workflows and local composite actions are followed), finds the tests they run (a test file a
command or interpreter runs or a `for` list names, `unittest discover`, `python -m unittest a.b`, `pytest DIR`,
`go test ./...`; a test is `test_*`, `*_test.*`, `*.test.*`, `*_tests.*` or under `test/` or `tests/`), and follows
each test's inputs, transitively:

  python  imports, resolved against the importing file's directory, every directory a visited file puts on sys.path
          (`sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools" / "x"))`) and the step's working
          directory; and every tracked file a path built from `__file__` names (Path / os.path.join / .parent /
          .parents[n] / with_name). A file passed to subprocess, spec_from_file_location or runpy is followed in
          turn; any other (a fixture, a text it asserts on) is an input read as data.
  shell   `source X` / `. X` and what a command runs (its first word, or an interpreter's script), once
          `$(dirname "$0")`, `${BASH_SOURCE%/*}`, `$(cd X && pwd)`, `$(git rev-parse --show-toplevel)`,
          $GITHUB_WORKSPACE, `cd` and the script's own literal assignments are substituted; `< FILE` is read as data.
  go      a `go test` package's .go files and the packages it imports from the same module.

An input it cannot resolve without guessing (an import of no tracked module outside the standard library, a path
that keeps a `$VAR` or a `${{ }}`, a directory listing) is listed as unknown and never fails the check. A push filter
on a workflow no pull request runs picks what to release, not what to test (widening it would publish more), so it
is listed, not checked. A gap is a resolved input the event's filter does not admit; `covered(test, input, workflow,
event, document)`, a repository's own router that already runs that test for that input whenever the event runs,
can excuse a test; the input is a gap unless it excuses every test that reads it. GitHub's `?` and `+` filter
operators (zero-or-one and one-or-more of the previous character) are read as one character and a literal `+`:
that can only miss a gap, never report a false one.

    python3 workflow_paths_cover_inputs.py [--root DIR] [--json] [--unknown]   # exit 1 when a gap is found
"""
from __future__ import annotations

import argparse
import ast
import fnmatch
import json
import os
import re
import shlex
import subprocess
import sys
import warnings
from bisect import bisect_left
from dataclasses import dataclass, field
from pathlib import Path

EVENTS = ("pull_request", "pull_request_target", "push")
FILTERS = ("paths", "paths-ignore")
STDLIB = set(getattr(sys, "stdlib_module_names", ())) | set(sys.builtin_module_names) | {"__future__"}
TEST_NAME = re.compile(r"(^test_.*|.*_test\.[^/]+|.*\.test\.[^/]+|.*_tests?\.[^/]+|^tests?\.(sh|py)|.*-tests?\.sh)$")
TEST_DIR = re.compile(r"(^|/)tests?/")
EVENT_TERM = re.compile(r"github\.event_name\s*(==|!=)\s*'([a-z_]+)'")
SCRIPT_DIR_EXPR = re.compile(
    r"\$\(\s*dirname\s+(?:--\s+)?\"?\$(?:0|\{0\}|\{BASH_SOURCE\[0\]\}|\{BASH_SOURCE\}|BASH_SOURCE)\"?\s*\)"
    r"|\$\{(?:BASH_SOURCE(?:\[0\])?|0)%/\*\}")
CD_PWD = re.compile(r"\$\(\s*cd\s+(?:--\s+)?\"?([^\"$()`;&|]+?)\"?\s*(?:&&|;)\s*pwd(?:\s+-P)?\s*\)")
TOPLEVEL = re.compile(r"\$\(\s*git\s+(?:-C\s+\S+\s+)?rev-parse\s+--show-toplevel\s*\)")
ASSIGN = re.compile(r"^\s*(?:export\s+|readonly\s+|local\s+|declare\s+(?:-\w+\s+)*)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?-([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)")
SHELLS = {"bash", "sh", "zsh", "source", "."}
INTERPRETERS = re.compile(r"^(bash|sh|zsh|dash|python3?(\.\d+)?|node|bun|deno|ruby|perl|pytest)$")
PREFIXES = {"exec", "env", "command", "time", "sudo", "nice", "timeout", "xargs", "then", "do", "else", "!", "{"}
# Calls whose path arguments a Python file runs or loads as code; any other path it builds is read as data.
RUN_CALLS = {"run", "call", "check_call", "check_output", "Popen", "execv", "execvp", "execve", "spawnv",
             "spec_from_file_location", "run_path", "SourceFileLoader", "import_path", "load_source"}


# --------------------------------------------------------------------------------------------- filters
def glob_regex(pattern: str) -> re.Pattern:
    """A GitHub paths-filter glob: `**` crosses directories, `*` and `?` do not, `[..]` is a class."""
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif pattern[i] == "?":
            out, i = out + "[^/]", i + 1
        elif pattern[i] == "[" and "]" in pattern[i + 2:]:
            end = pattern.index("]", i + 2)
            body = pattern[i + 1:end]
            body = ("^" + body[1:]) if body.startswith("!") else body
            klass = "[" + body.replace("\\", "\\\\") + "]"
            try:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore")
                    re.compile(klass)
            except re.error:
                klass = re.escape(pattern[i:end + 1])
            out, i = out + klass, end + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out + r"\Z")


def admits(kind: str, patterns: list[str], path: str) -> bool:
    """Whether a change to `path` alone starts the event under this filter (later patterns win; `!` negates)."""
    matched = False
    for pattern in patterns:
        pattern = str(pattern)
        negated = pattern.startswith("!")
        if glob_regex(pattern[1:] if negated else pattern).match(path):
            matched = not negated
    return not matched if kind == "paths-ignore" else matched


def triggers(document) -> dict:
    events = document.get("on", document.get(True)) if isinstance(document, dict) else None
    if isinstance(events, str):
        return {events: {}}
    if isinstance(events, list):
        return {e: {} for e in events}
    return events if isinstance(events, dict) else {}


def filtered_events(document) -> dict[str, tuple[str, list[str]]]:
    """{event: (filter kind, patterns)} for each push / pull_request event that has a path filter."""
    out = {}
    for event, config in triggers(document).items():
        if event in EVENTS and isinstance(config, dict):
            for kind in FILTERS:
                if kind in config:
                    out[event] = (kind, [str(p) for p in (config.get(kind) or [])])
    return out


def may_run_for(condition, event: str) -> bool:
    """False only when an `if:` made of `&&` terms has one that names another event."""
    text = str(condition or "")
    if "||" in text or "!(" in text:
        return True
    for op, name in EVENT_TERM.findall(text):
        if (op == "==") != (name == event):
            return False
    return True


# --------------------------------------------------------------------------------------------- the tree
@dataclass
class Repo:
    root: Path
    tracked: set[str] = field(default_factory=set)
    dirs: set[str] = field(default_factory=set)
    py_dirs: set[str] = field(default_factory=set)  # directories holding Python somewhere below
    ordered: list[str] = field(default_factory=list)
    globs: dict[str, list[str]] = field(default_factory=dict)

    @classmethod
    def load(cls, root: Path) -> "Repo":
        out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True).stdout
        tracked = {p for p in out.decode("utf-8", "replace").split("\0") if p}
        dirs, py_dirs = {""}, {""}
        for path in tracked:
            parts = path.split("/")
            for n in range(1, len(parts)):
                dirs.add("/".join(parts[:n]))
                if path.endswith(".py"):
                    py_dirs.add("/".join(parts[:n]))
        return cls(root.resolve(), tracked, dirs, py_dirs)

    def rel(self, absolute: str) -> str | None:
        """The repo path of an absolute path, or None outside the repo."""
        norm = os.path.normpath(absolute)
        root = str(self.root)
        if norm == root:
            return ""
        if norm.startswith(root + os.sep):
            return norm[len(root) + 1:].replace(os.sep, "/")
        return None

    def sorted(self) -> list[str]:
        if not self.ordered:
            self.ordered = sorted(self.tracked)
        return self.ordered

    def abs(self, rel: str) -> str:
        return str(self.root / rel) if rel else str(self.root)

    def is_file(self, rel: str | None) -> bool:
        return rel is not None and rel in self.tracked and (self.root / rel).is_file()

    def is_dir(self, rel: str | None) -> bool:
        return rel is not None and rel in self.dirs

    def glob(self, rel_pattern: str) -> list[str]:
        """Tracked files matching a shell glob (`*` stays within one directory, `**` crosses them)."""
        if rel_pattern in self.globs:
            return self.globs[rel_pattern]
        if not self.ordered:
            self.ordered = sorted(self.tracked)
        literal = re.split(r"[*?\[]", rel_pattern, maxsplit=1)[0]
        prefix = literal.rsplit("/", 1)[0] + "/" if "/" in literal else ""
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            regex = glob_regex(rel_pattern)
        out = []
        for path in self.ordered[bisect_left(self.ordered, prefix):]:
            if not path.startswith(prefix):
                break
            if regex.match(path):
                out.append(path)
        self.globs[rel_pattern] = out
        return out


def is_test(rel: str) -> bool:
    return bool(TEST_NAME.match(rel.rsplit("/", 1)[-1]) or TEST_DIR.search(rel))


# --------------------------------------------------------------------------------------------- python
@dataclass
class PyFacts:
    imports: list[tuple[str, int, tuple[str, ...]]]  # (module, level, names imported from it)
    paths: list[str]  # absolute paths the file builds from __file__ (files and directories)
    sys_path: list[str]  # absolute directories the file puts on sys.path
    globs: list[str]  # absolute glob patterns (a directory's glob / rglob)
    runs: list[str]  # the paths among `paths` the file runs or loads (a subprocess, spec_from_file_location, runpy)


class PathEval:
    """Evaluates the expressions a Python file builds paths with; each value is a list of candidates."""

    PATH_CALLS = {"Path", "PurePath", "PosixPath", "PurePosixPath"}
    IDENTITY = {"resolve", "absolute", "expanduser", "as_posix", "__fspath__"}
    IDENTITY_FUNCS = {"str", "os.fspath", "os.path.abspath", "os.path.realpath", "os.path.normpath",
                      "fspath", "abspath", "realpath", "normpath"}

    def __init__(self, file: str, nodes: list[ast.AST]):
        self.file = file
        self.env: dict[str, list[ast.AST]] = {}
        for node in nodes:
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name):
                        self.env.setdefault(target.id, []).append(node.value)
            elif isinstance(node, (ast.AnnAssign, ast.NamedExpr)) and isinstance(node.target, ast.Name) and node.value:
                self.env.setdefault(node.target.id, []).append(node.value)
            elif isinstance(node, (ast.For, ast.comprehension)) and isinstance(node.target, ast.Name) \
                    and isinstance(node.iter, (ast.Tuple, ast.List)):
                self.env.setdefault(node.target.id, []).extend(node.iter.elts)
        self.stack: set[int] = set()
        self.memo: dict[int, list] = {}

    @staticmethod
    def dotted(node) -> str:
        if isinstance(node, ast.Name):
            return node.id
        if isinstance(node, ast.Attribute):
            base = PathEval.dotted(node.value)
            return f"{base}.{node.attr}" if base else ""
        return ""

    def eval(self, node) -> list:
        """Candidates: ("p", absolute path) or ("s", string)."""
        key = id(node)
        if key in self.memo:
            return self.memo[key]
        if key in self.stack:
            return []
        self.stack.add(key)
        try:
            value = list(dict.fromkeys(self._eval(node)))[:32]
        finally:
            self.stack.discard(key)
        self.memo[key] = value
        return value

    def _eval(self, node) -> list:
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return [("s", node.value)]
        if isinstance(node, ast.Name):
            if node.id == "__file__":
                return [("p", self.file)]
            out = []
            for value in self.env.get(node.id, [])[:8]:
                out.extend(self.eval(value))
            return out
        if isinstance(node, ast.JoinedStr):
            return []
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            return [("p", os.path.join(left, right)) for kl, left in self.eval(node.left) if kl == "p"
                    for kr, right in self.eval(node.right) if kr == "s"]
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            return [(kl, left + right) for kl, left in self.eval(node.left)
                    for kr, right in self.eval(node.right) if kr == "s"]
        if isinstance(node, ast.Attribute):
            if node.attr == "parent":
                return [("p", os.path.dirname(os.path.normpath(v))) for k, v in self.eval(node.value) if k == "p"]
            return []
        if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Attribute) and node.value.attr == "parents":
            index = node.slice
            if isinstance(index, ast.Constant) and isinstance(index.value, int) and index.value >= 0:
                out = []
                for k, v in self.eval(node.value.value):
                    if k == "p":
                        v = os.path.normpath(v)
                        for _ in range(index.value + 1):
                            v = os.path.dirname(v)
                        out.append(("p", v))
                return out
            return []
        if isinstance(node, ast.Call):
            name = self.dotted(node.func)
            short = name.rsplit(".", 1)[-1]
            args = node.args
            if short in self.PATH_CALLS and args:
                out = [(("p" if k == "p" else "s"), v) for k, v in self.eval(args[0])]
                for arg in args[1:]:
                    out = [(k, os.path.join(v, s)) for k, v in out for ks, s in self.eval(arg) if ks == "s"]
                return [("p", v) for k, v in out if k == "p"]
            if name in ("os.path.join", "path.join") and args:
                out = [(k, v) for k, v in self.eval(args[0]) if k == "p"]
                for arg in args[1:]:
                    out = [("p", os.path.join(v, s)) for _, v in out for ks, s in self.eval(arg) if ks == "s"]
                return out
            if name in ("os.path.dirname", "dirname") and len(args) == 1:
                return [("p", os.path.dirname(os.path.normpath(v))) for k, v in self.eval(args[0]) if k == "p"]
            if name in self.IDENTITY_FUNCS and len(args) == 1:
                return self.eval(args[0])
            if isinstance(node.func, ast.Attribute):
                attr = node.func.attr
                if attr in self.IDENTITY:
                    return self.eval(node.func.value)
                if attr in ("joinpath",):
                    out = [(k, v) for k, v in self.eval(node.func.value) if k == "p"]
                    for arg in args:
                        out = [("p", os.path.join(v, s)) for _, v in out for ks, s in self.eval(arg) if ks == "s"]
                    return out
                if attr == "with_name" and len(args) == 1:
                    return [("p", os.path.join(os.path.dirname(os.path.normpath(v)), s))
                            for k, v in self.eval(node.func.value) if k == "p" for ks, s in self.eval(args[0]) if ks == "s"]
        return []


def python_facts(file_abs: str) -> PyFacts | None:
    try:
        source = Path(file_abs).read_text(encoding="utf-8")
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            tree = ast.parse(source, file_abs)
    except (OSError, UnicodeError, SyntaxError, ValueError):
        return None
    nodes = list(ast.walk(tree))
    evaluator = PathEval(file_abs, nodes)
    imports, paths, sys_path, globs, runs = [], [], [], [], []
    for node in nodes:
        if isinstance(node, ast.Import):
            imports.extend((alias.name, 0, ()) for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            imports.append((node.module or "", node.level, tuple(a.name for a in node.names)))
        elif isinstance(node, ast.Call):
            name = PathEval.dotted(node.func)
            if name in ("importlib.import_module", "import_module", "__import__") and node.args:
                for kind, value in evaluator.eval(node.args[0]):
                    if kind == "s" and re.fullmatch(r"[A-Za-z_][\w.]*", value):
                        imports.append((value, 0, ()))
            if name in ("sys.path.insert", "sys.path.append") and node.args:
                for kind, value in evaluator.eval(node.args[-1]):
                    if kind == "p":
                        sys_path.append(value)
            if name == "sys.path.extend" and node.args and isinstance(node.args[0], (ast.List, ast.Tuple)):
                for element in node.args[0].elts:
                    sys_path.extend(v for k, v in evaluator.eval(element) if k == "p")
            if isinstance(node.func, ast.Attribute) and node.func.attr in ("glob", "rglob") and node.args:
                for kind, base in evaluator.eval(node.func.value):
                    for ks, pattern in evaluator.eval(node.args[0]):
                        if kind == "p" and ks == "s":
                            prefix = "**/" if node.func.attr == "rglob" else ""
                            globs.append(os.path.join(base, prefix + pattern))
        elif isinstance(node, ast.Assign) and any(PathEval.dotted(t) == "sys.path" or (
                isinstance(t, ast.Subscript) and PathEval.dotted(t.value) == "sys.path") for t in node.targets):
            if isinstance(node.value, (ast.List, ast.Tuple)):
                for element in node.value.elts:
                    sys_path.extend(v for k, v in evaluator.eval(element) if k == "p")
        if isinstance(node, (ast.BinOp, ast.Call)):
            paths.extend(v for k, v in evaluator.eval(node) if k == "p")
        if isinstance(node, ast.Call) and PathEval.dotted(node.func).rsplit(".", 1)[-1] in RUN_CALLS:
            for arg in [*node.args, *(k.value for k in node.keywords if k.arg in (None, "args", "location", "path"))]:
                for inner in ast.walk(arg):
                    runs.extend(v for k, v in evaluator.eval(inner) if k == "p")
    return PyFacts(imports, sorted(set(paths)), sys_path, globs, sorted(set(runs)))


# --------------------------------------------------------------------------------------------- shell
def shell_words(text: str, script_dir: str | None, env: dict[str, str], unknown: list[str]):
    """Each command's words once the forms this resolves are substituted; a word left with `$` is dropped."""
    variables = dict(env)
    logical = re.sub(r"\\\n", " ", text)
    for raw in logical.split("\n"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if script_dir:
            line = SCRIPT_DIR_EXPR.sub(lambda _: script_dir, line)
        line = TOPLEVEL.sub(lambda _: env.get("GITHUB_WORKSPACE", "$__TOPLEVEL"), line)

        def substitute(match):
            name, default, bare = match.group(1), match.group(2), match.group(3)
            key = name or bare
            if key in variables:
                return variables[key]
            if default is not None and "$" not in default:
                return default
            return match.group(0)

        for _ in range(3):
            line = VAR.sub(substitute, line)
            line = CD_PWD.sub(lambda m: m.group(1), line)
        assignment = ASSIGN.match(line)
        if assignment and " " not in assignment.group(2).strip().strip("\"'"):
            try:
                value = shlex.split(assignment.group(2), comments=True)
            except ValueError:
                value = []
            if len(value) == 1 and "$" not in value[0] and "`" not in value[0]:
                variables[assignment.group(1)] = value[0]
            else:
                variables.pop(assignment.group(1), None)
            continue
        try:
            lexer = shlex.shlex(line, posix=True, punctuation_chars=";&|()<>")
            lexer.whitespace_split = True
            lexer.commenters = "#"
            words = list(lexer)
        except ValueError:
            continue
        command: list[str] = []
        for word in words + [";"]:
            if word and set(word) <= set(";&|()<>") and not set(word) & set("<>"):
                if command:
                    yield command
                command = []
            else:
                command.append(word)


def without_redirections(words: list[str]) -> list[str]:
    """The command's words with each redirection (`<`, `>`, `2>&1`, `>>`) and its operand taken out."""
    out, skip = [], False
    for word in words:
        if skip:
            skip = False
            continue
        if word and set(word) & set("<>") and set(word) <= set("<>&|0123456789"):
            skip = not word.endswith(("&", "&1", "&2"))
            continue
        out.append(word)
    return out


def run_targets(words: list[str]) -> list[str]:
    """The words a command runs: its first word, an interpreter's script, or a `for X in ...` list."""
    words = without_redirections(words)
    while words and (words[0] in PREFIXES or (ASSIGN.match(words[0]) and "=" in words[0])):
        words = words[1:]
    if not words:
        return []
    if words[0] == "for" and "in" in words:
        items = words[words.index("in") + 1:]
        return items[:items.index("do")] if "do" in items else items
    if INTERPRETERS.match(words[0].rsplit("/", 1)[-1]):
        index = 1
        while index < len(words) and words[index].startswith("-"):
            if words[index] in ("-m", "-c"):
                return []
            index += 2 if words[index] in ("-o", "-O", "-W", "-X") else 1
        return words[index:index + 1]
    return words[:1]


# --------------------------------------------------------------------------------------------- the walk
class Data(str):
    """An input read as data (a directory listing's files): its own imports and paths are not followed."""


@dataclass
class Finding:
    workflow: str
    event: str
    input: str
    chain: tuple[str, ...]  # test -> ... -> input


class Walker:
    def __init__(self, repo: Repo):
        self.repo = repo
        self.py_cache: dict[str, PyFacts | None] = {}
        self.unknown: dict[str, set[str]] = {}
        self.closures: dict[tuple[str, str], dict[str, tuple[str, ...]]] = {}
        self.results: dict[tuple, tuple[list[str], tuple[str, ...]]] = {}
        self.go_const_cache: dict[str, dict[str, str]] = {}

    def note_unknown(self, where: str, what: str, sink: dict | None = None):
        sink = self.unknown if sink is None else sink
        sink.setdefault(where, set()).add(what)

    # ---- entries from run text
    def entries(self, run: str, cwd: str, env: dict[str, str]) -> list[str]:
        """The test files (repo paths) a step's run text names."""
        repo = self.repo
        found: list[str] = []
        env = {"GITHUB_WORKSPACE": str(repo.root), **env}
        # `pkgs=$(go list ./... | ...)` then `go test $pkgs`: the variable stands for go list's own patterns (a
        # filter after the pipe only drops packages, so this reads at most a few more tests than run).
        for name, patterns in re.findall(r"(?m)^\s*([A-Za-z_]\w*)=\$\(\s*go\s+list\s+([^|)]*)", run):
            words = [w for w in patterns.split() if not w.startswith("-")]
            if words and all("$" not in w for w in words):
                env[name] = " ".join(words)
        for words in shell_words(run, None, env, []):
            if words[0] == "cd" and len(words) == 2 and "$" not in words[1] and not words[1].startswith("-"):
                target = os.path.normpath(os.path.join(cwd, words[1]))
                if repo.is_dir(repo.rel(target)):
                    cwd = target  # the step's later commands run from here
                continue
            if len(words) > 1 and words[0] == "go" and words[1] == "test":
                words = [part for w in words for part in w.split(" ")]  # an expanded package list
            found.extend(self.command_entries(words, cwd))
        return [p for p in dict.fromkeys(found) if is_test(p)]

    def word_paths(self, word: str, cwd: str) -> list[str]:
        """Tracked files a word names (a path, or a glob) relative to cwd (absolute)."""
        if "$" in word or "`" in word or not word or word.startswith("-"):
            return []
        if "=" in word and not word.startswith(("./", "/")):
            word = word.split("=", 1)[1]
        absolute = os.path.normpath(os.path.join(cwd, word))
        rel = self.repo.rel(absolute)
        if rel is None:
            return []
        if any(c in word for c in "*?["):
            # Only a file glob under a literal directory (`tests/test_*.py`); a `[[ x == */* ]]` or `case` pattern
            # and a bare `*` are not run lists.
            directory, _, name = rel.rpartition("/")
            if not directory or any(c in directory for c in "*?[$'\"") or not re.search(r"\.[A-Za-z]+$", name):
                return []
            return self.repo.glob(rel)
        return [rel] if self.repo.is_file(rel) else []

    def command_entries(self, words: list[str], cwd: str) -> list[str]:
        repo = self.repo
        out: list[str] = []
        names = [w.rsplit("/", 1)[-1] for w in words]
        for word in run_targets(words):
            out.extend(self.word_paths(word, cwd))
        # python -m unittest discover [-s DIR] [-p PATTERN] [-t TOP]
        if "unittest" in words and "discover" in words:
            start, pattern = ".", "test*.py"
            rest = words[words.index("discover") + 1:]
            positional = [w for w in rest if not w.startswith("-")]
            for j, w in enumerate(rest):
                if w in ("-s", "--start-directory") and j + 1 < len(rest):
                    start = rest[j + 1]
                if w in ("-p", "--pattern") and j + 1 < len(rest):
                    pattern = rest[j + 1]
            if not any(w in ("-s", "--start-directory") for w in rest) and positional:
                start = positional[0]
                if len(positional) > 1:
                    pattern = positional[1]
            base = repo.rel(os.path.join(cwd, start))
            if base is not None and "$" not in start:
                for path in repo.sorted():
                    if (base == "" or path.startswith(base + "/")) and fnmatch.fnmatchcase(path.rsplit("/", 1)[-1], pattern):
                        out.append(path)
        # python -m unittest a.b.c / pytest DIR
        if "-m" in words:
            module = words[words.index("-m") + 1] if words.index("-m") + 1 < len(words) else ""
            if module == "unittest":
                for w in words[words.index("-m") + 2:]:
                    if w != "discover" and re.fullmatch(r"[A-Za-z_]\w*(\.[A-Za-z_]\w*)*", w):
                        rel = repo.rel(os.path.join(cwd, w.replace(".", "/") + ".py"))
                        while rel and not repo.is_file(rel) and "/" in rel:
                            rel = rel.rsplit("/", 1)[0] + ".py"
                        if repo.is_file(rel):
                            out.append(rel)
        if any(n == "pytest" for n in names) or ("-m" in words and "pytest" in words):
            for w in words:
                rel = repo.rel(os.path.join(cwd, w)) if "$" not in w and not w.startswith("-") else None
                if rel and repo.is_dir(rel) and rel not in ("",):
                    out.extend(p for p in repo.sorted() if p.startswith(rel + "/") and re.match(
                        r"(test_.*|.*_test)\.py$", p.rsplit("/", 1)[-1]))
        # go test PKG... (./... recurses)
        if len(words) >= 2 and names[0] == "go" and words[1] == "test":
            for w in words[2:] or ["."]:
                if w.startswith("-") or "$" in w:
                    continue
                recursive = w.endswith("/...")
                base = repo.rel(os.path.join(cwd, w[:-4] if recursive else w))
                if base is None or not (w.startswith(".") or w.startswith("/")):
                    continue
                for path in repo.sorted():
                    parent = path.rsplit("/", 1)[0] if "/" in path else ""
                    if path.endswith("_test.go") and (parent == base or (recursive and (base == "" or path.startswith(base + "/")))):
                        out.append(path)
        return out

    # ---- inputs of one file, one step
    def closure(self, test: str, cwd: str) -> dict[str, tuple[str, ...]]:
        """{input repo path: chain from the test} for one test run from cwd (absolute)."""
        key = (test, cwd)
        if key in self.closures:
            return self.closures[key]
        chains: dict[str, tuple[str, ...]] = {test: (test,)}
        code = {test}  # files run or imported, whose own inputs count; a globbed file is read as data only
        sys_path: list[str] = []  # one process: a directory any visited file adds serves every later import
        while True:
            before = (len(chains), len(code), len(sys_path))
            for path in [p for p in chains if p in code]:
                for found in self.inputs_of(path, cwd, sys_path, None):
                    if found not in chains:
                        chains[found] = chains[path] + (str(found),)
                    if not isinstance(found, Data):
                        code.add(str(found))
            if (len(chains), len(code), len(sys_path)) == before:
                break
        for path in code:  # unknowns only once the search path is complete
            self.inputs_of(path, cwd, sys_path, self.unknown)
        self.closures[key] = chains
        return chains

    def inputs_of(self, rel: str, cwd: str, sys_path: list[str], unknown: dict | None) -> list[str]:
        """The files `rel` reads; with `unknown`, also records there what it could not resolve."""
        key = (rel, cwd, tuple(sys_path), unknown is not None)
        if key in self.results:
            out, added = self.results[key]
            sys_path.extend(d for d in added if d not in sys_path)  # what the file adds, whoever walked it first
            return out
        sink = unknown if unknown is not None else {}
        before = len(sys_path)
        out = self._inputs_of(rel, cwd, sys_path, sink)
        self.results[key] = (out, tuple(sys_path[before:]))
        return out

    def _inputs_of(self, rel: str, cwd: str, sys_path: list[str], sink: dict) -> list[str]:
        if rel.endswith(".py") or (not rel.endswith((".sh", ".bash", ".go")) and self.shebang(rel) == "python"):
            return self.python_inputs(rel, cwd, sys_path, sink)
        if rel.endswith((".sh", ".bash")) or self.shebang(rel) == "shell":
            return self.shell_inputs(rel, cwd, sink)
        if rel.endswith(".go"):
            return self.go_inputs(rel)
        return []

    def shebang(self, rel: str) -> str:
        try:
            with open(self.repo.abs(rel), "rb") as handle:
                first = handle.readline(200)
        except OSError:
            return ""
        if not first.startswith(b"#!"):
            return ""
        if b"python" in first:
            return "python"
        if re.search(rb"\b(ba|z)?sh\b", first):
            return "shell"
        return ""

    def python_inputs(self, rel: str, cwd: str, sys_path: list[str], sink: dict) -> list[str]:
        repo = self.repo
        absolute = repo.abs(rel)
        if absolute not in self.py_cache:
            self.py_cache[absolute] = python_facts(absolute)
        facts = self.py_cache[absolute]
        if facts is None:
            return []
        for directory in facts.sys_path:
            directory = os.path.normpath(directory)
            if directory not in sys_path:
                sys_path.append(directory)
        out = []
        runs = set(facts.runs)
        for path in facts.paths:
            prel = repo.rel(path)
            if repo.is_file(prel):
                out.append(prel if path in runs else Data(prel))
        for pattern in facts.globs:  # a listing reads whatever is there: listed, not checked
            prel = repo.rel(pattern)
            if prel is not None:
                self.note_unknown(rel, f"lists {prel}", sink)
        here = os.path.dirname(absolute)
        search = [here] + sys_path + [cwd]
        for module, level, names in facts.imports:
            if level:
                base = here
                for _ in range(level - 1):
                    base = os.path.dirname(base)
                found = self.resolve_module(module, names, [base], relative=True)
                if found is None:
                    self.note_unknown(rel, "." * level + module, sink)
                out.extend(found or [])
                continue
            top = module.split(".")[0]
            if top in STDLIB:
                continue
            found = self.resolve_module(module, names, search)
            if found is None:
                self.note_unknown(rel, module, sink)
            out.extend(found or [])
        return out

    def resolve_module(self, module: str, names: tuple[str, ...], search: list[str],
                       relative: bool = False) -> list[str] | None:
        """The tracked files `import module` (and `from module import names`) loads, or None if nothing matches."""
        repo = self.repo
        parts = module.split(".") if module else []
        for directory in search:
            base = repo.rel(directory)
            if base is None or not repo.is_dir(base) or (not parts and not relative):
                continue
            files: list[str] = []
            current: str | None = base
            ok = True
            for index, part in enumerate(parts):
                stem = f"{current}/{part}" if current else part
                if repo.is_file(stem + ".py"):
                    files.append(stem + ".py")
                    ok, current = index == len(parts) - 1, None
                    break
                if repo.is_file(stem + "/__init__.py"):
                    files.append(stem + "/__init__.py")
                elif stem not in repo.py_dirs:  # a namespace package holds Python somewhere
                    ok = False
                    break
                current = stem
            if not ok:
                continue
            if current is not None:
                for name in names:
                    stem = f"{current}/{name}" if current else name
                    if repo.is_file(stem + ".py"):
                        files.append(stem + ".py")
                    elif repo.is_file(stem + "/__init__.py"):
                        files.append(stem + "/__init__.py")
            return files
        return None

    def shell_inputs(self, rel: str, cwd: str, sink: dict) -> list[str]:
        repo = self.repo
        try:
            text = Path(repo.abs(rel)).read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            return []
        script_dir = os.path.dirname(repo.abs(rel))
        out: list[str] = []
        env = {"GITHUB_WORKSPACE": str(repo.root)}
        for words in shell_words(text, script_dir, env, []):
            while words and (words[0] in PREFIXES or (ASSIGN.match(words[0]) and "=" in words[0])):
                words = words[1:]
            if not words:
                continue
            if words[0] == "cd" and len(words) == 2 and "$" not in words[1] and not words[1].startswith("-"):
                target = os.path.normpath(os.path.join(cwd, words[1]))
                if repo.is_dir(repo.rel(target)):
                    cwd = target  # later relative paths in this script resolve from here
                continue
            if words[0] in ("source", ".") and len(words) > 1:
                target = words[1]
                found = [] if ("$" in target or "`" in target) else self.word_paths(target, cwd)
                if not found:
                    self.note_unknown(rel, f"source {target}", sink)
                out.extend(found)
                continue
            for run in run_targets(words):
                if "$" in run and re.search(r"\.(sh|py|bash)$", run):
                    self.note_unknown(rel, f"runs {run}", sink)
                elif not any(c in run for c in "*?["):  # a script's glob is a listing, not a run list
                    out.extend(self.word_paths(run, cwd))
            for index, word in enumerate(words[:-1]):
                if word in ("<", "0<"):
                    out.extend(Data(p) for p in self.word_paths(words[index + 1], cwd))
        return out

    def go_inputs(self, rel: str) -> list[str]:
        """A Go file's package siblings and the packages it imports from its own module."""
        repo = self.repo
        directory = rel.rsplit("/", 1)[0] if "/" in rel else ""
        out = [p for p in repo.sorted() if p.endswith(".go") and not p.endswith("_test.go")
               and (p.rsplit("/", 1)[0] if "/" in p else "") == directory]
        out.extend(Data(p) for p in self.go_reads(rel, directory))
        module_dir, module = self.go_module(directory)
        if module is None:
            return out
        out.append(f"{module_dir}/go.mod" if module_dir else "go.mod")
        try:
            text = Path(repo.abs(rel)).read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            return out
        blocks = re.findall(r"(?ms)^import\s*\((.*?)\)", text) + re.findall(r'(?m)^import\s+(?:[\w.]+\s+)?("[^"]+")', text)
        for path in re.findall(r'"([^"\s]+)"', "\n".join(blocks)):
            if path == module or path.startswith(module + "/"):
                sub = path[len(module):].lstrip("/")
                package = "/".join(x for x in (module_dir, sub) if x)
                out.extend(p for p in repo.sorted() if p.endswith(".go") and not p.endswith("_test.go")
                           and (p.rsplit("/", 1)[0] if "/" in p else "") == package)
        return out

    def go_reads(self, rel: str, directory: str) -> list[str]:
        """Tracked files a Go file opens (os.ReadFile / os.Open) by a path built only from string literals, its
        package's string constants and filepath.Join, relative to the package directory (go test's working
        directory). Any other argument is not followed."""
        consts = self.go_consts(directory)
        try:
            text = Path(self.repo.abs(rel)).read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            return []
        out = []
        for match in re.finditer(r"\bos\.(?:ReadFile|Open)\(", text):
            argument = balanced(text, match.end())
            value = go_eval(argument, consts) if argument is not None else None
            if value is None:
                continue
            target = self.repo.rel(os.path.join(self.repo.abs(directory), value))
            if self.repo.is_file(target):
                out.append(target)
        return out

    def go_consts(self, directory: str) -> dict[str, str]:
        if directory not in self.go_const_cache:
            consts: dict[str, str] = {}
            for path in self.repo.tracked:
                if path.endswith(".go") and (path.rsplit("/", 1)[0] if "/" in path else "") == directory:
                    try:
                        text = Path(self.repo.abs(path)).read_text(encoding="utf-8")
                    except (OSError, UnicodeError):
                        continue
                    for name, value in re.findall(r'(?m)^\s*(?:const\s+)?([A-Za-z_]\w*)\s*=\s*"([^"\\]*)"\s*$', text):
                        consts.setdefault(name, value)
            self.go_const_cache[directory] = consts
        return self.go_const_cache[directory]

    def go_module(self, directory: str) -> tuple[str, str | None]:
        current = directory
        while True:
            mod = f"{current}/go.mod" if current else "go.mod"
            if self.repo.is_file(mod):
                match = re.search(r"(?m)^module\s+(\S+)", Path(self.repo.abs(mod)).read_text(encoding="utf-8"))
                return current, match.group(1) if match else None
            if not current:
                return "", None
            current = current.rsplit("/", 1)[0] if "/" in current else ""


def balanced(text: str, start: int) -> str | None:
    """The text from `start` up to the `)` that closes the call opened just before it."""
    depth = 1
    for index in range(start, min(len(text), start + 400)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[start:index]
    return None


def split_top(text: str, separator: str) -> list[str]:
    parts, depth, current, quoted = [], 0, "", False
    for char in text:
        if char == '"':
            quoted = not quoted
        elif not quoted and char == "(":
            depth += 1
        elif not quoted and char == ")":
            depth -= 1
        if char == separator and depth == 0 and not quoted:
            parts.append(current)
            current = ""
        else:
            current += char
    return parts + [current]


def go_eval(expression: str, consts: dict[str, str]) -> str | None:
    """A Go string expression of literals, package constants, `+` and filepath.Join; None for anything else."""
    pieces = []
    for part in split_top(expression.strip(), "+"):
        part = part.strip()
        if re.fullmatch(r'"[^"\\]*"', part):
            pieces.append(part[1:-1])
        elif part in consts:
            pieces.append(consts[part])
        elif part.startswith(("filepath.Join(", "path.Join(")) and part.endswith(")"):
            args = [go_eval(a, consts) for a in split_top(part[part.index("(") + 1:-1], ",")]
            if any(a is None for a in args):
                return None
            pieces.append(os.path.join(*args) if args else "")
        else:
            return None
    return "".join(pieces)


# --------------------------------------------------------------------------------------------- workflows
def load_yaml(path: Path):
    import yaml  # noqa: PLC0415 - the one dependency; CI installs PyYAML

    return yaml.safe_load(path.read_text(encoding="utf-8"))


def mapping(value) -> dict:
    return value if isinstance(value, dict) else {}


def steps_for(repo: Repo, document, event: str, seen: set[str] | None = None, unknown=None):
    """(run text, working directory (repo path), env) for each step `event` can run, reusable workflows and local
    composite actions included. A nested file that cannot be read is noted in `unknown`, not followed."""
    seen = seen if seen is not None else set()
    document = mapping(document)
    defaults = mapping(mapping(document.get("defaults")).get("run"))
    top_env = literal_env(document.get("env"))
    for job in mapping(document.get("jobs")).values():
        if not isinstance(job, dict) or not may_run_for(job.get("if"), event):
            continue
        job_dir = (mapping(mapping(job.get("defaults")).get("run")).get("working-directory")
                   or defaults.get("working-directory") or "")
        job_env = {**top_env, **literal_env(job.get("env"))}
        uses = str(job.get("uses") or "")
        if uses.startswith("./.github/workflows/") and uses not in seen:
            seen.add(uses)
            nested = load_quietly(repo.root / uses[2:], unknown)
            if nested is not None:
                yield from steps_for(repo, nested, event, seen, unknown)
        steps = job.get("steps")
        for step in steps if isinstance(steps, list) else []:
            if not isinstance(step, dict) or not may_run_for(step.get("if"), event):
                continue
            step_dir = str(step.get("working-directory") or job_dir)
            env = {**job_env, **literal_env(step.get("env"))}
            if "run" in step:
                yield str(step["run"]), step_dir, env
            action = str(step.get("uses") or "")
            if action.startswith("./") and action not in seen:
                seen.add(action)
                for name in ("action.yml", "action.yaml"):
                    target = repo.root / action[2:] / name
                    if target.is_file():
                        inner_steps = mapping(mapping(load_quietly(target, unknown)).get("runs")).get("steps")
                        for inner in inner_steps if isinstance(inner_steps, list) else []:
                            if isinstance(inner, dict) and "run" in inner:
                                yield (str(inner["run"]), str(inner.get("working-directory") or step_dir),
                                       {**env, **literal_env(inner.get("env"))})
                        break


def load_quietly(path: Path, unknown):
    """The parsed YAML file, or None (noted in `unknown`) when it is missing or does not parse."""
    try:
        return load_yaml(path) if path.is_file() else None
    except Exception as error:  # noqa: BLE001 - a broken nested file is listed, not fatal
        if unknown is not None:
            unknown(str(path), f"unreadable: {error}")
        return None


def literal_env(env) -> dict[str, str]:
    if not isinstance(env, dict):
        return {}
    return {str(k): str(v) for k, v in env.items() if isinstance(v, (str, int)) and "${{" not in str(v)}


def find_gaps(root: Path, covered=None, workflows: list[Path] | None = None):
    """(gaps, unknown, checked): every input a filtered event's tests read that its filter does not admit."""
    repo = Repo.load(root)
    walker = Walker(repo)
    gaps: list[Finding] = []
    checked: dict[str, list[str]] = {}
    paths = workflows if workflows is not None else sorted(
        [*(repo.root / ".github/workflows").glob("*.yml"), *(repo.root / ".github/workflows").glob("*.yaml")])
    for workflow in paths:
        name = repo.rel(str(workflow)) or workflow.name
        try:
            document = load_yaml(workflow)
        except Exception as error:  # noqa: BLE001 - an unreadable workflow is listed, not fatal
            walker.note_unknown(name, f"unreadable: {error}")
            continue
        reviewed = any(e in triggers(document) for e in ("pull_request", "pull_request_target"))
        for event, (kind, patterns) in filtered_events(document).items():
            if event == "push" and not reviewed:
                # No pull request runs it: the push filter picks what to release or publish, not what to test.
                walker.note_unknown(name, "push-only filter (a release trigger) not checked")
                continue
            closures: dict[str, list[tuple[str, ...]]] = {}  # input -> one chain per test that reads it
            for run, workdir, env in steps_for(repo, document, event, unknown=walker.note_unknown):
                if "${{" in workdir or "$" in workdir:
                    walker.note_unknown(name, f"working-directory {workdir}")
                    continue
                cwd = repo.abs(os.path.normpath(workdir)) if workdir and workdir != "." else str(repo.root)
                run = re.sub(r"\$\{\{[^}]*\}\}", "$__EXPR", run)
                for test in walker.entries(run, cwd, env):
                    for found, chain in walker.closure(test, cwd).items():
                        chains = closures.setdefault(found, [])
                        if all(c[0] != chain[0] for c in chains):
                            chains.append(chain)
            checked.setdefault(name, []).extend(sorted({c[0] for cs in closures.values() for c in cs}))
            for found, chains in sorted(closures.items()):
                if admits(kind, patterns, found):
                    continue
                # A gap unless every test that reads it runs for it some other way (the repository's router).
                open_chains = [c for c in sorted(chains) if not (covered and covered(c[0], found, name, event,
                                                                                    document))]
                if open_chains:
                    gaps.append(Finding(name, event, found, open_chains[0]))
    unknown = {k: sorted(v) for k, v in sorted(walker.unknown.items())}
    return gaps, unknown, checked


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--unknown", action="store_true", help="also list inputs that could not be resolved")
    args = parser.parse_args(argv)
    gaps, unknown, checked = find_gaps(Path(args.root))
    if args.json:
        print(json.dumps({"gaps": [f.__dict__ for f in gaps], "unknown": unknown,
                          "checked": checked}, indent=1, default=list))
    else:
        for finding in gaps:
            print(f"{finding.workflow} ({finding.event}): {finding.input} is read by "
                  f"{' -> '.join(finding.chain)} but does not start the workflow")
        if args.unknown:
            for where, what in unknown.items():
                print(f"unknown in {where}: {', '.join(what)}")
        print(f"{len(gaps)} gap(s) in {len(checked)} path-filtered workflow(s)")
    return 1 if gaps else 0


if __name__ == "__main__":
    sys.exit(main())
