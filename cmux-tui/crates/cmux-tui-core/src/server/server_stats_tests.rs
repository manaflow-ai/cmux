//! `server-stats` optional sections: absent unless requested, so SDK
//! decoders that refuse unknown result fields keep working. Also the request
//! path scopes behind `request_path_io`: frames and queued requests run in
//! the daemon's scope, and a handler's notes carry the handler's line.

use serde_json::{Value, json};

use super::super::*;

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

fn stats(mux: &Arc<Mux>, client: u64, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    handle_command(mux, client, command, &writer()).unwrap()
}

#[test]
fn server_stats_include_reports_resource_projection_spans() {
    let mux = Mux::new_for_test("server-stats-projection", crate::SurfaceOptions::default());
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.new_workspace(None, Some((80, 24))).unwrap();

    let plain = stats(&mux, client, json!({"cmd":"server-stats"}));
    assert!(plain.get("resource_projection").is_none(), "{plain}");
    let unknown = stats(&mux, client, json!({"cmd":"server-stats","include":["no_such_section"]}));
    assert!(unknown.get("resource_projection").is_none(), "{unknown}");

    let full = stats(&mux, client, json!({"cmd":"server-stats","include":["resource_projection"]}));
    let section = &full["resource_projection"];
    assert!(section["projections"].as_u64().unwrap_or(0) >= 2, "{full}");
    assert!(section["commits"].as_u64().unwrap_or(0) >= 2, "{full}");
    assert!(
        section["commits"].as_u64() <= section["projections"].as_u64(),
        "only commits of projected patches count: {section}"
    );
    for span in [
        "read_us",
        "index_us",
        "diff_us",
        "commit_us",
        "commit_prune_us",
        "commit_apply_us",
        "commit_journal_us",
        "projected_changes",
        "written_changes",
        "journaled_changes",
    ] {
        assert!(section[span]["count"].as_u64().unwrap_or(0) >= 2, "{span}: {section}");
    }
    assert!(section["projected_changes"]["max"].as_u64().unwrap_or(0) >= 1, "{section}");
    assert!(section["written_changes"]["max"].as_u64().unwrap_or(0) >= 1, "{section}");
}

fn request_path_mux(label: &str) -> (Arc<Mux>, u64, MessageWriter, Arc<BoundedOutbound>) {
    let mux = Mux::new_for_test(format!("request-path-{label}"), crate::SurfaceOptions::default());
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    (mux, client, writer, outbound)
}

fn request_path_counts(mux: &Mux) -> (u64, u64) {
    let stats = mux.request_path_stats();
    (stats.handler_runs(), stats.count(crate::request_path::BlockingKind::Sqlite))
}

#[test]
fn server_stats_include_reports_request_path_io() {
    let (mux, client, _, _) = request_path_mux("section");
    let plain = stats(&mux, client, json!({"cmd":"server-stats"}));
    assert!(plain.get("request_path_io").is_none(), "{plain}");
    let full = stats(&mux, client, json!({"cmd":"server-stats","include":["request_path_io"]}));
    let section = &full["request_path_io"];
    for kind in crate::request_path::BlockingKind::ALL {
        if kind == crate::request_path::BlockingKind::LockHoldOver1ms {
            continue;
        }
        assert!(section[kind.name()].is_u64(), "{kind}: {section}");
    }
    assert!(section["scopes"].is_u64(), "{section}");
    assert!(section["sites"].is_array(), "{section}");
    assert_eq!(
        section.get("lock_hold_over_1ms").is_some(),
        mux.request_path_stats().mode().records(),
        "holds are reported only when timed: {section}"
    );
}

/// The section matches the SDK schema (spec/sdk-schema.json): the generated
/// Rust SDK decodes it and re-encodes every field, in both modes.
#[test]
fn server_stats_request_path_io_round_trips_through_the_sdk() {
    use crate::request_path::{
        BlockingKind, RequestPathIoSnapshot, RequestPathMode, RequestPathScope, RequestPathStats,
        note,
    };
    let (mux, client, _, _) = request_path_mux("sdk");
    let full = stats(&mux, client, json!({"cmd":"server-stats","include":["request_path_io"]}));
    let decoded: ::cmux::raw::ServerStatsResult =
        serde_json::from_value(full.clone()).expect("the SDK decodes server-stats");
    assert_eq!(serde_json::to_value(&decoded).unwrap(), full);
    for mode in [RequestPathMode::OFF, RequestPathMode::RECORD] {
        let stats = RequestPathStats::new(mode);
        {
            let _scope = RequestPathScope::enter(&stats);
            note(BlockingKind::Sqlite);
            note(BlockingKind::LockHoldOver1ms);
        }
        let section = serde_json::to_value(RequestPathIoSnapshot::of(&stats)).unwrap();
        let decoded: ::cmux::raw::ServerStatsRequestPathIo =
            serde_json::from_value(section.clone()).expect("the SDK decodes the section");
        assert_eq!(serde_json::to_value(&decoded).unwrap(), section, "{mode:?}");
        assert_eq!(decoded.lock_hold_over_1ms.is_some(), mode.records());
        assert_eq!(decoded.sites.len(), if mode.records() { 2 } else { 0 });
        assert!(decoded.lock_waits.is_some(), "the section always carries lock_waits");
    }
}

#[test]
fn request_path_a_frame_runs_its_handler_in_the_daemon_scope() {
    let (mux, client, writer, outbound) = request_path_mux("frame");
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let (runs, sqlite) = request_path_counts(&mux);
    assert!(handle_connection_frame(
        &mux,
        client,
        ClientTransport::Unix,
        &json!({"protocol": "cmux.protocol/2", "type": "request", "id": "r1", "operation": "workspace.list", "params": {"machine": "current", "session": "current"}}).to_string(),
        &writer,
        &scheduler,
    ));
    let reply: Value = serde_json::from_str(&outbound.try_pop().expect("a reply")).unwrap();
    assert!(reply["result"].is_array(), "a synchronous v2 reply: {reply}");
    let (runs_after, sqlite_after) = request_path_counts(&mux);
    assert_eq!(runs_after, runs + 1, "one frame, one outermost scope");
    assert!(sqlite_after > sqlite, "workspace.list reads the registry in the frame scope");
}

#[test]
fn request_path_a_queued_request_runs_in_the_daemon_scope() {
    let (mux, client, writer, outbound) = request_path_mux("queued");
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let request: Request =
        serde_json::from_value(json!({"id": 2, "cmd": "list-terminals"})).unwrap();
    let pending = PendingSurfaceRequest {
        request,
        arrival: RequestArrival::now(),
        cause: crate::event_cause::EventCause::Program,
        frame_call: None,
        retained_bytes: 0,
        _bytes_permit: mux.surface_operation_admission.try_reserve_bytes(0).expect("permit"),
        stream_barrier: None,
    };
    let (runs, sqlite) = request_path_counts(&mux);
    assert!(run_pending_request(&scheduler, &mux, client, pending, &writer));
    let reply: Value = serde_json::from_str(&outbound.try_pop().expect("a reply")).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    let (runs_after, sqlite_after) = request_path_counts(&mux);
    assert_eq!(runs_after, runs + 1);
    assert!(sqlite_after > sqlite);
}

#[test]
fn request_path_a_registry_handler_records_its_own_line() {
    use crate::request_path::{BlockingKind, RequestPathMode, RequestPathScope, RequestPathStats};
    let (mux, ..) = request_path_mux("handler-site");
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    cmd_terminals::list_terminals(&mux).expect("list-terminals");
    let sites: Vec<_> = stats
        .sites()
        .into_iter()
        .filter(|noted| noted.kind == BlockingKind::Sqlite)
        .map(|noted| noted.site.file())
        .collect();
    assert!(!sites.is_empty());
    assert!(
        sites.iter().all(|file| file.ends_with("server/cmd_terminals.rs")),
        "the handler's file, not mux/*.rs or workspace_registry*.rs: {sites:?}"
    );
}

#[test]
fn request_path_terminal_resources_is_a_proc_scan_at_the_handler() {
    use crate::request_path::{BlockingKind, RequestPathMode, RequestPathScope, RequestPathStats};
    let (mux, ..) = request_path_mux("terminal-resources");
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let _scope = RequestPathScope::enter(&stats);
    cmd_terminals::terminal_resources(&mux, None).expect("terminal-resources");
    assert!(stats.count(BlockingKind::ProcScan) >= 1);
    let sites: Vec<_> = stats
        .sites()
        .into_iter()
        .filter(|noted| noted.kind == BlockingKind::ProcScan)
        .map(|noted| noted.site.file())
        .collect();
    assert!(
        sites.iter().all(|file| file.ends_with("server/terminal_resources.rs")),
        "the handler's file, not process_resources.rs: {sites:?}"
    );
}

#[test]
fn server_stats_include_reports_slow_requests() {
    let mux = Mux::new_for_test("server-stats-slow-requests", crate::SurfaceOptions::default());
    let client = mux.control_clients.register(ClientTransport::Unix, writer());

    let plain = stats(&mux, client, json!({"cmd":"server-stats"}));
    assert!(plain.get("slow_requests").is_none(), "{plain}");

    let full = stats(&mux, client, json!({"cmd":"server-stats","include":["slow_requests"]}));
    let section = &full["slow_requests"];
    assert_eq!(section["threshold_ms"], json!(250), "{full}");
    assert_eq!(section["total"], json!(0), "{full}");
    assert_eq!(section["unwatched"], json!(0), "{full}");
    assert!(section["expected_waits"].is_u64(), "{full}");
    assert_eq!(section["spawn_failures"], json!(0), "{full}");
    assert!(section["watchdog_wakeups"].is_u64(), "{full}");
    assert_eq!(section["hang_ms"], json!(2000), "{full}");
    assert_eq!(section["hangs"], json!(0), "{full}");
    assert_eq!(section["recent"], json!([]), "{full}");
}

#[test]
fn server_stats_include_reports_hangs() {
    use std::time::{Duration, Instant};
    let mux = Mux::new_for_test("server-stats-hangs", crate::SurfaceOptions::default());
    let client = mux.control_clients.register(ClientTransport::Unix, writer());

    let plain = stats(&mux, client, json!({"cmd":"server-stats"}));
    assert!(plain.get("hangs").is_none(), "{plain}");
    let idle = stats(&mux, client, json!({"cmd":"server-stats","include":["hangs"]}));
    assert_eq!(idle["hangs"], json!({"over_250ms": 0, "records": []}), "{idle}");

    let method = WatchedMethod::resource(ResourceOperation::WorkspaceCreate);
    let scope = mux.request_watchdog.begin(client, method).expect("a free slot");
    std::thread::sleep(Duration::from_millis(300));
    drop(scope);
    let deadline = Instant::now() + Duration::from_secs(5);
    let full = loop {
        let full = stats(&mux, client, json!({"cmd":"server-stats","include":["hangs"]}));
        if full["hangs"]["over_250ms"] == json!(1) {
            break full;
        }
        assert!(Instant::now() < deadline, "never counted: {full}");
        std::thread::sleep(Duration::from_millis(10));
    };
    let record = &full["hangs"]["records"][0];
    assert_eq!(record["sequence"], json!(1), "{full}");
    assert_eq!(record["span"], json!("mux-conn:workspace.create"), "{full}");
    assert!(record["duration_ms"].as_u64().is_some_and(|ms| ms >= 300), "{full}");
}

#[test]
fn signaled_mutex_class_server_stats_reports_lock_classes() {
    let mux = Mux::new_for_test("server-stats-lock-classes", crate::SurfaceOptions::default());
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    mux.new_workspace(None, Some((80, 24))).unwrap();

    let plain = stats(&mux, client, json!({"cmd":"server-stats"}));
    assert!(plain.get("lock_classes").is_none(), "{plain}");

    let full = stats(&mux, client, json!({"cmd":"server-stats","include":["lock_classes"]}));
    let section = &full["lock_classes"];
    for lock in ["registry", "registry_connection", "state"] {
        for class in ["frontend", "program", "automation"] {
            let entry = &section[lock][class];
            assert!(entry["wait_p95_us"].is_u64(), "{lock}.{class}: {full}");
            assert!(entry["wait_us"]["p99"].is_u64(), "{lock}.{class}: {full}");
            assert!(entry["hold_us"]["count"].is_u64(), "{lock}.{class}: {full}");
        }
        assert!(section[lock]["automation_yields"].is_u64(), "{full}");
        assert!(section[lock]["automation_due_admissions"].is_u64(), "{full}");
    }
    // Creating a workspace took the state lock outside any request scope.
    assert!(section["state"]["program"]["wait_us"]["count"].as_u64().unwrap() >= 1, "{full}");
}

/// `ipc` over a real connection loop: after a few request lines every
/// traffic counter has moved, and the section decodes through the SDK.
#[cfg(unix)]
#[test]
fn server_stats_include_reports_ipc_after_traffic() {
    use crate::server::client_hello::tests::Client;
    let mux = Mux::new_for_test("server-stats-ipc", crate::SurfaceOptions::default());
    let mut client = Client::connect(&mux, "ipc");
    let plain = client.request(json!({"cmd": "server-stats"}));
    assert!(plain["data"].get("ipc").is_none(), "{plain}");
    for _ in 0..3 {
        assert_eq!(client.request(json!({"cmd": "ping"}))["ok"], true);
    }
    let full = client.request(json!({"cmd": "server-stats", "include": ["ipc"]}));
    let ipc = &full["data"]["ipc"];
    assert_eq!(ipc["streams"]["open"], json!(1), "{ipc}");
    assert_eq!(ipc["streams"]["opened"], json!(1), "{ipc}");
    assert!(ipc["sequence_depth"]["count"].as_u64().unwrap() >= 4, "{ipc}");
    let line = |direction: &str| ipc[direction][0].clone();
    assert_eq!(line("received")["kind"], "line", "{ipc}");
    assert!(line("received")["messages"].as_u64().unwrap() >= 5, "{ipc}");
    assert!(line("received")["bytes"].as_u64().unwrap() > 0, "{ipc}");
    assert_eq!(line("sent")["kind"], "line", "{ipc}");
    assert!(line("sent")["messages"].as_u64().unwrap() >= 4, "{ipc}");
    let lines = &ipc["parses"]["lines"];
    let requests = lines["requests"].as_u64().unwrap();
    assert!(requests >= 4, "{ipc}");
    assert!(lines["json_parses"].as_u64().unwrap() >= requests, "every line parses: {ipc}");
    assert!(lines["json_parses_per_request"].as_f64().unwrap() >= 1.0, "{ipc}");
    assert_eq!(ipc["parses"]["frames"]["requests"], json!(0), "{ipc}");
    let writes = &ipc["writes"];
    assert!(writes["messages"].as_u64().unwrap() >= 4, "{ipc}");
    assert!(writes["syscalls"].as_u64().unwrap() >= 4, "{ipc}");
    assert!(writes["syscalls_per_message"].as_f64().unwrap() >= 1.0, "{ipc}");
    assert_eq!(ipc["bad_message"], json!(0), "{ipc}");

    let decoded: ::cmux::raw::ServerStatsResult =
        serde_json::from_value(full["data"].clone()).expect("the SDK decodes the ipc section");
    assert_eq!(serde_json::to_value(&decoded).unwrap(), full["data"]);

    drop(client);
    assert_eq!(mux.ipc_stats().snapshot().streams.open, 0, "the stream closes with its connection");
}

/// `bytes` on a fresh line connection close it as a bad message; the
/// counters once the connection loop has returned.
#[cfg(unix)]
fn ipc_after_a_bad_line(label: &str, bytes: &[u8]) -> crate::diagnostics::IpcSnapshot {
    use std::io::Write;
    let mux =
        Mux::new_for_test(format!("server-stats-ipc-{label}"), crate::SurfaceOptions::default());
    let directory = std::env::temp_dir().join(format!("cmux-ipc-{label}-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let path = directory.join("s.sock");
    let listener = transport::listen(&path).unwrap();
    let mut client = transport::connect(&path).unwrap();
    let server = listener.accept().unwrap();
    let server_mux = mux.clone();
    let handler = std::thread::spawn(move || {
        serve_connection(
            server_mux,
            server,
            Arc::new(RenderService::new()),
            None,
            ClientTransport::Unix,
            Box::new(admission::LocalAdmission),
            Box::<frame_dispatch::RequestFrames>::default(),
        );
    });
    // The daemon closes as soon as it has read the bad bytes, so the write
    // may fail.
    let _ = client.write_all(bytes);
    handler.join().unwrap();
    let _ = std::fs::remove_dir_all(&directory);
    mux.ipc_stats().snapshot()
}

/// A line over the size limit closes its connection as a bad message.
#[cfg(unix)]
#[test]
fn server_stats_ipc_counts_an_oversized_line_as_bad_message() {
    let mut oversized = vec![b'x'; MAX_JSON_LINE_BYTES + 1];
    oversized.push(b'\n');
    let ipc = ipc_after_a_bad_line("oversized", &oversized);
    assert_eq!(ipc.bad_message, 1);
    assert_eq!(ipc.streams.open, 0);
    assert_eq!(ipc.parses.lines.requests, 0, "a bad line is no request");
}

/// A line that is not UTF-8 is malformed too: it closes as a bad message.
#[cfg(unix)]
#[test]
fn server_stats_ipc_counts_a_non_utf8_line_as_bad_message() {
    let ipc = ipc_after_a_bad_line("utf8", b"{\"cmd\":\"\xff\xfe\"}\n");
    assert_eq!(ipc.bad_message, 1);
    assert_eq!(ipc.streams.open, 0);
    assert_eq!(ipc.parses.lines.requests, 0, "a bad line is no request");
}

/// The parses one local line takes on its way to an answer.
#[cfg(unix)]
fn json_parses_of(mux: &Arc<Mux>, client: u64, line: &str) -> u64 {
    let stats = crate::diagnostics::IpcStats::default();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    {
        let _scope = crate::diagnostics::JsonParseScope::enter(
            &stats,
            crate::diagnostics::IpcTransport::Lines,
        );
        handle_connection_frame(mux, client, ClientTransport::Unix, line, &writer(), &scheduler);
    }
    let _ = scheduler.close_and_wait(Duration::from_secs(5));
    let parses = stats.snapshot().parses.lines;
    assert_eq!(parses.requests, 1);
    parses.json_parses
}

/// json_parses counts every parse where it happens: a line takes its
/// RequestHead and then the one handler its head names, the
/// `Command` parse or a feature route's, and `server-stats` `ipc` sees the
/// same count as the line's `daemon.frame.json_parses` trace instant.
#[cfg(unix)]
#[test]
fn server_stats_ipc_counts_each_parse_of_a_line() {
    let mux = Mux::new_for_test("server-stats-ipc-parses", crate::SurfaceOptions::default());
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    let ping = json_parses_of(&mux, client, r#"{"id":1,"cmd":"ping"}"#);
    assert_eq!(ping, 2, "RequestHead and the Command parse");
    let watch =
        json_parses_of(&mux, client, r#"{"id":2,"cmd":"agent-inventory-watch","enabled":true}"#);
    assert_eq!(watch, 2, "RequestHead and the watch route's parse");
}

/// The rows of `debug-daemon-locks` for `lock`: (caller, op, row).
fn daemon_lock_rows(locks: &Value, lock: &str) -> Vec<(String, String, Value)> {
    let table = locks["locks"]
        .as_array()
        .and_then(|tables| tables.iter().find(|table| table["lock"] == lock))
        .unwrap_or_else(|| panic!("{lock} is reported: {locks}"));
    table["ops"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            let caller = row["caller"].as_str().unwrap().to_owned();
            (caller, row["op"].as_str().unwrap().to_owned(), row.clone())
        })
        .collect()
}

/// A request's lock acquisitions count under its connection's caller class
/// (the verified app is the frontend, the CLI automation) and its op's
/// wire name, on the reader and on the connection's dispatcher.
#[test]
fn daemon_locks_attribute_each_request_to_its_caller_and_op() {
    use super::super::origin_gate::{set_role_for_test, set_verified_app_for_test};
    let (mux, cli, cli_writer, cli_outbound) = request_path_mux("daemon-locks");
    let app_outbound = Arc::new(BoundedOutbound::default());
    let app_writer =
        MessageWriter::new(QueuedSink { outbound: app_outbound.clone(), control: None });
    let app = mux.control_clients.register(ClientTransport::Unix, app_writer.clone());
    set_role_for_test(&mux, app, "main");
    set_verified_app_for_test(&mux, app, true);
    mux.new_workspace(None, Some((80, 24))).unwrap();

    let workspace_list = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": "r1",
        "operation": "workspace.list", "params": {"machine": "current", "session": "current"},
    })
    .to_string();
    for (client, writer, outbound) in
        [(app, &app_writer, &app_outbound), (cli, &cli_writer, &cli_outbound)]
    {
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        assert!(handle_connection_frame(
            &mux,
            client,
            ClientTransport::Unix,
            &workspace_list,
            writer,
            &scheduler
        ));
        let request: Request =
            serde_json::from_value(json!({"id": 2, "cmd": "list-workspaces"})).unwrap();
        let pending = PendingSurfaceRequest {
            request,
            arrival: RequestArrival::now(),
            cause: crate::event_cause::EventCause::Program,
            frame_call: None,
            retained_bytes: 0,
            _bytes_permit: mux.surface_operation_admission.try_reserve_bytes(0).expect("permit"),
            stream_barrier: None,
        };
        assert!(run_pending_request(&scheduler, &mux, client, pending, writer));
        while outbound.try_pop().is_some() {}
    }

    let locks = stats(&mux, cli, json!({"cmd": "debug-daemon-locks"}));
    assert_eq!(locks["schema"], 1, "{locks}");
    let state = daemon_lock_rows(&locks, "mux.state");
    let registry = daemon_lock_rows(&locks, "workspace.registry");
    for caller in ["frontend", "automation"] {
        assert!(
            state.iter().any(|(c, op, row)| c == caller
                && op == "list-workspaces"
                && row["hold_us"]["count"].as_u64() >= Some(1)),
            "{caller} list-workspaces took mux.state: {state:?}"
        );
        assert!(
            state.iter().chain(&registry).any(|(c, op, _)| c == caller && op == "workspace.list"),
            "{caller} workspace.list took a daemon lock: {locks}"
        );
    }
    // The fixture's own setup ran outside any request.
    assert!(state.iter().any(|(c, op, _)| c == "program" && op == "none"), "{state:?}");
    let callers: Vec<&str> = locks["locks"][0]["callers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["caller"].as_str().unwrap())
        .collect();
    assert_eq!(callers, ["frontend", "automation", "program"]);

    let remote = mux.control_clients.register(ClientTransport::WebSocket, writer());
    let error = handle_command(&mux, remote, Command::DebugDaemonLocks, &writer())
        .expect_err("a remote client must not read daemon lock stats");
    assert_eq!(
        error.downcast_ref::<super::DaemonLocksRefused>(),
        Some(&super::DaemonLocksRefused::NotLocal),
        "{error}"
    );
}

/// A request a worker thread answers (`home-inbox` asks the Cloud, so it
/// runs on a `mux-cloud-request` worker) counts its lock acquisitions under
/// the request's caller class and op, not as program work.
#[test]
fn daemon_locks_attribute_a_worker_answered_request_to_its_caller_and_op() {
    use super::super::origin_gate::{set_role_for_test, set_verified_app_for_test};
    use std::time::{Duration, Instant};
    let (mux, cli, _, _) = request_path_mux("daemon-locks-worker");
    let app_outbound = Arc::new(BoundedOutbound::default());
    let app_writer =
        MessageWriter::new(QueuedSink { outbound: app_outbound.clone(), control: None });
    let app = mux.control_clients.register(ClientTransport::Unix, app_writer.clone());
    set_role_for_test(&mux, app, "main");
    set_verified_app_for_test(&mux, app, true);

    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let request: Request = serde_json::from_value(json!({"id": 1, "cmd": "home-inbox"})).unwrap();
    let pending = PendingSurfaceRequest {
        request,
        arrival: RequestArrival::now(),
        cause: crate::event_cause::EventCause::Program,
        frame_call: None,
        retained_bytes: 0,
        _bytes_permit: mux.surface_operation_admission.try_reserve_bytes(0).expect("permit"),
        stream_barrier: None,
    };
    assert!(run_pending_request(&scheduler, &mux, app, pending, &app_writer));
    let deadline = Instant::now() + Duration::from_secs(10);
    let reply: Value = loop {
        if let Some(line) = app_outbound.try_pop() {
            break serde_json::from_str(&line).unwrap();
        }
        assert!(Instant::now() < deadline, "home-inbox never replied");
        std::thread::sleep(Duration::from_millis(2));
    };
    assert_eq!(reply["ok"], true, "{reply}");

    let locks = stats(&mux, cli, json!({"cmd": "debug-daemon-locks"}));
    let rows: Vec<_> = ["mux.state", "workspace.registry"]
        .into_iter()
        .flat_map(|lock| daemon_lock_rows(&locks, lock))
        .collect();
    assert!(
        rows.iter().any(|(caller, op, _)| caller == "frontend" && op == "home-inbox"),
        "the worker's locks count under frontend/home-inbox: {locks}"
    );
}

/// The caller class sits on the connection's writer, set by the origin
/// gate when the hello or the install proof changes the derived origin.
#[test]
fn daemon_locks_caller_class_follows_the_connection_origin() {
    use super::super::origin_gate::{set_hello, set_install_proved};
    use crate::diagnostics::LockCaller;
    use crate::request_origin::HelloRole;
    let (mux, cli, cli_writer, _) = request_path_mux("daemon-locks-origin");
    assert_eq!(cli_writer.lock_caller.get(), LockCaller::Automation);
    assert!(set_hello(&mux, cli, HelloRole::Main, None, false, None, false));
    assert_eq!(cli_writer.lock_caller.get(), LockCaller::Automation);
    assert!(set_install_proved(&mux, cli, "install"));
    assert_eq!(cli_writer.lock_caller.get(), LockCaller::Frontend);

    let signed = writer();
    let app = mux.control_clients.register(ClientTransport::Unix, signed.clone());
    assert!(set_hello(&mux, app, HelloRole::Main, None, true, None, false));
    assert_eq!(signed.lock_caller.get(), LockCaller::Frontend);
    let relay_writer = writer();
    let relay = mux.control_clients.register(ClientTransport::Unix, relay_writer.clone());
    assert!(set_hello(&mux, relay, HelloRole::PageRelay, None, true, None, false));
    assert_eq!(relay_writer.lock_caller.get(), LockCaller::Automation);
}
