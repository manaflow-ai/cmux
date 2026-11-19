#!/usr/bin/env python3
"""Launch harnesses whose runs share one bundle id leak macOS defaults between launches: cfprefsd keeps the
bundle's domain in the account's real preferences whatever HOME says, and the app keeps its last launch snapshot's
path there (cmuxNext.launchSnapshotPath.<session>). A new HOME is not enough.

- fresh_home_launch_smoke.defaults_before reads the domain just before a launch: key names, and only the
  launch snapshot paths' values.
- startup_paths.fresh_install_round fails a row whose domain held a key before the launch, or whose launch marked
  launch_snapshot_applied, and passes a clean one.
- quit_gamut_check's table says so in one line.
- chat-open-bench.py records what each launch read, and its saved pictures are this tag's, from this condition.

A stand-in `defaults` (CMUX_FRESH_SMOKE_DEFAULTS_TOOL) keeps one JSON store per bundle id in a folder."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from unittest import mock

TESTS = Path(__file__).resolve().parent
CI = TESTS.parent.parent / "ci"
sys.path.insert(0, str(CI))
sys.path.insert(0, str(TESTS))
import fresh_home_launch_smoke as smoke  # noqa: E402
import startup_paths as startup  # noqa: E402

STUB = """#!/usr/bin/env python3
import json, os, plistlib, sys
store = os.path.join(os.environ["DEFAULTS_STORE"], sys.argv[2] + ".json")
domain = json.load(open(store)) if os.path.exists(store) else {}
if sys.argv[1] == "export":
    data = plistlib.dumps(domain)
    if sys.argv[3] == "-":
        sys.stdout.buffer.write(data)
    else:
        open(sys.argv[3], "wb").write(data)
elif sys.argv[1] == "delete":
    if not os.path.exists(store):
        sys.exit(1)
    os.remove(store)
elif sys.argv[1] == "import":
    json.dump(plistlib.load(open(sys.argv[3], "rb")), open(store, "w"))
"""

BUNDLE = "com.example.app.debug.tag"
SNAPSHOT_KEY = "cmuxNext.launchSnapshotPath.cmux-app-a"


class StubDefaults(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="defaults-leak-test-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(self.dir, ignore_errors=True))
        tool = self.dir / "defaults"
        tool.write_text(STUB)
        tool.chmod(0o755)
        (self.dir / "store").mkdir()
        patcher = mock.patch.dict(os.environ, {"CMUX_FRESH_SMOKE_DEFAULTS_TOOL": str(tool),
                                               "DEFAULTS_STORE": str(self.dir / "store"),
                                               "CMUX_FRESH_SMOKE_LOCK_DIR": str(self.dir)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def write_domain(self, domain: dict) -> None:
        (self.dir / "store" / f"{BUNDLE}.json").write_text(json.dumps(domain))


class DefaultsBeforeTests(StubDefaults):
    def test_an_empty_domain_has_no_keys(self):
        self.assertEqual(smoke.defaults_before(BUNDLE), {"keys": [], "launch_snapshot_paths": {}})

    def test_keys_sorted_and_only_snapshot_paths_valued(self):
        self.write_domain({"zeta": "private value", SNAPSHOT_KEY: "/old/run/launch-snapshot.json", "alpha": 1})
        got = smoke.defaults_before(BUNDLE)
        self.assertEqual(got["keys"], ["alpha", SNAPSHOT_KEY, "zeta"])
        self.assertEqual(got["launch_snapshot_paths"], {SNAPSHOT_KEY: "/old/run/launch-snapshot.json"})
        self.assertNotIn("private value", json.dumps(got))

    def test_an_export_that_fails_is_an_error_not_an_empty_domain(self):
        with mock.patch.dict(os.environ, {"CMUX_FRESH_SMOKE_DEFAULTS_TOOL": "/bin/false"}):
            got = smoke.defaults_before(BUNDLE)
        self.assertIn("error", got)
        self.assertNotIn("keys", got)

    def test_set_aside_empties_the_domain_the_launch_reads_and_puts_it_back(self):
        self.write_domain({SNAPSHOT_KEY: "/old/run/launch-snapshot.json"})
        with smoke.DefaultsAside(BUNDLE, self.dir):
            self.assertEqual(smoke.defaults_before(BUNDLE)["keys"], [])
        self.assertEqual(smoke.defaults_before(BUNDLE)["keys"], [SNAPSHOT_KEY])


class FreshInstallRoundTests(unittest.TestCase):
    """fresh_install_round with its Mac-only steps replaced: the launch (open_launch) returns a row as a Mac's would."""

    def round(self, launch: dict) -> dict:
        folder = Path(tempfile.mkdtemp(prefix="fresh-install-test-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(folder, ignore_errors=True))
        app = folder / "cmux NEXT.app"
        (app / "Contents").mkdir(parents=True)
        import plistlib
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(
            {"CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "cmux", "CFBundleVersion": "1"}))

        class Aside:
            def __init__(self, *_args):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *_exc):
                return False

        fake = types.SimpleNamespace(CannotRun=smoke.CannotRun, bundle_info=smoke.bundle_info, DefaultsAside=Aside)
        marks = {"main_start": 50, "first_window_frame_committed": 900, "reveal.sidebar": 950, "reveal.tabs": 960,
                 "reveal.home": 1000}
        row = {"first_window_ms": 900, "settled_ms": 1000, "home_ms": 1000, "marks": marks, **launch}
        if row.get("launch_snapshot_applied"):
            row["marks"] = {**marks, "launch_snapshot_applied": 400}
        with mock.patch.object(startup, "install", return_value=(app, {})), \
                mock.patch.object(startup, "purge", return_value="skipped"), \
                mock.patch.object(startup, "open_launch", return_value=row):
            return startup.fresh_install_round(fake, Path("/nonexistent.dmg"), 1)

    def test_a_clean_domain_and_no_snapshot_passes(self):
        row = self.round({"defaults_before": {"keys": [], "launch_snapshot_paths": {}}, "launch_snapshot_applied": False})
        self.assertEqual(row["failures"], [])

    def test_a_leftover_key_fails(self):
        row = self.round({"defaults_before": {"keys": [SNAPSHOT_KEY],
                                              "launch_snapshot_paths": {SNAPSHOT_KEY: "/old/launch-snapshot.json"}},
                          "launch_snapshot_applied": False})
        self.assertTrue(any("held 1 keys" in f and "/old/launch-snapshot.json" in f for f in row["failures"]),
                        row["failures"])

    def test_an_applied_launch_snapshot_fails(self):
        row = self.round({"defaults_before": {"keys": [], "launch_snapshot_paths": {}}, "launch_snapshot_applied": True})
        self.assertTrue(any("launch_snapshot_applied" in f for f in row["failures"]), row["failures"])

    def test_an_unreadable_domain_fails_closed(self):
        row = self.round({"defaults_before": {"error": "defaults export exited 1"}, "launch_snapshot_applied": False})
        self.assertTrue(any("could not read the defaults domain" in f for f in row["failures"]), row["failures"])


class GamutTableTests(unittest.TestCase):
    def test_the_table_says_what_fails_a_fresh_install_row(self):
        try:
            import quit_gamut_check as gamut
        except ImportError as error:  # its Mac-side helpers: the line is checked where they import
            self.skipTest(f"quit_gamut_check does not import here: {error}")
        table = gamut.table([{"path": "fresh-install", "state": "first-run", "failures": []}])
        self.assertIn("a fresh-install row fails when its domain held any key or the mark is there", table)


class ChatOpenBenchTests(StubDefaults):
    def setUp(self):
        super().setUp()
        from test_chat_open_bench import load_bench
        self.bench = load_bench("--tag", "chatopen")

    def test_each_launch_records_the_domain_it_read(self):
        self.write_domain({SNAPSHOT_KEY: "/earlier/run/launch-snapshot.json", "other": "x"})
        scratch = self.dir / "scratch"
        bench = self.bench
        bench.BUNDLE_ID = BUNDLE
        bench.bm = types.SimpleNamespace(launch=lambda app, config, env: (1, str(self.dir / "s.sock"), str(scratch)),
                                         App=lambda app, sock: types.SimpleNamespace(ping=lambda: True))
        run = bench.Run(str(self.dir), str(self.dir / "acpmux"))
        run.launch()
        self.assertEqual(run.defaults_before, {"keys": [SNAPSHOT_KEY, "other"],
                                               "launch_snapshot_paths": {SNAPSHOT_KEY: "/earlier/run/launch-snapshot.json"}})

    def test_saved_pictures_are_this_tags_from_this_condition(self):
        home = self.dir / "home"
        support = home / "Library" / "Application Support" / "cmux-next" / "tags"
        for tag, name in (("chatopen", "ours.png"), ("chatopen2", "other-tag.png")):
            folder = support / tag / "agent-pane-images"
            folder.mkdir(parents=True)
            (folder / name).write_bytes(b"png")
        old = support / "chatopen" / "agent-pane-images" / "earlier-run.png"
        old.write_bytes(b"png")
        start = time.time() - 60
        os.utime(old, (start - 3600, start - 3600))
        self.assertEqual(self.bench.tag_pictures([str(home)], "chatopen", start), ["ours.png"])
        self.assertEqual(self.bench.tag_pictures([str(home)], "chatopen", 0.0), ["earlier-run.png", "ours.png"])


if __name__ == "__main__":
    unittest.main()
