//! Agent history over a long journal (CLI agent papercuts item 5).
//!
//! `history.entries.list` folds agent sessions out of the session journal.
//! The fold lived only in memory, so every daemon start folded the whole
//! journal again from sequence 0, decoding every sealed segment (gigabytes
//! of terminal output on a daemon that has run for weeks). `cmux history
//! list` then hung past the CLI's timeout and the daemon sat near 100% CPU.
//! The fold now keeps its sessions and cursor in the registry, so a restart
//! folds only the records after it.

use super::*;
use std::path::PathBuf;

fn list_agent_session_ids(mux: &Arc<Mux>) -> Vec<String> {
    let mut fields = serde_json::Map::new();
    fields.insert("kinds".into(), serde_json::json!(["agent"]));
    let listed = crate::history_ops::list_for_test(mux, &fields).expect("history list answers");
    listed["entries"]
        .as_array()
        .expect("entries")
        .iter()
        .filter_map(|entry| entry["session_id"].as_str().map(str::to_owned))
        .collect()
}

/// Checkpoint and seal the whole journal; returns the new segment ids.
fn seal_whole_journal(mux: &Mux, key: &str) -> Vec<String> {
    let checkpoint =
        mux.create_journal_checkpoint("client_test", &format!("{key}_checkpoint")).unwrap();
    let sealed = mux
        .seal_journal_segments(
            checkpoint.checkpoint.source_sequence,
            "client_test",
            &format!("{key}_seal"),
        )
        .unwrap();
    assert!(!sealed.segments.is_empty());
    sealed.segments.into_iter().map(|segment| segment.segment_id).collect()
}

/// Makes every listed segment undecodable: a read that inflates any of them
/// fails, so a fold that still reads them is visible.
fn make_segments_undecodable(root: &PathBuf, session: &str, segments: &[String]) {
    let registry = WorkspaceRegistry::open(root, session).unwrap();
    let database = registry.session_journal_database_path().unwrap();
    drop(registry);
    let connection = rusqlite::Connection::open(&database).unwrap();
    connection.execute_batch("DROP TRIGGER IF EXISTS journal_segments_reject_update;").unwrap();
    for segment_id in segments {
        let changed = connection
            .execute(
                "UPDATE journal_segments SET content = x'00112233' WHERE segment_id = ?1",
                rusqlite::params![segment_id],
            )
            .unwrap();
        assert_eq!(changed, 1);
    }
}

#[test]
fn agent_history_after_a_restart_folds_only_the_records_after_its_saved_cursor() {
    let session = "history-agent-fold-restart";
    let root = std::env::temp_dir()
        .join(format!("cmux-history-agent-fold-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &terminal_id, "SessionStart", Some("history-agent-before"));
    // Sealed first, then folded: the fold reads the sealed segments once.
    let sealed = seal_whole_journal(&mux, "history_agent_fold");
    assert_eq!(list_agent_session_ids(&mux), vec!["history-agent-before".to_owned()]);
    mux.shutdown();
    drop(mux);

    // The sealed prefix was folded before the restart. A fold that reads it
    // again fails on these segments (and on a real journal spends minutes
    // inflating them).
    make_segments_undecodable(&root, session, &sealed);
    let reopened = open_persistent_test_mux(session, &root);
    let surface = reopened.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&reopened, &terminal_id, "SessionStart", Some("history-agent-after"));
    let mut listed = list_agent_session_ids(&reopened);
    listed.sort();
    assert_eq!(
        listed,
        vec!["history-agent-after".to_owned(), "history-agent-before".to_owned()],
        "the restart keeps the folded sessions and adds only the new one"
    );
    reopened.shutdown();
    drop(reopened);
    let _ = std::fs::remove_dir_all(&root);
}
