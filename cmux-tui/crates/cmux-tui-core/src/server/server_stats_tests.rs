//! `server-stats` optional sections: absent unless requested, so SDK
//! decoders that refuse unknown result fields keep working.

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

/// Hook events dropped with their ended session are counted by the hook
/// children beside the session socket; `server-stats` shows the count, so
/// the loss is visible (R-L5), and only when asked.
#[test]
fn server_stats_include_reports_hook_events_dropped_with_their_session() {
    let mux = Mux::new_for_test("server-stats-hook-queue", crate::SurfaceOptions::default());
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("session.sock");
    mux.connection_stats().note_socket(&socket);

    let none = stats(&mux, client, json!({"cmd":"server-stats","include":["hook_queue"]}));
    assert_eq!(none["hook_queue"]["ended_session_events"], 0, "{none}");
    let spool = root.path().join(crate::diagnostics::HOOK_SPOOL_DIR);
    std::fs::create_dir_all(&spool).unwrap();
    std::fs::write(spool.join(crate::diagnostics::HOOK_SPOOL_ENDED_EVENTS), "7\n").unwrap();

    let plain = stats(&mux, client, json!({"cmd":"server-stats"}));
    assert!(plain.get("hook_queue").is_none(), "{plain}");
    let full = stats(&mux, client, json!({"cmd":"server-stats","include":["hook_queue"]}));
    assert_eq!(full["hook_queue"]["ended_session_events"], 7, "{full}");
}
