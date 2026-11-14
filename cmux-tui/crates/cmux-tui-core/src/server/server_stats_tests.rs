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

/// `disk` reports the registry's files, its journal tail by kind and its
/// sealed segments, only when asked and only for an on-disk registry.
#[test]
fn server_stats_include_reports_disk_use_by_file_and_journal_kind() {
    let memory = Mux::new_for_test("server-stats-disk-memory", crate::SurfaceOptions::default());
    let client = memory.control_clients.register(ClientTransport::Unix, writer());
    let in_memory = stats(&memory, client, json!({"cmd":"server-stats","include":["disk"]}));
    assert!(in_memory.get("disk").is_none(), "{in_memory}");

    let root = std::env::temp_dir()
        .join(format!("cmux-server-stats-disk-{}", crate::workspace_registry::new_uuid_v4()));
    let mux =
        Mux::open_persistent("server-stats-disk", crate::SurfaceOptions::default(), &root).unwrap();
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    mux.new_workspace(None, None).unwrap();
    let plain = stats(&mux, client, json!({"cmd":"server-stats"}));
    assert!(plain.get("disk").is_none(), "{plain}");

    let full = stats(&mux, client, json!({"cmd":"server-stats","include":["disk"]}));
    let disk = &full["disk"];
    assert!(disk["registry_bytes"].as_u64().unwrap_or(0) > 0, "{disk}");
    assert!(disk["page_size"].as_u64().unwrap_or(0) > 0, "{disk}");
    assert!(disk["error"].is_null(), "{disk}");
    let files = disk["files"].as_array().unwrap();
    assert!(
        files.iter().any(|file| file["name"] == "workspace-registry.sqlite3"),
        "the registry is listed beside its sidecars: {disk}"
    );
    let journal = &disk["journal"];
    assert!(journal["head_sequence"].as_u64().unwrap_or(0) >= 1, "{disk}");
    assert!(journal["sample_rows"].as_u64().unwrap_or(0) >= 1, "{disk}");
    let kinds = journal["kinds"].as_array().unwrap();
    assert!(!kinds.is_empty() && kinds.len() <= 16, "{disk}");
    for kind in kinds {
        assert!(kind["budget_bytes_per_day"].as_u64().unwrap_or(0) > 0, "{kind}");
    }
    assert_eq!(disk["segments"]["segments"], 0, "nothing is sealed yet: {disk}");
    mux.shutdown();
    let _ = std::fs::remove_dir_all(root);
}

/// `registry_cleanup` shows the file that a registry rebuild replaced while
/// it is kept beside the registry (name, size, the first time it can go and
/// the full starts that are left), and counts the reducer states that did
/// not load and are kept raw. Only when asked, only for a registry on disk.
#[test]
fn server_stats_include_shows_the_kept_registry_file_and_the_states_kept_raw() {
    let memory = Mux::new_for_test("server-stats-cleanup-memory", crate::SurfaceOptions::default());
    let client = memory.control_clients.register(ClientTransport::Unix, writer());
    let request = json!({"cmd":"server-stats","include":["registry_cleanup"]});
    let in_memory = stats(&memory, client, request.clone());
    assert!(in_memory.get("registry_cleanup").is_none(), "{in_memory}");

    let root = std::env::temp_dir()
        .join(format!("cmux-server-stats-cleanup-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = Mux::open_persistent("server-stats-cleanup", crate::SurfaceOptions::default(), &root)
        .unwrap();
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    let plain = stats(&mux, client, json!({"cmd":"server-stats"}));
    assert!(plain.get("registry_cleanup").is_none(), "{plain}");
    let nothing_kept = stats(&mux, client, request.clone());
    let section = &nothing_kept["registry_cleanup"];
    assert!(section["kept_file"].is_null(), "{section}");
    assert_eq!(section["kept_raw"], 0, "{section}");
    assert!(section["error"].is_null(), "{section}");

    // The file of a rebuild, and a saved state that a start kept raw.
    let db_path = mux.workspace_registry.lock().unwrap().session_journal_database_path().unwrap();
    let kept = crate::workspace_registry::output_cleanup::kept_path(&db_path);
    std::fs::write(&kept, vec![0_u8; 4096]).unwrap();
    rusqlite::Connection::open(&db_path)
        .unwrap()
        .execute(
            "INSERT INTO meta(key, value) VALUES('journal_reducer_kept.agent_roster', 'raw')",
            [],
        )
        .unwrap();

    let full = stats(&mux, client, request);
    let section = &full["registry_cleanup"];
    let file = &section["kept_file"];
    assert_eq!(file["name"], "workspace-registry.sqlite3.kept-before-cleanup", "{section}");
    assert_eq!(file["bytes"], 4096, "{section}");
    // This registry has no record of a rebuild: the time is the file's.
    let swapped_at = file["swapped_at_ms"].as_u64().unwrap_or(0);
    assert!(swapped_at > 0, "{section}");
    assert_eq!(
        file["kept_until_ms"].as_u64(),
        Some(swapped_at + 7 * 24 * 60 * 60 * 1_000),
        "{section}"
    );
    assert_eq!(file["full_starts"], 0, "{section}");
    assert_eq!(file["full_starts_left"], 3, "{section}");
    assert_eq!(section["kept_raw"], 1, "{section}");
    assert!(section["error"].is_null(), "{section}");
    mux.shutdown();
    let _ = std::fs::remove_dir_all(root);
}
