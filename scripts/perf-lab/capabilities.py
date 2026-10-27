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
  `debug:` and `env:` are the method and variable literals in the app sources; `signpost:` the emitted list of
  DebugCapabilities.swift, or for a commit before it the cases queues.py's MQ5 scan finds emitted; `file:` whether
  the commit has the file. Each answer is cached per commit (a commit never changes).
`privilege:` is a host property, which host_env.py checks on the lab host; no build lacks it.

Commands (also `lab.py capabilities ...`):

    python3 -I scripts/perf-lab/capabilities.py --check
    python3 -I scripts/perf-lab/capabilities.py --sha SHA [--stories a,b]
    python3 -I scripts/perf-lab/capabilities.py --probe FILE [--stories a,b]
    python3 -I scripts/perf-lab/capabilities.py --range GOOD..BAD --stories a

`--check` proves the tree's own claims: every emitted signpost DebugCapabilities.swift lists has an emit site,
every probe variable it lists has a reader, and every story need names something the tip has. `--sha` and `--probe`
print, per story, `measurable` or `not-measurable: lacks <need>, ...`. `--range` prints `range limited by
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

METHOD_LITERAL = re.compile(r'"(debug\.[a-z0-9_.]+)"')
ENV_LITERAL = re.compile(r'"(CMUX_NEXT_[A-Z0-9_]+)"')
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
    signposts: frozenset[str]
    environment: frozenset[str]
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

    def has(self, need: str, has_file: Callable[[str], bool] | None = None) -> bool:
        kind, name = parse_need(need)
        if kind == "debug":
            return name in self.methods
        if kind == "signpost":
            return self.cases.get(name, name) in self.signposts
        if kind == "env":
            return name in self.environment
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


class GitCapabilities:
    """A commit's capabilities from its source, cached per commit. `git` runs a git command in the lab's clone
    (a bare clone answers it too) and returns (exit code, stdout)."""

    def __init__(self, git: Git) -> None:
        self._git = git
        self._at: dict[str, Capabilities] = {}
        self._files: dict[tuple[str, str], bool] = {}

    @classmethod
    def of(cls, repo: Path) -> "GitCapabilities":
        return cls(git_runner(repo))

    def _show(self, sha: str, path: str) -> str | None:
        code, out = self._git(["show", f"{sha}:{path}"])
        return out if code == 0 else None

    def _grep(self, sha: str, pattern: re.Pattern) -> frozenset[str]:
        code, out = self._git(["grep", "-h", "-o", "-E", pattern.pattern, sha, "--", SOURCES])
        if code not in (0, 1):  # 1: no match
            raise CapabilityError(f"git grep at {sha[:12]} exited {code}")
        return frozenset(pattern.findall(out))

    def has_file(self, sha: str, path: str) -> bool:
        key = (sha, path)
        if key not in self._files:
            self._files[key] = self._git(["cat-file", "-e", f"{sha}:{path}"])[0] == 0
        return self._files[key]

    def at(self, sha: str) -> Capabilities:
        if sha not in self._at:
            self._at[sha] = self._read(sha)
        return self._at[sha]

    def _read(self, sha: str) -> Capabilities:
        if self._git(["cat-file", "-e", f"{sha}^{{commit}}"])[0] != 0:
            raise CapabilityError(f"{sha[:12]} is not a commit of the lab's clone")
        cases = signpost_cases(self._show(sha, SIGNPOST_NAME) or "")
        declared = self._show(sha, DEBUG_CAPABILITIES)
        if declared is not None:
            lists = declared_lists(declared)
            signposts = frozenset(cases[c] for c in lists.get("emittedSignposts", ()) if c in cases)
            environment = frozenset(lists.get("probeEnvironment", ()))
        else:
            signposts = frozenset(cases[c] for c in self._scanned_emits(sha, set(cases)) if c in cases)
            environment = self._grep(sha, ENV_LITERAL)
        return Capabilities(SOURCE, self._grep(sha, METHOD_LITERAL), signposts, environment, cases)

    def _scanned_emits(self, sha: str, cases: set[str]) -> set[str]:
        """The cases emitted in the commit's sources (a commit before DebugCapabilities.swift)."""
        code, out = self._git(["grep", "-l", "-E", "SignpostName|[sS]ignposter|signpost:", sha, "--", SOURCES])
        if code not in (0, 1):
            raise CapabilityError(f"git grep at {sha[:12]} exited {code}")
        emitted: set[str] = set()
        for line in out.splitlines():
            path = line.partition(":")[2] if line.startswith(f"{sha}:") else line
            if path == SIGNPOST_NAME:
                continue
            emitted |= emitted_cases(self._show(sha, path) or "")
        return emitted & cases

    def missing(self, needs: Iterable[str], sha: str) -> tuple[str, ...]:
        return missing(needs, self.at(sha), lambda path: self.has_file(sha, path))


class StoryNeeds:
    """The seam Pinpoint's executor and the scheduler take: (story, sha) -> the needs that commit lacks.
    A story the catalog does not know needs nothing here (the catalog lint and the runner refuse it)."""

    def __init__(self, needs: Mapping[str, Sequence[str]], commits: GitCapabilities) -> None:
        self._needs = {story: tuple(n) for story, n in needs.items()}
        self._commits = commits

    @classmethod
    def from_catalog(cls, root: Path, commits: GitCapabilities) -> "StoryNeeds":
        catalog = _load_sibling("catalog")
        return cls({s.id: s.needs for s in catalog.load_catalog(Path(root)).stories}, commits)

    def needs(self, story: str) -> tuple[str, ...]:
        return self._needs.get(story, ())

    def __call__(self, story: str, sha: str) -> tuple[str, ...]:
        needs = self.needs(story)
        return self._commits.missing(needs, sha) if needs else ()


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

def check_tree(root: Path = REPO_ROOT) -> list[str]:
    """Problems with what the tip claims: an emitted signpost with no emit site, a probe variable nobody reads, a
    story need the tip lacks."""
    problems: list[str] = []
    declared_path = root / DEBUG_CAPABILITIES
    if not declared_path.is_file():
        return [f"{DEBUG_CAPABILITIES} is missing"]
    declared = declared_path.read_text(encoding="utf-8")
    lists = declared_lists(declared)
    cases = tip_signpost_cases(root)
    queues = _load_sibling("queues")
    code, emitted = [], set()
    for path in sorted((root / SOURCES).rglob("*.swift")):
        rel = path.relative_to(root).as_posix()
        if rel in (DEBUG_CAPABILITIES, SIGNPOST_NAME):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
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
    tip = Capabilities(SOURCE, frozenset(METHOD_LITERAL.findall(code + declared)),
                       frozenset(cases[c] for c in lists.get("emittedSignposts", ()) if c in cases),
                       frozenset(lists.get("probeEnvironment", ())), cases)
    catalog = _load_sibling("catalog")
    for story in catalog.load_catalog(root).stories:
        try:
            lacked = missing(story.needs, tip, lambda path: (root / path).is_file())
        except CapabilityError as error:
            problems.append(f"{story.path}: {error}")
            continue
        for need in lacked:
            problems.append(f"{story.path}: needs {need}, which the tip does not have: no build can measure it")
    return problems


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
            check = StoryNeeds({s: stories[s].needs for s in wanted}, commits)
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
            judge = lambda story: commits.missing(story.needs, args.sha)
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
