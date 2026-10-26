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
        retained_bytes: 0,
        _bytes_permit: mux.surface_operation_admission.try_reserve_bytes(0).expect("permit"),
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
    assert_eq!(section["recent"], json!([]), "{full}");
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

/// A line over the size limit closes its connection as a bad message.
#[cfg(unix)]
#[test]
fn server_stats_ipc_counts_an_oversized_line_as_bad_message() {
    use std::io::Write;
    let mux = Mux::new_for_test("server-stats-ipc-bad", crate::SurfaceOptions::default());
    let directory = std::env::temp_dir().join(format!("cmux-ipc-bad-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let path = directory.join("s.sock");
    let listener = transport::listen(&path).unwrap();
    let mut client = transport::connect(&path).unwrap();
    let server = listener.accept().unwrap();
    let server_mux = mux.clone();
    let handler = std::thread::spawn(move || {
        serve_line_connection(
            server_mux,
            server,
            Arc::new(RenderService::new()),
            None,
            ClientTransport::Unix,
            &admission::LocalAdmission,
        );
    });
    let oversized = vec![b'x'; MAX_JSON_LINE_BYTES + 1];
    // The daemon closes as soon as it has read past the limit, so the
    // write may fail.
    let _ = client.write_all(&oversized).and_then(|()| client.write_all(b"\n"));
    handler.join().unwrap();
    let _ = std::fs::remove_dir_all(&directory);
    let ipc = mux.ipc_stats().snapshot();
    assert_eq!(ipc.bad_message, 1);
    assert_eq!(ipc.streams.open, 0);
    assert_eq!(ipc.received[0].kind, "line");
}
