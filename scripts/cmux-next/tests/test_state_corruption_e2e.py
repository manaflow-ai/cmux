#!/usr/bin/env python3
"""state-corruption-e2e.py, the state-corruption chaos lane (p10-stability-174):

1. Each mutation damages the bytes it says (flip: up to 16 bytes, each changed, the same offsets for the same seed).
2. format_accepts is the format's own verdict: JSON and plist parsers, and SQLite's integrity_check on the main file.
3. Discovery finds regular files only and skips sockets, SQLite side files, empties, caches and Chromium user data.
4. Only this build's tagged socket is used; a shipped build's tag, the untagged sockets and shared roots are refused,
   and no path outside the tag's roots is written.
5. A whole run against a fake app: one row per (file, mutation), the control finds the volatile files, a JSON file the
   app sets aside passes, one it does not set aside fails, and the baseline is restored at the end.
6. The lanes registry declares the lane the way stability-lab.py reads it.

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
import unittest
from pathlib import Path
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

    def test_sqlite_uses_its_own_integrity_check(self):
        data = sqlite_bytes()
        self.assertTrue(sc.format_accepts("sqlite", data))
        self.assertTrue(sc.format_accepts("sqlite", b""), "an empty file is an empty database")
        self.assertFalse(sc.format_accepts("sqlite", bytes(len(data))))
        self.assertFalse(sc.format_accepts("sqlite", sc.mutate(data, "truncate", None)[0]))

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

    def test_fault_entries_since_the_relaunch_and_about_the_file(self):
        reply = {"entries": [
            {"last_ms": 50, "template": "apps.json is corrupt", "count": 1},
            {"last_ms": 150, "template": "moved <path> aside", "context": {"path": "/x/apps.json"}, "count": 2},
            {"last_ms": 150, "template": "database disk image is malformed: corrupt", "count": 1},
            {"last_ms": 150, "template": "network down", "count": 1}]}
        found = sc.fault_entries(reply, 100, "apps.json")
        self.assertEqual([e["count"] for e in found], [2, 1])
        self.assertEqual(sc.fault_entries({"error": "x"}, 0, "a"), [])
        self.assertEqual(sc.fault_entries(None, 0, "a"), [])

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
            sc.tag_roots("/s/cmux", "/Users/u", "nightly", self.names(), "/o/state")
        with self.assertRaises(sc.Refused):
            sc.tag_roots("/s/cmux", "/Users/u", "..", self.names(), "/o/state")

    def test_roots_are_the_builds_own(self):
        roots = sc.tag_roots("/s/cmux", "/Users/u", TAG, self.names(), "/o/state")
        self.assertEqual(roots["tag-state"], f"/s/cmux/tags/{TAG}")
        self.assertEqual(roots["build-support"], f"/s/cmux/builds/{BUNDLE}")
        self.assertEqual(roots["acpmux"], f"/Users/u/.acpmux/builds/{BUNDLE}")
        with self.assertRaises(sc.Refused):
            sc.tag_roots("/s/cmux", "/Users/u", TAG, self.names(), "/Users/u")

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
    """A cmux that keeps a JSON workspace registry and a JSON settings file and handles damage the way the lane
    expects, except for `stubborn.json`, which it reads and silently replaces (no set-aside, no fault). Each launch
    writes `run.json` and each quit removes it: a volatile file."""

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
        self.faults = []
        self.launches = 0

    def state_root(self):
        return os.path.join(FakeApp.base, "tags", self.tag)

    def tag_processes(self):
        if self.process and not self.process.ended:
            return [(1, os.path.join(self.app, "Contents/Resources/bin/cmux-tui") + " --headless")]
        return []

    def read_store(self, path, empty):
        try:
            return json.loads(Path(path).read_text())
        except FileNotFoundError:
            return empty
        except ValueError:
            if os.path.basename(path) != "stubborn.json":
                os.rename(path, path + ".corrupt")
                self.faults.append({"last_ms": 10 ** 13, "template": f"{os.path.basename(path)} is corrupt; set aside",
                                    "count": 1})
            return empty

    def launch(self, timeout=0):
        root = self.state_root()
        self.faults = []  # the journal is in the tag's roots: each case starts from the baseline's
        os.makedirs(os.path.join(root, "tui"), exist_ok=True)
        self.registry = os.path.join(root, "tui", "registry.json")
        self.workspaces = self.read_store(self.registry, {"workspaces": []})["workspaces"]
        self.read_store(os.path.join(root, "stubborn.json"), {})
        self.read_store(self.env["CMUX_NEXT_CONFIG_FILE"], {})
        Path(root, "stubborn.json").write_text('{"ok": true}')
        Path(root, "run.json").write_text('{"pid": 4242}')
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
        return {"dir": os.path.join(self.bench.state_root(), "errors"), "entries": list(self.bench.faults)}

    def wait(self, predicate, seconds, step=0.5):
        return predicate()


class WholeRun(unittest.TestCase):
    def run_lane(self, *extra):
        with tempfile.TemporaryDirectory() as base:
            home, support = os.path.join(base, "home"), os.path.join(base, "home", "Library/Application Support/cmux")
            app = os.path.join(base, "apps", f"cmux DEV {TAG}.app")
            os.makedirs(os.path.join(app, "Contents"))
            with open(os.path.join(app, "Contents", "Info.plist"), "wb") as f:
                plistlib.dump({"CFBundleIdentifier": BUNDLE, "LSEnvironment": {"CMUX_TAG": TAG}}, f)
            # Earlier state of the tag's acpmux home: moved aside, never mixed into the baseline.
            os.makedirs(os.path.join(home, ".acpmux", "builds", BUNDLE))
            Path(home, ".acpmux", "builds", BUNDLE, "old.json").write_text("{}")
            FakeApp.base = support
            out = os.path.join(base, "out")
            output = io.StringIO()
            with mock.patch.object(sc.bench_launch, "account_home", return_value=home), \
                    mock.patch.object(sc.bench_launch, "crash_reports", return_value=[]), \
                    mock.patch.object(sc.Run, "end", lambda run: run.bench.process and not run.bench.process.ended
                                      and run.bench.quit_keep_sessions()), \
                    mock.patch.object(sc, "Run", FakeRun), mock.patch.object(sc.time, "sleep"), \
                    contextlib.redirect_stdout(output):
                code = sc.main(["--app", app, "--out", out, "--persist-seconds", "0", *extra], bench_app=FakeApp)
            rows = [json.loads(line) for line in Path(out, "state-corruption.jsonl").read_text().splitlines()] \
                if Path(out, "state-corruption.jsonl").exists() else []
            summary = json.loads(Path(out, "state-corruption-run.json").read_text())
            tag_dir = os.path.join(support, "tags", TAG)
            restored = sorted(os.listdir(tag_dir)) if os.path.isdir(tag_dir) else None
            acpmux_prev = os.path.exists(os.path.join(home, ".acpmux", "builds", BUNDLE + ".bench-prev", "old.json"))
            return code, rows, summary, restored, acpmux_prev, output.getvalue()

    def test_one_row_per_file_and_mutation(self):
        code, rows, summary, restored, acpmux_prev, output = self.run_lane()
        files = sorted({r["file"] for r in rows})
        self.assertEqual(files, ["scratch/settings/cmux-next.json", "tag-state/stubborn.json",
                                 "tag-state/tui/registry.json"], output)
        self.assertEqual(len(rows), len(files) * len(sc.MUTATIONS))
        self.assertEqual(len({(r["file"], r["mutation"]) for r in rows}), len(rows))
        self.assertEqual(summary["control"]["volatile"], [], "run.json is removed at quit, so the baseline has none")
        self.assertTrue(acpmux_prev)
        by = {(r["file"], r["mutation"]): r for r in rows}
        registry = by[("tag-state/tui/registry.json", "zero-fill")]
        self.assertEqual(registry["result"], "pass", registry["problems"])
        self.assertEqual(registry["set_aside"], ["registry.json.corrupt"])
        self.assertTrue(registry["set_aside_matches"])
        self.assertFalse(registry["workspace_expected"], "the registry holds the marker workspace")
        settings = by[("scratch/settings/cmux-next.json", "truncate")]
        self.assertEqual(settings["result"], "pass", settings["problems"])
        self.assertTrue(settings["workspace_kept"])
        stubborn = by[("tag-state/stubborn.json", "zero-length")]
        self.assertEqual(stubborn["result"], "fail")
        self.assertIn("the damaged file was not set aside as *.corrupt", stubborn["problems"])
        self.assertIn("no fault was counted", stubborn["problems"])
        self.assertEqual(code, 1)
        self.assertEqual(restored, ["stubborn.json", "tui"], "the baseline is back at the end")

    def test_only_and_mutations_narrow_the_rows(self):
        code, rows, *_ = self.run_lane("--only", "tag-state/tui/*", "--mutations", "zero-fill,zero-length")
        self.assertEqual([(r["file"], r["mutation"], r["result"]) for r in rows],
                         [("tag-state/tui/registry.json", "zero-fill", "pass"),
                          ("tag-state/tui/registry.json", "zero-length", "pass")])
        self.assertEqual(code, 0)

    def test_list_damages_nothing(self):
        code, rows, summary, _, _, output = self.run_lane("--list")
        self.assertEqual((code, rows), (0, []))
        self.assertIn("tag-state/tui/registry.json json", output)
        self.assertNotIn("control", summary)

    def test_a_socket_of_another_build_is_refused(self):
        with mock.patch.object(FakeApp, "launch", lambda app, timeout=0: setattr(app, "socket", "/tmp/cmux.sock") or
                               setattr(app, "process", FakeProcess()) or app):
            code, rows, summary, *_ , output = self.run_lane()
        self.assertEqual((code, rows), (2, []))
        self.assertIn("is not the tagged socket", output)


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
