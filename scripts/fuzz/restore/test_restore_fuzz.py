#!/usr/bin/env python3
"""Tests of the restore fuzz's oracle helpers and verdict reader (no app, no fleet).

    python3 scripts/fuzz/restore/test_restore_fuzz.py
"""
import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, path, argv=None):
    saved = sys.argv
    sys.argv = argv or [path]
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        sys.argv = saved


sys.path.insert(0, os.path.join(HERE, "..", "..", "cmux-next"))
OUT = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"restore-fuzz-test-{os.getpid()}")
rf = load("restore_fuzz", os.path.join(HERE, "restore_fuzz.py"), ["restore_fuzz.py", "--socket", "/nonexistent", "--out", OUT])
vd = load("verdict", os.path.join(HERE, "verdict.py"))


def ws(name, tabs, panes=1):
    return {"name": name, "tabs": {f"tab_{t}": f"term_{t}" for t in tabs}, "panes": [f"pane_{i}" for i in range(panes)],
            "raw_tabs": [f"tab_{t}" for t in tabs], "raw_terms": [f"term_{t}" for t in tabs]}


class Oracle(unittest.TestCase):
    def setUp(self):
        self.confirmed = {"w1": ws("fz-1", ["a"]), "w2": ws("fz-2", ["b", "c"], 2)}

    def test_inflight_create_may_land_or_not(self):
        p = {"name": "fz-3"}
        landed = dict(self.confirmed, w3=ws("fz-3", ["d"]))
        self.assertTrue(rf.allowed_after("ws_create", p, self.confirmed, landed))
        self.assertFalse(rf.allowed_after("ws_create", p, self.confirmed, self.confirmed))
        twice = dict(landed, w4=ws("fz-4", ["e"]))
        self.assertFalse(rf.allowed_after("ws_create", p, self.confirmed, twice))

    def test_inflight_split_adds_exactly_one_tab(self):
        p = {"ws": "w1", "pane": "pane_0", "dir": "right"}
        one = dict(self.confirmed, w1=ws("fz-1", ["a", "x"], 2))
        two = dict(self.confirmed, w1=ws("fz-1", ["a", "x", "y"], 3))
        lost = dict(self.confirmed, w1=ws("fz-1", ["x"], 1))
        self.assertTrue(rf.allowed_after("split", p, self.confirmed, one))
        self.assertFalse(rf.allowed_after("split", p, self.confirmed, two))
        self.assertFalse(rf.allowed_after("split", p, self.confirmed, lost))

    def test_inflight_close_and_rename(self):
        closed = {"w1": self.confirmed["w1"]}
        self.assertTrue(rf.allowed_after("ws_close", {"ws": "w2"}, self.confirmed, closed))
        renamed = {"w1": ws("fz-9", ["a"]), "w2": self.confirmed["w2"]}
        self.assertTrue(rf.allowed_after("rename", {"ws": "w1", "name": "fz-9"}, self.confirmed, renamed))
        tab_closed = dict(self.confirmed, w2=ws("fz-2", ["c"], 2))
        self.assertTrue(rf.allowed_after("tab_close", {"ws": "w2", "tab": "tab_b"}, self.confirmed, tab_closed))

    def test_effect_ok_catches_a_silent_loss(self):
        self.assertIsNone(rf.effect_ok("ws_create", {"name": "fz-3"}, self.confirmed,
                                       dict(self.confirmed, w3=ws("fz-3", ["d"])), {}))
        self.assertIsNotNone(rf.effect_ok("ws_create", {"name": "fz-3"}, self.confirmed, self.confirmed, {}))
        self.assertIsNotNone(rf.effect_ok("tab_close", {"ws": "w2", "tab": "tab_b"}, self.confirmed, self.confirmed, {}))
        self.assertIsNone(rf.effect_ok("write", {"ws": "w1"}, self.confirmed, self.confirmed, {}))

    def test_effect_ok_catches_collateral_change(self):
        # Review finding 3: an ok split in fz-1 that also drops a tab of fz-2 is a silent loss.
        p = {"ws": "w1", "pane": "pane_0", "dir": "right"}
        after = {"w1": ws("fz-1", ["a", "x"], 2), "w2": ws("fz-2", ["b"], 2)}
        self.assertIsNotNone(rf.effect_ok("split", p, self.confirmed, after, {}))
        # A split that adds a tab but no pane is not a split.
        no_pane = dict(self.confirmed, w1=ws("fz-1", ["a", "x"], 1))
        self.assertIsNotNone(rf.effect_ok("split", p, self.confirmed, no_pane, {}))
        self.assertIsNone(rf.effect_ok("tab_new", p, self.confirmed, no_pane, {}))

    def test_pick_action_respects_limits(self):
        run = rf.Run(7)
        full = {f"w{i}": ws(f"fz-{i}", ["a", "b", "c", "d"], 4) for i in range(rf.MAX_WS)}
        for _ in range(200):
            kind, _ = rf.pick_action(run, full)
            self.assertNotIn(kind, ("ws_create", "split", "tab_new"))
        single = {"w1": ws("fz-1", ["a"])}
        for _ in range(200):
            kind, _ = rf.pick_action(run, single)
            self.assertNotIn(kind, ("tab_close", "ws_close"))

    def test_same_seed_same_plan(self):
        state = {"w1": ws("fz-1", ["a"])}
        a = [rf.pick_action(rf.Run(42), state) for _ in range(5)]
        b = [rf.pick_action(rf.Run(42), state) for _ in range(5)]
        self.assertEqual(a, b)


class Judge(unittest.TestCase):
    def setUp(self):
        rf.MARKS.clear()
        rf.app_state = lambda: None  # no app here: the app row is checked on the mini
        self.wait = rf.wait
        rf.wait = lambda pred, seconds, step=0.25: pred()

    def tearDown(self):
        rf.wait = self.wait

    def problems(self, restored, confirmed, inflight=None):
        return [p for p in rf.judge(restored, confirmed, inflight) if "the app does not show" not in p]

    def test_replaced_terminal_is_a_lost_terminal(self):
        # Review finding 5: same tab id, new terminal id.
        confirmed = {"w1": ws("fz-1", ["a"])}
        restored = {"w1": dict(ws("fz-1", ["a"]), tabs={"tab_a": "term_new"}, raw_terms=["term_new"])}
        self.assertTrue(any("term_a is not in the restored" in p for p in self.problems(restored, confirmed)))

    def test_duplicate_in_one_list_is_seen(self):
        # Review finding 4: a tab listed twice in one workspace's list.
        confirmed = {"w1": ws("fz-1", ["a"])}
        restored = {"w1": dict(ws("fz-1", ["a"]), raw_tabs=["tab_a", "tab_a"])}
        self.assertIn("a tab is listed twice", self.problems(restored, confirmed))
        restored = {"w1": dict(ws("fz-1", ["a"]), dup_ws=1)}
        self.assertIn("a workspace id is listed twice", self.problems(restored, confirmed))

    def test_inflight_ok_answer_must_land(self):
        # Review finding 2: an ok answer is a commit, whenever it came.
        confirmed = {"w1": ws("fz-1", ["a"])}
        p = {"name": "fz-2"}
        self.assertTrue(any("answered ok" in x for x in self.problems(confirmed, confirmed, ("ws_create", p, True))))
        self.assertEqual(self.problems(confirmed, confirmed, ("ws_create", p, False)), [])

    def test_inflight_close_does_not_count_its_terminal_as_lost(self):
        confirmed = {"w1": ws("fz-1", ["a"]), "w2": ws("fz-2", ["b"])}
        restored = {"w1": ws("fz-1", ["a"])}
        self.assertEqual(self.problems(restored, confirmed, ("ws_close", {"ws": "w2"}, True)), [])


class Zombie(unittest.TestCase):
    def test_a_reaped_child_is_not_alive(self):
        # Review finding 1: a killed child of ours is a zombie until reaped; alive() must say it is gone.
        import signal
        import subprocess
        app = rf.App.__new__(rf.App)
        app.child = subprocess.Popen(["sleep", "30"])
        app.pid = app.child.pid
        self.assertTrue(app.alive())
        os.kill(app.child.pid, signal.SIGKILL)
        import time
        deadline = time.time() + 5
        while app.alive() and time.time() < deadline:
            time.sleep(0.05)
        self.assertFalse(app.alive())


class Evidence(unittest.TestCase):
    def test_only_this_builds_crash_reports(self):
        # Review finding at ce71d97ab38: other cmux apps' reports must not be copied.
        import tempfile
        app = rf.App.__new__(rf.App)
        app.bundle = "/Users/Shared/cmux-capture/slots/1/lease-x/app/cmux DEV t.app"
        rf.APP = app
        d = tempfile.mkdtemp()
        mine = os.path.join(d, "cmux DEV-2026.ips")
        other = os.path.join(d, "cmux DEV-2026-2.ips")
        crash = os.path.join(d, "cmux.crash")
        with open(mine, "w") as f:
            f.write('{"app_name":"cmux DEV"}\n{"procPath":"' + app.bundle + '/Contents/MacOS/cmux DEV"}')
        with open(other, "w") as f:
            f.write('{"app_name":"cmux DEV"}\n{"procPath":"/Applications/cmux.app/Contents/MacOS/cmux"}')
        with open(crash, "w") as f:
            f.write("Process: cmux\nPath:            " + app.bundle + "/Contents/Resources/bin/cmux-tui\n")
        self.assertTrue(rf.report_of_build(mine))
        self.assertFalse(rf.report_of_build(other))
        self.assertTrue(rf.report_of_build(crash))


class ExecEnv(unittest.TestCase):
    def test_exec_env_merges_repeated_keys(self):
        # Fleet rounds fgh-h-fdsoft-2032 / slowdisk-2033: a key in both maps raised TypeError at the first relaunch.
        app = rf.App.__new__(rf.App)
        app.full_env = {"CMUX_SOCKET_PATH": "/slot/a.sock", "CFFIXED_USER_HOME": "/slot/home", "HOME": "/slot/home"}
        app.env = {"CMUX_SOCKET_PATH": "/slot/a.sock", "HOME": "/slot/home"}
        env = app.exec_env()
        self.assertEqual(env["CMUX_SOCKET_PATH"], "/slot/a.sock")
        self.assertEqual(env["CFFIXED_USER_HOME"], "/slot/home")


class EnvLog(unittest.TestCase):
    def test_only_state_path_values_are_logged(self):
        saved_env, saved_run = rf.App.environment, rf.subprocess.run
        rf.App.environment = staticmethod(lambda pid, every=False: {
            "HOME": "/slot/home", "CMUX_TUI_STATE_DIR": "/slot/home/Library", "CMUX_API_TOKEN": "s3cret"})

        class Done:
            stdout = "/slot/app/cmux --headless\n"
        rf.subprocess.run = lambda *a, **k: Done()
        try:
            row = rf.proc_env(1)
        finally:
            rf.App.environment, rf.subprocess.run = saved_env, saved_run
        self.assertNotIn("s3cret", str(row))
        self.assertEqual(row["env"]["CMUX_TUI_STATE_DIR"], "/slot/home/Library")
        self.assertIn("CMUX_API_TOKEN", row["other_cmux_keys"])


class Hosts(unittest.TestCase):
    def test_host_rows_reads_only_this_builds_hosts(self):
        app = rf.App.__new__(rf.App)
        app.bundle_id = "com.cmuxterm.app.debug.t.capslot1"
        rf.APP = app
        saved = rf.subprocess.run

        class Done:
            stdout = ("  101     1 Sat Oct 31 04:38:10 2026 cmux-tui __terminal-host --bootstrap-stdio "
                      "--owner com.cmuxterm.app.debug.t.capslot1:sess term_abc\n"
                      "  102     1 Sat Oct 31 04:38:11 2026 cmux-tui __terminal-host --bootstrap-stdio "
                      "--owner com.cmuxterm.app.debug.other:sess term_x\n"
                      "  103    50 Sat Oct 31 04:38:12 2026 /bin/zsh -l\n")
        rf.subprocess.run = lambda *a, **k: Done()
        try:
            rows = rf.host_rows()
        finally:
            rf.subprocess.run = saved
        self.assertEqual([r["pid"] for r in rows], [101])
        self.assertEqual(rows[0]["lstart"], "Sat Oct 31 04:38:10 2026")
        self.assertIn("term_abc", rows[0]["argv"])


class Closes(unittest.TestCase):
    def test_only_ok_closes_with_terminals_are_noted(self):
        rf.CLOSES.clear()
        rf.note_close({"value": {}}, 3)
        rf.note_close({"error": "x"}, 2)
        rf.note_close([], 0)
        self.assertEqual([n for _, n in rf.CLOSES], [3])
        p = rf.pick_action(rf.Run(5), {"w1": ws("fz-1", ["a", "b"]), "w2": ws("fz-2", ["c"])})
        if p[0] == "ws_close":
            self.assertIn("tabs", p[1])


class DiskFull(unittest.TestCase):
    """Row h nearly-full disk: a bounded image at the daemon's state dir, filled to a margin."""

    def test_procargs2_gives_exact_env_values(self):
        # KERN_PROCARGS2: argc, exec path, NUL padding, argv, env; values keep their spaces.
        import struct
        blob = (struct.pack("i", 2) + b"/x/cmux-tui\0\0\0" + b"/x/cmux-tui\0--headless\0"
                + b"HOME=/s/home\0CMUX_TUI_STATE_DIR=/s/home/Library/Application Support/cmux/x\0\0")
        argv, env = rf.parse_procargs2(blob)
        self.assertEqual(argv, ["/x/cmux-tui", "--headless"])
        self.assertEqual(env["CMUX_TUI_STATE_DIR"], "/s/home/Library/Application Support/cmux/x")
        self.assertEqual(env["HOME"], "/s/home")

    def test_filler_leaves_the_margin(self):
        mb = 1 << 20
        self.assertEqual(rf.filler_bytes(100 * mb, 2), 98 * mb)
        self.assertEqual(rf.filler_bytes(1 * mb, 2), 0)

    def test_disk_plan_keeps_the_host_reserve(self):
        gb = 1 << 30
        self.assertIsNone(rf.disk_plan(host_free=40 * gb, image_mb=512, state_bytes=10 << 20))
        self.assertIn("reserve", rf.disk_plan(host_free=20 * gb, image_mb=512, state_bytes=10 << 20))
        self.assertIn("state dir", rf.disk_plan(host_free=40 * gb, image_mb=512, state_bytes=300 << 20))

    def test_volume_commands(self):
        vol = rf.DiskVolume("/out/fz.dmg", "/s/home/Library/Application Support/cmux/x", 512)
        self.assertEqual(vol.create_cmd(), ["/usr/bin/hdiutil", "create", "-size", "512m", "-fs", "HFS+",
                                            "-volname", "fzdisk", "-type", "UDIF", "/out/fz.dmg"])
        self.assertEqual(vol.attach_cmd(), ["/usr/bin/hdiutil", "attach", "-nobrowse", "-noautoopen",
                                            "-mountpoint", "/s/home/Library/Application Support/cmux/x", "/out/fz.dmg"])
        self.assertEqual(vol.detach_cmd(force=True), ["/usr/bin/hdiutil", "detach", "-force",
                                                     "/s/home/Library/Application Support/cmux/x"])

    def test_state_dir_must_be_in_the_slot_home(self):
        self.assertIsNone(rf.check_state_dir("/s/home/Library/Application Support/cmux/x", "/s/home"))
        self.assertIsNotNone(rf.check_state_dir("/Users/cmux/Library/Application Support/cmux/x", "/s/home"))
        self.assertIsNotNone(rf.check_state_dir("", "/s/home"))
        self.assertIsNotNone(rf.check_state_dir("/s/home/x", ""))


class TypedErrors(unittest.TestCase):
    def test_typed_error(self):
        self.assertTrue(rf.typed_error({"error": '{"code":"operation.failed","details":{}}'}))
        self.assertTrue(rf.typed_error({"error": {"code": "store.save_failed"}}))
        self.assertFalse(rf.typed_error({"error": "no daemon socket"}))
        self.assertFalse(rf.typed_error({"error": "no answer within 10 s", "stall": True}))


class VisibleState(unittest.TestCase):
    """Row h: during a slow restore the app must show a designed state (restore-journey's RecoverySampler rule)."""

    def sample(self, shows="content", link="connected", blank=0):
        return ({"connection": "connected", "windows": [{"id": "w1", "shows": shows}]},
                {"blank_panes": blank, "windows": [{"panes": [{"pane": "p1", "kind": "terminal", "presence": "visible",
                                                                "link": link}]}]})

    def test_designed_states_pass(self):
        for shows, link in (("content", "connected"), ("connecting", "restoring"),
                            ("content", "disconnected:eof:reconnecting")):
            st, su = self.sample(shows, link)
            self.assertEqual(rf.visible_problems(st, su), ([], []))

    def test_blank_and_dead_are_reported(self):
        st, su = self.sample(blank=1)
        self.assertTrue(rf.visible_problems(st, su)[0])
        st, su = self.sample(shows="nothing")
        self.assertTrue(rf.visible_problems(st, su)[0])
        st, su = self.sample(link="disconnected:eof")
        self.assertTrue(rf.visible_problems(st, su)[1])

    def test_judge_needs_one_second_dead_and_answers(self):
        good = [(0.25 * i,) + self.sample() for i in range(8)]
        self.assertEqual(rf.judge_visible(good, killed=0.0, end=2.0), [])
        dead = [(0.25 * i,) + self.sample(link="disconnected:eof") for i in range(8)]
        self.assertTrue(any("since" in v for v in rf.judge_visible(dead, killed=0.0, end=2.0)))
        silent = [(0.0,) + self.sample(), (1.9,) + self.sample()]
        silent[1] = (1.9, None, None)
        self.assertTrue(any("did not answer" in v for v in rf.judge_visible(silent, killed=0.0, end=2.0)))


class Answers(unittest.TestCase):
    def test_bare_list_answer_is_listed(self):
        # `cmux --json workspace list` answers a bare list (fleet run seed 1004, cmux21).
        bare = [{"id": "ws_1", "name": "Home"}, {"id": "ws_2", "name": "fz-1"}]
        self.assertEqual(rf.listed(bare, "workspaces"), bare)
        self.assertEqual(rf.listed({"value": bare}, "workspaces"), bare)
        self.assertEqual(rf.listed({"value": {"workspaces": bare}}, "workspaces"), bare)
        self.assertEqual(rf.listed({"error": "x"}, "workspaces"), [])


class Verdict(unittest.TestCase):
    def test_lines(self):
        self.assertTrue(vd.verdict("done\n").startswith("NOVERDICT"))
        self.assertEqual(vd.verdict("RESTORE-FUZZ SUMMARY seed=1 judged=4 violations=0\n"), "PASS")
        self.assertTrue(vd.verdict("RESTORE-FUZZ SUMMARY seed=1 judged=0 violations=0\n").startswith("NOVERDICT"))
        log = "RESTORE-FUZZ VIOLATION seed=5 what=lost\nRESTORE-FUZZ SUMMARY seed=1 judged=3 violations=1\n"
        self.assertTrue(vd.verdict(log).startswith("FAIL 1 violation(s): seed=5"))
        self.assertEqual(vd.verdict("FUZZ-G SUMMARY seeds=4 ops=900 kills=20 violations=0\n"), "PASS")
        # Review finding 8: no work counted is no verdict.
        self.assertTrue(vd.verdict("FUZZ-G SUMMARY seeds=4 ops=0 kills=0 violations=0\n").startswith("NOVERDICT"))
        self.assertTrue(vd.verdict("FUZZ-G SUMMARY seeds=4 violations=0\n").startswith("NOVERDICT"))
        self.assertTrue(vd.verdict("RESTORE-FUZZ SUMMARY seed=1 violations=0\n").startswith("NOVERDICT"))
        self.assertTrue(vd.verdict("RESTORE-FUZZ SUMMARY seed=1 judged=5 violations=0 chaos_lost=1\n").startswith("NOVERDICT"))


if __name__ == "__main__":
    unittest.main()
