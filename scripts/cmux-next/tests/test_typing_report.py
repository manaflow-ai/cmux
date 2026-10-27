#!/usr/bin/env python3
"""The typing benches' shared numbers (typing_report.py, p12-perf-process-050): percentiles from perf_stats with the
old report keys and p99, the result-v1 stories and metrics that stories.d matches, and the migration queues
(MQ1-MQ3) listing none of the four benches.

Runs on any host (Linux included): no app, no fleet, no network.

    python3 -m unittest scripts/cmux-next/tests/test_typing_report.py
"""

from __future__ import annotations

import ast
import importlib.util
import json
import re
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = HERE.parent / "perf-lab"
sys.path.insert(0, str(HERE))
import typing_report  # noqa: E402


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


catalog = load("perf_lab_catalog", PERF_LAB / "catalog.py")
queues = load("perf_lab_queues", PERF_LAB / "queues.py")
bench_typing = load("bench_typing", HERE / "bench-typing.py")

BENCHES = ("typing-frame-bench.py", "automation-typing-bench.py", "sidebar-churn-typing.py", "bench-typing.py")
# The fixed vector of the commit's old-vs-new table: 20 key-to-frame samples (ms) with a long tail.
VECTOR = [4.1, 4.3, 4.4, 4.6, 4.7, 4.9, 5.0, 5.2, 5.3, 5.5, 5.8, 6.0, 6.4, 6.9, 7.5, 8.2, 9.6, 12.0, 15.5, 31.0]


def old_round_rank(values, q):
    """typing-frame-bench, automation-typing-bench and sidebar-churn-typing before: s[round((n - 1) * q)]."""
    s = sorted(values)
    return s[min(len(s) - 1, int(round((len(s) - 1) * q)))]


class DistributionTests(unittest.TestCase):
    def test_percentiles_are_perf_stats_linear_interpolation(self) -> None:
        stats = typing_report.distribution(VECTOR)
        self.assertEqual(list(stats), ["n", "p50", "p95", "p99", "max", "mean"])
        self.assertEqual(stats["n"], 20)
        for name, q in (("p50", .5), ("p95", .95), ("p99", .99)):
            self.assertEqual(stats[name], round(typing_report.perf_stats.pct(VECTOR, q), 2))
        self.assertEqual((stats["p50"], stats["p95"], stats["p99"], stats["max"]), (5.65, 16.28, 28.05, 31.0))
        self.assertEqual(stats["mean"], 7.85)

    def test_old_definitions_on_the_fixed_vector(self) -> None:
        # The commit's old-vs-new table: what the benches reported before on VECTOR.
        self.assertEqual([old_round_rank(VECTOR, q) for q in (.5, .95, .99)], [5.8, 15.5, 31.0])
        old_nearest = load("bench_tagged", HERE / "bench_tagged.py").distribution(VECTOR)
        self.assertEqual((old_nearest["p50"], old_nearest["p95"], old_nearest["p99"]), (5.5, 15.5, 31.0))

    def test_empty_and_non_numbers(self) -> None:
        self.assertIsNone(typing_report.distribution([]))
        self.assertIsNone(typing_report.distribution([None, True, "x"]))
        self.assertEqual(typing_report.distribution([2, None, 4], mean=False),
                         {"n": 2, "p50": 3.0, "p95": 3.9, "p99": 3.98, "max": 4.0})

    def test_bench_typing_keeps_its_keys(self) -> None:
        stats = bench_typing.summarize(VECTOR)
        self.assertEqual(list(stats), ["n", "p50", "p95", "p99", "max", "median", "min"])
        self.assertEqual((stats["p95"], stats["median"], stats["min"]), (16.275, stats["p50"], 4.1))
        self.assertIsNone(bench_typing.summarize([]))


class NameTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.catalog = catalog.load_catalog(ROOT)
        cls.stories = {s.id: s for s in cls.catalog.stories}

    def stories_of(self, row: str) -> set[str]:
        return {s.id for s in catalog.story_for_row(self.catalog, row)}

    def test_the_catalog_lints_clean(self) -> None:
        self.assertEqual(self.catalog.problems, ())

    def test_frame_metrics(self) -> None:
        self.assertEqual(typing_report.frame_metric("terminal", "idle"), "terminal.key_to_frame")
        self.assertEqual(typing_report.frame_metric("terminal", "load"), "terminal.load.key_to_frame")
        self.assertEqual(typing_report.frame_metric("omnibar", "load"), "omnibar.load.key_to_frame")
        self.assertEqual(self.stories_of("terminal.key_to_frame"), {"typing-terminal", "typing", "typing-stress"})
        self.assertEqual(self.stories_of("omnibar.load.key_to_frame"), {"omnibar", "typing", "typing-stress"})
        for surface, phase in (("home", "idle"), ("home", "load"), ("dock", "idle"), ("terminal", "load")):
            self.assertEqual(self.stories_of(typing_report.frame_metric(surface, phase)), {"typing", "typing-stress"})

    def test_the_key_frame_target_rows_are_claimed(self) -> None:
        claims = catalog.claimed_checks(self.catalog)
        self.assertEqual(claims[("key-frame.light", r"terminal\.key_to_frame")], ["typing-terminal"])
        self.assertEqual(claims[("key-frame.stress", r"terminal\.key_to_frame")], ["typing-stress"])
        self.assertEqual(self.stories["typing-terminal"].tier, "T0")

    def test_other_bench_metrics(self) -> None:
        self.assertEqual(self.stories_of("automation.key_to_frame"), {"automation-typing"})
        self.assertEqual(typing_report.churn_metric("churn", False), "churn.key_to_frame")
        # idle.key_to_frame is the idle phase of both benches; the story id keeps their series apart.
        self.assertEqual(self.stories_of(typing_report.churn_metric("idle", False)),
                         {"sidebar-churn-typing", "automation-typing"})
        self.assertEqual(self.stories_of("churn.key_to_frame"), {"sidebar-churn-typing"})
        self.assertEqual(typing_report.churn_metric("churn", True), "churn.hid_key_to_frame")
        for series in bench_typing.KEY_SERIES:
            self.assertEqual(self.stories_of(f"flood.{series}"), {"typing-flood-stress"}, series)

    def test_stories_by_session(self) -> None:
        self.assertEqual(typing_report.session_story("typing", "light"), "typing")
        self.assertEqual(typing_report.session_story("automation-typing", "stress"), "automation-typing-stress")
        self.assertEqual(typing_report.flood_story(10, False), "bench-typing-flood-10")
        self.assertEqual(typing_report.flood_story(10, True), "bench-typing-flood-10-stress")

    def test_each_typing_story_writes_its_own_id_and_engine(self) -> None:
        for story_id in ("typing-terminal", "typing", "typing-stress", "omnibar", "automation-typing",
                         "sidebar-churn-typing", "typing-flood-stress"):
            story = self.stories[story_id]
            flags = dict(catalog._flag_values(list(story.command)))
            self.assertEqual(flags.get("--story"), story_id, story_id)
            self.assertEqual(story.owner, "PL-typing" if story_id != "omnibar" else "Performance Lead")
            if story.command[0].endswith("typing-frame-bench.py"):
                surfaces = flags.get("--surfaces", "dock,terminal,home,omnibar").split(",")
                engine = typing_report.frame_engine(surfaces, flags.get("--engine", "chromium"))
                self.assertEqual(engine, story.engine, story_id)
                self.assertEqual(flags["--sessions"], story.session, story_id)


def debug_methods(path: Path, skip: frozenset[str] = frozenset(), extra_roots: tuple[str, ...] = (),
                  runner_class: str | None = None) -> set[str]:
    """The `rpc("debug.*")` / `.rpc("debug.*")` methods a bench's run reaches: every module-level call and every
    function called from it (by name, any depth), except the functions in `skip` (a phase or surface the story does
    not run). `extra_roots` are functions the bench reaches through a table (typing-frame-bench.py's SURFACES).
    `runner_class` is the class a table picks for the story (bench-typing.py's runner): its methods win a shared name
    such as `run`."""
    tree = ast.parse(path.read_text())
    # Module functions and class methods; a nested function is part of the function that defines it.
    classes = [c for c in tree.body if isinstance(c, ast.ClassDef)]
    classes.sort(key=lambda c: c.name == runner_class)
    defs = list(tree.body) + [m for c in classes for m in c.body]
    functions = {node.name: node for node in defs if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}

    def calls(node):
        for child in ast.walk(node):
            if isinstance(child, ast.Call):
                yield child

    def callee(call):
        func = call.func
        return func.id if isinstance(func, ast.Name) else func.attr if isinstance(func, ast.Attribute) else None

    found, seen = set(), set()
    pending = [node for node in tree.body if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))]
    pending += [functions[name] for name in extra_roots]
    while pending:
        for call in calls(pending.pop()):
            name = callee(call)
            if name == "rpc" and call.args and isinstance(call.args[0], ast.Constant) \
                    and str(call.args[0].value).startswith("debug."):
                found.add(call.args[0].value)
            elif name in functions and name not in seen and name not in skip:
                seen.add(name)
                pending.append(functions[name])
    return found


class NeedsTests(unittest.TestCase):
    """Each typing story's `needs` names every debug method its command calls on the run the story makes, so a
    bisect or pinpoint build without one is skipped as unsupported, not measured into a partial report (task 211)."""

    # typing-frame-bench.py: what only a load phase reaches, and each surface's function (SURFACES).
    FRAME_LOAD_ONLY = frozenset({"make_load", "chat_streams", "home_stream"})
    FRAME_SURFACES = {"terminal": "surface_terminal", "home": "surface_home", "dock": "surface_dock",
                      "omnibar": "surface_omnibar"}

    # bench-typing.py: the class its `runner` picks for each --surface.
    TYPING_RUNNERS = {"terminal": "Launched", "agent-composer-chromium": "ComposerRun",
                      "chromium-page-scroll": "ScrollRun"}

    def reached(self, story) -> set[str]:
        path = ROOT / story.command[0]
        if path.name == "bench-typing.py":
            flags = dict(catalog._flag_values(list(story.command)))
            return debug_methods(path, runner_class=self.TYPING_RUNNERS[flags.get("--surface", "terminal")])
        if not path.name == "typing-frame-bench.py":
            return debug_methods(path)
        flags = dict(catalog._flag_values(list(story.command)))
        surfaces = flags.get("--surfaces", "dock,terminal,home,omnibar").split(",")
        skip = set() if "load" in flags.get("--phases", "idle,load").split(",") else set(self.FRAME_LOAD_ONLY)
        skip |= {fn for surface, fn in self.FRAME_SURFACES.items() if surface not in surfaces}
        return debug_methods(path, frozenset(skip), tuple(self.FRAME_SURFACES[s] for s in surfaces))

    def test_needs_name_every_debug_method_the_command_calls(self) -> None:
        stories = {s.id: s for s in catalog.load_catalog(ROOT).stories}
        for story_id in ("typing-terminal", "typing", "typing-stress", "omnibar", "automation-typing",
                         "sidebar-churn-typing", "typing-flood-stress"):
            story = stories[story_id]
            needed = {n.removeprefix("debug:") for n in story.needs if n.startswith("debug:")}
            reached = self.reached(story)
            self.assertIn("debug.key", reached, story_id)
            self.assertEqual(reached - needed, set(), f"{story_id}: needs lacks these")
            self.assertEqual(needed - reached, set(), f"{story_id}: needs names methods the run never calls")

    def test_the_terminal_cut_needs_no_load_or_other_surface_method(self) -> None:
        story = next(s for s in catalog.load_catalog(ROOT).stories if s.id == "typing-terminal")
        self.assertEqual(self.reached(story), {"debug.key", "debug.hangs", "debug.frames", "debug.view_churn",
                                               "debug.timings", "debug.focus"})


class RecordingTests(unittest.TestCase):
    def test_only_the_stories_that_claim_a_key_frame_row_name_its_target(self) -> None:
        self.assertEqual(typing_report.frame_targets("typing-terminal", "light"),
                         {"terminal.key_to_frame": "key-frame.light"})
        self.assertEqual(typing_report.frame_targets("typing-stress", "stress"),
                         {"terminal.key_to_frame": "key-frame.stress"})
        self.assertEqual(typing_report.frame_targets("typing", "light"), {})
        self.assertEqual(typing_report.frame_targets("typing-terminal", "stress"), {})

    def test_the_targets_agree_with_the_stories_claims(self) -> None:
        # Every story whose metric claims a key-frame row names that row in its results, and no other story does.
        lab = catalog.load_catalog(ROOT)
        claimed = {}
        for (target, pattern), owners in catalog.claimed_checks(lab).items():
            for owner in owners:
                if target.startswith("key-frame."):
                    claimed.setdefault(owner, []).append((target, pattern))
        for story in lab.stories:
            if not story.command[0].endswith("typing-frame-bench.py"):
                continue
            named = typing_report.frame_targets(story.id, story.session)
            rows = claimed.get(story.id, [])
            self.assertEqual(len(named), len(rows), story.id)
            for target, pattern in rows:
                self.assertTrue(any(t == target and re.fullmatch(pattern, m) for m, t in named.items()), story.id)

    def test_a_typing_terminal_result_names_key_frame_light(self) -> None:
        bench_tagged = load("bench_tagged", HERE / "bench_tagged.py")
        app = RecordingApp()
        story = "typing-terminal"
        written = bench_tagged.record_series(app, story, {"terminal.key_to_frame": [4.0, 5.0],
                                                          "terminal.load.key_to_frame": [6.0]},
                                             targets=typing_report.frame_targets(story, "light"))
        self.assertEqual(set(written), {"terminal.key_to_frame", "terminal.load.key_to_frame"})
        self.assertEqual(app.targets, {"terminal.key_to_frame": "key-frame.light", "terminal.load.key_to_frame": None})

    def test_a_perturbing_flag_records_nothing(self) -> None:
        self.assertIsNone(typing_report.unrecorded(sample=False, trace=False, task_diagnostics=False))
        self.assertEqual(typing_report.unrecorded(sample=True), "none: --sample perturbs the numbers")
        self.assertEqual(typing_report.unrecorded(task_diagnostics=True, trace=True),
                         "none: --task-diagnostics, --trace perturbs the numbers")

    def test_each_profiling_bench_records_only_when_unperturbed(self) -> None:
        # The profilers each bench can attach during the measured keys, and the one rule that keeps them out.
        for name, flags in (("typing-frame-bench.py", ("sample",)),
                            ("sidebar-churn-typing.py", ("task_diagnostics", "trace"))):
            text = (HERE / name).read_text()
            call = re.search(r"typing_report\.unrecorded\(([^)]*)\)", text)
            self.assertIsNotNone(call, name)
            self.assertEqual(sorted(re.findall(r"(\w+)=opts\.\w+", call.group(1))), sorted(flags), name)
            self.assertRegex(text, r"UNRECORDED or bench_tagged\.record_series|if UNRECORDED:", name)
            self.assertIn('results["perturbed"] = UNRECORDED is not None', text, name)


class RecordingApp:
    """BenchApp.record's signature; keeps each metric's target_ref."""

    def __init__(self) -> None:
        self.targets: dict[str, object] = {}

    def record(self, story, metric, unit, samples, better, engine, target_ref=None):
        self.targets[metric] = target_ref
        return f"{story}/{metric}.json"


class QueueTests(unittest.TestCase):
    def test_no_migration_queue_lists_the_typing_benches(self) -> None:
        paths = {f"scripts/cmux-next/{name}" for name in BENCHES} | {"scripts/cmux-next/typing_report.py"}
        for run in (queues.private_stats, queues.self_launch, queues.p95_without_p99):
            listed = {item.key for item in run(str(ROOT))}
            self.assertEqual(listed & paths, set(), run.__name__)

    def test_the_benches_import_perf_stats_through_typing_report(self) -> None:
        for name in BENCHES:
            text = (HERE / name).read_text()
            self.assertIn("import typing_report", text, name)
            self.assertNotRegex(text, r"def (pct|percentile|quantile|stats)\(", name)
            self.assertNotRegex(text, r"\.launch\([^)]*settle", name)  # BenchApp.launch has no settle (e85bafbd6f8)


if __name__ == "__main__":
    unittest.main()
