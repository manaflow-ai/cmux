//! The at-rest table is memory only (`mux/agent_hooks_at_rest.rs`): after the
//! daemon stops and opens the same registry again, the roster equals the one
//! before, the first report of each terminal is appended again, and the next
//! equal ones are not.

use serde_json::json;

use super::*;

fn hook(mux: &Arc<Mux>, terminal: &TerminalPublicId, event: &str) -> crate::JournalAppendCommit {
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal.as_str()),
        json!({ "session_id": "reopen-session", "cwd": "/work/project", "tool_name": "Read" }),
    )
    .unwrap();
    let key = format!("at-rest-reopen-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap()
}

#[test]
fn agents_at_rest_after_a_reopen_the_first_report_is_a_row_and_the_next_are_not() {
    let session = "agents-at-rest-reopen";
    let root = std::env::temp_dir()
        .join(format!("cmux-agents-at-rest-reopen-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    let terminals = (0..3)
        .map(|_| mux.new_workspace(None, None).unwrap().terminal_public_id().cloned().unwrap())
        .collect::<Vec<_>>();
    for terminal in &terminals {
        hook(&mux, terminal, "SessionStart");
        hook(&mux, terminal, "UserPromptSubmit");
        // At rest before the stop: no row.
        let head = mux.session_journal_head().unwrap();
        assert!(hook(&mux, terminal, "PreToolUse").replayed);
        assert_eq!(mux.session_journal_head().unwrap(), head);
    }
    let roster_before = settled(&mux).agent_roster.lock().unwrap().roster.entries.clone();
    assert_eq!(roster_before.len(), terminals.len());
    mux.shutdown();
    drop(mux);

    let reopened = open_persistent_test_mux(session, &root);
    reopened.stop_journal_maintenance();
    let roster_after = settled(&reopened).agent_roster.lock().unwrap().roster.entries.clone();
    assert_eq!(roster_after, roster_before, "the roster after the restart is the one before");
    // The terminal's host lives on through a daemon restart and the daemon
    // adopts it again. A test has no host process, so it puts a placeholder
    // runtime in the catalog: the at-rest table keeps an entry only for a
    // terminal the catalog holds.
    for (index, terminal) in terminals.iter().enumerate() {
        let runtime = Surface::exited_terminal_placeholder(
            reopened.next_surface_id_for_test(),
            SurfaceOptions::default(),
            Arc::downgrade(&reopened),
            TerminalHostIdentity {
                terminal_id: format!("00000000000040008000{:012x}", 0xb00 + index),
                incarnation: format!("10000000000040008000{:012x}", 0xb00 + index),
            },
        )
        .unwrap();
        reopened.install_live_terminal_runtime_for_test(terminal, runtime).unwrap();
    }
    for terminal in &terminals {
        let head = reopened.session_journal_head().unwrap();
        let first = hook(&reopened, terminal, "PreToolUse");
        assert!(!first.replayed, "the first report after a restart is appended: {first:?}");
        assert_eq!(reopened.session_journal_head().unwrap(), head + 1);
        // The roster's owner folds the appended row after the request answered.
        settled(&reopened);
        for _ in 0..4 {
            let next = hook(&reopened, terminal, "PreToolUse");
            assert!(next.replayed, "the next equal report is not appended: {next:?}");
            assert_eq!(next.sequence, first.sequence);
        }
        assert_eq!(reopened.session_journal_head().unwrap(), head + 1);
    }
    let roster_end = settled(&reopened).agent_roster.lock().unwrap().roster.entries.clone();
    assert_eq!(roster_end, roster_before, "the reports at rest left the roster as it was");
    reopened.shutdown();
    drop(reopened);
    let _ = std::fs::remove_dir_all(&root);
}
