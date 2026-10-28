#!/usr/bin/env python3
"""Tests of scripts/cmux-next/qos-audit.py (p02-threads-302, MQ-15): the RUN-3 / RUN-4 thread judges, the verdict
parts and exit codes, the closed user-interactive list read from threading-model.md, stable task ids, the peak
sampler and the modes' files.

Run: python3 -I scripts/cmux-next/tests/test_qos_audit.py
"""
import importlib.util, json, os, socket, sys, tempfile, threading, types, unittest

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
| `mux-conn` of the app's UI connection | daemon | Reads the person's keys | no |
| `mux-line-out`, `mux-pty-input` | daemon | Key in, echo out | yes |
| `mux-io` | daemon | Reads and writes every local connection | yes |
| `surface-<id>-reader`, `surface-frames` | daemon | PTY output | yes |

## Lanes
"""
TIERS = ["user-interactive", "user-initiated", "utility"]


def app_row(name, requested, declared=None, tiers=None, hidden=None, origin="cmux", **extra):
    row = {"tid": 1, "name": name, "label": None, "main": False, "requested_qos": requested, "effective_pri": 31,
           "cpu_ms": 0, "declared": declared, "declared_tiers": tiers, "declared_hidden": hidden,
           "declared_as": name if declared else None, "origin": origin if declared else None, "library": None,
           "undeclared_cmux": False, "undeclared_library": None,
           "match": None if declared is None or requested is None else requested in (tiers or [declared])}
    row.update(extra)
    return row


def renderer(requested, tid=1):
    return app_row("renderer", requested, "ghostty-surface", TIERS, hidden="utility", origin="library", tid=tid)


def app_report(threads, queues=(), role="foreground", not_recorded=0):
    return {"task_role": role, "threads": list(threads), "queues": list(queues), "queues_not_recorded": not_recorded}


def surfaces_report(drawing, hidden=0, live=None):
    panes = ([{"pane": f"p{i}", "surface": {"drawing": True}} for i in range(drawing)]
             + [{"pane": f"h{i}", "surface": {"drawing": False}} for i in range(hidden)])
    return {"windows": [{"window": "1", "panes": panes}], "live_terminals": live if live is not None else drawing}


def daemon_row(name, desired, tid, requested=None, nice=None, matches=True, declared=None, connection=None):
    row = {"name": name, "tid": tid, "declared": declared or desired, "desired": desired, "effective": desired,
           "requested_qos": requested, "nice": nice, "priority": 20, "refused_changes": 0, "matches": matches}
    if connection is not None:
        row["connection"] = connection
    return row


def connection(client, origin, peer_pid, cls, transport="unix", remote=False):
    return {"client": client, "transport": transport, "remote_device": remote, "origin": origin,
            "peer_pid": peer_pid, "class": cls}


def daemon_snapshot(threads, mac=False):
    process = {"pid": 7, "role": "foreground" if mac else None, "role_raw": None,
               "darwin_bg": {"internal": False, "external": False} if mac else None}
    return {"schema": 1, "uptime_ms": 1, "process": process, "threads": list(threads), "lanes": []}


def app_daemon_snapshot(extra=()):
    """The app's daemon with the verified app's connection (client 1, the app's pid 900) resting right."""
    app = connection(1, "user", 900, "person")
    return daemon_snapshot([daemon_row("mux-conn", "user-interactive", 11, nice=0, connection=app),
                            daemon_row("mux-control-dispatch", "user-initiated", 12, nice=0, connection=app),
                            *extra])


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
        row = renderer("user-initiated")
        self.assertEqual(qos.app_findings(app_report([row]), "visible", self.closed), [])
        found = qos.app_findings(app_report([row]), "hidden", self.closed)
        self.assertEqual(kinds(found), [("app", "hidden-tier", "renderer")])

    def test_a_surface_that_is_not_shown_keeps_its_threads_at_utility_in_the_visible_phase(self):
        # Two surfaces draw; a third, a background workspace's in the shown window, stays at user-initiated.
        rows = [renderer("user-interactive", 1), renderer("user-initiated", 2), renderer("user-initiated", 3),
                renderer("utility", 4)]
        census = qos.surface_census(surfaces_report(drawing=2, hidden=1, live=4))
        found = qos.app_findings(app_report(rows), "visible", self.closed, census)
        self.assertEqual(kinds(found), [("app", "hidden-workspace-tier", "renderer")])
        self.assertIn("3 threads above utility with 2 surfaces drawing (4 live terminals)", found[0]["detail"])
        self.assertEqual([row["tid"] for row in found[0]["evidence"]], [1, 2, 3])
        rows[2] = renderer("utility", 3)
        self.assertEqual(qos.app_findings(app_report(rows), "visible", self.closed, census), [])

    def test_a_surfaces_reply_without_windows_is_a_read_error(self):
        with self.assertRaises(qos.ReadError):
            qos.surface_census({"error": "unknown method debug.surfaces"})

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
                                              13: "notify-rs inoti", 14: "mux-deadline-3", 15: "cmux-tui"},
                      "platform": "linux"}
        found = qos.daemon_findings(snapshot, os_threads, "stress", self.closed)
        self.assertEqual(kinds(found), [("daemon", "unregistered", "main"),
                                        ("daemon", "unregistered", "mux-deadline-N"),
                                        ("daemon", "unregistered", "notify-rs inoti"),
                                        ("daemon", "unregistered", "unnamed")])
        self.assertEqual(qos.tasks_for([f for f in found if f["name"] in ("main", "unnamed")],
                                       grep=lambda *_: self.fail("main and unnamed have no name to search"))[0]["files"],
                         [])

    def test_macos_finds_the_main_thread_by_the_lowest_thread_id(self):
        # PROC_PIDLISTTHREADIDS ids are 64-bit thread ids, never the pid; the main thread has the lowest, and an
        # unnamed macOS thread has an empty name.
        snapshot = daemon_snapshot([daemon_row("mux-line-out", "user-interactive", 0x2A1B05,
                                               requested="user-interactive")], mac=True)
        os_threads = {"count": 4, "threads": {0x2A1B05: "mux-line-out", 0x2A1B00: "", 0x2A1B09: "",
                                              0x2A1B0C: "client-log"}, "platform": "darwin"}
        found = qos.daemon_findings(snapshot, os_threads, "stress", self.closed)
        self.assertEqual(kinds(found), [("daemon", "unregistered", "client-log"),
                                        ("daemon", "unregistered", "main"),
                                        ("daemon", "unregistered", "unnamed")])
        main = next(f for f in found if f["name"] == "main")
        self.assertEqual(main["evidence"], [{"tid": 0x2A1B00, "comm": ""}])
        # The ids JSON gives back are strings.
        saved = json.loads(json.dumps(os_threads))
        self.assertEqual(kinds(qos.daemon_findings(snapshot, saved, "stress", self.closed)), kinds(found))

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

    def test_rows_without_a_connection_field_rest_at_utility_with_automation_only(self):
        snapshot = daemon_snapshot([daemon_row("mux-conn", "user-initiated", 1, nice=0),
                                    daemon_row("mux-control-dispatch", "utility", 2, nice=5)])
        self.assertEqual(qos.daemon_findings(snapshot, {}, "stress", self.closed), [])
        found = qos.daemon_findings(snapshot, {}, "stress", self.closed, automation_only=True)
        self.assertEqual(kinds(found), [("daemon", "automation-class", "mux-conn")])

    def test_the_persons_connection_resting_right_is_clean(self):
        seen = set()
        self.assertEqual(qos.daemon_findings(app_daemon_snapshot(), {}, "visible", self.closed, seen=seen), [])
        self.assertEqual(seen, {"person"})

    def test_the_ui_reader_classed_automation_at_utility_is_a_finding(self):
        # The verified app's connection, classed Automation: desired equals the kernel's, so there is no
        # mismatch, but the person's reader must rest at the echo class.
        app = connection(1, "user", 900, "automation")
        snapshot = daemon_snapshot([daemon_row("mux-conn", "utility", 11, requested="utility", connection=app)],
                                   mac=True)
        found = qos.daemon_findings(snapshot, {}, "visible", self.closed)
        self.assertEqual(kinds(found), [("daemon", "ui-connection", "mux-conn")])
        self.assertIn("person connection 1 (unix, origin user, classed automation): desired utility, kernel "
                      "utility, rests at user-interactive", found[0]["detail"])

    def test_a_ui_reader_whose_kernel_class_is_low_is_a_finding(self):
        app = connection(1, "user", 900, "person")
        snapshot = daemon_snapshot([daemon_row("mux-conn", "user-interactive", 11, requested="user-initiated",
                                               matches=False, connection=app)], mac=True)
        found = qos.daemon_findings(snapshot, {}, "visible", self.closed)
        self.assertEqual(kinds(found), [("daemon", "mismatch", "mux-conn"), ("daemon", "ui-connection", "mux-conn")])

    def test_a_ui_dispatch_thread_not_at_user_initiated_is_a_finding(self):
        app = connection(1, "user", 900, "person")
        snapshot = daemon_snapshot([daemon_row("mux-control-dispatch", "default", 12, nice=0, connection=app)])
        found = qos.daemon_findings(snapshot, {}, "visible", self.closed)
        self.assertEqual(kinds(found), [("daemon", "ui-connection", "mux-control-dispatch")])

    def test_the_apps_other_connections_are_the_persons_and_the_rest_automation(self):
        app = connection(1, "user", 900, "person")
        attach = connection(2, "agent", 900, "person")  # terminal_attach: no hello, the app's process
        cli = connection(3, "agent", 4242, "automation")
        relay = connection(4, "page", 900, "automation")
        phone = connection(5, "user", 900, "automation", transport="remote")
        rows = [daemon_row("mux-conn", "user-interactive", 11, nice=0, connection=app),
                daemon_row("mux-conn", "user-initiated", 12, nice=0, connection=attach),
                daemon_row("mux-conn", "utility", 13, nice=5, connection=cli),
                daemon_row("mux-control-dispatch", "user-initiated", 14, nice=0, connection=relay),
                daemon_row("mux-remote-conn", "utility", 15, nice=5, connection=phone)]
        found = qos.daemon_findings(daemon_snapshot(rows), {}, "visible", self.closed)
        self.assertEqual([(f["kind"], f["evidence"][0]["tid"]) for f in found],
                         [("ui-connection", 12), ("automation-class", 14)])

    def test_the_persons_local_connection_is_judged_by_the_class_its_lines_run_at(self):
        # A local connection holds no thread; `connections` gives its lines' class.
        app = dict(connection(1, "user", 900, "person"), lines_qos="user-interactive")
        attach = dict(connection(2, "agent", 900, "person"), lines_qos="user-initiated")
        cli = dict(connection(3, "agent", 4242, "automation"), lines_qos="utility")
        relay = dict(connection(4, "page", 900, "automation"), lines_qos="user-initiated")
        snapshot = daemon_snapshot([daemon_row("mux-io", "user-interactive", 11, nice=-10)])
        snapshot["connections"] = [app, attach, cli, relay]
        seen = set()
        found = qos.daemon_findings(snapshot, {}, "visible", self.closed, seen=seen)
        self.assertEqual([(f["kind"], f["name"], f["evidence"][0]["client"]) for f in found],
                         [("ui-connection", "lines", 2), ("automation-class", "lines", 4)])
        self.assertIn("its lines run at user-initiated, not user-interactive", found[0]["detail"])
        self.assertEqual(seen, {"person", "automation"})

    def test_an_app_daemon_whose_app_connection_holds_no_thread_sees_the_person(self):
        snapshot = daemon_snapshot([daemon_row("mux-io", "user-interactive", 11, nice=-10)])
        snapshot["connections"] = [dict(connection(1, "user", 900, "person"), lines_qos="user-interactive")]
        findings, result = qos.judge(app_daemon=snapshot, doc_text=DOC)
        self.assertEqual(findings, [])
        self.assertIs(result["parts"]["run4_ui_connection"], True)

    def test_a_mac_daemon_without_a_task_role(self):
        snapshot = daemon_snapshot([], mac=True)
        snapshot["process"]["role"] = None
        found = qos.daemon_findings(snapshot, {}, "stress", self.closed)
        self.assertEqual(kinds(found), [("daemon", "task-role", "process")])


def automation_snapshot():
    """A headless daemon's samples: the audit's own connection, resting at utility."""
    cli = connection(1, "agent", 4242, "automation")
    return daemon_snapshot([daemon_row("mux-conn", "utility", 1, nice=5, connection=cli)])


class JudgeTests(unittest.TestCase):
    def full(self, **overrides):
        inputs = dict(app_visible=app_report([renderer("user-initiated")]), app_surfaces=surfaces_report(1),
                      app_hidden=app_report([renderer("utility")]), app_daemon=app_daemon_snapshot(),
                      daemon=automation_snapshot(), peaks=[90, 92], base_peaks=[100, 101], doc_text=DOC)
        inputs.update(overrides)
        return qos.judge(**inputs)

    def test_every_part_read_and_clean_passes_both_runs(self):
        findings, result = self.full()
        self.assertEqual(findings, [])
        self.assertEqual(result["parts"], dict.fromkeys(qos.RUN3_PARTS + qos.RUN4_PARTS, True))
        self.assertIs(result["run3_threads"], True)
        self.assertIs(result["run4_threads"], True)
        self.assertEqual(qos.exit_code(result), 0)

    def test_phases_merge_into_one_task_and_a_failed_part_fails_its_run(self):
        visible = app_report([app_row("cmux.loose 1", "utility", undeclared_cmux=True)])
        hidden = app_report([app_row("cmux.loose 2", "utility", undeclared_cmux=True)])
        samples = [automation_snapshot(), automation_snapshot()]
        samples[0]["_phase"], samples[1]["_phase"] = "idle", "stress"
        findings, result = qos.judge(app_visible=visible, app_hidden=hidden, daemon=samples,
                                     daemon_os=[{"count": 1, "threads": {1: "mux-conn"}},
                                                {"count": 2, "threads": {1: "mux-conn", 9: "client-log"}}],
                                     peaks=[120], base_peaks=[100], doc_text=DOC)
        self.assertEqual(kinds(findings), [("app", "undeclared-cmux", "cmux.loose N"),
                                           ("daemon", "peak-threads", "process"),
                                           ("daemon", "unregistered", "client-log")])
        self.assertEqual(findings[0]["phases"], ["visible", "hidden"])
        self.assertEqual(findings[0]["count"], 2)
        self.assertEqual(findings[2]["phases"], ["stress"])
        self.assertIs(result["run3_threads"], False, "a failed part fails RUN-3 though one part was not read")
        self.assertIs(result["run4_threads"], False)
        self.assertIsNone(result["parts"]["run3_hidden_workspaces"])
        self.assertEqual(result["by_kind"], {"undeclared-cmux": 1, "peak-threads": 1, "unregistered": 1})
        self.assertEqual(qos.exit_code(result), 2, "the hidden-workspace part was not read")

    def test_a_visible_only_judge_gives_no_verdict(self):
        findings, result = qos.judge(app_visible=app_report([]), doc_text=DOC)
        self.assertEqual(findings, [])
        self.assertIsNone(result["run3_threads"])
        self.assertEqual(result["missing"], ["run3_hidden_workspaces", "run3_hidden"])
        self.assertEqual(qos.exit_code(result), 2)

    def test_a_daemon_judge_without_the_base_peak_gives_no_verdict(self):
        findings, result = qos.judge(daemon=automation_snapshot(), doc_text=DOC)
        self.assertEqual(findings, [])
        self.assertIs(result["parts"]["run4_daemon_threads"], True)
        self.assertIsNone(result["run4_threads"])
        self.assertEqual(result["missing"], ["run4_peak"])
        self.assertEqual(qos.exit_code(result), 2)

    def test_a_judge_with_no_inputs_gives_no_verdict(self):
        findings, result = qos.judge(doc_text=DOC)
        self.assertEqual(findings, [])
        self.assertEqual(result["covers"], [])
        self.assertEqual(qos.exit_code(result), 2)

    def test_a_headless_daemon_never_passes_the_ui_connection_part(self):
        _, result = qos.judge(daemon=automation_snapshot(), peaks=[90], base_peaks=[100], doc_text=DOC)
        self.assertEqual(qos.exit_code(result), 0, "the daemon mode's parts pass")
        self.assertIsNone(result["parts"]["run4_ui_connection"])
        self.assertIsNone(result["run4_threads"], "RUN-4 needs the app daemon's UI connection too")

    def test_an_app_daemon_without_the_verified_app_is_a_finding(self):
        cli = connection(1, "agent", 4242, "automation")
        snapshot = daemon_snapshot([daemon_row("mux-conn", "utility", 1, nice=5, connection=cli)])
        findings, result = qos.judge(app_daemon=snapshot, doc_text=DOC)
        self.assertEqual(kinds(findings), [("daemon", "ui-connection", "unseen")])
        self.assertIs(result["parts"]["run4_ui_connection"], False)
        self.assertEqual(qos.exit_code(result), 1)

    def test_the_peak_passes_only_below_every_base_run(self):
        for peaks, base, ok in (([90, 99], [100, 104], True), ([90, 101], [100, 104], False),
                                ([100], [100], False)):
            _, result = self.full(peaks=peaks, base_peaks=base)
            self.assertIs(result["parts"]["run4_peak"], ok, (peaks, base))

    def test_peaks_read_from_a_peak_file_or_a_number(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "qos-peak.json")
            with open(path, "w") as f:
                json.dump({"peaks": [389, 391], "daemon_peak_threads": 391}, f)
            self.assertEqual(qos.load_peaks(path), [389, 391])
        self.assertEqual(qos.load_peaks("389"), [389])
        with self.assertRaises(qos.ReadError):
            qos.as_peaks({"peaks": []})

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
            def save(name, value):
                path = os.path.join(out, name)
                with open(path, "w") as f:
                    json.dump(value, f)
                return path
            inputs = ["--app-visible", save("visible.json", app_report([renderer("user-initiated")])),
                      "--app-hidden", save("hidden.json", app_report([renderer("utility")])),
                      "--app-surfaces", save("surfaces.json", surfaces_report(1))]
            self.assertEqual(qos.main(["judge", *inputs, "--out", out]), 0)
            for name in ("qos-findings.json", "qos-tasks.json", "qos-audit.md", "qos-verdict.json"):
                self.assertTrue(os.path.exists(os.path.join(out, name)), name)
            self.assertEqual(qos.main(["judge", inputs[0], inputs[1], "--out", out]), 2, "visible only")
            self.assertEqual(qos.main(["judge", "--out", out]), 2, "no inputs")
            save("visible.json", {"error": "unknown method debug.threads"})
            self.assertEqual(qos.main(["judge", *inputs, "--out", out]), 2)


class PeakSamplerTests(unittest.TestCase):
    def test_the_peak_is_the_highest_count_between_reads(self):
        counts = iter([10, 14, 31, 12, 11])
        done = threading.Event()

        def count(_pid):
            value = next(counts, None)
            if value is None:
                done.set()
                return 11
            return value
        with qos.PeakSampler(1, interval=0.0, count=count) as sampler:
            self.assertTrue(done.wait(10), "the sampler reads until stopped")
        self.assertEqual(sampler.peak, 31, "a transient thread between two server-threads reads counts")
        self.assertGreaterEqual(sampler.samples, 5)

    def test_a_gone_process_is_no_sample(self):
        with qos.PeakSampler(1, interval=0.0, count=lambda _pid: None) as sampler:
            pass
        self.assertEqual((sampler.peak, sampler.samples), (0, 0))

    def test_this_process_has_a_thread_count(self):
        self.assertGreaterEqual(qos.thread_count(os.getpid()) or 0, 1)


class FakeDaemonConn:
    """The calls lifecycle_round makes, answered as a headless daemon does."""

    def __init__(self):
        self.calls, self.next = [], 100

    def must(self, cmd, **params):
        self.calls.append(cmd)
        self.next += 1
        if cmd == "list-workspaces":
            return {"workspaces": [{"id": "w1", "screens": [{"panes": [{"id": "p9", "tabs": [{"surface": self.next - 1}]}]}]}]}
        if cmd in ("new-tab", "new-browser-tab", "new-workspace"):
            return {"surface": self.next}
        if cmd == "split":
            return {"surface": self.next, "pane": f"p{self.next}"}
        return {}


class DaemonModeTests(unittest.TestCase):
    def test_a_round_is_perf_10x_lifecycles_op_mix(self):
        conn = FakeDaemonConn()
        qos.lifecycle_round(conn, "p1", 0)
        self.assertEqual(conn.calls, ["new-tab", "close-surface", "new-browser-tab", "close-surface",
                                      "split", "close-pane", "split", "close-pane", "split", "close-pane",
                                      "new-workspace", "list-workspaces", "close-workspace"])

    def test_a_reply_without_its_field_is_a_read_error(self):
        class Empty(FakeDaemonConn):
            def must(self, cmd, **params):
                return {}
        with self.assertRaises(qos.ReadError):
            qos.lifecycle_round(Empty(), "p1", 0)

    def test_a_niced_linux_audit_refuses_to_start_the_daemon(self):
        self.assertIn("nice 10", qos.inherited_nice_problem(nice=10, linux=True))
        self.assertIsNone(qos.inherited_nice_problem(nice=0, linux=True))
        self.assertIsNone(qos.inherited_nice_problem(nice=10, linux=False), "macOS classes are not nice values")

    def test_daemon_mode_without_a_base_peak_exits_2_before_it_starts(self):
        with tempfile.TemporaryDirectory() as out:
            self.assertEqual(qos.main(["daemon", "--bin", "/nonexistent/cmux-tui", "--out", out]), 2)
            self.assertFalse(os.path.exists(os.path.join(out, "daemon.log")), "no daemon was started")


class FakeApp:
    """A debug socket that answers debug.threads, debug.surfaces, debug.window_list, debug.daemon and
    showHideAllWindows the way the app does; `hide_works` False leaves the window shown, as a hide that did not
    take."""

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
            return app_report([renderer("utility" if self.hidden else "user-initiated")])
        if method == "debug.surfaces":
            return surfaces_report(0 if self.hidden else 1)
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
    def run_app(self, hide_works, *extra):
        with tempfile.TemporaryDirectory() as root:
            app = FakeApp(os.path.join(root, "app.sock"), hide_works)
            try:
                out = os.path.join(root, "out")
                code = qos.main(["app", "--socket", app.path, "--settle", "0", "--out", out, *extra])
                files = sorted(os.listdir(out)) if os.path.isdir(out) else []
            finally:
                app.close()
            return code, files, app

    def test_reads_visible_then_hidden_and_shows_the_app_again(self):
        code, files, app = self.run_app(True, "--no-stress")
        self.assertEqual(code, 0)
        for name in ("debug-threads-visible.json", "debug-threads-hidden.json", "debug-surfaces-visible.json"):
            self.assertIn(name, files)
        self.assertEqual([c for c in app.calls if c in ("debug.threads", "action.run")],
                         ["debug.threads", "action.run", "debug.threads", "action.run"])
        self.assertFalse(app.hidden, "the app is shown again")

    def test_a_hide_that_did_not_take_gives_no_verdict(self):
        code, files, app = self.run_app(False, "--no-stress")
        self.assertEqual(code, 2)
        self.assertNotIn("qos-verdict.json", files)
        self.assertEqual(app.calls.count("debug.threads"), 1)
        self.assertEqual(app.calls[-1], "action.run", "the app is shown again after the failed phase")

    def test_a_stress_build_that_fails_is_a_read_error(self):
        class StressShapeError(RuntimeError):
            pass

        class Stress:
            def __init__(self, rpc):
                self.rpc = rpc

            def build(self):
                raise StressShapeError("focus never reached pane 3")

        module = types.SimpleNamespace(Stress=Stress, socket_rpc=lambda _path: lambda *args, **kwargs: {})
        with tempfile.TemporaryDirectory() as out:
            opts = qos.argparse.Namespace(app=None, socket="unused", stress=True, daemon_socket=None, settle=0,
                                          out=out)
            with self.assertRaises(qos.ReadError) as raised:
                qos.run_app(opts, stress=module)
            self.assertIn("StressShapeError: focus never reached pane 3", str(raised.exception))
            self.assertFalse(os.path.exists(os.path.join(out, "qos-verdict.json")))


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]] + sys.argv[1:], verbosity=1)
