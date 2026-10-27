#!/usr/bin/env python3
"""trace_quest.py: first and median attempt traces, R2 by digest, links and the 30-day retention.

  python3 -m unittest scripts/perf-lab/tests/test_trace_quest.py
"""
from __future__ import annotations

import contextlib
import gzip
import hashlib
import importlib.util
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, HERE.parent / file)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


tq = load("perf_lab_trace_quest", "trace_quest.py")
store = load("perf_lab_store_for_traces", "store.py")
perf_result = load("perf_result_for_traces", "perf_result.py")

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
def sha(pos: int) -> str:
    return hashlib.sha1(str(pos).encode()).hexdigest()


HOST = store.Host(name="cmux15", chip="Apple M4 Pro", memory_gb=24, display_hz=120, fingerprint="fp-1")


class FakeBlobs:
    def __init__(self, clock=lambda: NOW) -> None:
        self.objects: dict[str, tuple[bytes, datetime]] = {}
        self.clock = clock
        self.deleted: list[str] = []

    def put(self, key, data, content_type):
        assert content_type == "application/gzip"
        self.objects[key] = (data, self.clock())

    def delete(self, key):
        self.objects.pop(key, None)
        self.deleted.append(key)

    def size(self, key):
        return len(self.objects[key][0]) if key in self.objects else None

    def list(self, prefix):
        return [(key, at) for key, (_, at) in sorted(self.objects.items()) if key.startswith(prefix)]

    def url_for(self, key):
        return f"https://lab.example/{key}"


class FakeSource:
    """Writes its trace file on stop, as trace.py's recorders do."""

    def __init__(self, path: Path, text: str, log: list[str], fail_stop: bool = False) -> None:
        self.path, self.text, self.log, self.fail_stop = path, text, log, fail_stop

    def start(self):
        self.log.append(f"start {self.path.name}")

    def stop(self):
        self.log.append(f"stop {self.path.name}")
        if self.fail_stop:
            raise OSError("tail did not end")
        self.path.write_text(self.text)

    def kill(self):
        self.log.append(f"kill {self.path.name}")


def fake_sources(log, fail_stop=False):
    def factory(directory, rpc, spans_path):
        made = [FakeSource(directory / "signposts.ndjson", f"signposts {directory.name}\n", log)]
        if rpc is not None:
            made.append(FakeSource(directory / "hangs.json", json.dumps({"records": [directory.name]}), log))
        if spans_path is not None:
            made.append(FakeSource(directory / "daemon-spans-stamped.jsonl", "", log, fail_stop))
        return made
    return factory


class PickAttemptsTests(unittest.TestCase):
    def test_first_and_lower_median(self):
        self.assertEqual(tq.pick_attempts([5.0, 1.0, 9.0, 3.0]), [0, 3])  # sorted 1,3,5,9: lower median 3

    def test_first_is_median(self):
        self.assertEqual(tq.pick_attempts([2.0, 1.0, 3.0]), [0])

    def test_failed_attempt_is_never_the_median(self):
        self.assertEqual(tq.pick_attempts([None, 4.0, None, 2.0, 6.0]), [0, 1])

    def test_tie_takes_the_earlier_attempt(self):
        self.assertEqual(tq.pick_attempts([9.0, 1.0, 1.0]), [0, 1])

    def test_empty(self):
        self.assertEqual(tq.pick_attempts([]), [])


class QuestTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.blobs = FakeBlobs()

    def tearDown(self):
        self._tmp.cleanup()

    def test_records_every_attempt_and_keeps_first_and_median(self):
        log: list[str] = []
        quest = tq.TraceQuest(self.root / "story", self.blobs, fake_sources(log))
        values = [7.0, 3.0, 5.0, 9.0, 4.0]
        for attempt in range(len(values)):
            with quest.record(attempt, rpc=lambda *a, **k: None) as directory:
                self.assertTrue(directory.is_dir())
        self.assertEqual(log.count("start signposts.ndjson"), 5)
        refs = quest.publish(values)
        self.assertEqual(sorted(refs), [0, 2])  # sorted 3,4,5,7,9: the median 5 is attempt 2
        self.assertEqual(sorted(path.name for path in (self.root / "story").iterdir()),
                         ["attempt-000", "attempt-002"])
        kinds = [ref.attachment_kind for attempt in sorted(refs) for ref in refs[attempt]]
        self.assertEqual(kinds, ["trace-signpost-0", "trace-watchdog-0", "trace-signpost-2", "trace-watchdog-2"])
        for attempt in refs:
            for ref in refs[attempt]:
                data, _ = self.blobs.objects[tq.blob_key(ref.digest)]
                self.assertEqual(ref.digest, "sha256:" + hashlib.sha256(data).hexdigest())
                self.assertEqual(ref.bytes, len(data))
        signposts = gzip.decompress(self.blobs.objects[tq.blob_key(refs[2][0].digest)][0]).decode()
        self.assertEqual(signposts, "signposts attempt-002\n")

    def test_same_bytes_give_the_same_digest(self):
        for name in ("a", "b"):
            (self.root / name).mkdir()
            (self.root / name / "signposts.ndjson").write_text("same\n")
        first = tq.publish_attempt(self.root / "a", 0, self.blobs)
        second = tq.publish_attempt(self.root / "b", 3, self.blobs)
        self.assertEqual(first[0].digest, second[0].digest)
        self.assertEqual(len(self.blobs.objects), 1)

    def test_empty_source_is_not_uploaded(self):
        quest = tq.TraceQuest(self.root / "s", self.blobs, fake_sources([]))
        with quest.record(0, spans_path=self.root / "spans.jsonl"):
            pass
        refs = quest.publish([1.0])
        self.assertEqual([ref.source for ref in refs[0]], ["signpost"])

    def test_every_source_stops_when_one_stop_fails(self):
        log: list[str] = []
        quest = tq.TraceQuest(self.root / "s", self.blobs, fake_sources(log, fail_stop=True))
        with self.assertRaises(tq.TraceQuestError):
            with quest.record(0, rpc=lambda *a, **k: None, spans_path=self.root / "spans.jsonl"):
                pass
        self.assertEqual([line for line in log if line.startswith("stop")],
                         ["stop daemon-spans-stamped.jsonl", "stop hangs.json", "stop signposts.ndjson"])

    def test_a_source_whose_stop_fails_is_killed(self):
        log: list[str] = []
        quest = tq.TraceQuest(self.root / "s", self.blobs, fake_sources(log, fail_stop=True))
        with self.assertRaises(tq.TraceQuestError):
            with quest.record(0, rpc=lambda *a, **k: None, spans_path=self.root / "spans.jsonl"):
                pass
        self.assertEqual([line for line in log if line.startswith(("stop", "kill"))],
                         ["stop daemon-spans-stamped.jsonl", "kill daemon-spans-stamped.jsonl", "stop hangs.json",
                          "stop signposts.ndjson"])

    def test_publish_refuses_values_that_do_not_match_the_attempts(self):
        quest = tq.TraceQuest(self.root / "s", self.blobs, fake_sources([]))
        with quest.record(0):
            pass
        with self.assertRaises(tq.TraceQuestError):
            quest.publish([1.0, 2.0])

    def test_attachments_are_valid_result_v1(self):
        quest = tq.TraceQuest(self.root / "s", self.blobs, fake_sources([]))
        for attempt in range(3):
            with quest.record(attempt, rpc=lambda *a, **k: None):
                pass
        refs = quest.publish([3.0, 1.0, 2.0])
        result = perf_result.Result(
            story="terminal.key-frame.light", metric="key_to_frame_ms", unit="ms", better="lower", samples=[1.0],
            build=perf_result.Build(sha="a" * 40, config="bench", measure_version=1),
            host=perf_result.Host(fingerprint="f" * 64, host_class="m4pro/24gb/120hz", chip="Apple M4 Pro",
                                  macos="26.1", macos_build="25B78", display_hz=120),
            engine="webkit", session="light", run=perf_result.Run.start(now=lambda: NOW),
            attachments=[perf_result.Attachment(digest="sha256:" + "0" * 64, kind="histogram")])
        [traced] = tq.with_traces([result], refs, perf_result)
        traced.validate()
        self.assertEqual([a.kind for a in traced.attachments],
                         ["histogram", "trace-signpost-0", "trace-watchdog-0", "trace-signpost-2", "trace-watchdog-2"])


class StoreTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.path = Path(self._tmp.name) / "lab.sqlite"
        self.now = NOW
        self.store = store.Store(self.path, clock=lambda: self.now)
        self.store.migrate()
        self.db = tq.connect(self.path)
        self.blobs = FakeBlobs(clock=lambda: self.now)

    def tearDown(self):
        self.db.close()
        self.store.close()
        self._tmp.cleanup()

    def put_trace(self, text: str, source: str = "signpost", attempt: int = 0) -> dict:
        data = gzip.compress(text.encode(), mtime=0)
        digest = "sha256:" + hashlib.sha256(data).hexdigest()
        self.blobs.put(tq.blob_key(digest), data, "application/gzip")
        return {"digest": digest, "kind": f"trace-{source}-{attempt}"}

    def job(self, kind: str, *, group: int | None = None, base: str | None = None, head: str | None = None) -> int:
        stamp = tq.stamp(self.now)
        return self.db.execute(
            "INSERT INTO jobs (kind, state, story, base_sha, head_sha, alert_group_id, created_at, updated_at) "
            "VALUES (?, 'done', 'story', ?, ?, ?, ?, ?)", (kind, base, head, group, stamp, stamp)).lastrowid

    def group(self, *, verified: bool = False) -> int:
        stamp = tq.stamp(self.now)
        return self.db.execute(
            "INSERT INTO alert_groups (state, start_pos, end_pos, culprit_verified, created_at, updated_at) "
            "VALUES ('culprit', 10, 12, ?, ?, ?)", (int(verified), stamp, stamp)).lastrowid

    def add_run(self, uuid: str, pos: int, *, kind: str = "waterfall", job: int | None = None, tier: str | None = "T0",
            attachments: list | None = None, index: bool = True) -> None:
        self.store.insert_run(
            store.Run(run_uuid=uuid, kind=kind, measure_version="1", story="story", engine="webkit", macos_major=26,
                      macos_build="25B78", features_hash="f", safe_mode="off", started_at=self.now, tier=tier,
                      job_id=job, attachments=attachments or []),
            build=store.Build(sha=sha(pos), config="bench", commit_pos=pos), host=HOST,
            metrics=[store.Metric(name="key_to_frame_ms", unit="ms", better="lower", samples=[1.0, 2.0])])
        if index:
            tq.index_run(self.db, uuid, self.blobs, clock=lambda: self.now)

    def alert(self, group: int, start: int, end: int) -> None:
        series = self.db.execute("SELECT id FROM series").fetchone()[0]
        self.db.execute("INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, created_at) "
                        "VALUES (?, ?, 'edivisive', ?, ?, ?)", (series, group, start, end, tq.stamp(self.now)))

    def test_index_links_a_point_to_its_traces_and_is_idempotent(self):
        self.add_run("p1", 1, attachments=[self.put_trace("a"), self.put_trace("b", "watchdog", 3),
                                       {"digest": "sha256:" + "0" * 64, "kind": "histogram"}])
        self.assertEqual(tq.index_run(self.db, "p1", self.blobs), tq.IndexReport(0, []))
        rows = tq.traces_for_point(self.db, "p1")
        self.assertEqual([(r["kind"], r["attempt"]) for r in rows], [("signpost", 0), ("watchdog", 3)])
        self.assertTrue(rows[0]["url"].startswith("https://lab.example/perf-lab/traces/sha256/"))
        stored = self.db.execute("SELECT bytes FROM traces ORDER BY attempt").fetchall()
        self.assertTrue(all(row[0] > 0 for row in stored))

    def test_index_reports_an_attachment_missing_from_r2_and_indexes_the_rest(self):
        lost = {"digest": "sha256:" + "1" * 64, "kind": "trace-daemon-0"}
        self.add_run("p1", 1, attachments=[lost, self.put_trace("kept", "watchdog", 0)], index=False)
        report = tq.index_run(self.db, "p1", self.blobs)
        self.assertEqual(report, tq.IndexReport(1, [f"trace-daemon-0 {lost['digest']}"]))
        self.assertEqual([r["kind"] for r in tq.traces_for_point(self.db, "p1")], ["watchdog"])

    def test_issue_links_list_bisect_changes_in_commit_order(self):
        group = self.group()
        bisect = self.job("bisect", group=group)
        positions = [10, 11, 12, 13, 14, 15]
        self.assertNotEqual(sorted(positions, key=sha), positions)  # the sha hex order is not the commit order
        for pos in reversed(positions):
            self.add_run(f"b{pos}", pos, kind="bisect", job=bisect, tier=None, attachments=[self.put_trace(f"b{pos}")])
        lines = tq.issue_markdown(self.db, group).splitlines()[1:]
        self.assertEqual(lines, [line for pos in positions for line in lines if f"`{sha(pos)[:12]}`" in line])
        self.assertEqual(len(lines), len(positions))

    def test_coverage_counts_an_ingested_trace_digest_before_index(self):
        group = self.group(verified=True)
        bisect = self.job("bisect", group=group)
        verify = self.job("verify", group=group, base=sha(10), head=sha(11))
        self.add_run("t0", 1, attachments=[self.put_trace("t0")], index=False)
        self.add_run("b10", 10, kind="bisect", job=bisect, tier=None, attachments=[self.put_trace("b10")], index=False)
        self.add_run("v10", 10, kind="verify", job=verify, tier=None, attachments=[self.put_trace("v10")], index=False)
        self.add_run("v11", 11, kind="verify", job=verify, tier=None, attachments=[self.put_trace("v11")])
        missing = tq.coverage(self.db, NOW - timedelta(hours=1))
        self.assertEqual({name: missing[name] for name in tq.COVERAGE_MISSES},
                         {"t0_points": [], "bisect_changes": [], "verified_culprits": []})
        self.assertEqual(missing["not_indexed"], ["t0", "b10", "v10"])
        with contextlib.redirect_stdout(io.StringIO()):
            code = tq.main(["coverage", "--db", str(self.path), "--since", "1h"], clock=lambda: NOW)
        self.assertEqual(code, 0)

    def test_expire_keeps_the_objects_of_a_referenced_run_that_was_never_indexed(self):
        group = self.group()
        verify = self.job("verify", group=group, base=sha(10), head=sha(11))
        self.add_run("v10", 10, kind="verify", job=verify, tier=None, attachments=[self.put_trace("C^")], index=False)
        self.add_run("p11", 11, attachments=[self.put_trace("alert point")], index=False)
        self.add_run("plain", 3, attachments=[self.put_trace("plain")], index=False)
        self.alert(group, 11, 11)
        self.now = NOW + timedelta(days=29)
        self.add_run("recent", 4, attachments=[self.put_trace("recent")], index=False)
        self.now = NOW + timedelta(days=31)
        report = tq.expire(self.db, self.blobs, now=self.now)
        left = {gzip.decompress(data).decode() for data, _ in self.blobs.objects.values()}
        self.assertEqual(left, {"C^", "alert point", "recent"})
        self.assertEqual(len(report.blobs), 1)  # plain: an old run nothing references
        self.assertEqual(tq.index_run(self.db, "v10", self.blobs).missing, [])

    def test_expire_binds_no_variable_per_alert_point(self):
        group = self.group()
        for pos in range(10, 16):
            self.add_run(f"p{pos}", pos, attachments=[self.put_trace(f"p{pos}")])
        self.alert(group, 10, 15)
        self.db.setlimit(sqlite3.SQLITE_LIMIT_VARIABLE_NUMBER, 3)  # fewer than the 6 alert-point runs
        self.now = NOW + timedelta(days=31)
        self.assertEqual(tq.expire(self.db, self.blobs, now=self.now), tq.ExpireReport(0, []))
        self.assertEqual(len(tq.traces_for_group(self.db, group)), 6)

    def test_coverage_names_untraced_points_changes_and_culprits(self):
        group = self.group(verified=True)
        bisect = self.job("bisect", group=group)
        verify = self.job("verify", group=group, base=sha(10), head=sha(11))
        self.add_run("t0-traced", 1, attachments=[self.put_trace("t")])
        self.add_run("t0-bare", 2)
        self.add_run("t1-bare", 3, tier="T1")
        self.add_run("b10", 10, kind="bisect", job=bisect, tier=None, attachments=[self.put_trace("b10")])
        self.add_run("b11", 11, kind="bisect", job=bisect, tier=None)
        self.add_run("v10", 10, kind="verify", job=verify, tier=None, attachments=[self.put_trace("v10")])
        missing = tq.coverage(self.db, NOW - timedelta(hours=1))
        self.assertEqual(missing["t0_points"], ["t0-bare"])
        self.assertEqual(missing["bisect_changes"], [f"job {bisect} {sha(11)}"])
        self.assertEqual(missing["verified_culprits"], [f"group {group} C {sha(11)}"])
        self.add_run("v11", 11, kind="verify", job=verify, tier=None, attachments=[self.put_trace("v11")])
        self.assertEqual(tq.coverage(self.db, NOW - timedelta(hours=1))["verified_culprits"], [])

    def test_issue_links_list_c_caret_and_c_first(self):
        group = self.group(verified=True)
        verify = self.job("verify", group=group, base=sha(10), head=sha(11))
        bisect = self.job("bisect", group=group)
        self.add_run("b10", 10, kind="bisect", job=bisect, tier=None, attachments=[self.put_trace("b10")])
        self.add_run("v11", 11, kind="verify", job=verify, tier=None, attachments=[self.put_trace("v11")])
        self.add_run("v10", 10, kind="verify", job=verify, tier=None, attachments=[self.put_trace("v10")])
        lines = tq.issue_markdown(self.db, group).splitlines()
        self.assertEqual(lines[0], "### Traces")
        self.assertTrue(lines[1].startswith(f"- C^ `{sha(10)[:12]}`: [signpost #0](https://lab.example/"), lines)
        self.assertTrue(lines[2].startswith(f"- C `{sha(11)[:12]}`:"), lines)
        self.assertTrue(lines[3].startswith(f"- bisect `{sha(10)[:12]}`:"), lines)

    def test_group_traces_include_the_alert_points_and_the_point_before(self):
        group = self.group()
        for pos in (8, 9, 10, 11, 13):
            self.add_run(f"p{pos}", pos, attachments=[self.put_trace(f"p{pos}")])
        self.alert(group, 10, 11)
        self.assertEqual(sorted({r["run_uuid"] for r in tq.traces_for_group(self.db, group)}), ["p10", "p11", "p9"])

    def test_runs_since_lists_each_runs_trace_digests(self):
        traced = [self.put_trace("t0"), self.put_trace("w", "watchdog", 4)]
        self.add_run("t0", 1, attachments=[*traced, {"digest": "sha256:" + "0" * 64, "kind": "histogram"}])
        self.add_run("ingested-only", 2, attachments=[self.put_trace("later", "daemon", 0)], index=False)
        self.now = NOW - timedelta(hours=2)
        self.add_run("old", 3, attachments=[self.put_trace("old")])
        runs = tq.runs_since(self.db, NOW - timedelta(hours=1))
        self.assertEqual([r["run_uuid"] for r in runs], ["t0", "ingested-only"])
        self.assertEqual([(t["source"], t["attempt"], t["digest"], t["indexed"]) for t in runs[0]["traces"]],
                         [("signpost", 0, traced[0]["digest"], True), ("watchdog", 4, traced[1]["digest"], True)])
        self.assertTrue(runs[0]["traces"][0]["url"].startswith("https://lab.example/perf-lab/traces/sha256/"))
        self.assertEqual([(t["source"], t["indexed"], "url" in t) for t in runs[1]["traces"]], [("daemon", False, False)])
        self.assertEqual(tq.runs_since(self.db, NOW - timedelta(days=1), kind="bisect"), [])

    def test_lab_runs_json_shows_digests(self):
        """The task's test phase: `lab.py runs --since 1h --json` through lab.py's command discovery."""
        attachment = self.put_trace("t0")
        self.add_run("t0", 1, attachments=[attachment])
        lab = load("perf_lab_lab_for_traces", "lab.py")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            # lab.py imports its own trace_quest with the wall clock, so the test passes an ISO time, not 1h.
            code = lab.main(["runs", "--db", str(self.path), "--since", (NOW - timedelta(hours=1)).isoformat(), "--json"])
        self.assertEqual(code, 0)
        runs = json.loads(out.getvalue())
        self.assertEqual([t["digest"] for r in runs for t in r["traces"]], [attachment["digest"]])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(tq.main(["runs", "--db", str(self.path), "--since", "1h"], clock=lambda: NOW), 0)
        self.assertIn("signpost#0=" + attachment["digest"][7:19], out.getvalue())

    def test_lab_traces_links_prints_the_issue_section(self):
        group = self.group(verified=True)
        verify = self.job("verify", group=group, base=sha(10), head=sha(11))
        self.add_run("v10", 10, kind="verify", job=verify, tier=None, attachments=[self.put_trace("v10")])
        lab = load("perf_lab_lab_for_traces_links", "lab.py")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(lab.main(["traces", "links", "--db", str(self.path), "--group", str(group)]), 0)
        self.assertTrue(out.getvalue().startswith("### Traces\n- C^ "), out.getvalue())

    def test_expire_keeps_referenced_and_recent_traces(self):
        group = self.group()
        bisect = self.job("bisect", group=group)
        try_job = self.job("try")
        self.add_run("old-alert", 10, attachments=[self.put_trace("alert point")])
        self.add_run("old-before", 9, attachments=[self.put_trace("point before")])
        self.add_run("old-plain", 5, attachments=[self.put_trace("plain")])
        self.add_run("old-bisect", 12, kind="bisect", job=bisect, tier=None, attachments=[self.put_trace("bisect")])
        self.add_run("old-try", 12, kind="try", job=try_job, tier=None, attachments=[self.put_trace("try")])
        self.put_trace("never ingested")
        shared = self.put_trace("shared")
        self.add_run("old-shared", 4, attachments=[shared])
        self.alert(group, 10, 10)
        self.now = NOW + timedelta(days=29)
        self.add_run("new-shared", 20, attachments=[shared])
        self.add_run("new-plain", 21, attachments=[self.put_trace("recent")])
        self.now = NOW + timedelta(days=31)

        preview = tq.expire(self.db, self.blobs, now=self.now, dry_run=True)
        self.assertEqual(preview.rows, 3)  # old-plain, old-try, old-shared
        self.assertEqual(self.blobs.deleted, [])
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM traces").fetchone()[0], 8)

        report = tq.expire(self.db, self.blobs, now=self.now)
        self.assertEqual(report.rows, 3)
        left = sorted(row[0] for row in self.db.execute(
            "SELECT u.run_uuid FROM traces t JOIN runs u ON u.id = t.run_id"))
        self.assertEqual(left, ["new-plain", "new-shared", "old-alert", "old-before", "old-bisect"])
        gone = {gzip.decompress(data).decode() for key, (data, _) in list(self.blobs.objects.items())}
        self.assertEqual(gone, {"alert point", "point before", "bisect", "shared", "recent"})
        self.assertEqual(len(report.blobs), 3)  # plain, try, never ingested; shared is still named by new-shared
        self.assertEqual(sorted(report.blobs), sorted(preview.blobs))


class SigV4Tests(unittest.TestCase):
    def test_aws_documented_get_object_example(self):
        # AWS's "Example: GET Object" for Signature Version 4 (Amazon S3 API reference, sig-v4-header-based-auth).
        headers = tq.sigv4_headers(
            method="GET", host="examplebucket.s3.amazonaws.com", path="/test.txt", query={},
            headers={"range": "bytes=0-9"},
            payload_sha256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            access_key="AKIAIOSFODNN7EXAMPLE", secret_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            now=datetime(2013, 5, 24, tzinfo=timezone.utc), region="us-east-1")
        self.assertTrue(headers["authorization"].endswith(
            "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"), headers["authorization"])

    def test_blob_keys_round_trip(self):
        digest = "sha256:" + "ab" * 32
        self.assertEqual(tq.digest_of_key(tq.blob_key(digest)), digest)
        self.assertIsNone(tq.digest_of_key("perf-lab/traces/sha256/zz.gz"))
        with self.assertRaises(tq.TraceQuestError):
            tq.blob_key("sha1:abc")


LIST_NS = "http://s3.amazonaws.com/doc/2006-03-01/"


class R2ErrorTests(unittest.TestCase):
    def test_list_page_reads_keys_and_the_continuation_token(self):
        body = (f'<ListBucketResult xmlns="{LIST_NS}"><IsTruncated>true</IsTruncated>'
                "<NextContinuationToken>next</NextContinuationToken><Contents><Key>perf-lab/traces/sha256/a.gz</Key>"
                "<LastModified>2026-10-25T12:00:00.000Z</LastModified></Contents></ListBucketResult>").encode()
        self.assertEqual(tq.parse_list_page(body), ([("perf-lab/traces/sha256/a.gz", NOW)], "next"))

    def test_bad_list_bodies_are_trace_quest_errors(self):
        for body in (b"<html>gateway", f'<ListBucketResult xmlns="{LIST_NS}"><Contents><Key>k</Key></Contents>'
                     "</ListBucketResult>".encode(),
                     b"<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>"):
            with self.subTest(body=body), self.assertRaises(tq.TraceQuestError):
                tq.parse_list_page(body)

    def test_an_http_protocol_error_is_a_trace_quest_error(self):
        blobs = tq.R2BlobStore("acct", "key", "secret", "bucket", clock=lambda: NOW)
        connection = mock.Mock()
        connection.getresponse.side_effect = tq.http.client.IncompleteRead(b"part")
        with mock.patch.object(tq.http.client, "HTTPSConnection", return_value=connection), \
                self.assertRaises(tq.TraceQuestError):
            list(blobs.list(tq.PREFIX))
        connection.close.assert_called_once()

    def test_expire_exits_2_when_r2_breaks(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "lab.sqlite"
            lab = store.Store(path, clock=lambda: NOW)
            lab.migrate()
            lab.close()
            env = {"CMUX_PERF_LAB_R2_ACCOUNT_ID": "a", "CMUX_PERF_LAB_R2_ACCESS_KEY_ID": "k",
                   "CMUX_PERF_LAB_R2_SECRET_ACCESS_KEY": "s"}
            with mock.patch.dict(os.environ, env), \
                    mock.patch.object(tq.R2BlobStore, "_request", return_value=(None, b"not xml")), \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(tq.main(["expire", "--db", str(path)], clock=lambda: NOW), 2)
            self.assertIn("not an XML list body", err.getvalue())


class TracePySourcesTests(unittest.TestCase):
    def test_uses_trace_py_recorders_without_xctrace(self):
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            spans = Path(tmp) / "spans.jsonl"
            spans.write_text("an earlier attempt\n")
            sources = tq.trace_py_sources(Path(tmp), lambda method, params, timeout: calls.append((method, params)),
                                          spans)
            self.assertEqual([type(source).__name__ for source in sources],
                             ["SignpostStream", "HangDrain", "FileFollower"])
            self.assertEqual(calls, [("debug.hangs", {"clear": True})])
            self.assertEqual(spans.read_bytes(), b"")
            self.assertEqual([type(source).__name__ for source in tq.trace_py_sources(Path(tmp), None, None)],
                             ["SignpostStream"])


class CliTests(unittest.TestCase):
    def test_store_without_traces_table_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "empty.sqlite"
            sqlite3.connect(path).close()
            self.assertEqual(tq.main(["links", "--db", str(path), "--group", "1"]), 2)

    def test_since_takes_a_duration_or_a_zoned_time(self):
        self.assertEqual(tq.parse_since("1h", NOW), NOW - timedelta(hours=1))
        self.assertEqual(tq.parse_since("30m", NOW), NOW - timedelta(minutes=30))
        self.assertEqual(tq.parse_since("7d", NOW), NOW - timedelta(days=7))
        self.assertEqual(tq.parse_since("2026-10-25T11:00:00+00:00", NOW), NOW - timedelta(hours=1))
        with self.assertRaises(tq.TraceQuestError):
            tq.parse_since("2026-10-25T11:00:00", NOW)

    def test_runs_without_a_store_fails_with_a_reason(self):
        clean = {k: v for k, v in os.environ.items() if k != tq.DB_ENV}
        with mock.patch.dict(os.environ, clean, clear=True), contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(tq.main(["runs", "--since", "1h"]), 2)
        self.assertIn(tq.DB_ENV, err.getvalue())

    def test_lab_declares_runs_and_traces(self):
        lab = load("perf_lab_lab_for_traces_discovery", "lab.py")
        commands = lab.discover()
        self.assertEqual({name: path.name for name, (path, _) in commands.items() if path.name == "trace_quest.py"},
                         {"runs": "trace_quest.py", "traces": "trace_quest.py"})

    def test_publish_without_r2_credentials_fails_with_a_reason(self):
        clean = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_PERF_LAB_R2_")}
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, clean, clear=True):
            self.assertEqual(tq.main(["publish", tmp, "--attempt", "0"]), 2)


if __name__ == "__main__":
    unittest.main()
