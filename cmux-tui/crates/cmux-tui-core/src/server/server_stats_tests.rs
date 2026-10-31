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

#[test]
fn server_stats_include_reports_registry_and_state_lock_sites() {
    let mux = Mux::new_for_test("server-stats-locks", crate::SurfaceOptions::default());
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    mux.new_workspace(None, Some((80, 24))).unwrap();
    // A long hold at a known line: it heads the state lock's p99 list.
    let state_line = line!() + 1;
    let held = mux.state.lock().unwrap();
    std::thread::sleep(Duration::from_millis(300));
    drop(held);

    let plain = stats(&mux, client, json!({"cmd":"server-stats"}));
    assert!(plain.get("locks").is_none(), "{plain}");

    let full = stats(&mux, client, json!({"cmd":"server-stats","include":["locks"]}));
    for lock in ["registry", "state"] {
        let section = &full["locks"][lock];
        assert!(section["hold_us"]["count"].as_u64().unwrap_or(0) >= 1, "{lock}: {section}");
        let sites = section["sites"].as_u64().unwrap_or(0);
        assert!(sites >= 1, "{lock}: {section}");
        for list in ["by_hold_total", "by_hold_p99"] {
            let entries = section[list].as_array().unwrap();
            assert!(!entries.is_empty() && entries.len() <= 20, "{lock} {list}: {section}");
            for entry in entries {
                assert!(
                    entry["hold_p99_us"].as_u64() <= entry["hold_max_us"].as_u64(),
                    "{lock} {list}: {entry}"
                );
                assert!(
                    entry["wait_p99_us"].as_u64() <= entry["wait_max_us"].as_u64(),
                    "{lock} {list}: {entry}"
                );
            }
        }
    }
    // The state lock names the code that took it, not the lock wrapper.
    let site = format!("server_stats_tests.rs:{state_line}");
    let longest = &full["locks"]["state"]["by_hold_p99"][0];
    assert!(longest["site"].as_str().is_some_and(|s| s.ends_with(&site)), "{site}: {longest}");
    assert!(longest["hold_max_us"].as_u64().unwrap_or(0) >= 300_000, "{longest}");
}

/// `server-stats` shows the session's queued hook events and the events
/// `reset-state` dropped (R-L5: a loss is visible), and only when asked.
#[cfg(unix)]
#[test]
fn server_stats_include_reports_the_hook_queue() {
    let mux = Mux::new_for_test("server-stats-hook-queue", crate::SurfaceOptions::default());
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    let mut bytes = [0_u8; 8];
    getrandom::fill(&mut bytes).unwrap();
    let suffix: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let root = std::env::temp_dir().join(format!("cmux-server-stats-hook-queue-{suffix}"));
    let mut builder = std::fs::DirBuilder::new();
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(&root).unwrap();
    let socket = root.join("session.sock");
    mux.connection_stats().note_socket(&socket);

    let none = stats(&mux, client, json!({"cmd":"server-stats","include":["hook_queue"]}));
    assert_eq!(
        none["hook_queue"],
        json!({"queued_events":0,"reset_dropped_events":0,"undeliverable_events":0}),
        "{none}"
    );
    let spool = crate::diagnostics::hook_spool_dir(&socket).unwrap();
    let queue = |socket: &str, terminal: &str| {
        spool.join(format!(
            "{}.{}.jsonl",
            crate::diagnostics::queue_prefix(&root.join(socket)),
            crate::diagnostics::spool_name_part(terminal)
        ))
    };
    std::fs::write(queue("session.sock", "terminal_a"), "{}\n{}\n").unwrap();
    std::fs::write(queue("other.sock", "terminal_b"), "{}\n").unwrap();
    std::fs::write(spool.join(crate::diagnostics::HOOK_SPOOL_DROPPED_EVENTS), "7\n").unwrap();
    std::fs::write(spool.join(crate::diagnostics::HOOK_SPOOL_UNDELIVERABLE_EVENTS), "3\n").unwrap();

    let plain = stats(&mux, client, json!({"cmd":"server-stats"}));
    assert!(plain.get("hook_queue").is_none(), "{plain}");
    let full = stats(&mux, client, json!({"cmd":"server-stats","include":["hook_queue"]}));
    assert_eq!(
        full["hook_queue"],
        json!({"queued_events":2,"reset_dropped_events":7,"undeliverable_events":3}),
        "{full}"
    );
    std::fs::remove_dir_all(root).unwrap();
}
