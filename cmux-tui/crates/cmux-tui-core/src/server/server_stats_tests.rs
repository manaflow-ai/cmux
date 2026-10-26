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
            retained_bytes: 0,
            _bytes_permit: mux.surface_operation_admission.try_reserve_bytes(0).expect("permit"),
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
    assert!(error.to_string().contains("trusted local connection"), "{error}");
}
