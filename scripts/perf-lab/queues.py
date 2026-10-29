#!/usr/bin/env python3
"""The perf program's machine queues (plans/cmux-next/chrome-parity/p12-perf-process.md section 7).

Each queue is a query over the checkout whose items are the work left: one item is one task's
unit (a file, a signpost case, a feature key, a debug method). The shell one-liners in the plan
are the reference forms; these functions are the canonical ones, with the plan's corrections:

  MQ1   private-stats    private stat helpers (def pct/percentile(s)/quantile/p95/med/median/stats,
                         stat lambdas, inline `int(len(x) * 0.95)` picks) in every perf directory;
                         ALLOWLIST and RETIRED name the files that stay, each with its reason
  MQ2   self-launch      perf benches in scripts/cmux-next that launch the app themselves instead of
                         bench_launch.BenchApp (perf-gate.py is no longer excluded)
  MQ3   p95-no-p99       scripts/cmux-next files that report p95 and never p99 (files, not lines)
  MQ5   signposts        SignpostName cases with no emitter (`case x = N` declarations, every
                         Signposter / TraceRuntime call form, doc comments skipped)
  MQ6   features         perf-path tunables and env switches not yet a feature (gen-features.py
                         --unmigrated, loaded by file path, so a seed tunable is listed)
  MQ-B  bench-migration  MQ1 | MQ2 | MQ3 by file: one file is one migration task
  MQ13  bench-gaps       debug methods and env names that bench scripts use and that a
                         `--config bench` build (DEBUG off, CMUX_BENCH_HOOKS on) does not compile
                         (DEBUG_ONLY_BY_DESIGN names the script uses that stay Debug-only, each with its reason)
  MQ15  typecheck        Swift function and closure bodies that took 100 ms or more to type-check in the builder
                         story incremental-build, one file per item: by default from the newest stored waterfall
                         run (--latest: its typecheck-queue attachment, by digest, in the lab store --db or
                         $CMUX_PERF_LAB_DB), or from a run folder (--dir) or a compiler log (--log)

    python3 scripts/perf-lab/queues.py --all --counts          # one line per queue
    python3 scripts/perf-lab/queues.py bench-migration --files # MQ-B, one path per line
    python3 scripts/perf-lab/queues.py mq5                     # items with where and why
    python3 scripts/perf-lab/queues.py bench-gaps --json
    python3 -I scripts/perf-lab/lab.py queue typecheck --latest # the same command line through lab.py

Chromium keeps its debt queues the same way: a checked-in query per kind of debt
(tools/metrics/histograms/expired_histograms_allowlist.txt and its generator, the
//tools/perf/core/perf_data_generator.py validity checks), never a hand-kept list.
The queues are reports (exit 0), not gates. Standard library only.
"""
from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import os
import re
import sqlite3
import sys
from collections.abc import Callable, Iterator
from dataclasses import asdict, dataclass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
GEN_FEATURES = os.path.join(ROOT, "scripts", "cmux-next", "gen-features.py")

SKIP_DIRS = frozenset({".git", ".build", "node_modules", "__pycache__", ".venv", "venv", "target", "tests"})


class QueueError(RuntimeError):
    """A queue cannot run on this tree (its input file is missing or unreadable)."""


@dataclass(frozen=True)
class Item:
    """One unit of queue work. `key` is what a task takes (a path, a case, a key or a name)."""

    key: str
    where: str
    detail: str = ""


# ---------------------------------------------------------------------------------------------
# Tree reading

def _read(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def _walk(root: str, top: str, suffixes: tuple[str, ...], recursive: bool = True) -> Iterator[str]:
    """Repo-relative paths under `top` ending in one of `suffixes`, sorted; SKIP_DIRS pruned."""
    base = os.path.join(root, top)
    for directory, subdirs, files in os.walk(base):
        subdirs[:] = sorted(name for name in subdirs if name not in SKIP_DIRS) if recursive else []
        for name in sorted(files):
            if name.endswith(suffixes):
                yield os.path.relpath(os.path.join(directory, name), root).replace(os.sep, "/")


def _code_lines(text: str, comment: str) -> Iterator[tuple[int, str]]:
    """(1-based line number, line) for every line that is not a whole-line comment."""
    for number, line in enumerate(text.splitlines(), 1):
        if not line.lstrip().startswith(comment):
            yield number, line


def _code(text: str, comment: str) -> str:
    """`text` with whole-line comments blanked (line numbers kept)."""
    return "\n".join("" if line.lstrip().startswith(comment) else line for line in text.splitlines())


def _first_by_key(items: list[Item]) -> list[Item]:
    """One item per key (the first), with the number of further hits in its detail."""
    grouped: dict[str, list[Item]] = {}
    for item in items:
        grouped.setdefault(item.key, []).append(item)
    out = []
    for key in sorted(grouped):
        first, more = grouped[key][0], len(grouped[key]) - 1
        out.append(Item(key, first.where, first.detail + (" (+%d more)" % more if more else "")))
    return out


# ---------------------------------------------------------------------------------------------
# MQ1: private stat functions

# Every directory that holds perf benches or their analysis. `tests` subdirectories are pruned:
# unit tests are not benches.
PERF_DIRS = ("scripts", "cmux-tui/scripts", "webviews/scripts", "tests/automation-bench/perf")
# The one shared definition, and this file (its patterns are strings).
STATS_HOME = ("scripts/perf-lab/perf_stats.py", "scripts/perf-lab/queues.py")
# Files that keep a private stat function by design.
ALLOWLIST = {
    "scripts/cmux-next/perf-budgets.py":
        "the perf cron's report job sparse-checks out only a few files; a parity test proves its pct "
        "equals perf_stats.pct (p12-perf-process.md 3.2)",
    "scripts/cmux-next/perf-cron.py":
        "the cron's own 5-run median over stored rows, not a bench percentile (p12-perf-process.md 3.2)",
}
# Hits that are not perf benches: each leaves the queue with its reason.
RETIRED = {
    "scripts/ci/ci_health_report.py": "CI queue-time report, not an app measurement",
    "scripts/ci/warm_distance.py": "CI cache warmth model, not an app measurement",
    "scripts/benchmark-dev-fleet-warm-slots.py": "dev fleet slot timing, not an app measurement",
    "scripts/mobile-latency-trace/analyze.py": "iOS program (ios/AGENTS.md), outside the macOS perf lab",
    "scripts/mobile-stability-soak/latency-probe.py": "iOS program (ios/AGENTS.md), outside the macOS perf lab",
    "scripts/cmux-next/team-vm-spike/bench.py": "one-off cloud VM spike, kept as a record",
    "scripts/cmux-next/team-vm-spike/r2put.py": "one-off cloud VM spike, kept as a record",
}

_STAT_NAMES = r"_*(?:pct|percentiles?|quantiles?|p\d{2,3}|med|median|stats)"
PRIVATE_STAT_PATTERNS = (
    ("def", re.compile(r"^\s*def\s+(%s)\s*\(" % _STAT_NAMES)),
    # A named stat lambda, or any lambda that picks an element by a length (an order statistic).
    ("lambda", re.compile(r"\b(%s)\s*=\s*lambda\b" % _STAT_NAMES)),
    ("lambda", re.compile(r"\blambda\b[^:\n]*:\s*\w+\[[^\]\n]*\blen\(")),
    # An inline rank: int(len(x) * 0.95), int(0.9 * len(x)), int(p * len(x)), round(0.95 * (len(x) - 1)),
    # (len(x) - 1) * q.
    ("inline", re.compile(
        r"\b(?:int|round)\(\s*\(?\s*len\([^()\n]*\)\s*(?:-\s*1\s*\))?\s*\*\s*(?:0?\.\d+|[pq]|fraction|quantile)\b")),
    ("inline", re.compile(
        r"\b(?:int|round)\(\s*(?:0?\.\d+|[pq]|fraction|quantile)\s*\*\s*\(?\s*len\(")),
    ("inline", re.compile(r"\(\s*len\([^()\n]*\)\s*-\s*1\s*\)\s*\*\s*(?:0?\.\d+|[pq]|fraction|quantile)\b")),
    ("inline", re.compile(r"\bstatistics\.quantiles\(")),
)


def _delegates_to_shared(lines: list[str], index: int) -> bool:
    """Whether the function defined at `lines[index]` calls perf_stats in its body (a wrapper, not a copy),
    on the def line itself (`def pct(v, p): return perf_stats.pct(v, p)`) or in the indented block."""
    if "perf_stats." in lines[index].split(":", 1)[-1]:
        return True
    indent = len(lines[index]) - len(lines[index].lstrip())
    for line in lines[index + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            return False
        if "perf_stats." in line:
            return True
    return False


def _private_stat_hits(root: str) -> Iterator[Item]:
    for top in PERF_DIRS:
        for rel in _walk(root, top, (".py",)):
            if rel in STATS_HOME:
                continue
            lines = _read(os.path.join(root, rel)).splitlines()
            for number, line in enumerate(lines, 1):
                if line.lstrip().startswith("#"):
                    continue
                for kind, pattern in PRIVATE_STAT_PATTERNS:
                    if pattern.search(line):
                        if not (kind == "def" and _delegates_to_shared(lines, number - 1)):
                            yield Item(rel, "%s:%d" % (rel, number), "%s: %s" % (kind, line.strip()[:80]))
                        break


def private_stats(root: str = ROOT) -> list[Item]:
    """MQ1. Files with a private stat helper, minus ALLOWLIST and RETIRED."""
    seen = {}
    for item in _private_stat_hits(root):
        seen.setdefault(item.key, []).append(item)
    for path in sorted(set(ALLOWLIST) | set(RETIRED)):
        if path not in seen:
            print("warning: MQ1 keeps %s, which defines no private stat function now; drop the entry" % path,
                  file=sys.stderr)
    hits = [item for path, items in seen.items() if path not in ALLOWLIST and path not in RETIRED for item in items]
    return _first_by_key(hits)


# ---------------------------------------------------------------------------------------------
# MQ2: benches that launch their own app

BENCH_DIR = "scripts/cmux-next"
BENCH_NAME = re.compile(
    r"bench|perf|stress|typing|idle|launch|anim|memory|power|churn|hibern|tab[_-]switch|soak|lag|frames"
    r"|resize|paint|zoom|storm")
SELF_LAUNCH = re.compile(r'Contents/MacOS|"open",\s*"-n"|\blaunch_app\b|^[ \t]*def launch', re.M)
USES_BENCH_LAUNCH = re.compile(r"\bbench_launch\b|\bBenchApp\b")
SELF_LAUNCH_EXEMPT = {
    "perf-cron.py": "runs the other benches; it never launches the app itself",
    "bench_launch.py": "the shared launch",
}
# Scripts whose name matches BENCH_NAME but that are functional checks, not perf benches: MQ2 and MQ13
# both leave them out.
NOT_A_BENCH = {
    "launch-env-fence-live.py": "checks the launch environment (so it must launch by itself), not a perf bench",
}


def _is_bench_name(name: str) -> bool:
    return bool(BENCH_NAME.search(name)) and name not in NOT_A_BENCH


def self_launch(root: str = ROOT) -> list[Item]:
    """MQ2. Perf benches in scripts/cmux-next that start the app without bench_launch."""
    items = []
    for rel in _walk(root, BENCH_DIR, (".py",), recursive=False):
        name = os.path.basename(rel)
        if name in SELF_LAUNCH_EXEMPT or not _is_bench_name(name):
            continue
        code = _code(_read(os.path.join(root, rel)), "#")
        if USES_BENCH_LAUNCH.search(code):
            continue
        match = SELF_LAUNCH.search(code)
        if match:
            line = code.count("\n", 0, match.start()) + 1
            items.append(Item(rel, "%s:%d" % (rel, line), "launches with %r" % match.group(0).strip()))
    return items


# ---------------------------------------------------------------------------------------------
# MQ3: p95 without p99

P95_EXEMPT = {
    "guardrails.py": "names p95 in rule text; not a bench",
    "perf-cron.py": "stores the rows the benches report",
}


def p95_without_p99(root: str = ROOT) -> list[Item]:
    """MQ3. scripts/cmux-next files that mention p95 and never p99 (rg -l p95 | rg --files-without-match p99)."""
    items = []
    for rel in _walk(root, BENCH_DIR, (".py",), recursive=False):
        if os.path.basename(rel) in P95_EXEMPT:
            continue
        text = _read(os.path.join(root, rel))
        if "p95" in text and "p99" not in text:
            items.append(Item(rel, "%s:%d" % (rel, text.count("\n", 0, text.index("p95")) + 1), "p95, no p99"))
    return items


# ---------------------------------------------------------------------------------------------
# MQ-B: the bench-migration queue

def bench_migration(root: str = ROOT) -> list[Item]:
    """MQ-B. MQ1 | MQ2 | MQ3 by file; the detail names the queues each file is in."""
    queues: dict[str, list[str]] = {}
    for name, run in (("MQ1", private_stats), ("MQ2", self_launch), ("MQ3", p95_without_p99)):
        for item in run(root):
            queues.setdefault(item.key, []).append(name)
    return [Item(path, path, ",".join(names)) for path, names in sorted(queues.items())]


# ---------------------------------------------------------------------------------------------
# MQ5: SignpostName cases with no emitter

SIGNPOST_SOURCES = "Packages/macOS/CmuxNext/Sources"
SIGNPOST_NAME = SIGNPOST_SOURCES + "/CmuxNextSignposts/SignpostName.swift"
SIGNPOST_CASE = re.compile(r"^\s+case\s+(\w+)\s*(?:=\s*\d+)?\s*$", re.M)
# Signposter (os_signpost) and TraceRuntime (ring) entry points that take a SignpostName first.
SIGNPOST_CALLS = (
    "begin", "end", "endSpanningNestedLoop", "interval", "event", "asyncBegin", "asyncEnd",
    "flowOut", "flowIn", "counter",
)
# The receivers of those calls: `Signposter` and its categories (`Signposter.stall`), a `signposter` or
# `poster` value, and the TraceRuntime value (`trace`, `runtime`). Other types share the call and case
# names (HistogramID's `.counter(.cefPump`, a rename's `.begin(.direct`), so any other receiver is not
# an emit. The plan's reference form (p12-perf-process.md section 7) keys on the receiver the same way.
SIGNPOST_RECEIVER = r"(?:\bSignposter(?:\.[a-z]\w*)?|\b\w*[sS]ignposter|\bposter|\btrace|\bruntime)\??\s*"

# An emit: a call above on a signpost receiver with the case first (`.begin(.x`, `.begin(SignpostName.x`,
# across lines), the os_signpost static name (`SignpostName.x.staticName`), a typed binding a call
# takes later (`let name: SignpostName = .x`), or the name an emitter is made with, its `signpost:`
# argument (`SwitchFrameTimer(owner: "debug.workspace_switch", signpost: SignpostName.switchWorkspace)`
# begins and ends that interval on every switch). A `case .x:` in a switch over the catalog is not an emit.
SIGNPOST_EMIT = re.compile(
    SIGNPOST_RECEIVER + r"\.(?:%s)\(\s*(?:SignpostName)?\.(\w+)\b" % "|".join(SIGNPOST_CALLS)
    + r"|\bSignpostName\.(\w+)\.staticName\b"
    + r"|:\s*SignpostName\??\s*=\s*(?:SignpostName)?\.(\w+)\b"
    + r"|\bsignpost:\s*(?:SignpostName)?\.(\w+)\b")


def signpost_cases(root: str = ROOT) -> list[str]:
    path = os.path.join(root, SIGNPOST_NAME)
    if not os.path.isfile(path):
        raise QueueError("%s is missing" % SIGNPOST_NAME)
    return SIGNPOST_CASE.findall(_read(path))


def unemitted_signposts(root: str = ROOT) -> list[Item]:
    """MQ5. Cases of SignpostName that no source outside SignpostName.swift emits."""
    cases = signpost_cases(root)
    emitted = set()
    for rel in _walk(root, SIGNPOST_SOURCES, (".swift",)):
        if rel == SIGNPOST_NAME:
            continue
        code = _code(_read(os.path.join(root, rel)), "//")
        for match in SIGNPOST_EMIT.finditer(code):
            emitted.add(next(group for group in match.groups() if group))
    return [Item(case, SIGNPOST_NAME, "no emitter") for case in cases if case not in emitted]


# ---------------------------------------------------------------------------------------------
# MQ6: perf-path switches not yet a feature

def _gen_features():
    name = "perf_lab_gen_features"
    if name in sys.modules:
        return sys.modules[name]
    if not os.path.isfile(GEN_FEATURES):
        raise QueueError("scripts/cmux-next/gen-features.py is missing (task 090)")
    spec = importlib.util.spec_from_file_location(name, GEN_FEATURES)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # its dataclasses look their module up while it loads
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


def unmigrated_features(root: str = ROOT) -> list[Item]:
    """MQ6. gen-features.py's --unmigrated rows (seed and perf-owned Bool tunables, env switches)."""
    module = _gen_features()
    features, errors, _ = module.load_features(root, datetime.date.today())
    if errors:
        raise QueueError("schemas/features/features.d is invalid: " + "; ".join(errors[:3]))
    rows, stale = module.unmigrated(root, features)
    for seed in stale:
        print("warning: the MQ6 seed %s matches no declared tunable or env read" % seed, file=sys.stderr)
    return [Item(key, where, "not a feature") for key, where in rows]


# ---------------------------------------------------------------------------------------------
# MQ13: bench-config gaps

# What `scripts/reload.sh --config bench` defines: -DCMUX_BENCH_HOOKS only, no DEBUG. `--config
# bench-checks` adds -DCMUX_BLOCKING_CHECKS (a superset), so a name compiled into bench is in both, and a
# name only under `#if DEBUG || CMUX_BLOCKING_CHECKS` is a gap. The fleet Macs are arm64, the app macOS only.
BENCH_DEFINES = frozenset({"CMUX_BENCH_HOOKS"})
BENCH_SCRIPT_DIRS = ("scripts/cmux-next", "scripts/perf-lab", "scripts/measure", "scripts/perf-bench", "scripts/perf")
DEBUG_METHOD = re.compile(r"""["'](debug\.[a-z0-9_.]*[a-z0-9_])["']""")
ENV_NAME = re.compile(r"\b(CMUX_[A-Z0-9_]*[A-Z0-9])\b")
SWIFT_DEBUG_METHOD = re.compile(r'"(debug\.[a-z0-9_.]*[a-z0-9_])"')
SWIFT_ENV_NAME = re.compile(r'"(CMUX_[A-Z0-9_]*[A-Z0-9])"')
# Scripts that measure although their name and launch do not say so.
MEASURING_SCRIPTS = {
    "remote-browser-local-live.py": "--stats measures frame rate, bitrate and input to frame (task 221)",
    "child-crash-e2e.py": "becomes the crash survival timing story (task 036)",
}
# Script uses of a Debug-only name that stay Debug-only on purpose, by (name, script), each with its
# reason: an option the person adds for diagnosis, which the measurement does not need. MQ13 still
# lists the name for every other script that uses it (trace.py's and cef-idle-probe.py's
# remote-debugging-port, which their measurement needs, are gaps).
_EXTRA_SWITCHES_OPTION = ("an optional extra Chromium switch the person passes for diagnosis; a bench build "
                          "takes only the Web Page Replay pair, through CMUX_NEXT_BENCH_CEF_SWITCHES (task 221)")
DEBUG_ONLY_BY_DESIGN = {
    ("CMUX_NEXT_CEF_EXTRA_SWITCHES", "scripts/cmux-next/bench_renderer_sharing.py"): "--cef-switches: " + _EXTRA_SWITCHES_OPTION,
    ("CMUX_NEXT_CEF_EXTRA_SWITCHES", "scripts/cmux-next/bench_memory.py"): "--cef-switches: " + _EXTRA_SWITCHES_OPTION,
    ("CMUX_NEXT_CEF_EXTRA_SWITCHES", "scripts/cmux-next/bench-webui.py"):
        "--page-code-cache: p13-webui-052's spike arm, an engine no build ships; both arms run the same Debug build, "
        "and a run whose renderers lack the switch is refused",
    ("CMUX_NEXT_CEF_EXTRA_SWITCHES", "scripts/cmux-next/bench_power.py"): "an --env example in its help text only",
    ("CMUX_NEXT_CEF_EXTRA_SWITCHES", "scripts/cmux-next/browser-idle-cost-live.py"): "an --env example in its help text only",
    ("CMUX_NEXT_CHROMIUM_HOST_SWITCHES", "scripts/cmux-next/chromium-host-bench.py"):
        "--host-switches: optional host switches for diagnosis (child logging, no-sandbox); a bench build measures "
        "the host with the switches it ships with (task 221)",
}
QUEUES_SOURCE = "scripts/perf-lab/queues.py"
_PLATFORM = {"os": {"macOS"}, "arch": {"arm64"}, "targetEnvironment": set()}
_CONDITION_TOKEN = re.compile(r"\s*(\|\||&&|!|\(|\)|\w+\([^()]*\)|\w+)")


class _Condition:
    """A `#if` condition under the bench defines: identifiers, ||, &&, !, parentheses and
    os()/arch()/canImport()/compiler()/swift()/targetEnvironment()/hasFeature() calls."""

    def __init__(self, text: str, defines: frozenset[str]):
        self.tokens, self.defines, position = [], defines, 0
        text = text.split("//")[0].strip()
        while position < len(text):
            match = _CONDITION_TOKEN.match(text, position)
            if not match or not match.group(1):
                raise QueueError("cannot read #if condition %r" % text)
            self.tokens.append(match.group(1))
            position = match.end()
        self.position = 0

    def value(self) -> bool:
        result = self._or()
        if self.position != len(self.tokens):
            raise QueueError("cannot read #if condition %r" % " ".join(self.tokens))
        return result

    def _next(self):
        token = self.tokens[self.position] if self.position < len(self.tokens) else None
        self.position += 1
        return token

    def _peek(self):
        return self.tokens[self.position] if self.position < len(self.tokens) else None

    def _or(self) -> bool:
        result = self._and()
        while self._peek() == "||":
            self._next()
            result = self._and() or result
        return result

    def _and(self) -> bool:
        result = self._not()
        while self._peek() == "&&":
            self._next()
            result = self._not() and result
        return result

    def _not(self) -> bool:
        if self._peek() == "!":
            self._next()
            return not self._not()
        token = self._next()
        if token == "(":
            result = self._or()
            if self._next() != ")":
                raise QueueError("unbalanced #if condition %r" % " ".join(self.tokens))
            return result
        call = re.fullmatch(r"(\w+)\(([^()]*)\)", token or "")
        if call:
            name, argument = call.group(1), call.group(2).strip()
            return argument in _PLATFORM[name] if name in _PLATFORM else True
        if token is None or not re.fullmatch(r"\w+", token):
            raise QueueError("cannot read #if condition %r" % " ".join(self.tokens))
        return token == "true" or token in self.defines


def compiled_lines(text: str, defines: frozenset[str] = BENCH_DEFINES) -> list[bool]:
    """Per line of a Swift file, whether a build with `defines` compiles it (#if/#elseif/#else/#endif)."""
    stack: list[tuple[bool, bool]] = []  # (this branch taken, an earlier branch of the group taken)
    out = []
    for line in text.splitlines():
        stripped = line.strip()
        directive = re.match(r"#(if|elseif|else|endif)\b(.*)", stripped)
        if directive:
            kind, rest = directive.group(1), directive.group(2)
            if kind == "if":
                taken = _Condition(rest, defines).value()
                stack.append((taken, taken))
            elif kind == "elseif" and stack:
                _, done = stack[-1]
                taken = not done and _Condition(rest, defines).value()
                stack[-1] = (taken, done or taken)
            elif kind == "else" and stack:
                _, done = stack[-1]
                stack[-1] = (not done, True)
            elif kind == "endif" and stack:
                stack.pop()
            out.append(False)
            continue
        out.append(all(taken for taken, _ in stack))
    return out


def _bench_script_names(root: str) -> dict[str, dict[str, list[str]]]:
    """{"method"|"env": {name: [script paths]}} for the bench scripts: perf-named, MEASURING_SCRIPTS or
    BenchApp users, minus NOT_A_BENCH (the same exclusions as MQ2)."""
    used: dict[str, dict[str, list[str]]] = {"method": {}, "env": {}}
    for top in BENCH_SCRIPT_DIRS:
        for rel in _walk(root, top, (".py", ".sh"), recursive=False):
            if rel == QUEUES_SOURCE:  # names this file lists (DEBUG_ONLY_BY_DESIGN) are not uses
                continue
            code = _code(_read(os.path.join(root, rel)), "#")
            name = os.path.basename(rel)
            if name in NOT_A_BENCH or not (
                    _is_bench_name(name) or name in MEASURING_SCRIPTS or USES_BENCH_LAUNCH.search(code)):
                continue
            for kind, pattern in (("method", DEBUG_METHOD), ("env", ENV_NAME)):
                for name in sorted(set(pattern.findall(code))):
                    used[kind].setdefault(name, []).append(rel)
    return used


def bench_gaps(root: str = ROOT) -> list[Item]:
    """MQ13. Names bench scripts use whose every Swift mention is compiled out of a bench build."""
    used = _bench_script_names(root)
    sites: dict[str, list[tuple[str, bool]]] = {}
    for rel in _walk(root, "Packages/macOS", (".swift",)):
        if "/Tests/" in rel:
            continue
        text = _read(os.path.join(root, rel))
        if '"debug.' not in text and '"CMUX_' not in text:
            continue
        compiled = compiled_lines(text)
        for number, line in _code_lines(text, "//"):
            for pattern in (SWIFT_DEBUG_METHOD, SWIFT_ENV_NAME):
                for name in pattern.findall(line):
                    sites.setdefault(name, []).append(("%s:%d" % (rel, number), compiled[number - 1]))
    items = []
    for kind in ("method", "env"):
        for name, scripts in sorted(used[kind].items()):
            found = sites.get(name)
            scripts = [script for script in scripts if (name, script) not in DEBUG_ONLY_BY_DESIGN]
            if not scripts:
                continue
            if found and not any(bench for _, bench in found):
                more = " (+%d more)" % (len(scripts) - 1) if len(scripts) > 1 else ""
                items.append(Item(name, found[0][0], "%s, Debug only; used by %s%s" % (kind, scripts[0], more)))
    return items


# ---------------------------------------------------------------------------------------------
# MQ15: slow type-check bodies from the builder story incremental-build

INCREMENTAL_BUILD_STORY = os.path.join(HERE, "stories", "incremental_build.py")
DB_ENV = "CMUX_PERF_LAB_DB"


@dataclass(frozen=True)
class TypecheckSource:
    """Where MQ15 reads the queue: a compiler log, a run folder, or (neither) the lab store's newest run."""

    db: str | None = None
    run_dir: str | None = None
    log: str | None = None


def _incremental_build():
    name = "perf_lab_incremental_build_story"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, INCREMENTAL_BUILD_STORY)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        try:
            spec.loader.exec_module(module)
        except BaseException:
            del sys.modules[name]
            raise
    return sys.modules[name]


def _stored_typecheck_queue(story, db: str | None) -> dict:
    """The typecheck-queue attachment of the newest incremental-build waterfall run in the lab store."""
    db = db or os.environ.get(DB_ENV)
    if not db:
        raise QueueError(f"no lab store: pass --db or set ${DB_ENV}, or read a run folder (--dir) or a log (--log)")
    if not os.path.isfile(db):
        raise QueueError(f"{db}: no lab store there")
    try:
        lab = story.store.Store(db)
    except (story.store.StoreError, sqlite3.Error) as error:
        raise QueueError(f"{db}: {error}") from None
    try:
        run = lab.latest_run(story.STORY)
        if run is None:
            raise QueueError(f"{db}: no {story.STORY} waterfall run stored yet")
        where = f"run {run['run_uuid']} at {run['sha'][:12]}"
        digest = next((item["digest"] for item in json.loads(run["attachments_json"])
                       if isinstance(item, dict) and item.get("kind") == story.QUEUE_KIND), None)
        if digest is None:
            raise QueueError(f"{where} has no {story.QUEUE_KIND} attachment (its warm Swift build failed)")
        data = lab.attachment(digest)
    except sqlite3.Error as error:
        raise QueueError(f"{db}: {error} (a store older than this lab.py: ingest once to migrate it)") from None
    finally:
        lab.close()
    if data is None:
        raise QueueError(f"{where} names {story.QUEUE_KIND} {digest} and the store does not hold it; ingest the "
                         "run's result folder again")
    return json.loads(data)


def typecheck_document(root: str, source: TypecheckSource) -> dict:
    """The MQ15 queue document (stories/incremental_build.py typecheck_queue) from SOURCE."""
    story = _incremental_build()
    if source.log is not None:
        try:
            return story.typecheck_queue(_read(source.log), story.Path(root))
        except OSError as error:
            raise QueueError(f"{source.log}: {error}") from None
    if source.run_dir is not None:
        path = os.path.join(source.run_dir, story.QUEUE_FILE)
        try:
            return json.loads(_read(path))
        except (OSError, ValueError) as error:
            raise QueueError(f"{path}: {error}") from None
    return _stored_typecheck_queue(story, source.db)


def _body(body: dict) -> str:
    name = "closure" if body["declaration"] == "closure" else f"{body['declaration']} {body['subject']}"
    return f"{name} :{body['line']} {body['ms']:g} ms"


def slow_typecheck(root: str = ROOT, source: TypecheckSource | None = None) -> list[Item]:
    """MQ15: one item per file, files by their slowest body then path (the story's order)."""
    queue = typecheck_document(root, source or TypecheckSource())
    return [Item(task["file"], f"{task['file']}:{task['functions'][0]['line']}",
                 ", ".join(_body(body) for body in task["functions"]))
            for task in queue["tasks"]]


# ---------------------------------------------------------------------------------------------
# Catalog and command line

@dataclass(frozen=True)
class Queue:
    mq: str
    name: str
    title: str
    run: Callable[..., list[Item]]
    reads_typecheck_source: bool = False  # run(root, TypecheckSource) instead of run(root)


QUEUES = (
    Queue("MQ1", "private-stats", "private stat functions", private_stats),
    Queue("MQ2", "self-launch", "perf benches that launch their own app", self_launch),
    Queue("MQ3", "p95-no-p99", "p95 without p99", p95_without_p99),
    Queue("MQ5", "signposts", "SignpostName cases with no emitter", unemitted_signposts),
    Queue("MQ6", "features", "perf-path tunables not yet features", unmigrated_features),
    Queue("MQ-B", "bench-migration", "bench-migration queue (MQ1 | MQ2 | MQ3)", bench_migration),
    Queue("MQ13", "bench-gaps", "bench-config gaps", bench_gaps),
    Queue("MQ15", "typecheck", "Swift bodies at the 100 ms type-check limit or over (incremental-build)",
          slow_typecheck, reads_typecheck_source=True),
)

# lab.py reads this literal with ast; `lab.py queue ...` takes this module's command line.
LAB_COMMANDS = {"queue": "the perf program's machine queues (MQ1..MQ15): queue NAME | --all [--counts|--files|--json]"}


def find(name: str) -> Queue:
    wanted = name.lower()
    for queue in QUEUES:
        if wanted in (queue.mq.lower(), queue.name, queue.mq.lower().replace("-", "")):
            return queue
    raise QueueError("unknown queue %r; known: %s" % (name, ", ".join(q.name for q in QUEUES)))


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("queue", nargs="?", help="a queue name or MQ id (%s)" % ", ".join(q.name for q in QUEUES))
    parser.add_argument("--all", action="store_true", help="every queue")
    shape = parser.add_mutually_exclusive_group()
    shape.add_argument("--counts", "--count", action="store_true", help="only the number of items")
    shape.add_argument("--files", action="store_true", help="only the item keys, one per line")
    shape.add_argument("--json", action="store_true", help="items as JSON")
    typecheck = parser.add_argument_group("MQ15 typecheck", "where the type-check queue comes from")
    source = typecheck.add_mutually_exclusive_group()
    source.add_argument("--latest", action="store_true",
                        help="the newest stored incremental-build waterfall run's attachment (the default)")
    source.add_argument("--dir", default=None, help="a story run's output folder (its typecheck-queue.json)")
    source.add_argument("--log", default=None, help="a compiler log of a -warn-long-function-bodies=100 build")
    typecheck.add_argument("--db", default=None, help=f"the lab store for --latest (default ${DB_ENV})")
    parser.add_argument("--root", default=ROOT, help=argparse.SUPPRESS)


def _run_queue(queue: Queue, args: argparse.Namespace) -> list[Item]:
    if queue.reads_typecheck_source:
        return queue.run(args.root, TypecheckSource(db=args.db, run_dir=args.dir, log=args.log))
    return queue.run(args.root)


def run(command: str, args: argparse.Namespace) -> int:
    if bool(args.all) == bool(args.queue):
        print("queues: name one queue or pass --all", file=sys.stderr)
        return 2
    try:
        queues = list(QUEUES) if args.all else [find(args.queue)]
    except QueueError as error:
        print(f"queues: {error}", file=sys.stderr)
        return 2
    results = {}
    for queue in queues:
        try:
            results[queue] = _run_queue(queue, args)
        except QueueError as error:
            print("%s %s: %s" % (queue.mq, queue.name, error), file=sys.stderr)
            results[queue] = None
    if args.json:
        print(json.dumps({q.mq: None if items is None else [asdict(item) for item in items]
                          for q, items in results.items()}, indent=2))
    for queue, items in results.items() if not args.json else ():
        if args.counts:
            print("%s\t%s\t%s" % (queue.mq, queue.name, "error" if items is None else len(items)))
            continue
        if args.all and not args.files:
            print("== %s %s: %s" % (queue.mq, queue.name, queue.title))
        for item in items or ():
            print(item.key if args.files else "%s\t%s\t%s" % (item.key, item.where, item.detail))
        if not args.files:
            print("%s items" % ("error" if items is None else len(items)))
    return 1 if any(items is None for items in results.values()) else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    add_arguments("queue", parser)
    args = parser.parse_args(argv)
    if bool(args.all) == bool(args.queue):
        parser.error("name one queue or pass --all")
    if args.queue:
        try:
            find(args.queue)
        except QueueError as error:
            parser.error(str(error))
    return run("queue", args)


if __name__ == "__main__":
    sys.exit(main())
