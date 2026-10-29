#!/usr/bin/env python3
"""scripts/cmux-next/ipc-census.py: the p05-ipc machine queues Q1-Q18.

Each fixture test builds a small git tree with the paths the census reads and checks one queue
rule: a multi-line `DaemonConnection(` constructor and the other app sockets (Q4), a caller of a
receipt-wait wrapper and same-named wrappers (Q3), the QoS test of thread bodies and thread names
through a variable (Q8), the schema queues with a delegated event set (Q5, Q6, Q12, Q15), the
runtime record with and without `ipc5_ops` (Q9, Q18), `--record` / `--check`, `--callers` with
nested and private type names, and `--explain`. The last tests run on this checkout: for every
queue defined by a raw `git grep`, the census's raw count equals that command's `wc -l`, every
queue that is its raw query prints the same count, and every refined queue's breakdown sums from
the raw count to its count with no unexplained line. No count is written here.

Not on CI (Lawrence 2026-10-23: no new CI tests; lane = "manual"): run
python3 -I tests/test_ipc_census.py after changing ipc-census.py or ipc-targets.json.
"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

SOURCE = Path(__file__).resolve().parents[1]
SCRIPT = SOURCE / "scripts/cmux-next/ipc-census.py"
APP = "Packages/macOS/CmuxNext/Sources"
CORE = "cmux-tui/crates/cmux-tui-core/src"


def load():
    spec = importlib.util.spec_from_file_location("cmux_next_ipc_census", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses resolve annotations through sys.modules
    spec.loader.exec_module(module)
    return module


census_module = load()


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout


SCHEMA = {
    "commands": {
        "identify": {"capability": None},
        "new-tab": {"capability": "tabs-v1", "method_id": 0x0101, "priority": "control"},
    },
    "events": {
        "tab-added": {"event_id": 0xC001},
        "colors-changed": {},
    },
    "families": {"Tabs": {"id": 1}},
}


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-ipc-census-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        git(self.root, "init", "-q")
        git(self.root, "config", "user.email", "census@example.invalid")
        git(self.root, "config", "user.name", "census")
        self.write("cmux-tui/spec/sdk-schema.json", json.dumps(SCHEMA, indent=1))
        self.write(f"{CORE}/server.rs", """
            #[derive(Deserialize)]
            #[serde(tag = "cmd", rename_all = "kebab-case")]
            enum Command {
                /// Who is there.
                Identify {
                    #[serde(default)]
                    revisions: bool,
                },
                NewTab(tabs::Params),
                #[serde(rename = "x-legacy")]
                Legacy,
            }
        """)

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(textwrap.dedent(text).lstrip("\n"), encoding="utf-8")
        git(self.root, "add", path)

    def census(self, targets=None, io_record=None):
        return census_module.Census(census_module.Repo(self.root), targets or {}, io_record)

    def sites(self, queue, targets=None, io_record=None):
        return [(hit.file.rsplit("/", 1)[-1], hit.line, hit.key) for hit in self.census(targets, io_record).result(queue).hits]

    def run_main(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = census_module.main(["--repo", str(self.root), *args])
        return code, out.getvalue(), err.getvalue()


class SideConnectionTests(Fixture):
    def test_multi_line_constructor_and_other_sockets_count_but_prose_does_not(self):
        self.write(f"{APP}/CmuxNextDaemonService/GitLink.swift", """
            final class GitLink {
                func open() {
                    // DaemonConnection(configuration: x) in a comment is no connection
                    let text = "DaemonConnection(endpoint: y)"
                    let connection = DaemonConnection(
                        configuration: configuration,
                        endpointProvider: provider
                    )
                    watchDaemonConnection()
                }
            }
        """)
        self.write(f"{APP}/CmuxNextMobile/Lane.swift", """
            struct Lane {
                static func connect(path: String) {
                    let connection = NWConnection(to: .unix(path: path), using: .tcp)
                }
            }
        """)
        self.write(f"{APP}/CmuxNextApp/Probe.swift", """
            enum Probe {
                static func answers(_ path: String) -> Bool {
                    return withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                        }
                    }
                }
            }
        """)
        self.write(f"{APP}/CmuxNextDaemon/Connection/Transport.swift", """
            final class Transport {
                init(path: String, bridge: DaemonBridge?) {
                    if let bridge {
                        let opened = try bridge.open()
                    }
                }
                static func attach() {
                    let transport = try LineTransport(path: socketPath, bridge: nil)
                }
            }
        """)
        self.assertEqual(sorted(self.sites("Q4")), [
            ("GitLink.swift", 5, "GitLink.open: DaemonConnection("),
            ("Lane.swift", 3, "Lane.connect: NWConnection(to: .unix"),
            ("Probe.swift", 5, "Probe.answers: connect("),
            ("Transport.swift", 4, "Transport.init: DaemonBridge.open"),
            ("Transport.swift", 8, "Transport.attach: LineTransport(path:"),
        ])

    def test_allowlist_hides_a_site_by_file_or_by_key(self):
        self.write(f"{APP}/CmuxNextTasks/Tasks.swift", """
            struct Tasks {
                func dial() {
                    Darwin.connect(socket, $0, length)
                }
            }
        """)
        targets = {"allowlist": [{"queue": "Q4", "file": f"{APP}/CmuxNextTasks/Tasks.swift", "reason": "not the daemon"}]}
        self.assertEqual(self.sites("Q4"), [("Tasks.swift", 3, "Tasks.dial: connect(")])
        self.assertEqual(self.sites("Q4", targets), [])
        targets["allowlist"][0]["key"] = "Tasks.other: connect("
        self.assertEqual(len(self.sites("Q4", targets)), 1)


class ReceiptWaitTests(Fixture):
    def test_caller_of_wrapper_counts_and_definitions_and_tests_do_not(self):
        self.write(f"{CORE}/registry.rs", """
            impl Registry {
                pub(crate) fn commit_registry_intent(&mut self, intent: Intent) -> Receipt {
                    self.commit_registry_intent_with(intent, || {}, None)
                }

                pub(crate) fn commit_terminal(&mut self, intent: TerminalIntent) -> Receipt {
                    self.commit_registry_intent(Intent::Terminal(intent))
                }
            }

            #[cfg(test)]
            mod tests {
                #[test]
                fn commits() {
                    registry.commit_terminal(intent);
                }
            }
        """)
        self.write(f"{CORE}/mux/spawn.rs", """
            impl Mux {
                fn spawn_surface(&self) {
                    // registry.commit_terminal(x) in a comment does not count
                    let commit = registry
                        .commit_terminal(intent);
                }

                #[test]
                fn spawn_in_test() {
                    registry.commit_terminal(intent);
                }
            }
        """)
        self.write(f"{CORE}/mux/spawn_tests.rs", "fn t() { registry.commit_terminal(intent); }\n")
        self.assertEqual(self.sites("Q3"), [
            ("spawn.rs", 5, "spawn_surface -> commit_terminal (wraps commit_registry_intent)"),
            ("registry.rs", 7, "commit_terminal -> commit_registry_intent"),
        ])

    def test_a_same_named_function_does_not_hide_a_wrapper(self):
        self.write(f"{CORE}/mux/journal.rs", """
            impl Mux {
                pub(crate) fn append_ingress(&self, ingress: &Ingress, key: &str) -> Commit {
                    self.journal.send_producer(ingress.clone(), key)
                }
            }
        """)
        self.write(f"{CORE}/registry/journal.rs", """
            impl Registry {
                pub(crate) fn append_ingress(&mut self, ingress: &Ingress, validated: &Valid, key: &str) -> Commit {
                    let tx = self.db.transaction();
                    tx.commit()
                }
            }
        """)
        self.write(f"{CORE}/server/stream.rs", """
            fn handle(mux: &Mux, registry: &mut Registry) {
                let appended = mux.append_ingress(&ingress, key);
                let stored = registry.append_ingress(&ingress, &validated, key);
                let unknown = (lookup())(&ingress, key);
            }
            fn forward(source: &dyn Source) {
                source.append_ingress(&ingress);
            }
        """)
        self.assertEqual(self.sites("Q3"), [
            ("journal.rs", 3, "append_ingress -> send_producer"),
            ("stream.rs", 2, "handle -> append_ingress (wraps send_producer)"),
            ("stream.rs", 7, "forward -> append_ingress (ambiguous wrapper: wraps send_producer)"),
        ])

    def test_out_of_line_test_module_is_not_counted(self):
        self.write(f"{CORE}/journal.rs", """
            fn flush(mux: &Mux) {
                mux.flush_terminal_journal();
            }

            #[cfg(test)]
            mod journal_cases;
        """)
        self.write(f"{CORE}/journal/journal_cases.rs", "fn case(mux: &Mux) { mux.flush_terminal_journal(); }\n")
        self.assertEqual(self.sites("Q3"), [("journal.rs", 2, "flush -> flush_terminal_journal")])


class ThreadQosTests(Fixture):
    def test_a_body_that_begins_with_the_qos_call_is_not_counted(self):
        self.write(f"{CORE}/server/listen.rs", """
            fn listen() {
                std::thread::Builder::new().name("mux-conn".into()).spawn(move || {
                    cmux_tui_platform::qos::set_current(QosClass::UserInitiated);
                    serve();
                });
                std::thread::Builder::new().name(format!("mux-deadline-{index}")).spawn(move || {
                    serve();
                });
                std::thread::Builder::new().name("other-thread".into()).spawn(move || serve());
                mux.spawn_journal_writer("mux-session-journal-writer", move || run(weak));
            }
        """)
        self.assertEqual(self.sites("Q8"), [
            ("listen.rs", 6, "mux-deadline-{index}"),
            ("listen.rs", 10, "mux-session-journal-writer"),
        ])

    def test_a_registered_spawn_and_the_role_map_set_the_qos(self):
        # cmux_threads::spawn registers the thread at its declared class before the closure
        # runs, so every name passed to it is a thread with a QoS.
        self.write("cmux-tui/crates/cmux-threads/src/spawn.rs", """
            pub fn spawn(name: impl Into<String>, qos: ThreadQos, f: F) -> io::Result<JoinHandle<T>> {
                start(Builder::new(), name.into(), qos, f)
            }
            fn start(builder: Builder, name: String, qos: ThreadQos, f: F) -> io::Result<JoinHandle<T>> {
                builder.name(name.clone()).spawn(move || {
                    registry::register_current(name, qos);
                    f()
                })
            }
        """)
        self.write(f"{CORE}/mux/idle_close.rs", """
            fn start() {
                cmux_threads::spawn("mux-idle-close", qos, move || serve());
                std::thread::Builder::new().name("mux-role-set".into()).spawn(move || {
                    thread_qos::set(ThreadType::Utility);
                    serve();
                });
                std::thread::Builder::new().name("mux-threads-set".into()).spawn(move || {
                    cmux_threads::set_current(ThreadQos::Utility);
                });
                std::thread::Builder::new().name("mux-no-qos".into()).spawn(move || serve());
            }
        """)
        self.assertEqual(self.sites("Q8"), [("idle_close.rs", 10, "mux-no-qos")])


    def test_names_through_a_variable_count_and_another_builders_spawn_is_not_read(self):
        self.write(f"{CORE}/server/loopback_forward.rs", """
            fn open(stream: Stream) {
                for (name, run) in [
                    ("mux-loopback-rd", run_reader as fn(Arc<Stream>)),
                    ("mux-loopback-wr", run_writer as fn(Arc<Stream>)),
                ] {
                    let spawned = std::thread::Builder::new()
                        .name(name.into())
                        .stack_size(STACK)
                        .spawn(move || run(worker));
                }
                let label = format!("mux-forward-{index}");
                std::thread::Builder::new().name(label).spawn(move || serve());
            }
        """)
        self.write(f"{CORE}/surface/host_frames.rs", """
            impl HostFrames {
                pub(super) fn spawn(name: String, stream: UnixStream) -> std::io::Result<Self> {
                    std::thread::Builder::new().name(name).spawn(move || {
                        read_stream(stream);
                    })?;
                }
            }
        """)
        self.write(f"{CORE}/surface/hosted_reader.rs", """
            fn attach(id: u64, reader: UnixStream) {
                let frames = host_frames::HostFrames::spawn(
                    format!("surface-{id}-host-frames"),
                    reader,
                );
                let other = HostFrames::spawn(format!("unrelated-{id}"), reader);
            }
        """)
        self.write(f"{CORE}/server/builders.rs", """
            fn start() {
                let builder = std::thread::Builder::new().name("mux-stored".into());
                let worker = builder.spawn(move || {
                    cmux_tui_platform::qos::set_current(QosClass::UserInitiated);
                    serve();
                });
                let first = std::thread::Builder::new().name("mux-unspawned".into());
                std::thread::Builder::new().name("other".into()).spawn(move || {
                    cmux_tui_platform::qos::set_current(QosClass::Utility);
                });
            }
            fn spawn_with<S: FnOnce(String) -> Handle>(spawn: S) {
                spawn(format!("mux-closure-{index}"));
            }
            fn caller() {
                spawn_with(|name| std::thread::Builder::new().name(name).spawn(task));
            }
        """)
        self.assertEqual(sorted(self.sites("Q8")), [
            ("builders.rs", 7, "mux-unspawned"),
            ("builders.rs", 16, "<unresolved>"),
            ("host_frames.rs", 3, "surface-{id}-host-frames"),
            ("loopback_forward.rs", 7, "mux-loopback-rd"),
            ("loopback_forward.rs", 7, "mux-loopback-wr"),
            ("loopback_forward.rs", 12, "mux-forward-{index}"),
        ])

    def test_a_name_a_literal_site_counts_is_not_counted_again(self):
        self.write(f"{CORE}/journal_ingress.rs", """
            impl JournalWriter {
                fn spawn(name: &str, task: impl FnOnce()) -> io::Result<Self> {
                    let thread = std::thread::Builder::new().name(name.into()).spawn(move || {
                        task();
                    });
                }
            }
            impl JournalIngress {
                pub(crate) fn spawn_writer(&self, name: &str, task: impl FnOnce()) {
                    JournalWriter::spawn(name, task);
                }
            }
        """)
        self.write(f"{CORE}/mux/journal.rs", """
            impl Mux {
                pub(crate) fn spawn_journal_writer(&self, name: &str, task: impl FnOnce()) {
                    self.journal_ingress.spawn_writer(name, task)
                }
                fn start(&self) {
                    self.spawn_journal_writer("mux-session-journal-writer", move || run());
                }
            }
        """)
        self.assertEqual(self.sites("Q8"), [("journal.rs", 6, "mux-session-journal-writer")])


class SchemaQueueTests(Fixture):
    def setUp(self):
        super().setUp()
        self.write(f"{APP}/CmuxNextDaemon/Requests/Tabs/NewTab.swift", """
            struct NewTabRequest: Encodable {
                static let command = "new-tab"
            }
            struct AppsListRequest: Encodable {
                static let command: String = "apps-list"
            }
        """)
        self.write(f"{APP}/CmuxNextTasks/Views/Help.swift", """
            enum Help {
                static let command = "cmux task serve"
            }
        """)
        self.write(f"{APP}/CmuxNextDaemon/Events/DaemonEvent+Decoding.swift", """
            switch name {
            case "tab-added": return .tabAdded
            default: return nil
            }
        """)

    def test_q1_groups_by_directory_and_q5_keeps_wire_names_missing_from_the_schema(self):
        result = self.census().result("Q1")
        self.assertEqual(result.groups(), {"CmuxNextDaemon/Requests/Tabs": 2, "CmuxNextTasks/Views": 1})
        self.assertEqual([hit.key for hit in self.census().result("Q5").hits], ["apps-list"])

    def test_q1_counts_a_daemon_request_command_name(self):
        # Every DaemonRequest declares `commandName: DaemonCommandName`; the first Q1 query saw none.
        self.write(f"{APP}/CmuxNextDaemon/Requests/TerminalIO/Input.swift", """
            public struct SendKeyRequest: DaemonRequest {
                public static let commandName: DaemonCommandName = "send-key"
            }
        """)
        self.write(f"{APP}/CmuxNextDaemon/Terminal/Attachment.swift", """
            func press() { send(SendKeyRequest()) }
        """)
        self.assertIn(("Input.swift", 2, "send-key"), self.sites("Q1"))
        self.assertEqual(
            [(hit.file.rsplit("/", 1)[-1], hit.key) for hit in self.census().callers("CmuxNextDaemon/Requests/TerminalIO")],
            [("Attachment.swift", "SendKeyRequest")],
        )

    def test_q12_reads_a_delegated_name_set(self):
        schema = json.loads((self.root / "cmux-tui/spec/sdk-schema.json").read_text(encoding="utf-8"))
        schema["events"].update({"cloud-inbox-changed": {}, "cloud-mux-wake": {}})
        self.write("cmux-tui/spec/sdk-schema.json", json.dumps(schema, indent=1))
        self.write(f"{APP}/CmuxNextDaemon/Events/DaemonEvent+Decoding.swift", """
            switch name {
            case "tab-added": return .tabAdded
            case _ where CloudEvent.eventNames.contains(name): return .cloud
            case _ where MissingEvent.names.contains(name): return .missing
            default: return nil
            }
        """)
        self.write(f"{APP}/CmuxNextDaemon/Cloud/CloudEvent.swift", """
            public enum CloudEvent {
                case changed
                public static let eventNames: Set<String> = [
                    "cloud-inbox-changed", "colors-changed",
                ]
            }
            enum Other {
                static let eventNames: Set<String> = ["cloud-mux-wake"]
            }
        """)
        self.assertEqual(sorted(hit.key for hit in self.census().result("Q12").hits), [
            "<unread delegate MissingEvent.names>", "cloud-mux-wake",
        ])

    def test_q6_q12_q15_read_the_schema(self):
        self.assertEqual([hit.key for hit in self.census().result("Q6").hits], [
            "command identify: method_id, priority", "event colors-changed: event_id",
        ])
        self.assertEqual(self.sites("Q12"), [("sdk-schema.json", 16, "colors-changed")])
        q15 = self.census().result("Q15")
        self.assertEqual([(hit.key, hit.group) for hit in q15.hits], [
            ("identify", "capability:base"), ("new-tab", "Tabs"), ("x-legacy", "not-in-schema"),
        ])


class RuntimeQueueTests(Fixture):
    def test_q9_and_q18_come_from_a_record_run(self):
        record = [
            "      3 REQUEST_PATH_IO kind=sqlite site=src/workspace_registry/tabs.rs:120:9 op=new-tab",
            "      1 REQUEST_PATH_IO kind=sqlite site=src/workspace_registry/tabs.rs:120:9 op=new-tab",
            "      2 REQUEST_PATH_IO kind=journal_wait site=src/mux/spawn.rs:44",
            "      1 REQUEST_PATH_IO kind=sqlite site=src/inventory.rs:9 op=agent-inventory",
            "unrelated line",
        ]
        targets = {"ipc5_ops": ["new-tab"]}
        self.assertEqual(self.sites("Q9", targets, record), [
            ("inventory.rs", 9, "kind=sqlite op=agent-inventory"),
            ("spawn.rs", 44, "kind=journal_wait"),
            ("tabs.rs", 120, "kind=sqlite op=new-tab"),
        ])
        self.assertEqual(self.sites("Q18", targets, record), [("tabs.rs", 120, "kind=sqlite op=new-tab")])
        self.assertEqual(self.census(targets).result("Q9").source, "not recorded (p05-ipc-003 record run)")

    RECORD = [
        "REQUEST_PATH_IO kind=sqlite site=src/workspace_registry/tabs.rs:120 op=new-tab",
        "REQUEST_PATH_IO kind=sqlite site=src/inventory.rs:9 op=agent-inventory",
        "REQUEST_PATH_IO kind=sqlite site=src/state/load.rs:30",
    ]

    def test_q18_keeps_op_less_sites_and_an_empty_ops_list_filters_nothing(self):
        self.assertEqual(self.sites("Q18", {"ipc5_ops": ["new-tab"]}, self.RECORD), [
            ("load.rs", 30, "kind=sqlite"), ("tabs.rs", 120, "kind=sqlite op=new-tab"),
        ])
        for targets in ({"ipc5_ops": []}, {}):
            with self.subTest(targets=targets):
                self.assertEqual(len(self.sites("Q18", targets, self.RECORD)), 3)
                self.assertIn("ipc5_ops is empty", self.census(targets, self.RECORD).result("Q18").source)

    def test_check_refuses_an_empty_or_unknown_ops_list_once_q9_has_data(self):
        self.write(f"{CORE}/resource/wire_name.rs", 'Self::PaneSplit => "pane.split",\n')
        census = self.census({"ipc5_ops": []}, self.RECORD)
        self.assertTrue(any("ipc5_ops is empty" in problem for problem in census_module.check(census)))
        self.assertEqual(census_module.check(self.census({"ipc5_ops": []})), [])
        census = self.census({"ipc5_ops": ["new-tab", "pane.split", "split-pane", "pane.splat"]}, self.RECORD)
        self.assertEqual([problem.split(":")[0] for problem in census_module.check(census)], [
            "ipc5_ops split-pane", "ipc5_ops pane.splat",
        ])


class RecordCheckTests(Fixture):
    def setUp(self):
        super().setUp()
        self.write(f"{APP}/CmuxNextDaemon/Terminal/Attach.swift", """
            final class Attach {
                func attach() {
                    let transport = try LineTransport(path: endpoint.socketPath)
                }
            }
        """)
        self.targets = self.root / "plans/cmux-next/ipc-targets.json"
        self.targets.parent.mkdir(parents=True)
        self.targets.write_text(json.dumps({"allowlist": []}), encoding="utf-8")
        git(self.root, "commit", "-q", "-m", "base")

    def test_record_writes_counts_and_check_fails_when_a_queue_grows(self):
        self.assertEqual(self.run_main("--record")[0], 0)
        recorded = json.loads(self.targets.read_text(encoding="utf-8"))
        self.assertEqual(recorded["base"]["sha"], git(self.root, "rev-parse", "HEAD").strip())
        self.assertEqual(recorded["base"]["queues"]["Q4"]["count"], len(self.sites("Q4")))
        self.assertEqual(recorded["allowlist"], [])
        self.assertEqual(self.run_main("--check")[0], 0)

        self.write(f"{APP}/CmuxNextDaemon/Loopback/Forward.swift", """
            final class Forward {
                func open() { let transport = try LineTransport(path: path) }
            }
        """)
        code, _, err = self.run_main("--check")
        self.assertEqual(code, 1)
        self.assertIn("Q4 (side connections)", err)

    def test_check_refuses_an_entry_without_a_reason_or_without_a_site(self):
        self.run_main("--record")
        recorded = json.loads(self.targets.read_text(encoding="utf-8"))
        recorded["allowlist"] = [
            {"queue": "Q4", "file": f"{APP}/CmuxNextDaemon/Terminal/Attach.swift", "reason": " "},
            {"queue": "Q4", "file": f"{APP}/Gone.swift", "reason": "was removed"},
        ]
        self.targets.write_text(json.dumps(recorded), encoding="utf-8")
        code, _, err = self.run_main("--check")
        self.assertEqual(code, 1)
        self.assertIn("needs one reason", err)
        self.assertIn("matches no site", err)

    def test_queue_prints_sites_as_json(self):
        code, out, err = self.run_main("--queue", "Q4")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), [{
            "file": f"{APP}/CmuxNextDaemon/Terminal/Attach.swift", "line": 3,
            "key": "Attach.attach: LineTransport(path:",
        }])
        self.assertIn("raw 1:", err)


class CallersTests(Fixture):
    def test_callers_lists_files_that_use_a_directorys_request_types(self):
        self.write(f"{APP}/CmuxNextDaemon/Requests/Tabs/NewTab.swift", """
            struct NewTabRequest: Encodable {
                static let command = "new-tab"
            }
        """)
        self.write(f"{APP}/CmuxNextDaemon/Connection/Client+Tabs.swift", """
            extension Client {
                func newTab() async throws {
                    // NewTabRequest in a comment is no call
                    try await send(NewTabRequest())
                }
            }
        """)
        self.write(f"{APP}/CmuxNextApp/Unrelated.swift", "let text = \"NewTabRequest\"\n")
        sites = self.census().callers("CmuxNextDaemon/Requests/Tabs")
        self.assertEqual([(hit.file.rsplit("/", 1)[-1], hit.line, hit.key) for hit in sites], [
            ("Client+Tabs.swift", 4, "NewTabRequest"),
        ])


    def test_a_nested_or_private_name_matches_only_its_own_type(self):
        self.write(f"{APP}/CmuxNextDaemon/Connection/Ledger.swift", """
            public nonisolated struct Ledger: Sendable {
                public func list() async throws -> [Row] {
                    try await connection.request(List(limit: 10)).rows
                }

                private struct List: DaemonRequest {
                    static let command = "ledger-list"
                }
            }
        """)
        self.write(f"{APP}/CmuxNextDaemon/Connection/Requests.swift", """
            public enum Requests {
                public struct Ping: DaemonRequest {
                    public static let command = "ping"
                }
            }
        """)
        self.write(f"{APP}/CmuxNextHistory/HistoryPageView.swift", """
            struct HistoryPageView: View {
                var body: some View {
                    List { Text("rows") }
                    Ping()
                }
            }
        """)
        self.write(f"{APP}/CmuxNextWakeups/Trace.swift", """
            struct Trace {
                struct List { let rows: [Row] }
                func make() -> List { List(rows: []) }
            }
        """)
        self.write(f"{APP}/CmuxNextApp/Probe.swift", """
            enum Probe {
                static func ping() async throws {
                    try await connection.request(Requests.Ping())
                    try await connection.request(CmuxNextDaemon.Requests.Ping())
                    _ = settings.Ping
                }
            }
        """)
        sites = self.census().callers("CmuxNextDaemon/Connection")
        self.assertEqual([(hit.file.rsplit("/", 1)[-1], hit.line, hit.key) for hit in sites], [
            ("Probe.swift", 3, "Requests.Ping"),
            ("Ledger.swift", 3, "Ledger.List"),
        ])


class ExplainTests(Fixture):
    def test_the_breakdown_sums_from_the_raw_count_to_the_queue(self):
        self.write(f"{CORE}/mux/spawn.rs", """
            impl Mux {
                fn wrap(&self) { self.journal.send_durable(event); }
                fn spawn_surface(&self) {
                    // self.journal.send_durable(x) in a comment
                    self.wrap(); self.wrap();
                    self.journal.send_durable(event); self.journal.send_durable(other);
                }
                #[cfg(test)]
                fn t() { self.journal.send_durable(event); }
            }
        """)
        explained = self.census().breakdown("Q3")
        self.assertEqual(
            {key: explained[key] for key in ("raw_count", "dropped", "added", "same_line", "found")},
            {"raw_count": 4, "dropped": {"comment or string": 1, "test": 1}, "added": {"a caller of a wrapper": 2},
             "same_line": 1, "found": 5},
        )
        code, out, err = self.run_main("--explain", "Q3")
        self.assertEqual(code, 0)
        self.assertIn("raw 4 - comment or string 1 - test 1 + a caller of a wrapper 2 + more sites on one raw line 1 = found 5", err)
        self.assertEqual(len(json.loads(out)["dropped_lines"]), 2)


class LexerTests(unittest.TestCase):
    def test_blanking_keeps_offsets_and_hides_comments_and_literals(self):
        swift = 'let a = "x(\\(f("y")))" // DaemonConnection(\n/* LineTransport(path: */ b'
        blanked = census_module.blank_code(swift, "swift")
        self.assertEqual(len(blanked), len(swift))
        self.assertEqual(blanked.count("\n"), 1)
        self.assertNotIn("DaemonConnection", blanked)
        self.assertNotIn("LineTransport", blanked)
        self.assertTrue(blanked.endswith(" b"))
        rust = "let s = r#\"fn x() { \"#; let c = '\"'; fn real<'a>() {}"
        self.assertEqual(census_module.blank_code(rust, "rust").count("fn "), 1)


class ThisCheckoutTests(unittest.TestCase):
    """The base numbers: what the raw queries print here is what the census prints."""

    def test_raw_counts_equal_the_raw_query_and_exact_queues_equal_it(self):
        census = census_module.Census(census_module.Repo(SOURCE), {})
        exact = {"Q1", "Q2", "Q7", "Q10", "Q11", "Q13", "Q14"}
        for queue in census_module.QUEUE_IDS:
            result = census.result(queue)
            if result.raw is None:
                continue
            with self.subTest(queue=queue):
                printed = subprocess.run(["sh", "-c", result.raw], cwd=SOURCE, capture_output=True, text=True, check=True)
                self.assertEqual(result.raw_count, int(printed.stdout.strip()))
                if queue in exact:
                    self.assertEqual(result.found, result.raw_count)

    def test_every_refined_queue_explains_its_raw_count(self):
        census = census_module.Census(census_module.Repo(SOURCE), {})
        for queue in census_module.QUEUE_IDS:
            explained = census.breakdown(queue)
            if explained is None:
                continue
            with self.subTest(queue=queue):
                total = explained["raw_count"] - sum(explained["dropped"].values()) + sum(explained["added"].values())
                self.assertEqual(total + explained["same_line"], explained["found"])
                self.assertEqual(explained["found"], census.result(queue).found)
                self.assertNotIn("unexplained", explained["dropped"])

    def test_recorded_targets_are_current(self):
        code = subprocess.run(["python3", "-I", str(SCRIPT), "--check"], cwd=SOURCE, capture_output=True, text=True)
        self.assertEqual(code.returncode, 0, code.stderr)


if __name__ == "__main__":
    unittest.main()
