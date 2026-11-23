#!/usr/bin/env python3
"""Which ci-guards.yml steps a change can reach: run_ci_guards.py --affected's per-diff selection.

A guard step whose inputs a change leaves as they were gives the base's verdict again; running it
proves nothing (Leo, 2026-11-18: "Don't test b******t that we know vacuously true"). Each step's
inputs are a dependency graph read from its sources, the way large build systems pick affected tests:

  - the step's command must be plain test invocations (`python3 FILE`, `bash FILE`, `node --test
    FILE`, `bun test FILE`, `shellcheck -x FILE...`, joined by `&&` or one a line). Any other shell
    (a loop, a pipe, `git`, an install, `bun run`) makes the step whole-tree: it always runs.
  - each file it names is followed: Python imports (resolved in the folders the file puts on
    sys.path, else every file of that module name), the scripts a Python file runs (a subprocess
    call, a `[sys.executable, SCRIPT]` list, runpy, a file loader), JavaScript relative imports, and
    every file a shell script names. Any other tree path a Python file names (`ROOT / "config" /
    "a.json"`, through assignments) is data: an input, not followed, though the paths a data file
    names are inputs too (one level). A folder makes every path under it an input; a path with a
    glob or placeholder keeps the folder before it.
  - a Python walk (rglob, glob, iterdir, os.walk, listdir, scandir) adds the folder it walks, read
    through assignments; a temporary folder adds nothing. A walk of the root or of a folder the
    source cannot name, a shell or JavaScript walk (find, readdir, **), a git read (ls-files, grep,
    log, diff, show, merge-base, HEAD^), the base, or code built at runtime (`bash -c SCRIPT`,
    `exec(text)`) makes the step whole-tree: it always runs.

Every step runs when the change touches the selection itself (ci-guards.yml, this file,
run_ci_guards.py, guards-local.sh), changes more than MAX_CHANGED paths, or no base is known; a
push runs every step. A step that hands state to later steps (run_ci_guards.hands_state) runs
whenever a later selected step in its group does.

--verify tests the selection against what the steps really read: it runs every selectable step
under a Python audit hook and fails on a tree file opened, a folder listed or a git read of the
tree outside the step's inputs.

    guard_step_inputs.py --base REV [--head REV] [--json]   the plan for a diff
    guard_step_inputs.py --inputs STEP                       one step's inputs
    guard_step_inputs.py --verify [--step NAME]...           the traced check
"""
from __future__ import annotations

import argparse
import ast
import functools
import json
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAX_CHANGED = 400
# A change to any of these changes which steps run or how: every step runs.
SELECTION_INPUTS = frozenset({
    ".github/workflows/ci-guards.yml",
    "scripts/ci/guard_step_inputs.py",
    "scripts/ci/run_ci_guards.py",
    "scripts/ci/guards-local.sh",
    "scripts/ci/gh_expressions.py",
    "scripts/cmux-next/safe_log.py",  # run_ci_guards.py's output helper
})
CODE_SUFFIXES = (".py", ".sh", ".bash", ".js", ".mjs", ".cjs", ".ts", ".mts", ".cts", ".tsx")
JS_SUFFIXES = (".js", ".mjs", ".cjs", ".ts", ".mts", ".cts", ".tsx")
# A source with any of these reads git history, the index or the base: its inputs cannot be read from text.
GIT_OR_BASE = re.compile(
    r"ls-files|ls-tree|write-tree|\bgit\s+(-C\s+\S+\s+)?(grep|log|diff|show|blame|rev-list|cat-file|archive|worktree|stash)\b"
    r"|[\"']git[\"'],\s*([\"']-C[\"'],\s*[^,]+,\s*)?[\"'](grep|log|diff|show|blame|rev-list|cat-file|merge-base|archive|worktree|stash)[\"']"
    r"|merge-base|HEAD\^|HEAD~|GITHUB_BASE|BASE_SHA|BASE_REF|GITHUB_EVENT_PATH"
)
# A shell or JavaScript source with any of these walks folders its text may not name. A Python source's walks
# are read from its syntax instead (PythonSource.walks): a walk of a named folder or a temporary one is fine.
SHELL_WALK = re.compile(
    r"\breaddirSync\(|\breaddir\(|\bopendir\(|\bGlob\(|\bfast-glob\b|\bglobSync\(|\bglob\(|\bwalk\("
    r"|\bfind\s+[\"'$./]|\bxargs\b|\brg\s|grep\s+-[a-zA-Z]*[rR]|\*\*|\bls\s"
)
WALK_METHODS = {"rglob", "glob", "iterdir", "walk"}
WALK_FUNCTIONS = {"os.walk", "os.listdir", "os.scandir", "glob.glob", "glob.iglob", "listdir", "scandir", "walk",
                  "shutil.copytree", "fnmatch.filter"}
TEMP_CALLS = ("tempfile.", "mkdtemp", "TemporaryDirectory", "NamedTemporaryFile", "gettempdir", "mkstemp")
REPO_ROOT, OTHER, UNKNOWN = "repo", "other", None
# A call or command list that runs a tree file: the file's own imports and walks are the step's too.
EXEC_CALLEES = ("subprocess.", "os.system", "os.exec", "os.spawn", "os.posix_spawn", "runpy.", "run_path",
                "spec_from_file_location", "SourceFileLoader", "check_output", "check_call", "Popen")
COMMAND_HEADS = {"sys.executable", "python3", "python", "bash", "sh", "node", "bun", "zsh"}
# A tool a Python source starts that reads files of its own choosing (a Makefile's recipes, a package.json's
# scripts, a crate graph): what it reads is not in the source's text.
TOOL_HEADS = {"make", "gmake", "cargo", "rustc", "swift", "swiftc", "xcodebuild", "npm", "npx", "pnpm", "yarn", "bun",
              "bunx", "deno", "tsc", "go", "zig", "cmake", "ninja", "just", "gradle", "pytest", "uv", "uvx", "pip", "pip3",
              "ruff", "mypy", "vitest", "jest", "eslint", "prettier", "playwright", "biome", "tox", "nox"}
TOOL_MODULES = {"pytest", "mypy", "ruff", "pip", "coverage", "tox", "black", "build"}  # python3 -m NAME
# Words before the command that run it: `env A=B make`, `sudo make`, `xcrun swift`.
COMMAND_PREFIXES = {"env", "sudo", "nice", "xcrun", "timeout", "time", "command", "exec", "nohup", "stdbuf"}
SHELLS = {"bash", "sh", "zsh", "/bin/bash", "/bin/sh"}
JOINS = {"os.path.join", "Path", "pathlib.Path", "PurePath"}
PATH_TOKEN = re.compile(r"[A-Za-z0-9_.@+${}*-]+(?:/[A-Za-z0-9_.@+${}*<>-]*)+|[A-Za-z0-9_.-]+\.[A-Za-z0-9]{1,8}\b")
JS_IMPORT = re.compile(r"""(?:\bfrom\s+|\bimport\s*\(\s*|\brequire\s*\(\s*|^\s*import\s+)["']([^"']+)["']""", re.M)
JS_JOIN = re.compile(r"(?<![\w.$])(?:path\.)?(?:join|resolve)\(|\bpath\.(?:join|resolve)\(")
GLOB_CHARS = re.compile(r"[*?\[{$<]")
# A command a step may be made of and still have its inputs read: the runner, then files and flags.
RUNNERS = (
    ("python3", "-m", "unittest"), ("python3",), ("bash",), ("sh",), ("node", "--test"), ("node",),
    ("bun", "test"), ("shellcheck", "-x"), ("shellcheck",),
)
PLAIN_LINE = re.compile(r"\s*(set -[euxo]+( pipefail)?|set -o pipefail|#.*)?\s*")


def git(*args: str, root: Path = ROOT) -> str:
    return subprocess.run(["git", *args], cwd=root, check=True, stdout=subprocess.PIPE, text=True).stdout


@dataclass
class Inputs:
    files: set[str] = field(default_factory=set)  # read for what they in turn reach (code it imports or runs)
    data: set[str] = field(default_factory=set)  # read as data only: a path a Python source names but never runs
    folders: set[str] = field(default_factory=set)  # every path under one is an input
    modules: set[str] = field(default_factory=set)  # Python module stems: a changed or deleted <stem>.py anywhere
    whole: str = ""  # why the step reads the whole tree; empty when its inputs are the sets above
    runs_named: bool = False  # it runs a tree path built from a variable: any code file it names may run

    def reaches(self, path: str) -> bool:
        if self.whole or path in self.files:
            return True
        if any(path.startswith(folder + "/") for folder in self.folders):
            return True
        name = path.rsplit("/", 1)[-1]
        return name.endswith(".py") and name[:-3] in self.modules


class Tree:
    """The files of one checkout, and what each source reaches."""

    def __init__(self, root: Path = ROOT):
        self.root = root
        self.files = set(git("ls-files", "-z", root=root).split("\0")) - {""}
        self.folders = {str(Path(f).parent) for f in self.files} - {"."}
        self.folders |= {str(p) for f in list(self.folders) for p in Path(f).parents} - {"."}
        stages = git("ls-files", "-s", "-z", root=root).split("\0")
        self.submodules = {e.split("\t", 1)[1] for e in stages if e.startswith("160000 ")}
        self.by_stem: dict[str, list[str]] = {}
        for f in self.files:
            if f.endswith(".py"):
                self.by_stem.setdefault(Path(f).stem, []).append(f)
                if f.endswith("/__init__.py"):
                    self.by_stem.setdefault(Path(f).parent.name, []).append(f)

    def read(self, path: str) -> str | None:
        try:
            return (self.root / path).read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            return None

    def place(self, token: str, base: str, inputs: Inputs, changed: frozenset[str]) -> None:
        """Add what a path-like string names, read from the root and from `base`'s folders."""
        token = token.strip().strip("\"'`")
        if "://" in token or not token or token.startswith(("-", "~")):
            return
        token = re.sub(r"^\$\{?[A-Za-z_]+\}?/", "", token)  # $ROOT/x, ${repo}/x
        glob = GLOB_CHARS.search(token)
        if glob:
            token = token[: glob.start()].rpartition("/")[0]
            if not token:
                return
        token = token.lstrip("/").removeprefix("./")
        if not token or token in (".", ".."):
            return
        starts = [""] + [str(p) for p in Path(base).parents if str(p) != "."] + ([base] if base else [])
        for start in starts:
            candidate = os.path.normpath(os.path.join(start, token)) if start else os.path.normpath(token)
            if candidate.startswith("..") or candidate == ".":
                continue
            # a path inside a submodule: a pointer bump changes only the submodule's own entry
            inputs.files.update(m for m in self.submodules if candidate.startswith(m + "/"))
            if candidate in self.files or candidate in changed:
                inputs.files.add(candidate)
            elif candidate in self.folders or any(c.startswith(candidate + "/") for c in changed):
                inputs.folders.add(candidate)

    @functools.lru_cache(maxsize=None)
    def reach(self, path: str, changed: frozenset[str]) -> Inputs:
        """Everything `path` reaches, itself included."""
        inputs = Inputs()
        todo, seen, seen_data = [path], set(), set()
        while todo:
            current = todo.pop()
            if current in seen:
                continue
            seen.add(current)
            inputs.files.add(current)
            found = self.source(current, changed)
            if found.whole:
                inputs.whole = found.whole
                return inputs
            inputs.folders |= found.folders
            inputs.modules |= found.modules
            for data in sorted(found.data - seen_data):  # a workflow or a registry names more files a test reads
                seen_data.add(data)  # still followed as code if another source imports or runs it
                inputs.files.add(data)
                named = self.data_names(data, changed)
                inputs.files |= named.files
                inputs.folders |= named.folders
            todo.extend(sorted(found.files - seen))
        return inputs

    @functools.lru_cache(maxsize=None)
    def data_names(self, path: str, changed: frozenset[str]) -> Inputs:
        """The tree paths a data file (YAML, JSON, TOML, text) names: one level, as a test that reads a
        registry reads the files it lists (following those too would name most of the tree)."""
        named = Inputs()
        if path.endswith(CODE_SUFFIXES) or path.endswith((".swift", ".rs", ".css", ".png", ".lock")):
            return named
        try:
            text = self.read(path) if (self.root / path).stat().st_size < 1_000_000 else None
        except OSError:
            text = None
        for token in set(PATH_TOKEN.findall(text or "")):
            self.place(token, str(Path(path).parent), named, changed)
        return named

    @functools.lru_cache(maxsize=None)
    def source(self, current: str, changed: frozenset[str]) -> Inputs:
        """What one file reaches directly: `files` to follow, `data` to read, or `whole`."""
        found = Inputs()
        if not current.endswith(CODE_SUFFIXES) and not self.is_script(current):
            return found
        text = self.read(current)
        if text is None:
            if current in self.files:  # tracked but unreadable here: what it reaches is unknown, so it runs
                found.whole = f"cannot read {current} (not UTF-8 or not readable)"
            return found  # a file the change deletes: the path itself is the input
        if current.endswith(".py") or text.startswith(("#!/usr/bin/env python", "#!/usr/bin/python")):
            found.whole = self.python(current, text, found, changed)
            return found
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith(("#", "//")))
        marker = GIT_OR_BASE.search(code) or SHELL_WALK.search(code)
        if marker:
            found.whole = f"{current} reads more of the tree than it names ({marker.group(0).strip()!r})"
            return found
        if current.endswith(JS_SUFFIXES):
            self.javascript(current, code, found, changed)
        for token in PATH_TOKEN.findall(code):  # a shell script runs what it names
            self.place(token, str(Path(current).parent), found, changed)
        return found

    def is_script(self, path: str) -> bool:
        if "." in path.rsplit("/", 1)[-1] or path not in self.files:
            return False
        text = self.read(path)
        return bool(text and text.startswith("#!"))

    def python(self, path: str, text: str, found: Inputs, changed: frozenset[str]) -> str:
        """Add what a Python file imports, names and walks; return why it reads the whole tree, or ""."""
        try:
            tree = ast.parse(text)
        except (SyntaxError, ValueError, RecursionError):
            return f"{path} does not parse"
        for node in ast.walk(tree):  # docstrings name paths; they read none
            body = getattr(node, "body", None)
            if (isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and body
                    and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant)):
                body[0] = ast.Pass()
        nodes = list(ast.walk(tree))
        # Paths and git commands live in strings: its strings, one a line, less comments and docstrings.
        code = "\n".join(n.value for n in nodes if isinstance(n, ast.Constant) and isinstance(n.value, str))
        marker = GIT_OR_BASE.search(code)
        if marker:
            return f"{path} reads more of the tree than it names ({marker.group(0).strip()!r})"
        words = {n.value for n in nodes if isinstance(n, ast.Constant) and isinstance(n.value, str)}
        verbs = sorted(words & GIT_READS)
        if verbs and ("git" in words or any(dotted(n) == "git" for n in nodes if isinstance(n, ast.Call))):
            return f"{path} reads git ({verbs[0]!r}, through a git helper)"
        source = PythonSource(path, nodes)
        walked, why = source.walks(nodes)
        if why:
            return why
        found.folders |= walked
        parent = str(Path(path).parent)
        # Every path the source names, as written or built (`ROOT / "scripts" / "ci" / "x.py"`, an assigned
        # joinpath): data, unless the source runs it, whose own reach then counts too.
        named = Inputs()
        for token in PATH_TOKEN.findall(code):
            self.place(token, parent, named, changed)
        inner = inner_parts(nodes)
        for node in nodes:
            if id(node) in inner:  # `ROOT / "scripts"` inside `ROOT / "scripts" / "x.py"` names no folder
                continue
            if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
                parts = slash_parts(node)
                if parts:
                    self.place("/".join(parts), parent, named, changed)
            if (isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add)
                    or isinstance(node, ast.JoinedStr)
                    or isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "joinpath"):
                # where() joins an f-string's constant parts only: its runtime parts decide
                if (isinstance(node, ast.JoinedStr) or source.where(node) is UNKNOWN) and runtime_part(node) and source.rooted(node):
                    return f"{path}:{node.lineno} reads {ast.unparse(node)[:50]!r}, a tree file it names at runtime"
            if isinstance(node, (ast.BinOp, ast.Call)):
                place = source.where(node)
                if place and place[0] == REPO_ROOT and place[1]:
                    self.place(place[1], "", named, changed)
                elif place is UNKNOWN and isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
                    if source.rooted(node):  # ROOT / name / ...: a file of the root named at runtime
                        return f"{path}:{node.lineno} reads {ast.unparse(node)[:50]!r}, a tree file it names at runtime"
                elif place is UNKNOWN and isinstance(node, ast.Call) and dotted(node.func) in JOINS and len(node.args) > 1:
                    # os.path.join(root, "cmux-tui", "Cargo.toml") with an unknown root: the constant tail, from the root
                    tail = [a.value for a in node.args[1:] if isinstance(a, ast.Constant) and isinstance(a.value, str)]
                    if len(tail) == len(node.args) - 1:
                        self.place("/".join(tail), "", named, changed)
                    elif source.rooted(node.args[0]):  # os.path.join(ROOT, name, ...): named at runtime
                        return f"{path}:{node.lineno} reads {ast.unparse(node)[:50]!r}, a tree file it names at runtime"
        executed = self.executed(source, nodes, changed)
        if executed.whole:
            return executed.whole
        run = executed.files
        if executed.runs_named:
            run |= {f for f in named.files if f.endswith(CODE_SUFFIXES)}
        found.files |= run
        found.data |= named.files - run
        found.folders |= named.folders
        stdlib = getattr(sys, "stdlib_module_names", frozenset())
        search = {"" if parent == "." else parent, ""}
        names: set[str] = set()
        dynamic = False
        for node in nodes:
            if isinstance(node, ast.Import):
                names.update(alias.name for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                if node.level:  # a relative import: its package's folder
                    found.folders.add(str(Path(path).parent))
                elif node.module:
                    names.add(node.module)
                    names.update(f"{node.module}.{alias.name}" for alias in node.names)
            elif isinstance(node, ast.Call):
                callee = dotted(node.func)
                if callee.endswith(("import_module", "__import__")):
                    dynamic = True
                if callee in ("sys.path.insert", "sys.path.append") and node.args:
                    place = source.where(node.args[-1])
                    if place and place[0] == REPO_ROOT:
                        search.add(place[1])
                        found.files.update(self.submodule_of(place[1]))
        if dynamic:  # import_module("x"): any identifier string may name a module
            names.update(n.value for n in nodes
                         if isinstance(n, ast.Constant) and isinstance(n.value, str) and n.value.isidentifier())
        for name in names:
            parts = name.split(".")
            if parts[0] in stdlib:  # unless a tree file on its search path shadows it
                found.files.update(c for f in search for c in (os.path.join(f, parts[0] + ".py"),
                                                               os.path.join(f, parts[0], "__init__.py"))
                                   if c in self.files or c in changed)
                continue
            found.modules.add(parts[-1])
            hits = self.module_files(parts, search)
            if hits:
                found.files.update(hits)
            elif len(parts) == 1 or name.rpartition(".")[0] not in names:
                found.files.update(self.by_stem.get(parts[-1], ()))  # a sys.path this file builds at runtime
        return ""

    def executed(self, source: PythonSource, nodes: list[ast.AST], changed: frozenset[str]) -> Inputs:
        """The tree files a Python source runs or loads (`files`): what a subprocess call, a command list
        (`[sys.executable, SCRIPT]`), runpy or a file loader names; `whole` when it runs code it builds."""
        commands: list[ast.AST] = []
        for node in nodes:
            if isinstance(node, ast.Call):
                callee = dotted(node.func)
                if callee.startswith(EXEC_CALLEES) or callee.endswith(EXEC_CALLEES):
                    commands.append(node)
            elif isinstance(node, (ast.List, ast.Tuple)) and any(
                    dotted(e) in COMMAND_HEADS or (isinstance(e, ast.Constant) and e.value in COMMAND_HEADS) for e in node.elts):
                commands.append(node)
        found = Inputs()
        # Any list or string a call may run, wherever it is built (`cmd = ["make", "check"]; run(cmd)`).
        for node in nodes:
            words: list[str] | None = None
            if isinstance(node, (ast.List, ast.Tuple)) and node.elts:
                words = [e.value if isinstance(e, ast.Constant) and isinstance(e.value, str) else
                         ("python3" if dotted(e) == "sys.executable" else "") for e in node.elts]
            elif (isinstance(node, ast.Call) and node.args and isinstance(node.args[0], ast.Constant)
                    and isinstance(node.args[0].value, str) and node in commands):
                words = node.args[0].value.split()
            tool = starts_tool(words or [])
            if tool:
                found.whole = f"{source.path}:{node.lineno} starts {tool!r}, which reads files its text does not name"
                return found
        for node in nodes:
            why = runs_built_code(node)
            if why:
                found.whole = f"{source.path}:{getattr(node, 'lineno', '?')} {why}"
                return found
        inner = inner_parts(nodes)
        for command in commands:
            for node in ast.walk(command):
                if id(node) in inner:
                    continue
                if isinstance(node, ast.Constant) and isinstance(node.value, str):
                    self.place(node.value, str(Path(source.path).parent), found, changed)
                elif isinstance(node, (ast.Name, ast.Attribute, ast.BinOp, ast.Call, ast.JoinedStr)):
                    place = source.where(node)
                    if place and place[0] == REPO_ROOT and place[1]:
                        self.place(place[1], "", found, changed)
                    elif place is UNKNOWN:
                        built = node.args[0] if isinstance(node, ast.Call) and node.args and dotted(node.func) in (
                            "str", "Path", "pathlib.Path", "os.fspath") else node
                        if isinstance(built, ast.BinOp):
                            left = source.where(built.left)
                            found.runs_named |= bool(left and left[0] == REPO_ROOT)  # ROOT / relative
        return found

    def module_files(self, parts: list[str], search: set[str]) -> set[str]:
        """The tree files `import a.b.c` loads from these folders: the deepest module found, and its packages."""
        hits: set[str] = set()
        for folder in search:
            for size in range(len(parts), 0, -1):
                stem = os.path.join(folder, *parts[:size])
                found = [c for c in (stem + ".py", stem + "/__init__.py") if c in self.files]
                if found:
                    hits.update(found)
                    hits.update(f for f in (os.path.join(folder, *parts[:k], "__init__.py") for k in range(1, size))
                                if f in self.files)
                    break
        return hits

    @functools.lru_cache(maxsize=None)
    def js_packages(self) -> dict[str, str]:
        """The tree's own JavaScript packages, by name: an import of one reads its folder."""
        packages: dict[str, str] = {}
        for f in self.files:
            if f.endswith("package.json") and "/node_modules/" not in f:
                try:
                    name = json.loads((self.read(f) or "{}").lstrip("\ufeff")).get("name")
                except (ValueError, AttributeError):
                    continue
                if isinstance(name, str):
                    packages[name] = str(Path(f).parent)
        return packages

    @functools.lru_cache(maxsize=None)
    def js_package_folders(self, name: str) -> frozenset[str]:
        """A workspace package's folder and those of the workspace packages it depends on or imports, transitively."""
        folders, todo = set(), [name]
        while todo:
            current = todo.pop()
            folder = self.js_packages().get(current)
            if folder is None or folder in folders:
                continue
            folders.add(folder)
            try:
                manifest = json.loads((self.read(os.path.join(folder, "package.json")) or "{}").lstrip("\ufeff"))
            except ValueError:
                continue
            for key in ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies"):
                deps = manifest.get(key) if isinstance(manifest, dict) else None
                todo.extend(d for d in (deps if isinstance(deps, dict) else {}) if d in self.js_packages())
            for f in self.files:
                if f.startswith(folder + "/") and f.endswith(JS_SUFFIXES) and "/node_modules/" not in f:
                    for spec in JS_IMPORT.findall(self.read(f) or ""):
                        dep = "/".join(spec.split("/")[:2]) if spec.startswith("@") else spec.split("/")[0]
                        if dep in self.js_packages():
                            todo.append(dep)
        return frozenset(folders)

    @functools.lru_cache(maxsize=None)
    def js_aliases(self) -> tuple[str, ...]:
        """Import prefixes a tsconfig `paths` entry maps to a folder (`@app/*`): an import of one may read any folder."""
        aliases: set[str] = set()
        for f in self.files:
            if Path(f).name.startswith(("tsconfig", "jsconfig")) and f.endswith(".json") and "/node_modules/" not in f:
                for key in re.findall(r'"([^"\s]+)"\s*:\s*\[', self.read(f) or ""):
                    if "*" in key or "/" in key or key.startswith(("@", "~", "#", "$")):
                        aliases.add(key.split("*", 1)[0])
        return tuple(sorted(a for a in aliases if a))

    def submodule_of(self, path: str) -> set[str]:
        return {m for m in self.submodules if path == m or path.startswith(m + "/")}

    def javascript(self, path: str, text: str, found: Inputs, changed: frozenset[str]) -> None:
        folder = Path(path).parent
        for spec in JS_IMPORT.findall(text):
            if not spec.startswith("."):
                continue
            target = os.path.normpath(folder / spec)
            found.files.update(self.submodule_of(target))
            for candidate in [target] + [target + s for s in JS_SUFFIXES + (".json",)] + [f"{target}/index{s}" for s in JS_SUFFIXES]:
                if candidate in self.files:
                    found.files.add(candidate)
        for call in JS_JOIN.finditer(text):  # path.join(here, "..", "web", "fix", "data.json")
            args = js_arguments(text, call.end())
            if not all(js_string(a) for a in args[1:]):  # the first may be a folder (__dirname, a root); no other
                found.whole = f"{path} builds a path at runtime ({text[call.start():call.end() + 40]!r})"
                return
            literal = [a[1:-1] for a in args if js_string(a)]
            if literal:  # the first, when not a string, is a folder: __dirname, a root
                self.place("/".join(literal), str(folder), found, changed)
                self.place("/".join(p for p in literal if p not in ("..", ".")), "", found, changed)
        for spec in JS_IMPORT.findall(text):  # a workspace package is its folder; an alias may be any folder
            if spec.startswith((".", "node:")):
                continue
            name = "/".join(spec.split("/")[:2]) if spec.startswith("@") else spec.split("/")[0]
            if name in self.js_packages():
                found.folders |= self.js_package_folders(name)
            elif spec.startswith(("@/", "~/", "#", "$")) or any(spec.startswith(a) for a in self.js_aliases()):
                found.whole = f"{path} imports {spec!r} through an alias its text does not resolve"
                return
        for parent in [folder, *folder.parents]:  # its package and lockfile: a dependency bump
            for name in ("package.json", "bun.lock", "tsconfig.json"):
                candidate = str(parent / name) if str(parent) != "." else name
                if candidate in self.files:
                    found.files.add(candidate)


class PythonSource:
    """Where a Python file's path expressions point: a tree path, somewhere else (a temporary folder), or unknown.

    Names are followed through their assignments (`WORKFLOWS = ROOT / ".github/workflows"`, `self.tmp =
    Path(tempfile.mkdtemp())`, `with tempfile.TemporaryDirectory() as tmp`); a function's parameter, or a name
    given two places, is unknown unless every place agrees."""

    def __init__(self, path: str, nodes: list[ast.AST]):
        self.path = path
        self.memo: dict[int, tuple[str, str] | None] = {}
        self.assigned: dict[str, list[ast.AST]] = {}
        self.temp_names: set[str] = set()
        for node in nodes:
            if isinstance(node, (ast.Assign, ast.AnnAssign)) and node.value is not None:
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                for target in targets:
                    name = dotted(target)
                    if name:  # `a, b = ...` names no one path
                        self.assigned.setdefault(name, []).append(node.value)
                    else:
                        for part in ast.walk(target):  # each name it unpacks into: unknown
                            if dotted(part):
                                self.assigned.setdefault(dotted(part), []).append(ast.Constant(value=None))
            elif isinstance(node, (ast.With, ast.AsyncWith)):
                for item in node.items:
                    if item.optional_vars is not None and dotted(item.optional_vars):
                        self.assigned.setdefault(dotted(item.optional_vars), []).append(item.context_expr)
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                for arg in node.args.args + node.args.kwonlyargs:
                    if arg.arg in ("tmp", "tmp_path", "tmpdir", "temp", "scratch", "tempdir", "temp_dir", "tmp_dir"):
                        self.temp_names.add(arg.arg)

    def where(self, node: ast.AST, depth: int = 0) -> tuple[str, str] | None:
        key = id(node)
        if key not in self.memo:
            self.memo[key] = UNKNOWN  # a name assigned from itself (`p = p / "x"`) stays unknown
            self.memo[key] = self.resolve(node, depth)
        return self.memo[key]

    def resolve(self, node: ast.AST, depth: int) -> tuple[str, str] | None:
        if depth > 12:
            return UNKNOWN
        text = dotted(node)
        if isinstance(node, ast.Call) and any(marker in dotted(node.func) for marker in TEMP_CALLS):
            return (OTHER, "")
        if text and text in self.temp_names:
            return (OTHER, "")
        if isinstance(node, ast.Name) and node.id == "__file__":
            return (REPO_ROOT, self.path)
        if isinstance(node, (ast.Name, ast.Attribute)) and text and text in self.assigned:
            places = {self.where(value, depth + 1) for value in self.assigned[text]}
            return places.pop() if len(places) == 1 else UNKNOWN
        if isinstance(node, ast.Attribute):
            base = self.where(node.value, depth + 1)
            if node.attr == "parent" and base and base[0] == REPO_ROOT:
                return up(base[1], 1)
            if node.attr == "name" and base and base[0] == OTHER:
                return base
            return UNKNOWN
        if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Attribute) and node.value.attr == "parents":
            base = self.where(node.value.value, depth + 1)
            index = node.slice
            if base and base[0] == REPO_ROOT and isinstance(index, ast.Constant) and isinstance(index.value, int):
                return up(base[1], index.value + 1)
            return UNKNOWN
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            base = self.where(node.left, depth + 1)
            if not base or base[0] != REPO_ROOT:
                return base
            if isinstance(node.right, ast.Constant) and isinstance(node.right.value, str):
                return join(base[1], node.right.value)
            return (REPO_ROOT, base[1]) if base[1] else UNKNOWN  # ROOT / name: somewhere in the tree
        if isinstance(node, ast.Call):
            callee = dotted(node.func)
            if callee in ("Path", "pathlib.Path", "PurePath", "str", "os.fspath", "os.path.abspath",
                          "os.path.realpath", "os.path.normpath") and len(node.args) == 1:
                return self.where(node.args[0], depth + 1)
            if callee == "os.path.dirname" and len(node.args) == 1:
                base = self.where(node.args[0], depth + 1)
                return up(base[1], 1) if base and base[0] == REPO_ROOT else base
            if callee in ("os.path.join", "Path", "pathlib.Path") and node.args:
                base = self.where(node.args[0], depth + 1)
                for part in node.args[1:]:
                    if not base or base[0] != REPO_ROOT:
                        break
                    if not (isinstance(part, ast.Constant) and isinstance(part.value, str)):
                        return (REPO_ROOT, base[1]) if base[1] else UNKNOWN
                    base = join(base[1], part.value)
                return base
            if isinstance(node.func, ast.Attribute) and node.func.attr in ("resolve", "absolute", "expanduser"):
                return self.where(node.func.value, depth + 1)
            if isinstance(node.func, ast.Attribute) and node.func.attr == "joinpath":
                base = self.where(node.func.value, depth + 1)
                for part in node.args:
                    if not base or base[0] != REPO_ROOT:
                        break
                    if not (isinstance(part, ast.Constant) and isinstance(part.value, str)):
                        return (REPO_ROOT, base[1]) if base[1] else UNKNOWN
                    base = join(base[1], part.value)
                return base
        if isinstance(node, ast.JoinedStr) and node.values and isinstance(node.values[0], ast.FormattedValue):
            base = self.where(node.values[0].value, depth + 1)
            rest = node.values[1] if len(node.values) > 1 else None
            if base and base[0] == REPO_ROOT and isinstance(rest, ast.Constant) and isinstance(rest.value, str):
                return join(base[1], rest.value)
            return base
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            # A step runs from the tree's root, so a relative path is a tree path.
            return (OTHER, "") if node.value.startswith(("/", "~")) else join("", node.value)
        return UNKNOWN

    def rooted(self, node: ast.AST) -> bool:
        """Whether an unknown path is built on the tree's root: `ROOT / d / "index.md"` reads a root folder named at
        runtime, so any root path may be read."""
        while True:
            if self.where(node) == (REPO_ROOT, ""):
                return True
            if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Div, ast.Add)):
                node = node.left  # ROOT / d, str(ROOT) + "/" + d
            elif isinstance(node, ast.Call) and node.args and dotted(node.func) in JOINS | {"str", "os.fspath"}:
                node = node.args[0]
            elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "joinpath":
                node = node.func.value
            elif isinstance(node, ast.JoinedStr) and node.values and isinstance(node.values[0], ast.FormattedValue):
                node = node.values[0].value  # f"{ROOT}/{d}/index.md"
            else:
                return False

    def walks(self, nodes: list[ast.AST]) -> tuple[set[str], str]:
        """The tree folders this file walks, or why one of its walks may cover more than it names."""
        folders: set[str] = set()
        for node in nodes:
            if not isinstance(node, ast.Call):
                continue
            callee = dotted(node.func)
            if callee == "ast.walk":
                continue
            if isinstance(node.func, ast.Attribute) and node.func.attr in WALK_METHODS and callee not in WALK_FUNCTIONS:
                target = node.func.value
                pattern = node.args[0] if node.args else None
            elif callee in WALK_FUNCTIONS:
                if not node.args:
                    return set(), f"{self.path}:{node.lineno} {callee}() walks the working folder"
                target, pattern = node.args[0], None
            else:
                continue
            place = self.where(target)
            if place and place[0] == REPO_ROOT and callee.startswith("glob."):
                place = (REPO_ROOT, GLOB_CHARS.split(place[1])[0].rpartition("/")[0])
            if place and place[0] == OTHER:
                continue
            if place is UNKNOWN or not place[1]:
                return set(), f"{self.path}:{node.lineno} walks {ast.unparse(target)!r}, not a named folder"
            folder = place[1]
            if isinstance(pattern, ast.Constant) and isinstance(pattern.value, str):
                fixed = GLOB_CHARS.split(pattern.value)[0].rpartition("/")[0]
                folder = join(folder, fixed)[1] if fixed else folder
            folders.add(folder)
        return folders, ""


def up(path: str, levels: int) -> tuple[str, str] | None:
    for _ in range(levels):
        if not path:
            return (OTHER, "")  # above the tree
        path = path.rpartition("/")[0]
    return (REPO_ROOT, path)


def join(base: str, part: str) -> tuple[str, str]:
    joined = os.path.normpath(os.path.join(base, part)) if part else base
    if joined == ".":
        joined = ""
    if joined.startswith(".."):
        return (OTHER, "")
    return (REPO_ROOT, joined)


def starts_tool(words: list[str]) -> str:
    """The tool a command's words start, past `env A=B`, `sudo`, `bash -c "..."` and `python3 -m`, or ""."""
    words = [w for w in words if w is not None]
    while words and (words[0].rsplit("/", 1)[-1] in COMMAND_PREFIXES or re.fullmatch(r"[A-Za-z_]+=.*", words[0])):
        words = words[1:]
    if not words or not words[0]:
        return ""
    head = words[0].split()[0].rsplit("/", 1)[-1] if words[0].split() else ""
    if head in TOOL_HEADS:
        return head
    if head in {w.rsplit("/", 1)[-1] for w in SHELLS} and "-c" in words[1:-1]:
        return starts_tool(words[words.index("-c") + 1].split())
    if head.startswith("python") and "-m" in words[1:-1]:
        module = words[words.index("-m") + 1]
        if module in TOOL_MODULES or (module == "unittest" and "discover" in words):
            return f"{head} -m {module}"
    return ""


def runtime_part(node: ast.AST) -> bool:
    """Whether a path expression has a part only known at runtime past its base (a name, a call, a value)."""
    if isinstance(node, ast.JoinedStr):
        return sum(isinstance(v, ast.FormattedValue) for v in node.values) > 1
    if isinstance(node, ast.BinOp):
        return not isinstance(node.right, ast.Constant) or runtime_part(node.left)
    if isinstance(node, ast.Call):
        return any(not isinstance(a, ast.Constant) for a in node.args) or (
            isinstance(node.func, ast.Attribute) and runtime_part(node.func.value))
    return False


def js_string(arg: str) -> bool:
    return len(arg) > 1 and arg[0] == arg[-1] and arg[0] in "\"'" and arg[0] not in arg[1:-1]


def js_arguments(text: str, start: int) -> list[str]:
    """The top-level arguments of the call whose `(` ends at `start`, as written."""
    args, depth, quote, current, i = [], 0, "", [], start
    while i < len(text):
        c = text[i]
        if quote:
            current.append(c)
            if c == "\\" and i + 1 < len(text):
                current.append(text[i + 1])
                i += 1
            elif c == quote:
                quote = ""
        elif c in "\"'`":
            quote = c
            current.append(c)
        elif c in "([{":
            depth += 1
            current.append(c)
        elif c in ")]}":
            if depth == 0:
                break
            depth -= 1
            current.append(c)
        elif c == "," and depth == 0:
            args.append("".join(current).strip())
            current = []
        else:
            current.append(c)
        i += 1
    tail = "".join(current).strip()
    return args + [tail] if tail or args else args


def runs_built_code(node: ast.AST) -> str:
    """Why `node` runs code its file does not hold as text (`bash -c SCRIPT` with a script read from a
    workflow, `exec(text)`, a `shell=True` command built at runtime), or ""."""
    interpreter = isinstance(node, (ast.List, ast.Tuple)) and any(  # not git's `-c key=value`
        dotted(e) in COMMAND_HEADS or (isinstance(e, ast.Constant) and e.value in COMMAND_HEADS) for e in node.elts)
    if interpreter:
        for flag, value in zip(node.elts, node.elts[1:]):
            if isinstance(flag, ast.Constant) and flag.value in ("-c", "-e", "--eval") and not (
                    isinstance(value, ast.Constant) and isinstance(value.value, str)):
                return f"runs code it builds ({flag.value} {ast.unparse(value)[:40]})"
    if isinstance(node, ast.Call):
        callee = dotted(node.func)
        if callee in ("exec", "eval", "compile") and node.args and not isinstance(node.args[0], ast.Constant):
            return f"runs code it builds ({callee})"
        shell = any(k.arg == "shell" and not (isinstance(k.value, ast.Constant) and not k.value.value)
                    for k in node.keywords)
        if shell and callee.startswith(EXEC_CALLEES) and node.args and not isinstance(node.args[0], ast.Constant):
            return "runs a shell command it builds (shell=True)"
    return ""


def dotted(node: ast.AST) -> str:
    """`a.b.c` for a name or an attribute chain, else "" (cheaper than ast.unparse, which this runs per node)."""
    parts: list[str] = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if not isinstance(node, ast.Name):
        return ""
    parts.append(node.id)
    return ".".join(reversed(parts))


def inner_parts(nodes: list[ast.AST]) -> set[int]:
    """The nodes that are only a piece of a longer path: the left side of a `/` join, `Path(x)`'s x and a
    `.parent` or `.parents[N]` base."""
    inner: set[int] = set()
    for node in nodes:
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            inner.add(id(node.left))
        elif (isinstance(node, ast.Attribute) and node.attr in ("parent", "parents")
              and isinstance(node.value, (ast.BinOp, ast.Call))):
            inner.add(id(node.value))  # `(ROOT / "a").read_text()` reads ROOT / "a"; `(ROOT / "a").parent` does not
        elif isinstance(node, ast.Call) and node.args and dotted(node.func) in ("Path", "pathlib.Path", "str"):
            inner.add(id(node.args[0]))
    return inner


def slash_parts(node: ast.AST) -> list[str]:
    """The string pieces of `a / "b" / "c"`, in order; empty when none."""
    parts: list[str] = []
    while isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
        right = node.right
        if isinstance(right, ast.Constant) and isinstance(right.value, str):
            parts.append(right.value)
        else:
            break
        node = node.left
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        parts.append(node.value)
    return list(reversed(parts)) if len(parts) > 1 else []


def command_files(run: str, working_directory: str | None) -> tuple[list[str], str]:
    """The files a step's command runs, or why its command is not plain test invocations."""
    files: list[str] = []
    lines = [line for line in run.replace("\\\n", " ").splitlines() if not PLAIN_LINE.fullmatch(line)]
    if not lines:
        return [], "the step runs no command"
    for line in lines:
        for command in line.split("&&"):
            try:
                words = shlex.split(command, comments=True)
            except ValueError:
                return [], f"cannot read {command.strip()!r}"
            while words and re.fullmatch(r"[A-Z_][A-Z0-9_]*=\S*", words[0]):
                words = words[1:]  # PYTHON_BIN=python3.9 bash ...
            if not words:
                continue
            if re.fullmatch(r"python3\.\d+", words[0]):
                words[0] = "python3"
            runner = next((r for r in RUNNERS if tuple(words[: len(r)]) == r), None)
            if runner is None:
                if words[0].startswith(("./", "tests/", "scripts/", "ios/")) and len(words) >= 1:
                    runner = ()
                else:
                    return [], f"runs {words[0]!r}, not a plain test invocation"
            for word in words[len(runner):]:
                if word.startswith("-"):
                    continue
                if any(ch in word for ch in "|;<>`$*") and not word.startswith("$"):
                    return [], f"cannot read {command.strip()!r}"
                path = os.path.normpath(os.path.join(working_directory or "", word))
                files.append(path)
    return files, ""


def step_inputs(tree: Tree, run: str, working_directory: str | None, changed: frozenset[str],
                env: dict[str, str] | None = None) -> Inputs:
    files, why = command_files(run, working_directory)
    if why:
        return Inputs(whole=why)
    if not files:
        return Inputs(whole="the step names no file")
    inputs = Inputs()
    for key, value in (env or {}).items():  # the step's env: a base it compares with, a path it reads
        marker = GIT_OR_BASE.search(f"{key}={value}")
        if marker:
            return Inputs(whole=f"its env {key} reads the base or git ({marker.group(0)!r})")
        for token in PATH_TOKEN.findall(str(value)):
            tree.place(token, working_directory or "", inputs, changed)
    for path in files:
        if path not in tree.files and path not in changed:
            inputs.whole = f"{path} is not a tracked file"
            return inputs
        reached = tree.reach(path, changed)
        if reached.whole:
            return Inputs(whole=reached.whole)
        inputs.files |= reached.files
        inputs.folders |= reached.folders
        inputs.modules |= reached.modules
    return inputs


def changed_paths(base: str, head: str = "HEAD", root: Path = ROOT, worktree: bool = False) -> list[str]:
    paths = set(git("diff", "--no-renames", "--name-only", "-z", f"{base}...{head}", root=root).split("\0"))
    if worktree:  # a local run: uncommitted and untracked files too
        paths |= set(git("diff", "--no-renames", "--name-only", "-z", "HEAD", root=root).split("\0"))
        paths |= set(git("ls-files", "--others", "--exclude-standard", "-z", root=root).split("\0"))
    return sorted(paths - {""})


def everything_reason(changed: list[str]) -> str:
    if len(changed) > MAX_CHANGED:
        return f"{len(changed)} changed paths (over {MAX_CHANGED})"
    touched = sorted(SELECTION_INPUTS.intersection(changed))
    if touched:
        return f"the change touches the selection itself ({', '.join(touched)})"
    return ""


def inputs_of(tree: Tree, step: tuple, changed: frozenset[str] = frozenset()) -> Inputs:
    """A (name, run, working_directory[, env items]) step's inputs."""
    _name, run, working_directory, *env = step
    return step_inputs(tree, run, working_directory, changed, dict(env[0]) if env else None)


def select(tree: Tree, steps: list[tuple], changed: list[str]) -> dict[str, str]:
    """{step name: why it runs} for (name, run, working_directory[, env items]) steps; a step not in it is skipped."""
    frozen = frozenset(changed)
    picked: dict[str, str] = {}
    for step in steps:
        name = step[0]
        inputs = inputs_of(tree, step, frozen)
        if inputs.whole:
            picked[name] = f"always: {inputs.whole}"
            continue
        hits = [path for path in changed if inputs.reaches(path)]
        if hits:
            picked[name] = "reached by " + ", ".join(hits[:3]) + (f" and {len(hits) - 3} more" if len(hits) > 3 else "")
    return picked


def guard_steps(root: Path = ROOT) -> list[tuple]:
    """(name, run, working_directory, env items) for every ci-guards.yml step; the base reads as BASE_SHA."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import run_ci_guards  # noqa: PLC0415

    workflow = run_ci_guards.load_yaml(root / ".github/workflows/ci-guards.yml")
    units = run_ci_guards.plan(workflow, "BASE_SHA", "HEAD")
    seen: dict[str, tuple] = {}
    for unit in units:
        for step in unit.steps:
            seen.setdefault(step.name, (step.name, step.run, step.working_directory, tuple(sorted(step.env.items()))))
    return list(seen.values())


# --verify loads this into every Python process a step starts (PYTHONPATH): an audit hook that logs each
# file the process opens, each folder it lists and each command it runs. The import system's own reads are
# left out; the imports themselves are read from the source.
TRACER = '''
import json, os, sys
_log = os.environ.get("CMUX_GUARD_TRACE")
if _log:
    _out = open(_log, "a", buffering=1)
    def _importing():
        frame = sys._getframe(2)
        while frame is not None:
            if frame.f_code.co_filename.startswith("<frozen importlib"):
                return True
            frame = frame.f_back
        return False
    def _hook(event, args):
        try:
            if event == "open" and isinstance(args[0], (str, bytes, os.PathLike)):
                path, mode, flags = os.fsdecode(args[0]), args[1], args[2] or 0
                if mode is None:  # os.open: a relative path may be under a dir_fd (shutil.rmtree), not the cwd
                    if not os.path.isabs(path) or flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT):
                        return
                    mode = "r"
                if not any(c in mode for c in "wax") and not _importing():
                    _out.write("open\\t" + os.path.abspath(os.fsdecode(args[0])) + "\\n")
            elif event in ("os.listdir", "os.scandir") and not isinstance(args[0], int) and not _importing():
                _out.write("list\\t" + os.path.abspath(os.fsdecode(args[0] if args[0] is not None else ".")) + "\\n")
            elif event == "subprocess.Popen":
                argv = args[1] if isinstance(args[1], (list, tuple)) else [args[1]]
                cwd = os.path.abspath(os.fsdecode(args[2])) if args[2] is not None else os.getcwd()
                _out.write("exec\\t" + json.dumps([os.fsdecode(a) if isinstance(a, (str, bytes, os.PathLike)) else str(a)
                                                  for a in argv]) + "\\t" + cwd + "\\n")
        except Exception:
            pass
    sys.addaudithook(_hook)
'''


def escapes(inputs: Inputs, trace: str, root: Path) -> list[str]:
    """The tree reads in a step's trace that its inputs do not cover."""
    found: set[str] = set()
    prefix = str(root) + "/"
    for line in trace.splitlines():
        kind, _, value = line.partition("\t")
        if kind == "exec":
            command, _, cwd = value.partition("\t")
            argv = [str(a) for a in json.loads(command)]
            if argv and Path(argv[0]).name == "git":
                where = argv[argv.index("-C") + 1] if "-C" in argv[:-1] else cwd
                where = os.path.join(cwd, where) if cwd else where
                in_tree = not cwd or os.path.abspath(where) == str(root) or os.path.abspath(where).startswith(prefix)
                if in_tree and any(w in GIT_READS for w in argv[1:5]):
                    found.add(f"runs {' '.join(argv[:4])}")
            continue
        if not value.startswith(prefix):
            if kind == "list" and value == str(root):
                found.add("lists the tree's root")
            continue
        rel = value[len(prefix):]
        if rel.startswith(".git/") or "/__pycache__/" in f"/{rel}" or rel.startswith(".guard-trace"):
            continue
        if kind == "open" and not (root / rel).parent.exists():
            continue  # a fixture's made-up path (no/such/runners.json): no change adds a file there unnamed
        if kind == "open" and not ((root / rel).is_dir() or inputs.reaches(rel)):
            found.add(f"reads {rel}")
        elif kind == "list" and not (rel in inputs.folders or inputs.reaches(rel + "/x")):
            found.add(f"lists {rel}/")
    return sorted(found)


GIT_READS = {"ls-files", "ls-tree", "grep", "log", "diff", "show", "blame", "rev-list", "cat-file", "merge-base",
             "archive", "worktree", "stash", "write-tree"}


def verify(tree: Tree, steps: list[tuple[str, str, str | None]], jobs: int, names: set[str]) -> int:
    """Run every step whose inputs the selection reads, traced; fail on a read outside them."""
    import concurrent.futures  # noqa: PLC0415
    import tempfile  # noqa: PLC0415

    picked = [(s, inputs_of(tree, s)) for s in steps if not names or s[0] in names]
    picked = [(s, i) for s, i in picked if not i.whole]
    scratch = Path(tempfile.mkdtemp(prefix="guard-trace-"))
    (scratch / "sitecustomize.py").write_text(TRACER)

    def run(item):
        (name, run_text, working_directory, *step_env), inputs = item
        log = scratch / f"{abs(hash(name))}.log"
        env = {**os.environ, "CI": "true", **dict(step_env[0] if step_env else ()), "CMUX_GUARD_TRACE": str(log),
               "PYTHONDONTWRITEBYTECODE": "1",
               "PYTHONPATH": os.pathsep.join(filter(None, [str(scratch), os.environ.get("PYTHONPATH")]))}
        try:
            done = subprocess.run(["bash", "-eo", "pipefail", "-c", run_text], cwd=tree.root / (working_directory or ""),
                                  env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
            code = done.returncode
        except subprocess.TimeoutExpired:
            code = "timeout"
        trace = log.read_text(errors="replace") if log.exists() else ""
        return name, code, escapes(inputs, trace, tree.root)

    bad = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        for name, code, found in pool.map(run, picked):
            if found:
                bad += 1
                print(f"ESCAPE {name} (exit {code}):")
                for line in found[:20]:
                    print(f"    {line}")
    print(f"verify: {len(picked)} selectable steps run traced, {bad} read outside their inputs")
    return 1 if bad else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", help="the revision the change is measured from")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--inputs", metavar="STEP", help="print one step's inputs")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--verify", action="store_true",
                        help="run each selectable step traced and fail on a read outside its inputs")
    parser.add_argument("--step", action="append", default=[], help="with --verify: only this step")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    args = parser.parse_args(argv)
    tree = Tree()
    steps = guard_steps()
    if args.verify:
        return verify(tree, steps, args.jobs, set(args.step))
    if args.inputs:
        match = [s for s in steps if s[0] == args.inputs]
        if not match:
            print(f"no guard step named {args.inputs!r}", file=sys.stderr)
            return 2
        inputs = inputs_of(tree, match[0])
        print(json.dumps({"whole": inputs.whole, "files": sorted(inputs.files), "folders": sorted(inputs.folders),
                          "modules": sorted(inputs.modules)}, indent=2))
        return 0
    if not args.base:
        parser.error("--base or --inputs")
    changed = changed_paths(args.base, args.head)
    reason = everything_reason(changed)
    picked = {s[0]: f"always: {reason}" for s in steps} if reason else select(tree, steps, changed)
    skipped = [s[0] for s in steps if s[0] not in picked]
    if args.json:
        print(json.dumps({"changed": len(changed), "run": picked, "skipped": skipped}, indent=2))
    else:
        always = sum(1 for why in picked.values() if why.startswith("always"))
        print(f"{len(changed)} changed paths: {len(picked)} of {len(steps)} guard steps run "
              f"({always} always, {len(picked) - always} reached), {len(skipped)} skipped as unchanged")
        for name, why in picked.items():
            print(f"  run   {name}: {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
