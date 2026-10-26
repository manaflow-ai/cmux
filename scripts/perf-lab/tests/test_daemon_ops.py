#!/usr/bin/env python3
"""stories/daemon_ops.py: daemon spans grouped by op through trace.py's parser, and its result-v1.

  python3 -m unittest scripts/perf-lab/tests/test_daemon_ops.py
"""
from __future__ import annotations

import fnmatch
import importlib.util
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
ROOT = LAB.parent.parent

_SPEC = importlib.util.spec_from_file_location("perf_lab_daemon_ops_under_test", LAB / "stories" / "daemon_ops.py")
daemon_ops = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = daemon_ops
_SPEC.loader.exec_module(daemon_ops)
perf_result = daemon_ops.perf_result
catalog = daemon_ops.load_by_path("perf_lab_daemon_ops_catalog", LAB / "catalog.py")

SPANS = [  # (label, total_us), as the daemon writes them (debug_spans.rs finish)
    ("resource:workspace.create", 1500),
    ("new-tab", 1000), ("new-tab", 3000), ("new-tab", 1200), ("new-tab", 900),
    ("pane-create", 4000), ("pane-create", 5000),
    ("new-tab.follow", 90000),  # a terminal's first output: not a request
    ("host", 7000),  # a terminal host's own launch: not a daemon request
    ("slow-request", 60000),  # the request watchdog's record of a request already counted
]


def write_spans(folder: Path, spans=SPANS, junk: bool = True) -> None:
    """trace.py's stamped span file (FileFollower): one {"at_us", "line"} row per daemon line."""
    rows = []
    for index, (label, total) in enumerate(spans):
        line = {"label": label, "total_us": total, "start_uptime_ns": (index + 1) * 10_000_000, "tid": 7,
                "marks": [["queued", total // 2], ["reply.sent", total]]}
        rows.append(json.dumps({"at_us": (index + 1) * 10_000.0 + total, "line": json.dumps(line)}))
    if junk:
        rows.append(json.dumps({"at_us": 1.0, "line": "not json"}))
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "daemon-spans-stamped.jsonl").write_text("\n".join(rows) + "\n", encoding="utf-8")


BUILD = perf_result.Build(sha="a" * 40, config="bench", measure_version=2)
HOST = perf_result.Host(fingerprint="b" * 64, host_class="m4pro-48g-120", chip="Apple M4 Pro", macos="27.0.1",
                        macos_build="27A123", display_hz=120)


class DaemonOpsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_reads_spans_with_trace_py_parser(self) -> None:
        self.assertIs(daemon_ops.trace.daemon_span_events.__module__, daemon_ops.trace.__name__)
        self.assertEqual(Path(daemon_ops.trace.__file__).resolve(), ROOT / "scripts" / "cmux-next" / "trace.py")
        write_spans(self.dir)
        report = daemon_ops.read_spans(self.dir)
        self.assertEqual(report.ops, {"new-tab": (1.0, 3.0, 1.2, 0.9), "pane-create": (4.0, 5.0),
                                      "resource_workspace_create": (1.5,)})

    def test_no_op_spans_is_an_error(self) -> None:
        write_spans(self.dir, spans=[("host", 1000), ("new-tab.follow", 2000)])
        with self.assertRaises(daemon_ops.StoryError):
            daemon_ops.read_spans(self.dir)

    def test_op_names_are_one_metric_segment(self) -> None:
        self.assertEqual(daemon_ops.op_of("resource:tab.create_terminal"), "resource_tab_create_terminal")
        self.assertIsNone(daemon_ops.op_of("ops"))  # never the aggregate's name
        self.assertIsNone(daemon_ops.op_of("pane-create.follow"))

    def test_results_per_op_aggregate_and_over_budget(self) -> None:
        write_spans(self.dir)
        report = daemon_ops.read_spans(self.dir)
        self.assertEqual(report.over_budget, ["new-tab", "pane-create"])  # p95 2.73 and 4.95 ms; workspace 1.5 ms
        rows = {r.metric: r for r in daemon_ops.results(report, BUILD, HOST, "stress")}
        self.assertEqual(sorted(rows), ["daemon.new-tab.ms", "daemon.ops.ms", "daemon.ops.over_budget",
                                        "daemon.pane-create.ms", "daemon.resource_workspace_create.ms"])
        self.assertEqual(len(rows["daemon.ops.ms"].samples), 7)
        self.assertEqual(rows["daemon.ops.over_budget"].samples, [2])
        ref = rows["daemon.new-tab.ms"].target_ref
        self.assertEqual(catalog.resolve_ref(ROOT, catalog.Ref(ref.path, ref.key)), daemon_ops.OP_P95_BUDGET_MS)
        self.assertEqual(len({r.run.id for r in rows.values()}), 1)

    def test_story_patterns_split_per_op_from_monitored_aggregate(self) -> None:
        story = json.loads((LAB / "stories.d" / "daemon-ops.json").read_text(encoding="utf-8"))
        per_op, aggregate, over = (m["name"] for m in story["metrics"])
        self.assertTrue(re.fullmatch(per_op, "daemon.new-tab.ms"))
        self.assertTrue(re.fullmatch(per_op, "daemon.resource_workspace_create.ms"))
        self.assertFalse(re.fullmatch(per_op, "daemon.ops.ms"))
        self.assertTrue(re.fullmatch(aggregate, "daemon.ops.ms"))
        self.assertTrue(re.fullmatch(over, "daemon.ops.over_budget"))
        subscriptions = json.loads((LAB / "subscriptions.json").read_text(encoding="utf-8"))["subscriptions"]
        monitored = [s for s in subscriptions if fnmatch.fnmatch("daemon.ops.ms", s["match"].get("metric", "-"))]
        self.assertEqual([s["name"] for s in monitored], ["aggregate-daemon-ops"])
        self.assertFalse(any(fnmatch.fnmatch("daemon.new-tab.ms", s["match"].get("metric", "-"))
                             for s in subscriptions if set(s["match"]) == {"metric"}))

    def test_catalog_lint_accepts_the_story(self) -> None:
        problems = [p for p in catalog.load_catalog(ROOT).problems if "daemon-ops" in p]
        self.assertEqual(problems, [])

    def test_main_records_the_storm_and_writes_result_v1(self) -> None:
        out = self.dir / "out"
        app = self.dir / "cmux DEV t.app"
        seen = []

        def record(argv):
            seen.append(list(argv))
            write_spans(Path(argv[argv.index("--out") + 1]))
            return 0

        code = daemon_ops.main(["--app", str(app), "--tag", "t", "--out", str(out), "stress"], environ={},
                               record=record, measure=lambda _app: (BUILD, HOST))
        self.assertEqual(code, 0)
        argv = seen[0]
        self.assertEqual(argv[argv.index("--scenario") + 1], "stress-storm")
        self.assertIn("--no-cef", argv)
        self.assertEqual(Path(argv[argv.index("--out") + 1]), out / "trace")
        written = perf_result.read_dir(out)  # validates every line as result-v1
        self.assertEqual(len(list(out.glob("*.ndjson"))), 1)
        metrics = {r.metric for r in written}
        self.assertIn("daemon.ops.ms", metrics)
        self.assertTrue(all(m.startswith("daemon.") for m in metrics))
        self.assertEqual({(r.story, r.session, r.engine, r.build.config) for r in written},
                         {("daemon-ops", "stress", "none", "bench")})
        table = json.loads((out / daemon_ops.OPS_FILE).read_text())
        self.assertEqual(table["ops"]["new-tab"]["n"], 4)

    def test_main_light_session_uses_the_light_storm(self) -> None:
        seen = []

        def record(argv):
            seen.append(list(argv))
            write_spans(Path(argv[argv.index("--out") + 1]))
            return 0

        code = daemon_ops.main(["--app", "a.app", "--out", str(self.dir)], environ={"PERF_LAB_SESSION": "light"},
                               record=record, measure=lambda _app: (BUILD, HOST))
        self.assertEqual(code, 0)
        self.assertEqual(seen[0][seen[0].index("--scenario") + 1], "light-storm")

    def test_main_failed_trace_writes_nothing(self) -> None:
        def record(argv):
            write_spans(Path(argv[argv.index("--out") + 1]))
            return 3

        code = daemon_ops.main(["--app", "a.app", "--out", str(self.dir)], environ={}, record=record,
                               measure=lambda _app: (BUILD, HOST))
        self.assertEqual(code, 3)
        self.assertEqual(list(self.dir.glob("*.ndjson")), [])

    def test_main_refuses_unknown_session(self) -> None:
        code = daemon_ops.main(["--from-trace", str(self.dir), "corpus:x"], environ={})
        self.assertEqual(code, 2)

    def test_from_trace_prints_without_writing(self) -> None:
        write_spans(self.dir)
        self.assertEqual(daemon_ops.main(["--from-trace", str(self.dir), "--json"], environ={}), 0)
        self.assertEqual(list(self.dir.glob("*.ndjson")), [])


if __name__ == "__main__":
    unittest.main()
