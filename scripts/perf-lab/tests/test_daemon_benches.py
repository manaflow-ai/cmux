#!/usr/bin/env python3
"""The daemon and Rust benches as lab stories (p12-perf-process-218): cmux-tui/scripts/daemon_bench_lab.py and each
bench's result-v1 series, without a daemon or a build.

Covers: the percentiles are perf_stats.pct; --out FILE.json is a report alone and --out DIR a result folder; a run that
cannot name its build or host never starts; the Linux host block; each bench's report becomes series whose names and
units a story of stories.d claims, written and read back through perf_result; the spans copy in a result folder is
never *.ndjson; the Rust benches' outputs parse.

  python3 -m unittest scripts/perf-lab/tests/test_daemon_benches.py
"""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
ROOT = LAB.parent.parent
SCRIPTS = ROOT / "cmux-tui" / "scripts"
SHA = "0123456789abcdef0123456789abcdef01234567"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


lab = load("daemon_bench_lab", SCRIPTS / "daemon_bench_lab.py")
lifecycle = load("test_bench_lifecycle", SCRIPTS / "bench-lifecycle.py")
create = load("test_bench_terminal_create", SCRIPTS / "bench-terminal-create.py")
scale = load("test_bench_scale", SCRIPTS / "bench-scale.py")
tperf = load("test_bench_terminal_perf", SCRIPTS / "bench-terminal-perf.py")
latency = load("test_bench_daemon_latency", SCRIPTS / "bench-daemon-latency.py")
rust = load("test_bench_rust_lab", SCRIPTS / "bench-rust-lab.py")
catalog = lab.perf_import.load("catalog")
perf_result = lab.perf_result

CPUINFO = "processor\t: 0\nmodel name\t: AMD EPYC 9B14\n"
MEMINFO = "MemTotal:       16384000 kB\nMemFree: 1 kB\n"


def linux_host():
    files = {"/proc/cpuinfo": CPUINFO, "/proc/meminfo": MEMINFO}
    return lab.linux_host(read=files.__getitem__, cpus=8, release="6.8.0")


def measured():
    return lab.Measured(perf_result.Build(sha=SHA, config="release", measure_version=lab.MEASURE_VERSION),
                        linux_host())


def story(story_id):
    stories = {s.id: s for s in catalog.load_catalog(ROOT).stories}
    return stories[story_id]


class Claims(unittest.TestCase):
    """Every series a bench writes is claimed, with its unit and direction, by one metric of its story."""

    def assertClaimed(self, story_id, series):
        claims = story(story_id).metrics
        self.assertTrue(series)
        for s in series:
            hits = [m for m in claims if re.fullmatch(m.name, s.metric)]
            self.assertEqual(len(hits), 1, f"{story_id}: {s.metric} is claimed by {len(hits)} metrics")
            self.assertEqual((hits[0].unit, hits[0].better), (s.unit, s.better), s.metric)

    def write_and_read(self, story_id, series):
        with tempfile.TemporaryDirectory() as tmp:
            path = lab.write(tmp, story_id, series, measured())
            back = perf_result.read_dir(tmp)
        self.assertEqual(Path(path).suffix, ".ndjson")
        self.assertEqual({r.metric for r in back}, {s.metric for s in series if s.samples})
        for r in back:
            self.assertEqual((r.story, r.engine, r.session, r.build.config), (story_id, "none", "light", "release"))
        return back


class Percentiles(unittest.TestCase):
    VALUES = [float(v) for v in range(100, 0, -1)]

    def test_every_bench_summary_is_perf_stats_pct(self):
        want = {q: round(lab.perf_stats.pct(self.VALUES, q), 3) for q in (0.5, 0.95, 0.99)}
        for module in (lifecycle, create):
            row = module.summary(self.VALUES)
            self.assertEqual((row["p50"], row["p95"], row["p99"]), (want[0.5], want[0.95], want[0.99]), module)
        self.assertEqual(scale.latency_summary(self.VALUES)["p99_ms"], want[0.99])
        self.assertEqual(latency.stats(self.VALUES)["p95_ms"], want[0.95])
        # The old nearest rank of this vector was 51 / 96 / 100 (int(q * n)); linear interpolation gives these.
        self.assertEqual((want[0.5], want[0.95], want[0.99]), (50.5, 95.05, 99.01))

    def test_empty(self):
        self.assertEqual(lifecycle.summary([]), {"n": 0})
        self.assertEqual(create.summary([]), {"n": 0})


class Outputs(unittest.TestCase):
    def test_json_path_is_a_report_and_anything_else_a_result_folder(self):
        self.assertEqual(lab.outputs("/w/a.json", "r.json"), lab.Outputs(None, "/w/a.json"))
        self.assertEqual(lab.outputs("/w/run", "r.json"), lab.Outputs("/w/run", "/w/run/r.json"))
        self.assertEqual(lab.outputs(None, "r.json"), lab.Outputs(None, None))

    def test_spans_copy_in_a_result_folder_is_not_ndjson(self):
        self.assertEqual(lab.spans_copy(lab.Outputs(None, "/w/a.json")), "/w/a.json.spans.ndjson")
        self.assertFalse(lab.spans_copy(lab.outputs("/w/run", "r.json")).endswith(".ndjson"))

    def test_a_result_folder_needs_a_named_build_before_anything_runs(self):
        parser = argparse.ArgumentParser()
        for flag in ("--bin", "--out", "--app", "--tag"):
            parser.add_argument(flag)
        lab.add_arguments(parser, "daemon-lifecycle")
        with tempfile.TemporaryDirectory() as tmp:
            args = parser.parse_args(["--bin", "/x/cmux-tui", "--out", os.path.join(tmp, "run")])
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                lab.prepare(parser, args, "r.json", environ={})  # no --sha, no --build-config
            self.assertFalse(os.path.exists(os.path.join(tmp, "run")))
            args = parser.parse_args(["--bin", "/x/cmux-tui", "--out", os.path.join(tmp, "r.json")])
            self.assertEqual(lab.prepare(parser, args, "r.json", environ={}),
                             ("/x/cmux-tui", lab.Outputs(None, os.path.join(tmp, "r.json")), None))
            args = parser.parse_args(["--out", os.path.join(tmp, "r.json")])
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                lab.prepare(parser, args, "r.json", environ={})  # no daemon named

    def test_a_stated_build_takes_the_runner_variables(self):
        environ = {lab.SHA_ENV: SHA, lab.CONFIG_ENV: "release"}
        host = linux_host()
        with tempfile.TemporaryDirectory() as tmp:
            host_file = os.path.join(tmp, "host.json")
            Path(host_file).write_text(json.dumps(host.to_dict()))
            got = lab.stated(None, None, {**environ, lab.HOST_FILE_ENV: host_file})
        self.assertEqual(got.build, perf_result.Build(SHA, "release", lab.MEASURE_VERSION))
        self.assertEqual(got.host, host)
        with self.assertRaises(lab.LabError):
            lab.stated(None, "fast", environ)

    def test_checkout_sha_refuses_another_stated_commit(self):
        head = lab.checkout_sha(environ={})
        self.assertRegex(head, r"^[0-9a-f]{40}$")
        self.assertEqual(lab.checkout_sha(environ={lab.SHA_ENV: head}), head)
        other = "f" * 40 if head != "f" * 40 else "e" * 40
        with self.assertRaises(lab.LabError):
            lab.checkout_sha(environ={lab.SHA_ENV: other})


class LinuxHost(unittest.TestCase):
    def test_block(self):
        host = linux_host()
        self.assertEqual(host.host_class, "linux/amd-epyc-9b14/8c/16gb")
        self.assertEqual((host.chip, host.macos, host.macos_build, host.display_hz), ("AMD EPYC 9B14", None, None, None))
        self.assertEqual(perf_result.validation_errors({**_result_dict(host)}), [])

    def test_unreadable_memory_refuses(self):
        files = {"/proc/cpuinfo": CPUINFO, "/proc/meminfo": ""}
        with self.assertRaises(lab.LabError):
            lab.linux_host(read=files.__getitem__, cpus=8, release="6.8.0")


def _result_dict(host):
    return perf_result.Result(story="s", metric="m", unit="ms", better="lower", samples=[1.0],
                              build=perf_result.Build(SHA, "release", 1), host=host, engine="none", session="light",
                              run=perf_result.Run.start()).to_dict()


class Series(Claims):
    def test_lifecycle(self):
        report = {"ops": {"new-tab terminal": {"samples_ms": [1.0, 2.0]},
                          "close-pane (split right unsized)": {"samples_ms": [3.0]}},
                  "daemon_threads_per_terminal": 0.5}
        series = lifecycle.lab_series(report)
        self.assertEqual([s.metric for s in series], ["daemon.lifecycle.close_pane_split_right_unsized",
                                                      "daemon.lifecycle.new_tab_terminal",
                                                      "daemon.lifecycle.threads_per_terminal"])
        self.assertClaimed("daemon-lifecycle", series)
        self.write_and_read("daemon-lifecycle", series)

    def test_terminal_create(self):
        report = {"ops": {"new-tab reply": {"samples_ms": [1.0]}, "split right first-text": {"samples_ms": [9.0]},
                          "new-workspace exec": {"samples_ms": [4.0, 5.0]}},
                  "per_terminal": {"terminals": 4, "host_processes_added": 4, "host_rss_kb_added": 400,
                                   "daemon_rss_kb_added": 40, "terminal_processes": 5}}
        series = {s.metric: s for s in create.lab_series(report)}
        self.assertIn("daemon.terminal_create.split_right.first_text", series)
        self.assertEqual(series["daemon.terminal_create.per_terminal.host_rss"].samples, [102400.0])
        self.assertEqual(series["daemon.terminal_create.per_terminal.host_processes"].samples, [1.0])
        self.assertClaimed("daemon-terminal-create", list(series.values()))
        self.write_and_read("daemon-terminal-create", list(series.values()))

    def test_scale(self):
        step = {"target": 100, "terminals": 100, "create_rate_per_s": 50.0,
                "samples_ms": {"create": [1.0, 2.0], "echo": [0.5], "topology_read": [0.1], "topology_write": [0.2]},
                "roles": {role: {"pss_per": 1e6, "threads": 3, "cpu_pct_window": 0.5, "wakeups_per_s": 2.0}
                          for role in ("daemon", "hosts", "shells")}}
        series = scale.lab_series({"steps": [step]})
        self.assertEqual(len(series), 4 + 1 + 3 * 4)
        self.assertClaimed("daemon-scale", series)
        self.write_and_read("daemon-scale", series)

    def test_scale_failed_or_short_step_records_nothing(self):
        def step(target, terminals, **extra):
            return {"target": target, "terminals": terminals, "create_rate_per_s": 50.0,
                    "samples_ms": {"create": [1.0], "echo": [0.5]},
                    "roles": {"hosts": {"pss_per": 1e6, "threads": terminals}}, **extra}

        steps = [step(100, 100), step(1000, 600, error="create failed: timeout"), step(5000, 4000)]
        metrics = {s.metric for s in scale.lab_series({"steps": steps})}
        self.assertIn("daemon.scale.100.hosts.threads", metrics)
        self.assertEqual({m for m in metrics if not m.startswith("daemon.scale.100.")}, set())
        dead = [step(100, 100, error="daemon exited 1: ...")]
        self.assertEqual(scale.lab_series({"steps": dead}), [])

    def test_scale_exit_status(self):
        ok = {"steps": [{"target": 100, "terminals": 100}]}
        self.assertEqual(scale.run_status(ok, harness_error=False), 0)
        guard = {"steps": [], "stopped": {"at": 1000, "reason": "memory guard"}}
        self.assertEqual(scale.run_status(guard, harness_error=False), 0)
        self.assertEqual(scale.run_status(ok, harness_error=True), 1)
        failed = {"steps": [{"target": 1000, "terminals": 600, "error": "x"}]}
        self.assertEqual(scale.run_status(failed, harness_error=False), 1)

    def test_terminal_perf(self):
        roles = {"daemon": {"count": 1, "footprint_each_bytes": 4e7, "threads": 30},
                 "hosts": {"count": 10, "footprint_each_bytes": 3e6, "threads": 9}}
        report = {"idle": [{"terminals": 10, "roles": roles}],
                  "scrollback": {"mb_per_10k_lines": {"daemon": 1.0, "hosts": 2.0}},
                  "throughput": {"mb": 64, "seconds": 2.0, "host_seen": True},
                  "busy": {"cpu_pct": {"daemon": 1.5, "hosts": 3.0}}}
        series = {s.metric: s for s in tperf.lab_series(report)}
        self.assertEqual(series["daemon.terminal_perf.throughput"].samples, [32 * tperf.MB])
        self.assertClaimed("daemon-terminal-perf", list(series.values()))
        self.write_and_read("daemon-terminal-perf", list(series.values()))
        unseen = {**report, "throughput": {"mb": 64, "seconds": 30.6, "host_seen": False}}
        self.assertNotIn("daemon.terminal_perf.throughput", {s.metric for s in tperf.lab_series(unseen)})

    def test_terminal_perf_short_idle_step_records_nothing(self):
        # wait_hosts timed out: 6 of 10 hosts came up, so the hosts' thread total is that of 6.
        short = {"daemon": {"count": 1, "footprint_each_bytes": 4e7, "threads": 30},
                 "hosts": {"count": 6, "footprint_each_bytes": 3e6, "threads": 5}}
        full = {**short, "hosts": {**short["hosts"], "count": 1}}
        report = {"idle": [{"terminals": 1, "roles": full}, {"terminals": 10, "roles": short}],
                  "scrollback": None, "throughput": None, "busy": None}
        metrics = {s.metric for s in tperf.lab_series(report)}
        self.assertIn("daemon.terminal_perf.idle.1.hosts.threads", metrics)
        self.assertEqual({m for m in metrics if m.startswith("daemon.terminal_perf.idle.10.")}, set())

    def test_daemon_latency(self):
        res = {"ops": {"ping": latency.stats([0.1, 0.2]), "close-tabs": {"n": 0, "skipped": "not advertised"}},
               "concurrent": {"c10-ping": latency.stats([0.3])},
               "automation_storm": {"storm": {"echo": latency.stats([1.0]),
                                              "automation": latency.stats([2.0], keep_samples=False)}}}
        series = latency.lab_series({"scenarios": {"small": res}})
        self.assertEqual(sorted(s.metric for s in series), ["daemon.latency.small.automation_storm.storm.echo",
                                                             "daemon.latency.small.c10_ping",
                                                             "daemon.latency.small.ping"])
        self.assertClaimed("daemon-latency", series)
        self.write_and_read("daemon-latency", series)

    def test_daemon_latency_failed_rows_record_nothing(self):
        res = {"ops": {"ping": latency.stats([0.1, 0.2]),
                       # 3 samples, then a DaemonError: the op loop keeps them with `error`.
                       "split": {**latency.stats([1.0, 2.0, 3.0]), "error": "timed out"}},
               "cli": {"cli-ping": latency.stats([5.0]),
                       "cli-terminal-write": {"n": 0, "error": "no working CLI form"}},
               "concurrent": {"c10-ping": latency.stats([0.3]), "errors": ["ConnectionResetError()"]},
               "bulk_interference": {"bulk-64k-ping-same": latency.stats([0.4]),
                                     "bulk-64k-ping-other": {**latency.stats([0.5]), "error": "client died"}},
               "automation_storm": {"storm": {"echo": latency.stats([1.0]),
                                              "automation": {**latency.stats([2.0], keep_samples=False),
                                                             "clients_cover_window": False}}},
               "locks": {**latency.stats([9.0]), "error": "RuntimeError('section failed')"}}
        series = latency.lab_series({"scenarios": {"small": res, "scale": {"error": "start failed"}}})
        self.assertEqual(sorted(s.metric for s in series), ["daemon.latency.small.cli_ping",
                                                             "daemon.latency.small.ping"])


class RustBenches(Claims):
    def test_parse_corpus_is_fixed(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = os.path.join(tmp, "a"), os.path.join(tmp, "b")
            rust.write_corpus(a, 20000)
            rust.write_corpus(b, 20000)
            self.assertEqual(Path(a).read_bytes(), Path(b).read_bytes())
            self.assertIn(b"\x1b[", Path(a).read_bytes())

    def test_outputs_parse(self):
        row = rust.json_line('noise\n{"spawnbench":200,"terminal_new_us":12.5,"openpty_us":30.0}\n', "spawnbench")
        self.assertEqual(row["terminal_new_us"], 12.5)
        line = "test echo_behind_two_flooders ... ECHO-BEHIND-FLOODERS p50_ms=0.78 p95_ms=1.77 max_ms=2.42 flood_mib=128"
        self.assertEqual(rust.fields(line, "ECHO-BEHIND-FLOODERS"),
                         {"p50_ms": 0.78, "p95_ms": 1.77, "max_ms": 2.42, "flood_mib": 128.0})
        with self.assertRaises(rust.BenchError):
            rust.fields("nothing", "YES-X4")

    def test_series_are_claimed(self):
        claimed = {
            "mux2-parse": ["mux2.parse.wrapper", "mux2.parse.raw", "mux2.parse.wrapper_overhead"],
            "mux2-spawn": ["mux2.spawn.terminal_new", "mux2.spawn.posix_spawn"],
            "holder-link": ["holder.link.echo.p95", "holder.link.yes4.holder", "holder.link.yes4.daemon_cpu"],
            "rd-host-g2g": ["rd.g2g.p99", "rd.decode.p95", "rd.lost", "rd.frames"],
        }
        for story_id, names in claimed.items():
            self.assertEqual(rust.STORIES[next(k for k, v in rust.STORIES.items() if v == story_id)], story_id)
            for name in names:
                hits = [m for m in story(story_id).metrics if re.fullmatch(m.name, name)]
                self.assertEqual(len(hits), 1, f"{story_id}: {name}")


class Catalog(unittest.TestCase):
    STORIES = ("daemon-latency", "daemon-lifecycle", "daemon-terminal-create", "daemon-terminal-perf", "daemon-scale",
               "mux2-parse", "mux2-spawn", "holder-link", "rd-host-g2g")

    def test_daemon_stories_are_in_the_catalog(self):
        loaded = catalog.load_catalog(ROOT)
        self.assertEqual([p for p in loaded.problems if any(s in p for s in self.STORIES)], [])
        by_id = {s.id: s for s in loaded.stories}
        for story_id in self.STORIES:
            self.assertEqual(by_id[story_id].owner, "PL-daemon", story_id)

    def test_commands_take_the_runner_flags(self):
        run_story = lab.perf_import.load("run_story")
        stories = {s.id: s for s in catalog.load_catalog(ROOT).stories}
        for story_id in self.STORIES:
            self.assertEqual(run_story.contract_problems(stories[story_id], str(ROOT)), [], story_id)

    def test_mq1_lists_none_of_the_benches(self):
        queues = lab.perf_import.load("queues")
        hits = {item.key for item in queues.private_stats(str(ROOT))}
        self.assertEqual(sorted(h for h in hits if h.startswith("cmux-tui/scripts/")), [])


if __name__ == "__main__":
    unittest.main()
