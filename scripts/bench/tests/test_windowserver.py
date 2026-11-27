from __future__ import annotations

import ast
import json
import os
import plistlib
import subprocess
import threading
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402
from benches.windowserver import BENCH  # noqa: E402
from importlib.util import module_from_spec, spec_from_file_location  # noqa: E402

_spec = spec_from_file_location("windowserver_harness", BENCH_DIR.parent / "cmux-next" / "windowserver-bench.py")
assert _spec and _spec.loader
_harness = module_from_spec(_spec)
_spec.loader.exec_module(_harness)
import windowserver_gpu as gpu_module  # noqa: E402


def context() -> Context:
    return Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                   timestamp="2026-11-20T00:00:00Z", args={})


class WindowServerTest(unittest.TestCase):
    def production_functions(self, filename, names, namespace):
        path = BENCH_DIR.parent / "cmux-next" / filename
        tree = ast.parse(path.read_text())
        body = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
        exec(compile(ast.Module(body=body, type_ignores=[]), str(path), "exec"), namespace)
        return namespace

    def test_retained_workspace_cycle_and_invalid_evidence(self) -> None:
        focused = ["source"]
        invalid = [None]

        def rpc(method):
            shown = focused[0] == "source"
            if method == "debug.themes":
                workspaces = [{"workspace": "source", "shown": shown}, {"workspace": "other", "shown": not shown}]
                if invalid[0] == "evicted":
                    workspaces = workspaces[1:]
                if invalid[0] == "shown":
                    workspaces[0]["shown"] = not shown
                return {"windows": [{"window_number": 7, "workspaces": workspaces}]}
            status = {"parked_workspaces": 1, "hibernated_workspaces": 0, "workspaces_hibernated_total": 0,
                      "hibernation": {"pressure": "normal", "page_phases": {
                          "front": "mountedVisible" if shown else "mountedHidden", "loading": "mountedHidden"}}}
            if invalid[0] == "hibernated":
                status["workspaces_hibernated_total"] = 1
            if invalid[0] == "missing":
                del status["parked_workspaces"]
            if invalid[0] == "page":
                status["hibernation"]["page_phases"]["front"] = "hibernated"
            return status

        switches = []

        def switch(workspace):
            switches.append(workspace)
            focused[0] = workspace

        namespace = self.production_functions("browser-idle-cost-live.py", {
            "cycle_evidence", "measure_workspace_cycle"}, dict(
                rpc=rpc, focused_workspace=lambda: "wrong" if invalid[0] == "focus" else focused[0],
                never_lock=threading.Lock(), never_connections=set(),
                select=SimpleNamespace(select=lambda *a: ([1] if invalid[0] == "request" else [], [], [])),
                switch_workspace=switch, opts=SimpleNamespace(settle_s=0), time=Mock(),
                measure=lambda pid, phase: {"phase": phase}))
        rows = []
        for phase in ("static", "loading"):
            if phase == "loading":
                namespace["never_connections"].add(object())
            rows.extend(namespace["measure_workspace_cycle"](1, phase, "source", "other", "front",
                                                            "loading" if phase == "loading" else None))
        self.assertEqual(switches, ["source", "other", "source"] * 2)
        self.assertEqual([row["workspace_state"] for row in rows], ["shown", "parked", "restored"] * 2)
        self.assertEqual(rows[4]["evidence"]["before"]["mounted_workspaces"], {"source": False, "other": True})
        normalized = _harness.extract_runs("spinner", {"phases": rows})
        self.assertEqual(normalized[4]["visibility"], "parked")
        self.assertEqual(normalized[4]["evidence"], rows[4]["evidence"])
        for problem in ("evicted", "shown", "hibernated", "missing", "page", "request", "focus"):
            with self.subTest(problem=problem):
                invalid[0] = problem
                with self.assertRaises(RuntimeError):
                    namespace["cycle_evidence"]("source", "source", "other", "front", True, "loading")

    def test_scenario_commands_and_material_readback(self) -> None:
        spinner, _ = _harness.scenario_command("spinner", "test.app", Path("out"), 20, 5, 40)
        self.assertIn("--workspace-cycle", spinner)
        glass, _ = _harness.scenario_command("glass-blur", "test.app", Path("out"), 20, 5, 40)
        self.assertEqual(glass[glass.index("--backdrops") + 1], "blur-none,blur-frosted,blur-glass,blur-glassClear")
        path = BENCH_DIR.parent / "cmux-next/typing-frame-bench.py"
        body = [node for node in ast.parse(path.read_text()).body if
                (isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == "BACKDROPS"
                                                     for target in node.targets)) or
                (isinstance(node, ast.Expr) and isinstance(node.value, ast.Call) and
                 isinstance(node.value.func, ast.Attribute) and isinstance(node.value.func.value, ast.Name) and
                 node.value.func.value.id == "BACKDROPS")]
        namespace = {}
        exec(compile(ast.Module(body=body, type_ignores=[]), str(path), "exec"), namespace)
        for material in ("none", "frosted", "glass", "glassClear"):
            self.assertEqual(namespace["BACKDROPS"]["blur-" + material],
                             {"background": "none", "backgroundOpacity": 0.85, "backgroundBlur": material})
        backdrop = {"blending": "false", "glassOverlay": "", "glassTint": "#112233ff"}
        namespace = self.production_functions("typing-frame-bench.py", {"backdrop_evidence"}, {
            "rpc": lambda method: {"windows": [{"window_number": 7, "backdrop": backdrop}]}})
        self.assertEqual(namespace["backdrop_evidence"]()[0]["backdrop"], backdrop)
        backdrop["blending"] = "true"
        with self.assertRaises(RuntimeError):
            namespace["backdrop_evidence"]()

    def test_app_provenance_hashes_actual_binary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "cmux"}))
            executable = app / "Contents/MacOS/cmux"
            executable.write_bytes(b"before")
            before = _harness.provenance(str(app), "a" * 40)
            executable.write_bytes(b"after")
            after = _harness.provenance(str(app), "b" * 40)
            self.assertNotEqual(before["executable_sha256"], after["executable_sha256"])
            self.assertEqual(before["harness_sha256"], after["harness_sha256"])
            self.assertEqual(after["declared_app_source_sha"], "b" * 40)

    def test_wrapper_reuses_app_without_building(self) -> None:
        wrapper = BENCH_DIR.parent / "measure/windowserver-cost.sh"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app, output = root / "existing app.app", root / "output"
            app.mkdir()
            for name, source in {
                "git": '#!/bin/sh\nprintf "%s\\n" "$FAKE_ROOT"\n',
                "python3": '#!/bin/sh\nprintf "%s\\n" "$@" > "$FAKE_ROOT/args"\nprintf "{}" > "$FAKE_ROOT/output/report.json"\n',
            }.items():
                path = root / name
                path.write_text(source)
                path.chmod(0o755)
            command = ["bash", str(wrapper), f"--app={app}", f"--out={output}"]
            env = {**os.environ, "FAKE_ROOT": tmp, "PATH": tmp + os.pathsep + os.environ["PATH"]}
            rejected = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(rejected.returncode, 2)
            accepted = subprocess.run(command + ["--app-source-sha=" + "a" * 40], env=env, capture_output=True, text=True)
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            args = (root / "args").read_text().splitlines()
            self.assertEqual(args[args.index("--app") + 1], str(app))
            self.assertEqual(args[args.index("--app-source-sha") + 1], "a" * 40)

    def test_pair_wrapper_validates_arms_and_preserves_receipts(self) -> None:
        wrapper = BENCH_DIR.parent / "measure/windowserver-cost-pair.sh"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts/measure").mkdir(parents=True)
            files = {
                "git": '#!/bin/sh\nprintf "%s\\n" "$FAKE_ROOT"\n',
                "scripts/measure/app-at-commit.sh": '''measure_remove_scratch() {
python3 - "$1" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
}
measure_app_at_commit() {
echo "built exact source $1" >&2
printf '%s\\n' "$3.app"
}
''',
                "scripts/measure/windowserver-cost.sh": '''#!/usr/bin/env python3
import json, os, pathlib, sys
args = dict(item[2:].split("=", 1) for item in sys.argv[1:])
failed = os.environ.get("FAIL_FIXED") and args["out"].endswith("fixed")
report = {"verdict": "failed" if failed else "passed", "failures": [], "harness_exit_code": int(bool(failed)),
          "provenance": {"declared_app_source_sha": args["app-source-sha"], "executable_sha256": "binary",
                         "harness_sha256": {"probe": "identical"}}}
(pathlib.Path(args["out"]) / "report.json").write_text(json.dumps(report))
''',
            }
            for name, source in files.items():
                path = root / name
                path.write_text(source)
                path.chmod(0o755)
            env = {**os.environ, "FAKE_ROOT": tmp, "PATH": tmp + os.pathsep + os.environ["PATH"]}
            command = ["bash", str(wrapper), "--baseline-ref=" + "a" * 40, "--fixed-ref=" + "b" * 40]
            for extra in (["--unknown=yes"], ["--fixed-ref=short"]):
                bad = subprocess.run(command + extra, env=env, capture_output=True, text=True)
                self.assertEqual(bad.returncode, 2, bad.stderr)
            for fail in (False, True):
                output = root / ("failed" if fail else "passed")
                run = subprocess.run(command + [f"--out={output}"],
                                     env={**env, "FAIL_FIXED": "yes" if fail else ""}, capture_output=True, text=True)
                self.assertEqual(run.returncode, int(fail), run.stderr)
                self.assertEqual("WINDOWSERVER-PAIR-PASS" in run.stdout, not fail)
                for arm, sha in (("baseline", "a" * 40), ("fixed", "b" * 40)):
                    receipt = json.loads((output / arm / "build-receipt.json").read_text())
                    self.assertEqual(receipt["declared_source_sha"], sha)
                    self.assertIn(sha, (output / arm / "build.log").read_text())
                    self.assertTrue((output / arm / "report.json").is_file())

    def test_registered(self) -> None:
        self.assertIs(load_all()["windowserver"], BENCH)

    def test_extract_gpu_is_aggregate_only(self) -> None:
        report = {"phases": [{"phase": "static", "window_server_cpu_percent": 1.0,
                              "classes": {"app": {"cpu_percent": 2.0}, "gpu": {"cpu_percent": 3.0}}}]}
        report["phases"][0]["gpu"] = {"available": True, "device_utilization_percent": 4.0}
        rows = _harness.extract_runs("spinner", report)
        self.assertEqual([row["phase"] for row in rows], ["static"])
        self.assertEqual(rows[0]["gpu"]["device_utilization_percent"], 4.0)

    def test_typing_report_cpu_keys_and_gpu(self) -> None:
        for key in ("cpu_pct", "cpu_percent"):
            with self.subTest(key=key):
                gpu = {"available": True, "device_utilization_percent": 4.0}
                row = _harness.extract_runs("typing", {"runs": [{
                    key: {"app": 2.0, "window_server": 3.0}, "gpu": gpu,
                }]})[0]
                self.assertEqual(row["window_server_cpu_percent"], 3.0)
                self.assertEqual(row["app_cpu_percent"], 2.0)
                self.assertEqual(row["gpu"], gpu)

    def test_spinner_labels_only_loading_as_background(self) -> None:
        report = {"phases": [{"phase": phase} for phase in ("static", "loading")]}
        idle = _harness.extract_runs("idle", report)
        spinner = _harness.extract_runs("spinner", report)
        self.assertEqual([(r["surface"], r["visibility"]) for r in idle],
                         [("browser-tabs", "shown"), ("browser-tabs", "shown")])
        self.assertEqual([(r["surface"], r["visibility"]) for r in spinner],
                         [("browser-tabs", "shown"), ("tab-strip", "background-loading-tab")])

    def test_gpu_stats_accept_numeric_plist_values(self) -> None:
        payload = plist_bytes = b'''<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array><dict><key>PerformanceStatistics</key><dict><key>Device Utilization %</key><real>12.5</real><key>Renderer Utilization %</key><integer>9</integer><key>In use system memory</key><integer>1048576</integer></dict></dict></array></plist>'''
        import subprocess
        proc = subprocess.CompletedProcess([], 0, stdout=payload, stderr=b"")
        self.assertEqual(_harness.read_gpu_stats(proc)["Device Utilization %"], 12.5)
        summary = _harness.summarize_gpu([_harness.read_gpu_stats(proc)])
        self.assertEqual(summary["in_use_system_memory_mb"], 1.0)

    def test_ingest_shapes_scenarios_and_gpu(self) -> None:
        report = {"schema": "cmux-windowserver/v1", "host": "bench-mac", "runs": [
            {"scenario": "spinner", "phase": "loading", "round": 1, "window_server_cpu_percent": 4.25,
             "app_cpu_percent": 2.0, "cef_gpu_cpu_percent": 1.0,
             "gpu": {"available": True, "device_utilization_percent": 8.5, "renderer_utilization_percent": 4.0}},
            {"scenario": "glass-blur", "phase": "idle", "round": 1, "window_server_cpu_percent": None,
             "gpu": {"available": False}},
        ]}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "report.json"
            path.write_text(json.dumps(report), encoding="utf-8")
            ctx = context()
            BENCH.ingest(ctx, path)
        rows = {(row["metric"], row["labels"].get("scenario")): row for row in ctx.rows}
        self.assertEqual(rows[("window_server_cpu", "spinner")]["value"], 4.25)
        self.assertEqual(rows[("gpu_device_utilization", "spinner")]["value"], 8.5)
        self.assertTrue(any("GPU counters unavailable" in note for note in ctx.notes))

    def test_agentpane_production_path_samples_gpu_and_cleans_up(self) -> None:
        # Execute the production function without the script's CLI/app startup.
        path = BENCH_DIR.parent / "cmux-next" / "typing-frame-bench.py"
        tree = ast.parse(path.read_text())
        functions = [node for node in tree.body if isinstance(node, ast.FunctionDef)
                     and node.name in ("measure_agentpane", "cpu_share")]
        code = compile(ast.Module(body=functions, type_ignores=[]), str(path), "exec")
        for fail in (False, True):
            with self.subTest(exception=fail):
                sampled = threading.Event()
                samplers = []

                def sample():
                    sampled.set()
                    return {"Device Utilization %": 12.0}

                def sampler():
                    instance = gpu_module.GPUSampler()
                    samplers.append(instance)
                    return instance

                def cpu_seconds(pid):
                    self.assertTrue(sampled.wait(2), "GPU sampling never started in agentpane")
                    return 1.0

                def rpc(method, params=None, **kwargs):
                    params = params or {}
                    if method == "debug.focus":
                        return {"app_active": True}
                    if params.get("action") == "reset_typing" and fail:
                        raise RuntimeError("injected RPC failure")
                    if params.get("action") == "typing_stats":
                        return {"keys": 10, "composer_text": ""}
                    return {}

                namespace = dict(
                    GPUSampler=sampler, WINDOW_SERVER=2, SESSION="test", MODE=None, LOAD={},
                    opts=SimpleNamespace(launch="open", chat_agent="mock", prefill=0, sample=False,
                                         samples=1, interval=0.01, json=None),
                    foreground_activation=lambda: {}, rpc=rpc, wait=lambda fn, *a, **k: fn(),
                    draw_on_input_frames=lambda: None, launch_switch_once=lambda: (True, None),
                    cpu_seconds=cpu_seconds, time=Mock(monotonic=Mock(side_effect=range(100)),
                                                       time=Mock(return_value=1.0)),
                    agent_expected_text=lambda n: "a", SchedProbe=Mock(),
                    agent_typing_verdict=lambda *a: {"observed_keys": 1, "complete": True, "text_exact": True},
                    frame_metrics=lambda value: {}, pct=lambda value: {},
                    frame_timing_validity=lambda *a: {}, results={"runs": []}, note=Mock())
                exec(code, namespace)
                with patch.object(gpu_module, "read_gpu_stats", side_effect=sample):
                    if fail:
                        with self.assertRaisesRegex(RuntimeError, "injected RPC failure"):
                            namespace["measure_agentpane"]("idle", 1, "pane")
                    else:
                        entry = namespace["measure_agentpane"]("idle", 1, "pane")
                        self.assertEqual(entry["gpu"]["device_utilization_percent"], 12.0)
                        normalized = _harness.extract_runs("typing", {"runs": [entry]})[0]
                        self.assertEqual(normalized["gpu"], entry["gpu"])
                        self.assertEqual(normalized["window_server_cpu_percent"], 0.0)
                self.assertEqual(len(samplers), 1)
                self.assertFalse(samplers[0].is_alive())
                self.assertTrue(samplers[0].stop_event.is_set())

    def test_sampler_finish_waits_for_inflight_read_and_discards_it(self) -> None:
        entered, release, finished = threading.Event(), threading.Event(), threading.Event()

        def read():
            entered.set()
            release.wait(2)
            return {"Device Utilization %": 99.0}

        sampler = gpu_module.GPUSampler()
        self.assertEqual(sampler.interval, 1.0)
        with patch.object(gpu_module, "read_gpu_stats", side_effect=read):
            sampler.start()
            self.assertTrue(entered.wait(2))
            worker = threading.Thread(target=lambda: (sampler.finish(), finished.set()))
            worker.start()
            try:
                self.assertTrue(sampler.stop_event.wait(2))
                self.assertFalse(finished.is_set())
            finally:
                release.set()
                worker.join(2)
                sampler.join(2)
        self.assertTrue(finished.is_set())
        self.assertFalse(sampler.is_alive())
        self.assertEqual(sampler.samples, [])

    def test_partial_failure_transports_report_but_fails_ingestion(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report_path = Path(tmp) / "report.json"
            argv = ["bench", "--app", "/fake.app", "--out", tmp, "--json", str(report_path),
                    "--scenarios", "idle,typing", "--transport-envelope"]
            good = [{"scenario": "idle", "window_server_cpu_percent": 2.0}]
            with patch.object(sys, "argv", argv), patch.object(
                    _harness, "run_scenario", side_effect=[good, RuntimeError("typing failed")]):
                self.assertEqual(_harness.main(), 0)
            report = json.loads(report_path.read_text())
            self.assertEqual(report["verdict"], "failed")
            self.assertEqual(report["harness_exit_code"], 1)
            self.assertEqual(report["failures"][0]["scenario"], "typing")
            self.assertEqual(len(report["runs"]), 1)
            ctx = context()
            with self.assertRaisesRegex(BenchError, "scenario validation failed"):
                BENCH.ingest(ctx, report_path)
            self.assertTrue(ctx.rows, "partial measurements should survive ingestion failure")

    def test_bad_schema_raises(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "report.json"
            path.write_text("{}", encoding="utf-8")
            with self.assertRaises(BenchError):
                BENCH.ingest(context(), path)


if __name__ == "__main__":
    unittest.main()
