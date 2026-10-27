#!/usr/bin/env python3
"""state-corruption-e2e.py, the state-corruption chaos lane (p10-stability-174):

1. Each mutation damages the bytes it says (flip: up to 16 bytes, each changed, the same offsets for the same seed).
2. format_accepts is the format's own verdict: JSON and plist parsers (a torn or flipped XML plist included), and
   SQLite's integrity_check on the main file with any log left beside it; the baseline copy's logs are folded in.
3. Discovery finds regular files only and skips sockets, SQLite side files, empties, caches and Chromium user data.
4. Only this build's tagged socket is used, and the CLI names it with --app-socket; a shipped build's tag, the untagged
   sockets, shared roots and a shared bundle folder are refused, no path outside the tag's roots is written, and
   nothing moves while a process of the tag runs.
5. Faults name the damaged file by its path or set-aside and count only what the relaunch added; a crash report goes
   to the row that ran its pid or held its crash time, never to the next row.
6. A whole run against a fake app: one row per (file, mutation), the control finds the volatile and rewritten files,
   a JSON file the app sets aside passes, one it does not set aside fails, one whose damage resets another store
   fails, and the baseline is restored at the end.
7. The lanes registry declares the lane the way stability-lab.py reads it.

Runs on any host (Linux included): no app, no socket.

    python3 -I scripts/cmux-next/tests/test_state_corruption_e2e.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import plistlib
import random
import socket
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

HERE = Path(__file__).resolve().parent.parent


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


sc = load("state_corruption_e2e", HERE / "state-corruption-e2e.py")
lab = load("stability_lab", HERE / "stability-lab.py")

TAG = "sc-test"
BUNDLE = f"com.cmuxterm.app.debug.{TAG.replace('-', '.')}"


def sqlite_bytes(rows=200):
    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, "db.sqlite3")
        connection = sqlite3.connect(path)
        connection.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT)")
        connection.executemany("INSERT INTO t (body) VALUES (?)", [("x" * 300,)] * rows)
        connection.commit()
        connection.close()
        return Path(path).read_bytes()


class Mutations(unittest.TestCase):
    def test_truncate_keeps_the_first_half(self):
        damaged, detail = sc.mutate(b"0123456789", "truncate", random.Random(1))
        self.assertEqual((damaged, detail), (b"01234", {"kept": 5}))

    def test_flip_changes_each_chosen_byte_and_repeats_for_a_seed(self):
        data = bytes(range(256)) * 4
        damaged, detail = sc.mutate(data, "flip", sc.row_rng(7, "tag-state/a.json", "flip"))
        again, _ = sc.mutate(data, "flip", sc.row_rng(7, "tag-state/a.json", "flip"))
        changed = [i for i, (a, b) in enumerate(zip(data, damaged)) if a != b]
        self.assertEqual(changed, detail["offsets"])
        self.assertEqual(len(changed), sc.FLIP_BYTES)
        self.assertEqual(damaged, again)
        self.assertEqual(len(damaged), len(data))

    def test_flip_of_a_short_file_changes_every_byte(self):
        damaged, detail = sc.mutate(b"abc", "flip", random.Random(3))
        self.assertEqual(detail["offsets"], [0, 1, 2])
        self.assertTrue(all(a != b for a, b in zip(b"abc", damaged)))

    def test_zero_fill_and_zero_length(self):
        self.assertEqual(sc.mutate(b"abcd", "zero-fill", None)[0], b"\0\0\0\0")
        self.assertEqual(sc.mutate(b"abcd", "zero-length", None)[0], b"")
        with self.assertRaises(ValueError):
            sc.mutate(b"abcd", "shred", None)


class Formats(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(sc.kind_of("registry.sqlite3", sc.SQLITE_MAGIC), "sqlite")
        self.assertEqual(sc.kind_of("noext", sc.SQLITE_MAGIC), "sqlite")
        self.assertEqual(sc.kind_of("cmux-next.json", b"{"), "json")
        self.assertEqual(sc.kind_of("terminal-losses.jsonl", b"{"), "jsonl")
        self.assertEqual(sc.kind_of("x.plist", b"<?xml"), "plist")
        self.assertEqual(sc.kind_of("snapshot", b"\x01\x02"), "other")

    def test_json(self):
        self.assertTrue(sc.format_accepts("json", b'{"a": 1}'))
        self.assertFalse(sc.format_accepts("json", b'{"a": '))
        self.assertFalse(sc.format_accepts("json", b""))
        self.assertFalse(sc.format_accepts("json", b"\xff\xfe"))

    def test_plist(self):
        self.assertTrue(sc.format_accepts("plist", plistlib.dumps({"a": 1}, fmt=plistlib.FMT_BINARY)))
        self.assertFalse(sc.format_accepts("plist", b"\0" * 40))

    def test_damaged_xml_plists_are_rejected_not_raised(self):
        """Expat's error (a torn or flipped XML plist) and an unknown encoding are the format's verdict, never an
        exception out of the row after the file is already damaged."""
        data = plistlib.dumps({"workspaces": ["a", "b"], "window": {"x": 1, "y": 2.5}, "on": True},
                              fmt=plistlib.FMT_XML)
        self.assertTrue(sc.format_accepts("plist", data))
        self.assertFalse(sc.format_accepts("plist", sc.mutate(data, "truncate", None)[0]))
        for seed in range(200):
            flipped, _ = sc.mutate(data, "flip", random.Random(seed))
            self.assertIn(sc.format_accepts("plist", flipped), (True, False), seed)
        self.assertFalse(sc.format_accepts("plist", data.replace(b"UTF-8", b"UTF-Q")))
        self.assertFalse(sc.format_accepts("plist", sc.mutate(data, "zero-fill", None)[0]))

    def test_sqlite_uses_its_own_integrity_check(self):
        data = sqlite_bytes()
        self.assertTrue(sc.format_accepts("sqlite", data))
        self.assertTrue(sc.format_accepts("sqlite", b""), "an empty file is an empty database")
        self.assertFalse(sc.format_accepts("sqlite", bytes(len(data))))
        self.assertFalse(sc.format_accepts("sqlite", sc.mutate(data, "truncate", None)[0]))

    def wal_database(self, scratch):
        """(main bytes, wal bytes) of a WAL database whose rows are still only in its log: copied while the
        writer holds it open, as a teardown that kills the daemon leaves it."""
        path = os.path.join(scratch, "live.sqlite3")
        writer = sqlite3.connect(path)
        writer.execute("PRAGMA journal_mode=WAL")
        writer.execute("PRAGMA wal_autocheckpoint=0")
        writer.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT)")
        writer.executemany("INSERT INTO t (body) VALUES (?)", [("y" * 300,)] * 50)
        writer.commit()
        main, wal = Path(path).read_bytes(), Path(path + "-wal").read_bytes()
        writer.close()
        return main, wal

    def test_sqlite_reads_a_left_log_with_its_file(self):
        with tempfile.TemporaryDirectory() as scratch:
            main, wal = self.wal_database(scratch)
            self.assertTrue(wal)
            self.assertTrue(sc.format_accepts("sqlite", main, wal))
            zeroed = bytes(len(main))
            self.assertFalse(sc.format_accepts("sqlite", zeroed), "the main file alone is damaged")
            self.assertTrue(sc.format_accepts("sqlite", zeroed, wal),
                            "but a reader that finds the log replays it over the damaged pages")
            self.assertFalse(sc.format_accepts("sqlite", zeroed, bytes(len(wal))))

    def test_checkpoint_folds_the_log_into_the_baseline_copy(self):
        with tempfile.TemporaryDirectory() as scratch:
            main, wal = self.wal_database(scratch)
            copy = os.path.join(scratch, "pristine", "tui")
            os.makedirs(copy)
            Path(copy, "registry.sqlite3").write_bytes(main)
            Path(copy, "registry.sqlite3-wal").write_bytes(wal)
            Path(copy, "notes.txt-wal").write_bytes(b"not a database's log")
            done = sc.checkpoint_sqlite(os.path.join(scratch, "pristine"))
            db = os.path.join(copy, "registry.sqlite3")
            self.assertEqual(done, {db: "folded"})
            self.assertFalse(os.path.exists(db + "-wal"), "no log is left to replay over a damaged main file")
            immutable = sqlite3.connect(f"file:{db}?immutable=1", uri=True)
            self.assertEqual(immutable.execute("SELECT count(*) FROM t").fetchone(), (50,),
                             "the main file alone now holds every row")
            immutable.close()

    def test_logs_and_unknown_formats_have_no_verdict(self):
        self.assertIsNone(sc.format_accepts("jsonl", b"{"))
        self.assertIsNone(sc.format_accepts("other", b"\0"))


class Discovery(unittest.TestCase):
    def test_regular_files_only_with_the_skips(self):
        with tempfile.TemporaryDirectory() as root:
            files = {"tui/workspace-registry.sqlite3": sqlite_bytes(2), "tui/workspace-registry.sqlite3-wal": b"w",
                     "tui/workspace-registry.sqlite3-shm": b"s", "launch-snapshot.json": b"{}", "empty.json": b"",
                     "app.log": b"log", "a.json.corrupt-1": b"{", "chromium/Local State": b"{}",
                     "chromium/Default/Preferences": b"{}", "web/GPUCache/data_0": b"\1"}
            for relative, data in files.items():
                os.makedirs(os.path.dirname(os.path.join(root, relative)), exist_ok=True)
                Path(root, relative).write_bytes(data)
            os.symlink(os.path.join(root, "launch-snapshot.json"), os.path.join(root, "link.json"))
            sock = socket.socket(socket.AF_UNIX)
            sock_path = os.path.join(root, "s")
            try:
                sock.bind(sock_path)
            except OSError:
                sock_path = None  # a path too long for sun_path: the socket case is covered by the symlink
            targets, skipped = sc.discover({"tag-state": root})
            sock.close()
            self.assertEqual([(t["id"], t["kind"]) for t in targets],
                             [("tag-state/launch-snapshot.json", "json"),
                              ("tag-state/tui/workspace-registry.sqlite3", "sqlite")])
            why = {s["id"]: s["why"] for s in skipped}
            self.assertEqual(why["tag-state/chromium/"], "chromium user data")
            self.assertEqual(why["tag-state/web/GPUCache/"], "cache")
            self.assertEqual(why["tag-state/empty.json"], "empty")
            self.assertEqual(why["tag-state/link.json"], "not a regular file")
            for name in ("tui/workspace-registry.sqlite3-wal", "tui/workspace-registry.sqlite3-shm", "app.log",
                         "a.json.corrupt-1"):
                self.assertEqual(why[f"tag-state/{name}"], "skipped name")
            if sock_path:
                self.assertEqual(why["tag-state/s"], "not a regular file")
            with_chromium, _ = sc.discover({"tag-state": root}, include_chromium=True)
            self.assertIn("tag-state/chromium/Default/Preferences", [t["id"] for t in with_chromium])

    def test_only_globs(self):
        targets = [{"id": "tag-state/tui/a.sqlite3"}, {"id": "scratch/settings/cmux-next.json"}]
        self.assertEqual(sc.select(targets, ["tag-state/tui/*"]), targets[:1])
        self.assertEqual(sc.select(targets, []), targets)


class Checks(unittest.TestCase):
    def test_set_aside_names(self):
        self.assertEqual(sc.set_aside_names("apps.json", ["apps.json"], ["apps.json", "apps.json.corrupt"]),
                         ["apps.json.corrupt"])
        self.assertEqual(sc.set_aside_names("r.sqlite3", ["r.sqlite3"], ["r.sqlite3", "r.corrupt-9", "other.corrupt"]),
                         ["r.corrupt-9"])
        self.assertEqual(sc.set_aside_names("a.json", ["a.json", "a.json.corrupt"], ["a.json", "a.json.corrupt"]), [],
                         "a set-aside that was already there is not this relaunch's")

    def test_fault_entries_name_the_file_by_its_path_or_its_set_aside(self):
        reply = {"entries": [
            {"fingerprint": "old", "last_ms": 50, "sample": "/x/apps.json is corrupt", "count": 1},
            {"fingerprint": "ctx", "last_ms": 150, "template": "moved <path> aside",
             "context": {"path": "/x/apps.json"}, "count": 2},
            {"fingerprint": "aside", "last_ms": 150,
             "sample": "apps.json was unreadable; moved it to apps.json.corrupt", "count": 1},
            {"fingerprint": "other", "last_ms": 150, "sample": "database disk image is malformed: corrupt", "count": 1},
            {"fingerprint": "longer", "last_ms": 150, "sample": "read /x/apps.json.bak: corrupt", "count": 1},
            {"fingerprint": "net", "last_ms": 150, "template": "network down", "count": 1}]}
        found = sc.fault_entries(reply, {}, 100, ["/x/apps.json"], ["apps.json.corrupt"])
        self.assertEqual([(e["fingerprint"], added) for e, added in found], [("ctx", 2), ("aside", 1)])
        self.assertEqual(sc.fault_entries({"error": "x"}, {}, 0, ["/x/a"]), [])
        self.assertEqual(sc.fault_entries(None, {}, 0, ["/x/a"]), [])

    def test_an_unrelated_running_warning_is_not_a_damaged_run_json_fault(self):
        """`run` is in `running`, and another file's warning says `corrupt`: neither is run.json's fault."""
        reply = {"entries": [
            {"fingerprint": "jobs", "last_ms": 150, "template": "running <n> jobs", "sample": "running 3 jobs",
             "count": 1},
            {"fingerprint": "cache", "last_ms": 150, "sample": "/x/other.json is corrupt; set aside", "count": 1},
            {"fingerprint": "runtime", "last_ms": 150, "sample": "runtime.json: corrupt",
             "context": {"path": "/x/runtime.json"}, "count": 1}]}
        self.assertEqual(sc.fault_entries(reply, {}, 100, ["/x/run.json"]), [])

    def test_faults_count_only_what_this_relaunch_added(self):
        """A fingerprint's count is its lifetime total; the journal on disk before the relaunch is subtracted."""
        reply = {"entries": [
            {"fingerprint": "aside", "last_ms": 150, "context": {"path": "/x/run.json"}, "count": 5},
            {"fingerprint": "same", "last_ms": 150, "context": {"path": "/x/run.json"}, "count": 3}]}
        found = sc.fault_entries(reply, {"aside": 4, "same": 3}, 100, ["/x/run.json"])
        self.assertEqual([(e["fingerprint"], added) for e, added in found], [("aside", 1)])

    def test_journal_counts_from_disk(self):
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, "segment-000001.ndjson").write_text(
                json.dumps({"fp": "a", "count": 2}) + "\n" + json.dumps({"fp": "b", "count": 7}) + "\n")
            Path(folder, "segment-000002.ndjson").write_text(
                json.dumps({"fp": "a", "count": 3}) + "\n{torn")
            Path(folder, "cursors.json").write_text("{}")
            self.assertEqual(sc.journal_counts(folder), {"a": 3, "b": 7}, "the newest line per fingerprint wins")
            self.assertEqual(sc.journal_counts(os.path.join(folder, "absent")), {})
            self.assertEqual(sc.journal_counts(None), {})

    def test_other_changes_find_a_reset_store(self):
        with tempfile.TemporaryDirectory() as root:
            def target(name, body):
                Path(root, name).write_bytes(body)
                return {"id": f"tag-state/{name}", "sha256": sc.hashlib.sha256(body).hexdigest()}
            kept, reset, gone, rewritten = (target("kept.json", b'{"a": 1}'), target("prefs.json", b'{"t": 1}'),
                                            target("gone.json", b"{}"), target("launches.json", b'{"n": 1}'))
            Path(root, "prefs.json").write_text("{}")
            Path(root, "launches.json").write_text('{"n": 2}')
            os.unlink(os.path.join(root, "gone.json"))
            live = lambda t: os.path.join(root, t["id"].split("/", 1)[1])  # noqa: E731
            control_kept = {"tag-state/kept.json", "tag-state/prefs.json", "tag-state/gone.json"}
            self.assertEqual(sc.other_changes([kept, reset, gone, rewritten], live, control_kept),
                             (["tag-state/gone.json"], ["tag-state/prefs.json"]))

    def row(self, **changes):
        row = {"app_started": True, "launch_error": None, "daemon_started": True, "app_alive": True,
               "crash_reports": [], "other_missing": [], "other_set_aside": [], "workspace_expected": True,
               "workspace_kept": True, "expect_set_aside": True, "set_aside": ["a.json.corrupt"], "faults": 1}
        row.update(changes)
        return row

    def test_verdicts(self):
        self.assertEqual(sc.problems_of(self.row()), [])
        self.assertEqual(sc.problems_of(self.row(expect_set_aside=False, set_aside=[], faults=0)), [])
        self.assertIn("the damaged file was not set aside as *.corrupt", sc.problems_of(self.row(set_aside=[])))
        self.assertIn("no fault was counted", sc.problems_of(self.row(faults=0)))
        self.assertTrue(sc.problems_of(self.row(app_started=False, launch_error="app-exited"))[0]
                        .startswith("the app did not start (app-exited)"))
        self.assertIn("no daemon answered", sc.problems_of(self.row(daemon_started=False)))
        self.assertEqual(sc.problems_of(self.row(workspace_expected=False, workspace_kept=False)), [])
        self.assertTrue(sc.problems_of(self.row(workspace_kept=False)))
        self.assertTrue(sc.problems_of(self.row(other_missing=["tag-state/x.json"])))
        self.assertTrue(sc.problems_of(self.row(crash_reports=["/r/cmux DEV-1.ips"])))
        self.assertTrue(sc.problems_of(self.row(other_changed=["tag-state/prefs.json"]))[0]
                        .startswith("other state rewritten"))


class CrashReports(unittest.TestCase):
    def test_report_facts_read_the_crash_time_not_the_write_time(self):
        with tempfile.TemporaryDirectory() as folder:
            ips = Path(folder, "cmux-tui-2026-10-27-101112.ips")
            ips.write_text(json.dumps({"app_name": "cmux-tui", "timestamp": "2026-10-27 10:11:12.00 +0000"}) + "\n"
                           + json.dumps({"pid": 77, "procPath": "/A/cmux DEV x.app/Contents/Resources/bin/cmux-tui"}))
            os.utime(ips, (2_000_000_000, 2_000_000_000))
            when, pid, executable = sc.report_facts(str(ips))
            self.assertEqual(when, 1793095872.0)
            self.assertEqual((pid, executable), (77, "/A/cmux DEV x.app/Contents/Resources/bin/cmux-tui"))
            text = Path(folder, "cmux DEV-2026.crash")
            text.write_text("Process:  cmux DEV [88]\nPath:  /A/x/Contents/MacOS/cmux DEV\n"
                            "Date/Time:  2026-10-27 10:11:13.500 +0000\n")
            self.assertEqual(sc.report_facts(str(text)), (1793095873.5, 88, "/A/x/Contents/MacOS/cmux DEV"))
            bare = Path(folder, "cmux DEV-bare.ips")
            bare.write_text("garbage")
            os.utime(bare, (1234.0, 1234.0))
            self.assertEqual(sc.report_facts(str(bare)), (1234.0, None, None))

    def test_a_late_report_belongs_to_its_own_row(self):
        ledger = sc.CrashLedger()
        first = ledger.open(10.0, "a.json flip")
        ledger.ran(first, [5, None])
        ledger.close(first, 20.0)
        second = ledger.open(30.0, "b.json flip")
        ledger.ran(second, [6])
        ledger.close(second, 40.0)
        facts = [("/r/late.ips", 15.0, None), ("/r/pid.ips", 35.0, 5), ("/r/own.ips", 35.0, None),
                 ("/r/own-pid.ips", 99.0, 6), ("/r/between.ips", 25.0, None)]
        self.assertEqual(ledger.take(facts, second), ["/r/own-pid.ips", "/r/own.ips"])
        self.assertEqual(ledger.late, [{"path": "/r/late.ips", "row": "a.json flip"},
                                       {"path": "/r/pid.ips", "row": "a.json flip"}])
        self.assertEqual(ledger.take(facts, second), ["/r/own-pid.ips", "/r/own.ips"], "a read again counts once")
        self.assertEqual(len(ledger.late), 2)
        third = ledger.open(50.0, "c.json flip")
        ledger.close(third, 60.0)
        self.assertEqual(ledger.take(facts, third), [], "the next row is never charged an earlier row's report")
        ledger.take([("/r/last.ips", 55.0, None)], None)
        self.assertEqual(ledger.late[-1], {"path": "/r/last.ips", "row": "c.json flip"})


class Safety(unittest.TestCase):
    def names(self, home="/Users/u"):
        return sc.build_names.names(BUNDLE, TAG, home)

    def test_only_the_tagged_socket(self):
        names = self.names()
        self.assertTrue(sc.socket_allowed(f"/Users/u/.local/state/cmux/cmux-debug-{TAG}.sock", TAG, names))
        self.assertTrue(sc.socket_allowed(names["socket"], TAG, names))
        for path in ("/tmp/cmux.sock", "/tmp/cmux-debug.sock", "/tmp/cmux-debug-other.sock",
                     "/tmp/cmux-debug-nightly.sock", "", None):
            self.assertFalse(sc.socket_allowed(path, TAG, names), path)
        self.assertFalse(sc.socket_allowed("/tmp/cmux-debug-nightly.sock", "nightly",
                                           sc.build_names.names("com.cmuxterm.app.debug", "nightly", "/Users/u")))

    def test_shipped_builds_are_refused(self):
        for bundle in ("com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc", "org.other"):
            with self.assertRaises(ValueError):
                sc.build_names.names(bundle, TAG, "/Users/u")
        with self.assertRaises(sc.Refused):
            sc.tag_roots("/s/cmux", "/Users/u", "nightly", self.names(), "/o/state", BUNDLE)
        with self.assertRaises(sc.Refused):
            sc.tag_roots("/s/cmux", "/Users/u", "..", self.names(), "/o/state", BUNDLE)

    def test_roots_are_the_builds_own(self):
        roots = sc.tag_roots("/s/cmux", "/Users/u", TAG, self.names(), "/o/state", BUNDLE)
        self.assertEqual(roots["tag-state"], f"/s/cmux/tags/{TAG}")
        self.assertEqual(roots["build-support"], f"/s/cmux/builds/{BUNDLE}")
        self.assertEqual(roots["app-support"], f"/s/{BUNDLE}", "History.sqlite and the error journal live here")
        self.assertEqual(roots["acpmux"], f"/Users/u/.acpmux/builds/{BUNDLE}")
        with self.assertRaises(sc.Refused):
            sc.tag_roots("/s/cmux", "/Users/u", TAG, self.names(), "/Users/u", BUNDLE)

    def test_the_bundle_folder_of_a_shipped_or_shared_id_is_refused(self):
        """`com.cmuxterm.app.debug` is every untagged DEV build's id: its folder is shared, never this run's."""
        for bundle in ("com.cmuxterm.app", "com.cmuxterm.app.debug", "com.cmuxterm.app.nightly",
                       "com.cmuxterm.app.nightly.x", "com.cmuxterm.app.debug/../x", "org.other.debug.x", "", None):
            with self.assertRaises(sc.Refused, msg=bundle):
                sc.tag_roots("/s/cmux", "/Users/u", TAG, self.names(), "/o/state", bundle)

    def test_the_real_cli_names_the_app_socket_as_the_app_socket(self):
        """Run.cli's own argv: `--app-socket`, never `--socket` (a daemon socket to the CLI), after the guard."""
        sock = f"/tmp/cmux-debug-{TAG}.sock"
        run = SimpleNamespace(socket=lambda: sock, bench=SimpleNamespace(cli="/A/bin/cmux"))
        with mock.patch.object(sc.bench_launch, "account_home", return_value="/Users/u"), \
                mock.patch.object(sc.subprocess, "run",
                                  return_value=sc.subprocess.CompletedProcess([], 0, "", "")) as ran:
            sc.Run.cli(run, "workspace", "create", "--name", "m", "--shell", "echo m")
        argv = ran.call_args.args[0]
        self.assertEqual(argv, ["/A/bin/cmux", "--app-socket", sock, "workspace", "create", "--name", "m",
                                "--shell", "echo m"])
        self.assertNotIn("--socket", argv)

        def refused():
            raise sc.Refused("not the tagged socket")
        with mock.patch.object(sc.subprocess, "run") as ran, self.assertRaises(sc.Refused):
            sc.Run.cli(SimpleNamespace(socket=refused, bench=run.bench), "workspace", "list")
        ran.assert_not_called()

    def test_guard_refuses_paths_outside_and_symlink_escapes(self):
        with tempfile.TemporaryDirectory() as base:
            root, outside = os.path.join(base, "root"), os.path.join(base, "real")
            os.makedirs(root)
            os.makedirs(outside)
            os.symlink(outside, os.path.join(root, "escape"))
            roots = {"tag-state": root}
            self.assertEqual(sc.guard(os.path.join(root, "a.json"), roots), os.path.join(root, "a.json"))
            for path in (os.path.join(outside, "a.json"), os.path.join(root, "escape", "a.json"),
                         os.path.join(root, "..", "real", "a.json"), root + "-sibling/a.json"):
                with self.assertRaises(sc.Refused, msg=path):
                    sc.guard(path, roots)

    def test_restore_waits_for_an_idle_tag(self):
        with tempfile.TemporaryDirectory() as base:
            root, pristine = os.path.join(base, "root"), os.path.join(base, "pristine")
            os.makedirs(root)
            Path(root, "a.json").write_text("{}")
            roots = {"tag-state": root}
            sc.copy_roots(roots, pristine)
            Path(root, "a.json").write_text("{")
            Path(root, "new.json").write_text("{}")
            with self.assertRaises(sc.Refused):
                sc.restore_roots(roots, pristine, lambda: False)
            self.assertEqual(Path(root, "a.json").read_text(), "{")
            sc.restore_roots(roots, pristine, lambda: True)
            self.assertEqual(sorted(os.listdir(root)), ["a.json"])
            self.assertEqual(Path(root, "a.json").read_text(), "{}")

    def test_state_sites_from_the_baseline(self):
        sites = sc.state_sites(Path(sc.STATE_ROOTS_BASELINE).read_text())
        self.assertIn("Packages/macOS/CmuxNext/Sources/CmuxNextCompat/BuildIdentity.swift", sites["resolvers"])
        self.assertTrue(sites["unreviewed"])
        self.assertFalse(set(sites["resolvers"]) & set(sites["unreviewed"]))


# ---------------------------------------------------------------- a whole run against a fake app

class FakeProcess:
    def __init__(self):
        self.ended = False
        self.pid = 4242

    def poll(self):
        return 0 if self.ended else None

    def kill(self):
        self.ended = True

    def wait(self, timeout=None):
        return 0


class FakeApp:
    """A cmux that keeps JSON stores and handles damage the way the lane expects, except:
    `stubborn.json`, which it reads and silently replaces (no set-aside, no fault), and `resetter.json`, whose damage
    it sets aside but also resets `prefs.json` to `{}` (another store lost to its defaults). Each launch writes
    `run.json` and each quit removes it (a volatile file), rewrites `launches.json` with its count (a file a clean
    relaunch rewrites), and journals an unrelated warning that says `running` and `corrupt`. The error journal is on
    disk in the bundle's own folder, as ErrorSegmentStore keeps it, so its lifetime counts carry over launches."""

    def __init__(self, app, out=None, env=None, log_name=None):
        self.app, self.tag = os.path.realpath(app), TAG
        self.config = {}
        self.env = env
        self.socket = f"/tmp/cmux-debug-{TAG}.sock"
        self.process = None
        self.teardown = None
        self.fresh_state = True
        self.binary = os.path.join(self.app, "Contents/MacOS/cmux DEV")
        self.cli = os.path.join(self.app, "Contents/Resources/bin/cmux")
        self.launches = 0
        self.lingering = False

    def state_root(self):
        return os.path.join(FakeApp.base, "tags", self.tag)

    def journal_dir(self):
        return os.path.join(os.path.dirname(FakeApp.base), BUNDLE, "errors")

    def tag_processes(self):
        if self.lingering or (self.process and not self.process.ended):
            return [(1, os.path.join(self.app, "Contents/Resources/bin/cmux-tui") + " --headless")]
        return []

    def journal(self):
        entries = {}
        for path in sorted(Path(self.journal_dir()).glob("segment-*.ndjson")):
            for line in path.read_bytes().split(b"\n"):
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if isinstance(entry, dict) and "fp" in entry:
                    entries[entry["fp"]] = entry
        return entries

    def note(self, fp, template, sample, context=None):
        entries = self.journal()
        entry = entries.get(fp) or {"fp": fp, "source": "app", "level": "warning", "template": template, "count": 0,
                                    "first_ms": int(time.time() * 1000)}
        entry.update(sample=sample, ctx=context or {}, count=entry["count"] + 1, last_ms=int(time.time() * 1000))
        entries[fp] = entry
        os.makedirs(self.journal_dir(), exist_ok=True)
        Path(self.journal_dir(), "segment-000001.ndjson").write_text(
            "".join(json.dumps(e) + "\n" for e in entries.values()))

    def read_store(self, path, empty):
        name = os.path.basename(path)
        try:
            return json.loads(Path(path).read_text())
        except FileNotFoundError:
            return empty
        except ValueError:
            if name != "stubborn.json":
                os.rename(path, path + ".corrupt")
                self.note(f"aside-{name}", "<path> was unreadable; moved it to <path>",
                          f"{name} was unreadable; moved it to {name}.corrupt")
                if name == "resetter.json":
                    Path(self.state_root(), "prefs.json").write_text("{}")
            return empty

    def launch(self, timeout=0):
        root = self.state_root()
        os.makedirs(os.path.join(root, "tui"), exist_ok=True)
        self.registry = os.path.join(root, "tui", "registry.json")
        self.workspaces = self.read_store(self.registry, {"workspaces": []})["workspaces"]
        self.read_store(os.path.join(root, "stubborn.json"), {})
        self.read_store(self.env["CMUX_NEXT_CONFIG_FILE"], {})
        if self.read_store(os.path.join(root, "resetter.json"), None) is None:
            Path(root, "resetter.json").write_text('{"r": 1}')
        if self.read_store(os.path.join(root, "prefs.json"), None) is None:
            Path(root, "prefs.json").write_text('{"theme": "dark"}')
        count = (self.read_store(os.path.join(root, "launches.json"), {}) or {}).get("n", 0)
        Path(root, "launches.json").write_text(json.dumps({"n": count + 1}))
        Path(root, "stubborn.json").write_text('{"ok": true}')
        Path(root, "run.json").write_text('{"pid": 4242}')
        self.note("unrelated", "running <n> jobs; a corrupt cache entry was dropped",
                  "running 3 jobs; a corrupt cache entry was dropped")
        self.save()
        self.process = FakeProcess()
        self.launches += 1
        return self

    def save(self):
        Path(self.registry).write_text(json.dumps({"workspaces": self.workspaces}))

    def quit_keep_sessions(self, timeout=30):
        Path(self.state_root(), "run.json").unlink(missing_ok=True)
        self.process.ended = True
        return {"quit": True}


class FakeRun(sc.Run):
    def cli(self, *argv, timeout=30):
        self.socket()
        app = self.bench
        if argv[:2] == ("workspace", "create"):
            app.workspaces.append(argv[3])
            app.save()
            return sc.subprocess.CompletedProcess(argv, 0, "OK workspace:2\n", "")
        if argv[:2] == ("workspace", "list"):
            return sc.subprocess.CompletedProcess(argv, 0, "\n".join(app.workspaces), "")
        return sc.subprocess.CompletedProcess(argv, 2, "", "unknown")

    def rpc(self, method, params=None, timeout=20):
        self.socket()
        entries = [{"fingerprint": e["fp"], "template": e["template"], "sample": e["sample"],
                    "context": e.get("ctx") or {}, "count": e["count"], "last_ms": e["last_ms"]}
                   for e in self.bench.journal().values()]
        return {"dir": self.bench.journal_dir(), "entries": entries}

    def wait(self, predicate, seconds, step=0.5):
        return predicate()


class WholeRun(unittest.TestCase):
    def run_lane(self, *extra, lingering=False):
        with tempfile.TemporaryDirectory() as base:
            home, support = os.path.join(base, "home"), os.path.join(base, "home", "Library/Application Support/cmux")
            app = os.path.join(base, "apps", f"cmux DEV {TAG}.app")
            os.makedirs(os.path.join(app, "Contents"))
            with open(os.path.join(app, "Contents", "Info.plist"), "wb") as f:
                plistlib.dump({"CFBundleIdentifier": BUNDLE, "LSEnvironment": {"CMUX_TAG": TAG}}, f)
            # Earlier state of the tag's acpmux home and of the bundle's folder (an earlier run's journal): moved
            # aside, never mixed into the baseline.
            acpmux = os.path.join(home, ".acpmux", "builds", BUNDLE)
            os.makedirs(acpmux)
            Path(acpmux, "old.json").write_text("{}")
            bundle_dir = os.path.join(os.path.dirname(support), BUNDLE)
            os.makedirs(os.path.join(bundle_dir, "errors"))
            Path(bundle_dir, "errors", "segment-000001.ndjson").write_text(json.dumps(
                {"fp": "aside-registry.json", "template": "t", "sample": "registry.json was unreadable; moved it to "
                 "registry.json.corrupt", "count": 40, "last_ms": 1}) + "\n")
            FakeApp.base = support
            out = os.path.join(base, "out")
            output = io.StringIO()
            make = FakeApp
            if lingering:
                def make(*args, **kwargs):
                    fake = FakeApp(*args, **kwargs)
                    fake.lingering = True
                    return fake
            with mock.patch.object(sc.bench_launch, "account_home", return_value=home), \
                    mock.patch.object(sc.bench_launch, "crash_report_candidates", return_value=[]), \
                    mock.patch.object(sc.Run, "end", lambda run: run.bench.process and not run.bench.process.ended
                                      and run.bench.quit_keep_sessions()), \
                    mock.patch.object(sc, "Run", FakeRun), mock.patch.object(sc.time, "sleep"), \
                    contextlib.redirect_stdout(output):
                code = sc.main(["--app", app, "--out", out, "--persist-seconds", "0", *extra], bench_app=make)
            rows = [json.loads(line) for line in Path(out, "state-corruption.jsonl").read_text().splitlines()] \
                if Path(out, "state-corruption.jsonl").exists() else []
            summary = json.loads(Path(out, "state-corruption-run.json").read_text())
            tag_dir = os.path.join(support, "tags", TAG)
            return SimpleNamespace(
                code=code, rows=rows, summary=summary, output=output.getvalue(),
                restored=sorted(os.listdir(tag_dir)) if os.path.isdir(tag_dir) else None,
                acpmux_prev=os.path.exists(acpmux + ".bench-prev/old.json"),
                acpmux_kept=os.path.exists(os.path.join(acpmux, "old.json")),
                bundle_prev=os.path.isdir(bundle_dir + ".bench-prev"),
                journal_restored=sc.journal_counts(os.path.join(bundle_dir, "errors")))

    def test_one_row_per_file_and_mutation(self):
        run = self.run_lane()
        rows, output = run.rows, run.output
        files = sorted({r["file"] for r in rows})
        self.assertEqual(files, ["app-support/errors/segment-000001.ndjson", "scratch/settings/cmux-next.json",
                                 "tag-state/launches.json", "tag-state/prefs.json", "tag-state/resetter.json",
                                 "tag-state/stubborn.json", "tag-state/tui/registry.json"], output)
        self.assertEqual(len(rows), len(files) * len(sc.MUTATIONS))
        self.assertEqual(len({(r["file"], r["mutation"]) for r in rows}), len(rows))
        control = run.summary["control"]
        self.assertEqual(control["volatile"], [], "run.json is removed at quit, so the baseline has none")
        self.assertEqual(control["rewritten"], ["app-support/errors/segment-000001.ndjson", "tag-state/launches.json"])
        self.assertTrue(run.acpmux_prev)
        self.assertTrue(run.bundle_prev, "the bundle's own folder is moved aside at the baseline")
        self.assertTrue(run.summary["error_journal"]["inside_roots"])
        by = {(r["file"], r["mutation"]): r for r in rows}
        registry = by[("tag-state/tui/registry.json", "zero-fill")]
        self.assertEqual(registry["result"], "pass", registry["problems"])
        self.assertEqual(registry["set_aside"], ["registry.json.corrupt"])
        self.assertTrue(registry["set_aside_matches"])
        self.assertEqual(registry["faults"], 1)
        self.assertFalse(registry["workspace_expected"], "the registry holds the marker workspace")
        settings = by[("scratch/settings/cmux-next.json", "truncate")]
        self.assertEqual(settings["result"], "pass", settings["problems"])
        self.assertTrue(settings["workspace_kept"])
        launches = by[("tag-state/launches.json", "zero-length")]
        self.assertEqual(launches["result"], "pass", launches["problems"])
        stubborn = by[("tag-state/stubborn.json", "zero-length")]
        self.assertEqual(stubborn["result"], "fail")
        self.assertIn("the damaged file was not set aside as *.corrupt", stubborn["problems"])
        self.assertIn("no fault was counted", stubborn["problems"],
                      "the unrelated warning that says `corrupt` is not this file's fault")
        resetter = by[("tag-state/resetter.json", "zero-fill")]
        self.assertEqual(resetter["other_changed"], ["tag-state/prefs.json"])
        self.assertEqual(resetter["result"], "fail")
        self.assertTrue(any(p.startswith("other state rewritten") for p in resetter["problems"]))
        for row in rows:
            if row["file"] not in ("tag-state/resetter.json",):
                self.assertEqual(row["other_changed"], [], row["file"])
        self.assertEqual(run.code, 1)
        self.assertEqual(run.restored, ["launches.json", "prefs.json", "resetter.json", "stubborn.json", "tui"],
                         "the baseline is back at the end")
        self.assertNotIn("aside-registry.json", run.journal_restored, "the bundle's folder is the baseline's again")

    def test_only_and_mutations_narrow_the_rows(self):
        run = self.run_lane("--only", "tag-state/tui/*", "--mutations", "zero-fill,zero-length")
        self.assertEqual([(r["file"], r["mutation"], r["result"]) for r in run.rows],
                         [("tag-state/tui/registry.json", "zero-fill", "pass"),
                          ("tag-state/tui/registry.json", "zero-length", "pass")], run.output)
        self.assertEqual(run.code, 0)

    def test_list_damages_nothing(self):
        run = self.run_lane("--list")
        self.assertEqual((run.code, run.rows), (0, []))
        self.assertIn("tag-state/tui/registry.json json", run.output)
        self.assertNotIn("control", run.summary)

    def test_a_socket_of_another_build_is_refused(self):
        with mock.patch.object(FakeApp, "launch", lambda app, timeout=0: setattr(app, "socket", "/tmp/cmux.sock") or
                               setattr(app, "process", FakeProcess()) or app):
            run = self.run_lane()
        self.assertEqual((run.code, run.rows), (2, []))
        self.assertIn("is not the tagged socket", run.output)

    def test_a_running_tag_is_refused_before_any_root_moves(self):
        run = self.run_lane(lingering=True)
        self.assertEqual((run.code, run.rows), (2, []))
        self.assertIn("processes of the tag still run", run.output)
        self.assertTrue(run.acpmux_kept)
        self.assertFalse(run.acpmux_prev, "nothing is moved aside while a process of the tag runs")
        self.assertFalse(run.bundle_prev)


class Registry(unittest.TestCase):
    def test_the_lane_is_declared(self):
        registry = json.loads((HERE / "stability-lanes.json").read_text())
        lanes = {lane["id"]: lane for lane in lab.lane_entries(registry)}
        lane = lanes["state-corruption"]
        self.assertEqual((lane["tier"], lane["host_class"], lane["priority"]), ("long", "dedicated", "lowest"))
        self.assertIn("bench", lane["never_with"])
        self.assertTrue(lane["bare_metal"])
        self.assertTrue((HERE.parent.parent / lane["script"]).is_file())


if __name__ == "__main__":
    unittest.main()
