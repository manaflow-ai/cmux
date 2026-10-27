#!/usr/bin/env python3
"""Tests of scripts/cmux-next/qos-audit.py (p02-threads-302, MQ-15): the RUN-3 / RUN-4 thread judges, the closed
user-interactive list read from threading-model.md, stable task ids and the judge mode's files.

Run: python3 -I scripts/cmux-next/tests/test_qos_audit.py
"""
import importlib.util, json, os, socket, sys, tempfile, threading, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "qos-audit.py")
spec = importlib.util.spec_from_file_location("qos_audit", SCRIPT)
qos = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qos)

DOC = """# Threading model

## Closed user-interactive list

| Thread or queue | Process | Why a frame or the echo waits on it | At user-interactive today |
|---|---|---|---|
| `cmux-next vsync <display>` | app | Frame ticks | yes |
| `mux-line-out`, `mux-pty-input` | daemon | Key in, echo out | yes |
| `surface-<id>-reader`, `surface-frames` | daemon | PTY output | yes |

## Lanes
"""


def app_row(name, requested, declared=None, tiers=None, hidden=None, origin="cmux", **extra):
    row = {"tid": 1, "name": name, "label": None, "main": False, "requested_qos": requested, "effective_pri": 31,
           "cpu_ms": 0, "declared": declared, "declared_tiers": tiers, "declared_hidden": hidden,
           "declared_as": name if declared else None, "origin": origin if declared else None, "library": None,
           "undeclared_cmux": False, "undeclared_library": None,
           "match": None if declared is None or requested is None else requested in (tiers or [declared])}
    row.update(extra)
    return row


def app_report(threads, queues=(), role="foreground", not_recorded=0):
    return {"task_role": role, "threads": list(threads), "queues": list(queues), "queues_not_recorded": not_recorded}


def daemon_row(name, desired, tid, requested=None, nice=None, matches=True, declared=None):
    return {"name": name, "tid": tid, "declared": declared or desired, "desired": desired, "effective": desired,
            "requested_qos": requested, "nice": nice, "priority": 20, "refused_changes": 0, "matches": matches}


def daemon_snapshot(threads, mac=False):
    process = {"pid": 7, "role": "foreground" if mac else None, "role_raw": None,
               "darwin_bg": {"internal": False, "external": False} if mac else None}
    return {"schema": 1, "uptime_ms": 1, "process": process, "threads": list(threads), "lanes": []}


def kinds(findings):
    return sorted((f["process"], f["kind"], f["name"]) for f in findings)


class ClosedListTests(unittest.TestCase):
    def test_placeholders_match_any_part_and_rows_outside_do_not(self):
        patterns = qos.closed_list(DOC)
        self.assertTrue(qos.on_closed_list(["cmux-next vsync 1"], patterns))
        self.assertTrue(qos.on_closed_list(["surface-12-reader"], patterns))
        self.assertTrue(qos.on_closed_list(["mux-line-out"], patterns))
        self.assertFalse(qos.on_closed_list(["mux-line-outx"], patterns))
        self.assertFalse(qos.on_closed_list(["surface-12-host"], patterns))
        self.assertFalse(qos.on_closed_list([None, ""], patterns))

    def test_the_repo_doc_has_the_section(self):
        with open(qos.DOC) as f:
            patterns = qos.closed_list(f.read())
        self.assertTrue(qos.on_closed_list(["mux-pty-input"], patterns))
        self.assertTrue(qos.on_closed_list(["com.cmuxterm.next.terminal.output"], patterns))

    def test_a_doc_without_the_section_is_a_read_error(self):
        with self.assertRaises(qos.ReadError):
            qos.closed_list("# nothing\n")


class NameTests(unittest.TestCase):
    def test_per_object_parts_collapse(self):
        self.assertEqual(qos.generic_name("surface-12-reader"), "surface-N-reader")
        self.assertEqual(qos.generic_name("network_thread 0x7f9c00a1"), "network_thread N")
        self.assertEqual(qos.generic_name("mux-deadline-3"), "mux-deadline-N")
        self.assertEqual(qos.generic_name("x-1.2.3"), "x-N")

    def test_task_id_is_stable_and_a_slug(self):
        item = {"process": "daemon", "kind": "unregistered", "name": "notify-rs inoti"}
        self.assertEqual(qos.task_id(item), "p02-threads-R-qos-daemon-unregistered-notify-rs-inoti")


class AppJudgeTests(unittest.TestCase):
    def setUp(self):
        self.closed = qos.closed_list(DOC)

    def test_a_matching_registry_is_clean(self):
        report = app_report([app_row("cmux-next vsync 1", "user-interactive", "user-interactive", ["user-interactive"]),
                             app_row("cmux.home.cache", "utility", "utility", ["utility"])])
        self.assertEqual(qos.app_findings(report, "visible", self.closed), [])

    def test_mismatch_undeclared_and_interactive_outside_the_list(self):
        rows = [app_row("cmux.settings.watch", "user-initiated", "utility", ["utility"]),
                app_row("cmux.loose 4", "user-interactive", undeclared_cmux=True),
                app_row("Chrome_IOThread", "user-initiated", undeclared_library="CEF"),
                app_row("com.apple.NSEventThread", "user-interactive")]
        found = qos.app_findings(app_report(rows), "visible", self.closed)
        self.assertEqual(kinds(found), [
            ("app", "interactive-outside-closed-list", "cmux.loose N"),
            ("app", "mismatch", "cmux.settings.watch"),
            ("app", "undeclared-cmux", "cmux.loose N"),
            ("app", "undeclared-library", "CEF Chrome_IOThread"),
        ])

    def test_hidden_tier_only_in_the_hidden_phase(self):
        tiers = ["user-interactive", "user-initiated", "utility"]
        row = app_row("ghostty renderer", "user-initiated", "ghostty-surface", tiers, hidden="utility",
                      origin="library")
        self.assertEqual(qos.app_findings(app_report([row]), "visible", self.closed), [])
        found = qos.app_findings(app_report([row]), "hidden", self.closed)
        self.assertEqual(kinds(found), [("app", "hidden-tier", "ghostty renderer")])

    def test_a_library_thread_at_user_interactive_is_not_a_cmux_finding(self):
        row = app_row("ghostty renderer", "user-interactive", "ghostty-surface", ["user-interactive"],
                      origin="library")
        self.assertEqual(qos.app_findings(app_report([row]), "visible", self.closed), [])

    def test_queues_task_role_and_overflow(self):
        queues = [{"name": "cmux.a", "declared": True, "made": [{"label": "cmux.a", "problem": "qos default, row utility"}]},
                  {"name": "cmux.b", "declared": False, "made": [{"label": "cmux.b", "problem": None}]}]
        found = qos.app_findings(app_report([], queues, role="unknown", not_recorded=3), "visible", self.closed)
        self.assertEqual(kinds(found), [("app", "queue-log-overflow", "checked-queue-log"),
                                        ("app", "queue-problem", "cmux.a"), ("app", "task-role", "process"),
                                        ("app", "undeclared-queue", "cmux.b")])

    def test_a_reply_without_threads_is_a_read_error(self):
        with self.assertRaises(qos.ReadError):
            qos.app_findings({"error": "unknown method"}, "visible", self.closed)


class DaemonJudgeTests(unittest.TestCase):
    def setUp(self):
        self.closed = qos.closed_list(DOC)

    def test_linux_names_each_unregistered_thread_by_tid(self):
        snapshot = daemon_snapshot([daemon_row("mux-line-out", "user-interactive", 11, nice=0),
                                    daemon_row("mux-files-be", "utility", 12, nice=5)])
        os_threads = {"count": 6, "threads": {7: "cmux-tui", 11: "mux-line-out", 12: "mux-files-be",
                                              13: "notify-rs inoti", 14: "mux-deadline-3", 15: "cmux-tui"}}
        found = qos.daemon_findings(snapshot, os_threads, "stress", self.closed)
        self.assertEqual(kinds(found), [("daemon", "unregistered", "main"),
                                        ("daemon", "unregistered", "mux-deadline-N"),
                                        ("daemon", "unregistered", "notify-rs inoti"),
                                        ("daemon", "unregistered", "unnamed")])
        self.assertEqual(qos.tasks_for([f for f in found if f["name"] in ("main", "unnamed")],
                                       grep=lambda *_: self.fail("main and unnamed have no name to search"))[0]["files"],
                         [])

    def test_an_os_without_thread_names_counts_the_unregistered_threads(self):
        snapshot = daemon_snapshot([daemon_row("mux-line-out", "user-interactive", 11, requested="user-interactive")],
                                   mac=True)
        found = qos.daemon_findings(snapshot, {"count": 3, "threads": {}}, "stress", self.closed)
        self.assertEqual(kinds(found), [("daemon", "unregistered", "unnamed")])
        self.assertEqual(found[0]["evidence"], [{"os_count": 3, "registered": 1}])
        self.assertEqual(qos.daemon_findings(snapshot, {"count": 1, "threads": {}}, "stress", self.closed), [])

    def test_mismatch_and_interactive_outside_the_list(self):
        snapshot = daemon_snapshot([daemon_row("mux-conn", "utility", 1, nice=0, matches=False, declared="default"),
                                    daemon_row("mux-surface-operation", "user-interactive", 2, nice=0)])
        found = qos.daemon_findings(snapshot, {}, "stress", self.closed)
        self.assertEqual(kinds(found), [("daemon", "interactive-outside-closed-list", "mux-surface-operation"),
                                        ("daemon", "mismatch", "mux-conn")])
        mismatch = next(f for f in found if f["kind"] == "mismatch")
        self.assertIn("desired utility, applied utility, kernel nice 0", mismatch["detail"])

    def test_an_unreadable_row_is_no_mismatch(self):
        snapshot = daemon_snapshot([daemon_row("mux-files-be", "utility", 1, matches=None)])
        self.assertEqual(qos.daemon_findings(snapshot, {}, "stress", self.closed), [])

    def test_automation_connections_rest_at_utility(self):
        snapshot = daemon_snapshot([daemon_row("mux-conn", "user-initiated", 1, nice=0),
                                    daemon_row("mux-control-dispatch", "utility", 2, nice=5)])
        self.assertEqual(qos.daemon_findings(snapshot, {}, "stress", self.closed), [])
        found = qos.daemon_findings(snapshot, {}, "stress", self.closed, automation_only=True)
        self.assertEqual(kinds(found), [("daemon", "automation-class", "mux-conn")])

    def test_a_mac_daemon_without_a_task_role(self):
        snapshot = daemon_snapshot([], mac=True)
        snapshot["process"]["role"] = None
        found = qos.daemon_findings(snapshot, {}, "stress", self.closed)
        self.assertEqual(kinds(found), [("daemon", "task-role", "process")])


class JudgeTests(unittest.TestCase):
    def test_phases_merge_into_one_task_and_the_verdict_reads_both_runs(self):
        visible = app_report([app_row("cmux.loose 1", "utility", undeclared_cmux=True)])
        hidden = app_report([app_row("cmux.loose 2", "utility", undeclared_cmux=True)])
        samples = [daemon_snapshot([daemon_row("mux-conn", "default", 1, nice=0)]),
                   daemon_snapshot([daemon_row("mux-conn", "default", 1, nice=0)])]
        samples[0]["_phase"], samples[1]["_phase"] = "idle", "stress"
        findings, result = qos.judge(app_visible=visible, app_hidden=hidden, daemon=samples,
                                     daemon_os=[{"count": 1, "threads": {1: "mux-conn"}},
                                                {"count": 2, "threads": {1: "mux-conn", 9: "client-log"}}],
                                     peak=120, base_peak=100, doc_text=DOC)
        self.assertEqual(kinds(findings), [("app", "undeclared-cmux", "cmux.loose N"),
                                           ("daemon", "peak-threads", "process"),
                                           ("daemon", "unregistered", "client-log")])
        self.assertEqual(findings[0]["phases"], ["visible", "hidden"])
        self.assertEqual(findings[0]["count"], 2)
        self.assertEqual(findings[2]["phases"], ["stress"])
        self.assertEqual(result["run3_threads"], False)
        self.assertEqual(result["run4_threads"], False)
        self.assertEqual(result["by_kind"], {"undeclared-cmux": 1, "peak-threads": 1, "unregistered": 1})

    def test_clean_reads_pass_and_unread_runs_say_so(self):
        findings, result = qos.judge(app_visible=app_report([]), doc_text=DOC)
        self.assertEqual(findings, [])
        self.assertIs(result["run3_threads"], True)
        self.assertIsNone(result["run4_threads"])
        _, result = qos.judge(daemon=daemon_snapshot([]), peak=90, base_peak=100, doc_text=DOC)
        self.assertIs(result["run4_threads"], True)

    def test_sample_lists_of_unequal_length_are_a_read_error(self):
        with self.assertRaises(qos.ReadError):
            qos.judge(daemon=[daemon_snapshot([])], daemon_os=[{}, {}], doc_text=DOC)

    def test_tasks_name_spawn_sites_without_tests_and_the_registry(self):
        item = {"process": "app", "kind": "undeclared-cmux", "name": "cmux.loose N", "phases": ["visible"],
                "detail": "a cmux thread with no row", "evidence": []}
        seen = []

        def grep(needle, roots):
            seen.append((needle, roots))
            return ["Packages/macOS/CmuxNext/Sources/X/Loose.swift",
                    "Packages/macOS/CmuxNext/Tests/XTests/LooseTests.swift",
                    "Packages/macOS/CmuxNext/Sources/X/README.md"]
        task = qos.tasks_for([item], grep)[0]
        self.assertEqual(seen, [("cmux.loose", ["Packages/macOS", "Packages/Shared"])])
        self.assertEqual(task["id"], "p02-threads-R-qos-app-undeclared-cmux-cmux-loose-n")
        self.assertEqual(task["files"], ["Packages/macOS/CmuxNext/Sources/X/Loose.swift", *qos.REGISTRY_FILES["app"],
                                         qos.DOC_REL])
        self.assertEqual(task["machine_queue"], "MQ-15")

    def test_judge_mode_writes_its_files_and_exits_by_the_verdict(self):
        with tempfile.TemporaryDirectory() as out:
            visible = os.path.join(out, "visible.json")
            with open(visible, "w") as f:
                json.dump(app_report([app_row("cmux.home.cache", "utility", "utility", ["utility"])]), f)
            self.assertEqual(qos.main(["judge", "--app-visible", visible, "--out", out]), 0)
            for name in ("qos-findings.json", "qos-tasks.json", "qos-audit.md", "qos-verdict.json"):
                self.assertTrue(os.path.exists(os.path.join(out, name)), name)
            with open(visible, "w") as f:
                json.dump({"error": "unknown method debug.threads"}, f)
            self.assertEqual(qos.main(["judge", "--app-visible", visible, "--out", out]), 2)


class FakeApp:
    """A debug socket that answers debug.threads, debug.window_list, debug.daemon and showHideAllWindows the way
    the app does; `hide_works` False leaves the window shown, as a hide that did not take."""

    def __init__(self, path, hide_works=True):
        self.path, self.hide_works, self.hidden, self.calls = path, hide_works, False, []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(8)
        self.thread = threading.Thread(target=self.serve, name="fake-app", daemon=True)
        self.thread.start()

    def answer(self, method, params):
        self.calls.append(method)
        if method == "debug.window_list":
            return {"windows": [{"kind": "main", "visible": not self.hidden, "miniaturized": False}]}
        if method == "debug.daemon":
            return {"connection": "connected"}
        if method == "action.run" and params.get("action") == "showHideAllWindows":
            self.hidden = bool(params["args"]["hidden"]) and self.hide_works
            return {"ok": True}
        if method == "debug.threads":
            tier = "utility" if self.hidden else "user-initiated"
            tiers = ["user-interactive", "user-initiated", "utility"]
            return app_report([app_row("ghostty renderer", tier, "ghostty-surface", tiers, hidden="utility",
                                       origin="library")])
        return None

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                data = b""
                while not data.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                request = json.loads(data)
                result = self.answer(request["method"], request.get("params") or {})
                reply = {"id": request["id"], "ok": result is not None, "result": result,
                         "error": None if result is not None else "unknown method"}
                conn.sendall((json.dumps(reply) + "\n").encode())

    def close(self):
        self.server.close()


class AppModeTests(unittest.TestCase):
    def run_app(self, hide_works):
        with tempfile.TemporaryDirectory() as root:
            app = FakeApp(os.path.join(root, "app.sock"), hide_works)
            try:
                out = os.path.join(root, "out")
                code = qos.main(["app", "--socket", app.path, "--no-stress", "--settle", "0", "--out", out])
                files = sorted(os.listdir(out)) if os.path.isdir(out) else []
            finally:
                app.close()
            return code, files, app

    def test_reads_visible_then_hidden_and_shows_the_app_again(self):
        code, files, app = self.run_app(hide_works=True)
        self.assertEqual(code, 0)
        self.assertIn("debug-threads-visible.json", files)
        self.assertIn("debug-threads-hidden.json", files)
        self.assertEqual([c for c in app.calls if c in ("debug.threads", "action.run")],
                         ["debug.threads", "action.run", "debug.threads", "action.run"])
        self.assertFalse(app.hidden, "the app is shown again")

    def test_a_hide_that_did_not_take_gives_no_verdict(self):
        code, files, app = self.run_app(hide_works=False)
        self.assertEqual(code, 2)
        self.assertNotIn("qos-verdict.json", files)
        self.assertEqual(app.calls.count("debug.threads"), 1)
        self.assertEqual(app.calls[-1], "action.run", "the app is shown again after the failed phase")


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]] + sys.argv[1:], verbosity=1)
