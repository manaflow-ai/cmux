#!/usr/bin/env python3
"""Capability skew: which builds can measure a story (p12-perf-process.md 3.2, task 211).

The lab runs today's harness against old builds: a bisect midpoint, the weekly reference, a batch tip from before a
probe landed. A story declares what it reads (`needs` in stories.d: `debug:<method>`, `signpost:<name>`,
`env:<NAME>`, `file:<path>`, `privilege:<name>`). A build that lacks a need is not-measurable: Pinpoint skips the
Change and narrows the range (pinpoint.py), the scheduler records a gap, and nothing is ever judged a regression
for it. Telemetry does the same before it runs a story on a browser (`CanRunOnBrowser`,
third_party/catapult/telemetry/telemetry/page/shared_page_state.py): a story that cannot run is skipped, not failed.

Two sources answer what a build has:
- the build itself: `debug.capabilities` (Debug and bench builds, DebugCapabilities.swift) lists its registered
  `debug.*` methods, its emitted signposts and its probe launch variables (`Capabilities.from_probe`);
- its commit, read with git and no build (`GitCapabilities`): what labd knows before it builds or runs anything.
  `debug:` and `env:` are the method and variable literals in the app sources that the story's build config
  compiles; `signpost:` the emitted list of DebugCapabilities.swift, or for a commit before it the cases queues.py's
  MQ5 scan finds emitted in compiled code; `file:` whether the commit has the file. Each answer is cached per
  (commit, config): a commit never changes.
`privilege:` is a host property, which host_env.py checks on the lab host; no build lacks it.

A config compiles a Swift block when its `#if` condition can be true under that config's -D flags (`CONFIG_FLAGS`,
as scripts/reload.sh sets them): `bench` is Release + CMUX_BENCH_HOOKS with no DEBUG, so a method that only an
`#if DEBUG` block registers is not in a bench build. A condition on a flag the lab does not know
(GHOSTTY_RENDERER_FRAMES, arch(...)) keeps its block. The git answer is a guess made before the build exists; the
build's own answer is the last word: the story runner asks the launched build `debug.capabilities`
(`probe_missing`, bench_launch.py), a build that lacks a need ends its job with run_story.py's EXIT_NOT_MEASURABLE,
and Pinpoint skips that Change as not-measurable (pinpoint_exec.py).

Commands (also `lab.py capabilities ...`):

    python3 -I scripts/perf-lab/capabilities.py --check
    python3 -I scripts/perf-lab/capabilities.py --sha SHA [--stories a,b]
    python3 -I scripts/perf-lab/capabilities.py --probe FILE [--stories a,b]
    python3 -I scripts/perf-lab/capabilities.py --range GOOD..BAD --stories a

`--check` proves the tree's own claims: every emitted signpost DebugCapabilities.swift lists has an emit site,
every probe variable it lists has a reader, and every story need names something a build of the tip in the story's
config has (a bench story cannot need a method only `#if DEBUG` registers). `--sha` (in each story's config) and
`--probe` print, per story, `measurable` or `not-measurable: lacks <need>, ...`. `--range` prints `range limited by
capability <need> since <sha>` for each need of the story that commits of the first-parent range lack.
Exit: 0 every story measurable (or `--check` clean), 1 a story is not measurable (or a `--check` problem), 2 usage.

Stdlib only; loads its siblings by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import subprocess
import sys
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]

SCHEMA = "cmux-debug-capabilities/v1"
PROBE_METHOD = "debug.capabilities"
SOURCES = "Packages/macOS/CmuxNext/Sources"
DEBUG_CAPABILITIES = SOURCES + "/CmuxNextControl/Diagnostics/DebugCapabilities.swift"
SIGNPOST_NAME = SOURCES + "/CmuxNextSignposts/SignpostName.swift"
PROBE, SOURCE = "probe", "source"
HOST_KINDS = ("privilege",)  # judged on the lab host (host_env.py), never by a build

SYSTEM_METHODS = "system.capabilities"  # every build's registered methods: the fallback of a build before the probe
SWIFT_SOURCES = f":(glob){SOURCES}/**/*.swift"

# The -D flags of each build config (scripts/reload.sh --config: bench is Release + CMUX_BENCH_HOOKS with no DEBUG,
# bench-checks adds CMUX_BLOCKING_CHECKS). A flag that is not listed is unknown to the lab: its blocks stay in.
_OFF = {"DEBUG": False, "CMUX_BENCH_HOOKS": False, "CMUX_BLOCKING_CHECKS": False, "CMUX_UI_LAYER_PREVIEW": False}
CONFIG_FLAGS: dict[str, dict[str, bool]] = {
    "debug": {**_OFF, "DEBUG": True, "CMUX_UI_LAYER_PREVIEW": True},
    "bench": {**_OFF, "CMUX_BENCH_HOOKS": True},
    "bench-checks": {**_OFF, "CMUX_BENCH_HOOKS": True, "CMUX_BLOCKING_CHECKS": True},
    "release": dict(_OFF),
}
DEFAULT_CONFIG = "bench"

METHOD_LITERAL = re.compile(r'"(debug\.[a-z0-9_.]+)"')
ENV_LITERAL = re.compile(r'"(CMUX_NEXT_[A-Z0-9_]+)"')
LITERAL_FILES = r'"(debug\.|CMUX_NEXT_)'
SIGNPOST_FILES = r"SignpostName|[sS]ignposter|signpost:"
DIRECTIVE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")
CONDITION_TOKEN = re.compile(r"\s*(\|\||&&|!|\(|\)|[A-Za-z_]\w*(?:\s*\([^()]*\))?)")
STATIC_NAME = re.compile(r'case\s+\.(\w+):\s*"([^"]+)"')
CASE_REFERENCE = re.compile(r"\.([a-z]\w*)\b")
# A begin, interval or event call with a SignpostName case first, on any receiver (`stall.begin(.x`,
# `TraceRuntime.shared.event(.x`): queues.py's MQ5 scan keys on a few receiver names and misses these.
ANY_RECEIVER_EMIT = re.compile(r"\.(?:begin|interval|event|asyncBegin|flowOut)\(\s*(?:SignpostName)?\.(\w+)\b")
# A Swift array literal assigned to a static of DebugCapabilities: its name and its body.
STATIC_LIST = re.compile(r"static\s+let\s+(\w+)\s*:\s*\[\w+\]\s*=\s*\[(.*?)\]", re.S)

LAB_COMMANDS = {
    "capabilities": "Which builds can measure a story: --check, --sha SHA, --probe FILE or --range GOOD..BAD.",
}


class CapabilityError(RuntimeError):
    """A probe document, a need or a git answer this module cannot read."""


def _load_sibling(name: str):
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module  # before exec: dataclasses resolve their module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(module_name, None)
        raise
    return module


# ---------- what a build has ----------

@dataclass(frozen=True)
class Capabilities:
    """One build's capabilities. signposts are wire names (`action.commit`); cases maps a SignpostName case to its
    wire name, so a need may name either. A probe knows no files: `file:` needs are the commit's, judged by git."""

    source: str  # PROBE or SOURCE
    methods: frozenset[str]
    signposts: frozenset[str] | None  # None: unknown (a build before the probe answers only its methods)
    environment: frozenset[str] | None
    cases: Mapping[str, str] = field(default_factory=dict)

    @classmethod
    def from_probe(cls, document: Mapping, cases: Mapping[str, str] | None = None) -> "Capabilities":
        """The `debug.capabilities` answer; `cases` defaults to the tip's catalog (case names never change meaning)."""
        if not isinstance(document, Mapping) or document.get("schema") != SCHEMA:
            raise CapabilityError(f"not a {SCHEMA} document")

        def names(key: str) -> frozenset[str]:
            value = document.get(key)
            if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
                raise CapabilityError(f"{PROBE_METHOD}: {key} is not a list of names")
            return frozenset(value)

        return cls(PROBE, names("methods"), names("signposts"), names("environment"),
                   dict(tip_signpost_cases() if cases is None else cases))

    @classmethod
    def from_methods(cls, document: Mapping) -> "Capabilities":
        """The `system.capabilities` answer of a build from before `debug.capabilities`: its registered methods only,
        so its signposts and variables stay unknown and are not judged here."""
        methods = document.get("methods") if isinstance(document, Mapping) else None
        if not isinstance(methods, list) or not all(isinstance(m, str) for m in methods):
            raise CapabilityError(f"{SYSTEM_METHODS}: methods is not a list of names")
        return cls(PROBE, frozenset(m for m in methods if m.startswith("debug.")), None, None)

    def has(self, need: str, has_file: Callable[[str], bool] | None = None) -> bool:
        kind, name = parse_need(need)
        if kind == "debug":
            return name in self.methods
        if kind == "signpost":
            return self.signposts is None or self.cases.get(name, name) in self.signposts
        if kind == "env":
            return self.environment is None or name in self.environment
        if kind == "file":
            return True if has_file is None else has_file(name)
        return True  # HOST_KINDS


def parse_need(need: str) -> tuple[str, str]:
    kind, sep, name = need.partition(":")
    if not sep or not name or kind not in ("debug", "signpost", "env", "file", *HOST_KINDS):
        raise CapabilityError(f"need {need!r} is not <debug|signpost|env|file|privilege>:<name>")
    return kind, name


def missing(needs: Iterable[str], capabilities: Capabilities,
            has_file: Callable[[str], bool] | None = None) -> tuple[str, ...]:
    """The needs the build lacks, in the story's order; () when it can measure the story."""
    return tuple(need for need in needs if not capabilities.has(need, has_file))


def probe_missing(needs: Sequence[str], ask: Callable[[str], object]) -> tuple[str, ...]:
    """The needs a running build lacks, from its own answer: `ask(method)` sends one control request with no params
    and returns its result (bench_launch.rpc_at: a reply with `error` when it failed). A build from before the probe
    is judged on its `system.capabilities` methods. `file:` needs are the commit's (git), never judged here."""
    reply = ask(PROBE_METHOD)
    if isinstance(reply, Mapping) and reply.get("schema") == SCHEMA:
        build = Capabilities.from_probe(reply)
    else:
        build = Capabilities.from_methods(ask(SYSTEM_METHODS))
    return missing(needs, build)


# ---------- what a config compiles ----------

def _and(a: bool | None, b: bool | None) -> bool | None:
    return False if a is False or b is False else True if a and b else None


def _or(a: bool | None, b: bool | None) -> bool | None:
    return True if a is True or b is True else False if a is False and b is False else None


def condition(expr: str, flags: Mapping[str, bool]) -> bool | None:
    """A Swift `#if` condition under `flags`: True, False, or None when it names a flag the lab does not know or a
    platform test (`arch(arm64)`, `compiler(>=6.4)`), or does not parse."""
    tokens, pos, text = [], 0, expr.strip()
    while pos < len(text):
        match = CONDITION_TOKEN.match(text, pos)
        if not match:
            return None
        tokens.append(match.group(1))
        pos = match.end()
        while pos < len(text) and text[pos].isspace():
            pos += 1
    at = 0

    def peek() -> str | None:
        return tokens[at] if at < len(tokens) else None

    def take() -> str:
        nonlocal at
        if at == len(tokens):
            raise _Unparsed
        at += 1
        return tokens[at - 1]

    def unary() -> bool | None:
        token = take()
        if token == "!":
            value = unary()
            return None if value is None else not value
        if token == "(":
            value = disjunction()
            if take() != ")":
                raise _Unparsed
            return value
        if token in ("||", "&&", ")"):
            raise _Unparsed
        if "(" in token:
            return None  # arch(...), os(...), compiler(...), canImport(...)
        return {"true": True, "false": False}.get(token, flags.get(token))

    def conjunction() -> bool | None:
        value = unary()
        while peek() == "&&":
            take()
            value = _and(value, unary())
        return value

    def disjunction() -> bool | None:
        value = conjunction()
        while peek() == "||":
            take()
            value = _or(value, conjunction())
        return value

    try:
        value = disjunction()
    except _Unparsed:
        return None
    return value if at == len(tokens) else None


class _Unparsed(Exception):
    """An `#if` condition condition() cannot read; it is unknown, so its block stays in."""


def compiled(text: str, flags: Mapping[str, bool]) -> str:
    """`text` with the lines a build with `flags` cannot compile blanked (line numbers kept): every block whose `#if`
    or `#elseif` is false, or whose `#else` follows a true branch. The directive lines are blanked too."""
    lines, stack, kept = [], [], True
    for line in text.splitlines():
        match = DIRECTIVE.match(line)
        if not match:
            lines.append(line if kept else "")
            continue
        kind, rest = match.group(1), match.group(2).split("//", 1)[0]
        if kind == "if":
            value = condition(rest, flags)
            stack.append([kept, value is True, value is None])  # [parent kept, a branch taken, a branch unknown]
            kept = kept and value is not False
        elif kind in ("elseif", "else") and stack:
            frame = stack[-1]
            if frame[1]:
                value = False
            elif kind == "else":
                value = None if frame[2] else True
            else:
                value = condition(rest, flags)
            kept = frame[0] and value is not False
            frame[1] = frame[1] or value is True
            frame[2] = frame[2] or value is None
        elif kind == "endif" and stack:
            kept = stack.pop()[0]
        lines.append("")
    return "\n".join(lines)


def config_flags(config: str) -> Mapping[str, bool]:
    if config not in CONFIG_FLAGS:
        raise CapabilityError(f"build config {config!r} is not one of {', '.join(CONFIG_FLAGS)}")
    return CONFIG_FLAGS[config]


def signpost_cases(text: str) -> dict[str, str]:
    """SignpostName case -> wire name, from SignpostName.swift's staticName switch."""
    return dict(STATIC_NAME.findall(text))


def tip_signpost_cases(root: Path = REPO_ROOT) -> dict[str, str]:
    path = root / SIGNPOST_NAME
    return signpost_cases(path.read_text(encoding="utf-8")) if path.is_file() else {}


def declared_lists(text: str) -> dict[str, list[str]]:
    """DebugCapabilities.swift's `emittedSignposts` (case names) and `probeEnvironment` (variables)."""
    lists = {}
    for name, body in STATIC_LIST.findall(text):
        body = "\n".join(line.split("//", 1)[0] for line in body.splitlines())
        if name == "emittedSignposts":
            lists[name] = CASE_REFERENCE.findall(body)
        elif name == "probeEnvironment":
            lists[name] = re.findall(r'"([^"]+)"', body)
    return lists


def emitted_cases(swift: str) -> set[str]:
    """The SignpostName cases one Swift source emits: queues.py's MQ5 forms and ANY_RECEIVER_EMIT."""
    queues = _load_sibling("queues")
    code = queues._code(swift, "//")
    found = {next(group for group in match.groups() if group) for match in queues.SIGNPOST_EMIT.finditer(code)}
    return found | set(ANY_RECEIVER_EMIT.findall(code))


# ---------- a commit's capabilities, from git ----------

Git = Callable[[Sequence[str]], tuple[int, str]]


def git_runner(repo: Path) -> Git:
    def run(args: Sequence[str]) -> tuple[int, str]:
        done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, errors="replace")
        return done.returncode, done.stdout

    return run


def source_capabilities(sources: Mapping[str, str], declared: str | None, cases: Mapping[str, str],
                        config: str) -> Capabilities:
    """What a `config` build of these Swift sources ({path: text}, without DebugCapabilities.swift) has: the method
    and variable literals of the code that config compiles, and the emitted signposts (DebugCapabilities.swift's
    list when the commit has it, else the cases the compiled code emits)."""
    queues = _load_sibling("queues")
    flags = config_flags(config)
    code = {path: queues._code(compiled(text, flags), "//") for path, text in sources.items()}
    joined = "\n".join(code.values())
    methods = set(METHOD_LITERAL.findall(joined))
    if declared is not None:
        methods |= set(METHOD_LITERAL.findall(queues._code(compiled(declared, flags), "//")))
        lists = declared_lists(declared)
        signposts = frozenset(cases[c] for c in lists.get("emittedSignposts", ()) if c in cases)
        environment = frozenset(lists.get("probeEnvironment", ()))
    else:
        emitted = set().union(*(emitted_cases(text) for path, text in code.items() if path != SIGNPOST_NAME))
        signposts = frozenset(cases[c] for c in emitted if c in cases)
        environment = frozenset(ENV_LITERAL.findall(joined))
    return Capabilities(SOURCE, frozenset(methods), signposts, environment, dict(cases))


class GitCapabilities:
    """A commit's capabilities from its source, per build config, cached per commit. `git` runs a git command in
    the lab's clone (a bare clone answers it too) and returns (exit code, stdout)."""

    def __init__(self, git: Git) -> None:
        self._git = git
        self._at: dict[str, dict[str, Capabilities]] = {}
        self._files: dict[tuple[str, str], bool] = {}

    @classmethod
    def of(cls, repo: Path) -> "GitCapabilities":
        return cls(git_runner(repo))

    def _show(self, sha: str, path: str) -> str | None:
        code, out = self._git(["show", f"{sha}:{path}"])
        return out if code == 0 else None

    def _paths(self, sha: str, pattern: str) -> set[str]:
        code, out = self._git(["grep", "-l", "-E", pattern, sha, "--", SWIFT_SOURCES])
        if code not in (0, 1):  # 1: no match
            raise CapabilityError(f"git grep at {sha[:12]} exited {code}")
        return {line.partition(":")[2] if line.startswith(f"{sha}:") else line for line in out.splitlines()}

    def has_file(self, sha: str, path: str) -> bool:
        key = (sha, path)
        if key not in self._files:
            self._files[key] = self._git(["cat-file", "-e", f"{sha}:{path}"])[0] == 0
        return self._files[key]

    def at(self, sha: str, config: str = DEFAULT_CONFIG) -> Capabilities:
        config_flags(config)
        if sha not in self._at:
            self._at[sha] = self._read(sha)
        return self._at[sha][config]

    def _read(self, sha: str) -> dict[str, Capabilities]:
        """Every config's capabilities of the commit, from one read of its sources."""
        if self._git(["cat-file", "-e", f"{sha}^{{commit}}"])[0] != 0:
            raise CapabilityError(f"{sha[:12]} is not a commit of the lab's clone")
        cases = signpost_cases(self._show(sha, SIGNPOST_NAME) or "")
        declared = self._show(sha, DEBUG_CAPABILITIES)
        paths = self._paths(sha, LITERAL_FILES)
        if declared is None:
            paths |= self._paths(sha, SIGNPOST_FILES)
        paths -= {DEBUG_CAPABILITIES}
        sources = {path: self._show(sha, path) or "" for path in sorted(paths)}
        return {config: source_capabilities(sources, declared, cases, config) for config in CONFIG_FLAGS}

    def missing(self, needs: Iterable[str], sha: str, config: str = DEFAULT_CONFIG) -> tuple[str, ...]:
        return missing(needs, self.at(sha, config), lambda path: self.has_file(sha, path))


class StoryNeeds:
    """The seam Pinpoint's executor and the scheduler take: (story, sha) -> the needs a build of that commit in the
    story's config lacks. A story the catalog does not know needs nothing here (the catalog lint and the runner
    refuse it)."""

    def __init__(self, needs: Mapping[str, Sequence[str]], commits: GitCapabilities,
                 configs: Mapping[str, str] | None = None) -> None:
        self._needs = {story: tuple(n) for story, n in needs.items()}
        self._configs = dict(configs or {})
        self._commits = commits

    @classmethod
    def from_catalog(cls, root: Path, commits: GitCapabilities) -> "StoryNeeds":
        catalog = _load_sibling("catalog")
        stories = catalog.load_catalog(Path(root)).stories
        return cls({s.id: s.needs for s in stories}, commits, {s.id: s.config for s in stories})

    def needs(self, story: str) -> tuple[str, ...]:
        return self._needs.get(story, ())

    def __call__(self, story: str, sha: str) -> tuple[str, ...]:
        needs = self.needs(story)
        return self._commits.missing(needs, sha, self._configs.get(story, DEFAULT_CONFIG)) if needs else ()


# ---------- what a range can say ----------

def first_with(shas: Sequence[str], need: str, lacks: Callable[[str], Sequence[str]]) -> int | None:
    """The index of the first commit of `shas` (oldest first) that has `need`, assuming that once a commit has a
    capability every later one does; None when the last commit lacks it too."""
    if need in lacks(shas[-1]):
        return None
    lo, hi = -1, len(shas) - 1  # shas[lo] lacks it (or lo = -1), shas[hi] has it
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if need in lacks(shas[mid]):
            lo = mid
        else:
            hi = mid
    return hi


def range_limits(shas: Sequence[str], needs: Iterable[str], lacks: Callable[[str], Sequence[str]]) -> list[str]:
    """One line per need some commit of the range lacks: `range limited by capability <need> since <sha>`, the first
    commit that has it, or `no commit in the range has capability <need>`."""
    lines = []
    for need in sorted(set(needs)):
        index = first_with(shas, need, lacks)
        if index is None:
            lines.append(f"no commit in the range has capability {need}")
        elif index > 0:
            lines.append(f"range limited by capability {need} since {shas[index][:12]}")
    return lines


# ---------- the tree's own claims ----------

def story_problems(stories: Iterable, tip: Callable[[str], Capabilities],
                   has_file: Callable[[str], bool]) -> list[str]:
    """Each story need a build of the tip in the story's config lacks (`tip(config)`): no build can measure it.
    A need only another config compiles (a method an `#if DEBUG` block registers, for a bench story) says so."""
    problems = []
    for story in stories:
        try:
            lacked = missing(story.needs, tip(story.config), has_file)
            for need in lacked:
                where = [c for c in CONFIG_FLAGS if c != story.config and tip(c).has(need, has_file)]
                only = f" (only a {' or '.join(where)} build has it)" if where else ""
                problems.append(f"{story.path}: needs {need}, which a {story.config} build of the tip does not "
                                f"have{only}: no build can measure it")
        except CapabilityError as error:
            problems.append(f"{story.path}: {error}")
    return problems


def check_tree(root: Path = REPO_ROOT) -> list[str]:
    """Problems with what the tip claims: an emitted signpost with no emit site, a probe variable nobody reads, a
    story need a build of the tip in the story's config lacks."""
    problems: list[str] = []
    declared_path = root / DEBUG_CAPABILITIES
    if not declared_path.is_file():
        return [f"{DEBUG_CAPABILITIES} is missing"]
    declared = declared_path.read_text(encoding="utf-8")
    lists = declared_lists(declared)
    cases = tip_signpost_cases(root)
    queues = _load_sibling("queues")
    sources, code, emitted = {}, [], set()
    for path in sorted((root / SOURCES).rglob("*.swift")):
        rel = path.relative_to(root).as_posix()
        if rel in (DEBUG_CAPABILITIES, SIGNPOST_NAME):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if METHOD_LITERAL.search(text) or ENV_LITERAL.search(text):
            sources[rel] = text
        code.append(queues._code(text, "//"))
        emitted |= emitted_cases(text)
    code = "\n".join(code)
    for case in lists.get("emittedSignposts", ()):
        if case not in cases:
            problems.append(f"emittedSignposts: {case} is not a SignpostName case with a staticName")
        elif case not in emitted:
            problems.append(f"emittedSignposts: no source emits {case}; list it in the change that adds its emitter")
    for name in lists.get("probeEnvironment", ()):
        if f'"{name}"' not in code:
            problems.append(f"probeEnvironment: no source reads {name}")
    tips: dict[str, Capabilities] = {}

    def tip(config: str) -> Capabilities:
        if config not in tips:
            tips[config] = source_capabilities(sources, declared, cases, config)
        return tips[config]

    catalog = _load_sibling("catalog")
    return problems + story_problems(catalog.load_catalog(root).stories, tip, lambda path: (root / path).is_file())


# ---------- command ----------

def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    parser.add_argument("--repo", type=Path, help="the git clone to read commits from (default: --root)")
    what = parser.add_mutually_exclusive_group(required=True)
    what.add_argument("--check", action="store_true", help="check the tree's own capability claims")
    what.add_argument("--sha", help="judge the stories against this commit's sources")
    what.add_argument("--probe", type=Path, help=f"judge the stories against a saved {PROBE_METHOD} answer")
    what.add_argument("--range", help="GOOD..BAD: where a first-parent range's capability limits are")
    parser.add_argument("--stories", help="comma-separated story ids (default: every story)")


def _first_parent(git: Git, spec: str) -> list[str]:
    good, sep, bad = spec.partition("..")
    if not sep or not good or not bad:
        raise CapabilityError(f"--range {spec!r} is not GOOD..BAD")
    code, out = git(["rev-list", "--first-parent", "--reverse", f"{good}..{bad}"])
    code_good, out_good = git(["rev-parse", "--verify", f"{good}^{{commit}}"])
    if code or code_good:
        raise CapabilityError(f"--range {spec}: git could not list it")
    return [out_good.strip(), *out.split()]


def run(command: str, args: argparse.Namespace, out=None, err=None) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    catalog = _load_sibling("catalog")
    try:
        if args.check:
            problems = check_tree(args.root)
            for problem in problems:
                print(problem, file=out)
            return 1 if problems else 0
        stories = {s.id: s for s in catalog.load_catalog(args.root).stories}
        wanted = args.stories.split(",") if args.stories else sorted(stories)
        unknown = [s for s in wanted if s not in stories]
        if unknown:
            raise CapabilityError(f"no such story: {', '.join(unknown)}")
        commits = GitCapabilities.of(args.repo or args.root)
        if args.range:
            shas = _first_parent(git_runner(args.repo or args.root), args.range)
            check = StoryNeeds({s: stories[s].needs for s in wanted}, commits, {s: stories[s].config for s in wanted})
            lines = [f"{s}: {line}" for s in wanted
                     for line in range_limits(shas, check.needs(s), lambda sha, s=s: check(s, sha))]
            for line in lines:
                print(line, file=out)
            return 1 if lines else 0
        if args.probe:
            probe = Capabilities.from_probe(json.loads(args.probe.read_text(encoding="utf-8")),
                                            tip_signpost_cases(args.root))
            judge = lambda story: missing(story.needs, probe)
        else:
            judge = lambda story: commits.missing(story.needs, args.sha, story.config)
        blocked = 0
        for story_id in wanted:
            lacked = judge(stories[story_id])
            blocked += bool(lacked)
            print(f"{story_id}\t" + (f"not-measurable: lacks {', '.join(lacked)}" if lacked else "measurable"),
                  file=out)
        return 1 if blocked else 0
    except (CapabilityError, catalog.CatalogError, OSError, ValueError) as error:
        print(f"capabilities: {error}", file=err)
        return 2


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="capabilities.py", description=LAB_COMMANDS["capabilities"])
    add_arguments("capabilities", parser)
    return run("capabilities", parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
