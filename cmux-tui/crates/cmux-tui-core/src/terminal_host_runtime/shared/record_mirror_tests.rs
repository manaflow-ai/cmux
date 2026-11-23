use super::*;

fn record(nonce: &str, pid: u32, workspace: &str) -> TerminalHostRecord {
    TerminalHostRecord {
        record_version: 4,
        terminal_id: "00000000000040008000000000000b01".into(),
        incarnation: "00000000000040008000000000000b02".into(),
        host_pid: pid,
        host_start_nonce: nonce.into(),
        workspace_key: workspace.into(),
        ..Default::default()
    }
}

/// A rehost keeps the terminal id and the incarnation (the shell is the
/// same run) and changes the host pid and nonce. A mirror write queued
/// for the replaced host must not overwrite the replacement's record:
/// the next start would find the dead host's nonce, end the live
/// terminal, and remove the replacement's endpoint.
#[test]
fn a_queued_write_of_a_replaced_host_keeps_the_replacements_record() {
    let dir = std::env::temp_dir()
        .join(format!("cmux-record-mirror-{}", crate::workspace_registry::new_uuid_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("00000000000040008000000000000b01.json");
    let replacement = record("bb", 222, "workspace-one");
    std::fs::write(&path, serde_json::to_vec(&replacement).unwrap()).unwrap();
    assert!(
        !still_this_incarnation(&path, &record("aa", 111, "workspace-two")),
        "a write for the replaced host would overwrite its replacement's record"
    );
    assert!(still_this_incarnation(&path, &record("bb", 222, "workspace-two")));
    std::fs::remove_dir_all(dir).unwrap();
}
