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
use std::path::Path;

fn list_agent_session_ids(mux: &Arc<Mux>) -> Vec<String> {
    let mut fields = Map::new();
    fields.insert("kinds".into(), serde_json::json!(["agent"]));
    let listed = crate::history_ops::list_for_test(mux, &fields).expect("history list answers");
    listed["entries"]
        .as_array()
        .expect("entries")
        .iter()
        .filter_map(|entry| entry["session_id"].as_str().map(str::to_owned))
        .collect()
}

/// `history.entries.list` of the agent kind through the resource router, the
/// path of every client: the router checks each answer against the embedded
/// operation catalog. Returns the whole response envelope.
fn list_agents_through_the_router(mux: &Arc<Mux>) -> Value {
    let envelope = serde_json::json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": "history-list",
        "operation": "history.entries.list",
        "params": {"machine": "current", "session": "current", "kinds": ["agent"]},
    });
    crate::resource_router::handle_resource_message(mux, &envelope.to_string())
        .expect("the response envelope encodes")
}

/// Checkpoint and seal the whole journal; returns the new segment ids.
pub(super) fn seal_whole_journal(mux: &Mux, key: &str) -> Vec<String> {
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
/// fails, so a fold that still reads them is visible. Their kept reducer
/// records go too, as for segments an older build sealed, or a read would
/// take them and never meet the damage.
fn make_segments_undecodable(root: &Path, session: &str, segments: &[String]) {
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
        connection
            .execute(
                "DELETE FROM journal_segment_reducer_records WHERE segment_id = ?1",
                rusqlite::params![segment_id],
            )
            .unwrap();
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

/// Issue 23038: the agent history save wrote its whole snapshot under the
/// workspace registry lock, so every state commit (Cmd-N's pin, create and
/// first tab) waited behind it, for seconds on a large history. The save
/// now takes the registry connection alone and finishes while another
/// thread holds the registry lock.
#[test]
fn agent_history_save_does_not_wait_for_the_workspace_registry_lock() {
    let session = "history-agent-save-off-registry";
    let root = std::env::temp_dir()
        .join(format!("cmux-history-agent-save-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &terminal_id, "SessionStart", Some("history-agent-save"));
    assert_eq!(list_agent_session_ids(&mux), vec!["history-agent-save".to_owned()]);

    let (saved_tx, saved_rx) = std::sync::mpsc::channel();
    let registry = mux.workspace_registry.lock().unwrap();
    let saver = {
        let mux = Arc::clone(&mux);
        std::thread::spawn(move || {
            let _ = saved_tx.send(crate::history_ops::resave_agent_fold_for_test(&mux));
        })
    };
    let saved = saved_rx.recv_timeout(Duration::from_secs(10));
    drop(registry);
    saver.join().unwrap();
    let cursor =
        saved.expect("the agent history save finishes while another thread holds the registry");

    let (version, stored_cursor, snapshot) = mux
        .workspace_registry
        .lock()
        .unwrap()
        .journal_reducer_state("history.agent_sessions")
        .unwrap()
        .expect("the agent history was saved");
    assert_eq!(version, 1);
    assert_eq!(stored_cursor, cursor);
    assert!(snapshot.contains("history-agent-save"), "the saved fold holds the session");
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// cmux#38186: an agent clear the app queued while the daemon was away
/// carries its click time (`until_ms`). A session active after the click
/// still lists when the clear arrives; a clear without it (an older caller)
/// hides everything active until the delivery.
#[test]
fn a_queued_agent_clear_keeps_a_session_active_after_its_click() {
    let session = "history-agent-clear-until";
    let root = std::env::temp_dir().join(format!(
        "cmux-history-agent-clear-until-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let mux = open_persistent_test_mux(session, &root);
    let click_ms = crate::history_ops::now_ms() - 60_000;
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &terminal_id, "SessionStart", Some("history-agent-after-click"));
    assert_eq!(list_agent_session_ids(&mux), vec!["history-agent-after-click".to_owned()]);

    let mut fields = Map::new();
    fields.insert("kinds".into(), serde_json::json!(["agent"]));
    fields.insert("range".into(), serde_json::json!("all"));
    fields.insert("until_ms".into(), serde_json::json!(click_ms.to_string()));
    crate::history_ops::mutate_for_test(&mux, "clear-until-click", "history.clear", &fields)
        .expect("the clear answers");
    assert_eq!(
        list_agent_session_ids(&mux),
        vec!["history-agent-after-click".to_owned()],
        "a session active after the click was hidden by a clear delivered later"
    );

    fields.remove("until_ms");
    crate::history_ops::mutate_for_test(&mux, "clear-until-now", "history.clear", &fields)
        .expect("the clear answers");
    assert!(list_agent_session_ids(&mux).is_empty(), "a clear until now left the session");
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// A list answers what is folded when its budget ends before the agent fold
/// reaches the journal head, and names the kind in `pending_kinds`. The
/// catalog type of the answer did not have that field, so the router refused
/// the daemon's own answer (`operation.failed`: "operation result violates
/// the embedded catalog") for each ask until the fold was less than the
/// budget behind: after a start on a large journal, History did not load.
#[test]
fn a_history_list_with_the_agent_fold_behind_answers_through_the_router() {
    let session = "history-agent-fold-behind";
    let root = std::env::temp_dir().join(format!(
        "cmux-history-agent-fold-behind-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let mux = open_persistent_test_mux(session, &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &terminal_id, "SessionStart", Some("history-agent-behind"));

    // No budget: the list answers before its fold reaches the journal head.
    crate::history_ops::set_list_fold_budget_for_test(&mux, Some(Duration::ZERO));
    let behind = list_agents_through_the_router(&mux);
    assert_eq!(
        behind["ok"], true,
        "the router refused the list while the agent fold was behind: {behind}"
    );
    assert_eq!(
        behind["result"]["pending_kinds"],
        serde_json::json!(["agent"]),
        "the answer names the kind that is not complete: {behind}"
    );
    assert!(behind["result"]["entries"].is_array(), "the answer has its entries: {behind}");

    // The daemon's own budget: the fold reaches the head, the answer is whole.
    crate::history_ops::set_list_fold_budget_for_test(&mux, None);
    let whole = list_agents_through_the_router(&mux);
    assert_eq!(whole["ok"], true, "the list answers when the fold is at the head: {whole}");
    assert!(
        whole["result"].get("pending_kinds").is_none(),
        "a complete answer names no pending kind: {whole}"
    );
    let sessions = whole["result"]["entries"]
        .as_array()
        .expect("entries")
        .iter()
        .filter_map(|entry| entry["session_id"].as_str())
        .collect::<Vec<_>>();
    assert_eq!(sessions, vec!["history-agent-behind"]);
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

// The rows of the save stride seed a running terminal, which is unix only:
// each item from here to the file's end is for them.
#[cfg(unix)]
const STRIDE_TERMINAL: &str = "00000000000040008000000000000071";
#[cfg(unix)]
const STRIDE_INCARNATION: &str = "10000000000040008000000000000071";
#[cfg(unix)]
const STRIDE_AGENT: &str = "history-agent-save-stride";

/// One hook of the agent session `STRIDE_AGENT` on `terminal`, through the
/// journal ingress path, as its hook helper sends it.
#[cfg(unix)]
fn stride_hook(mux: &Arc<Mux>, terminal: &TerminalPublicId, event: &str, mut native: Value) {
    native["session_id"] = serde_json::json!(STRIDE_AGENT);
    native["cwd"] = serde_json::json!("/srv/project");
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal.as_str()),
        native,
    )
    .unwrap();
    let key = format!("history-save-stride-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap();
}

/// The saved agent fold in the registry: its cursor and its sessions (`None`
/// when the fold was never saved).
#[cfg(unix)]
pub(super) fn saved_agent_fold(mux: &Mux) -> Option<(u64, String)> {
    mux.workspace_registry
        .lock()
        .unwrap()
        .journal_reducer_state("history.agent_sessions")
        .unwrap()
        .map(|(_, cursor, snapshot)| (cursor, snapshot))
}

/// Journal rows after `sequence`, counted by kind.
#[cfg(unix)]
pub(super) fn journal_kinds_after(
    mux: &Mux,
    mut sequence: u64,
) -> std::collections::BTreeMap<String, usize> {
    let mut kinds = std::collections::BTreeMap::new();
    loop {
        let page = mux.session_journal_after(sequence, 500).unwrap();
        let Some(last) = page.records.last() else { return kinds };
        sequence = last.sequence;
        for record in &page.records {
            *kinds.entry(record.kind.clone()).or_default() += 1;
        }
    }
}

/// The saved agent fold is a cache of what the journal holds: each agent
/// record is durable in the journal before its hook has an answer, and a
/// start folds the records after the saved cursor again. With the history
/// feed on (one history read in the daemon's life starts it), each journal
/// page with an agent record saved the whole fold again: the end of one
/// turn has 2 such records in 2 commits, so it made 2 more commits of the
/// registry's file only to write a cache.
///
/// COUNT form (no clock): the row reads the saved fold after the first
/// history read, makes turn ends that move the journal less than one page
/// of the fold (512 sequences), asks a list (which answers when the fold is
/// at the journal's head) and reads the saved fold again. It must be the
/// same row: the turn ends saved nothing.
#[cfg(unix)]
#[test]
fn turn_ends_below_one_journal_page_do_not_save_the_agent_history_again() {
    const TURNS: usize = 8;
    const PAGE: u64 = 512;
    let session = "history-agent-save-stride";
    let root = std::env::temp_dir().join(format!(
        "cmux-history-agent-save-stride-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let mux = open_persistent_test_mux(session, &root);
    // The maintenance worker checkpoints and seals on its own clock.
    mux.stop_journal_maintenance();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap().key;
    mux.seed_running_terminal_for_test(STRIDE_TERMINAL, STRIDE_INCARNATION, &workspace).unwrap();
    let terminal = mux
        .workspace_registry
        .lock()
        .unwrap()
        .terminal_resource_id(STRIDE_TERMINAL)
        .unwrap()
        .unwrap();
    stride_hook(&mux, &terminal, "SessionStart", serde_json::json!({}));
    // A list folds until the journal's head, with no budget that ends first.
    crate::history_ops::set_list_fold_budget_for_test(&mux, Some(Duration::from_secs(600)));
    // The first history read folds the journal and starts the history feed.
    assert_eq!(list_agent_session_ids(&mux), vec![STRIDE_AGENT.to_owned()]);
    let first = saved_agent_fold(&mux);
    let first_cursor = first.as_ref().map_or(0, |(cursor, _)| *cursor);

    for turn in 0..TURNS {
        let prompt = serde_json::json!({ "prompt": format!("turn {turn}") });
        stride_hook(&mux, &terminal, "UserPromptSubmit", prompt);
        stride_hook(&mux, &terminal, "Stop", serde_json::json!({}));
    }
    // The feed, or this list, folded each turn end before the list answers.
    assert_eq!(list_agent_session_ids(&mux), vec![STRIDE_AGENT.to_owned()]);
    let head = mux.session_journal_head().unwrap();
    let rows = journal_kinds_after(&mux, first_cursor);
    let last = saved_agent_fold(&mux);
    let last_cursor = last.as_ref().map_or(0, |(cursor, _)| *cursor);
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    assert_eq!(
        rows.get("agent.turn.completed"),
        Some(&TURNS),
        "setup: each `Stop` hook is the end of a turn (journal rows {rows:?})"
    );
    assert!(
        head - first_cursor < PAGE,
        "setup: the turn ends moved the journal less than one page of the fold (from \
         {first_cursor} to {head})"
    );
    assert!(
        last == first,
        "{TURNS} turn ends of one agent session, with the history feed on, saved the agent \
         history again: the cursor of the saved fold went from {first_cursor} to {last_cursor} \
         (the journal's head is {head}; journal rows {rows:?}). The target is no save while the \
         journal is less than {PAGE} sequences past the saved cursor: the journal has each \
         record, and a start folds the records after the saved cursor again."
    );
}
