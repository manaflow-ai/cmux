//! The commits of the registry's file that ONE turn-end hook of an agent makes.
//!
//! The end of an agent's turn (`Stop`) is one journal row, one notification
//! and one agent report. Each commit of the registry's file writes one WAL
//! frame for each b-tree page that it changes, and a page that two commits
//! both change is written two times. So what the hook puts on the disk
//! follows the count of its commits.
//!
//! COUNT form (no clock): the registry is a file in a temporary directory and
//! its commits go through the journal writer thread, as in a daemon. The row
//! reads `write_path.wal_commits` before the hook and when the hook's caller
//! has its answer. The hook makes each of its commits before it answers, so
//! the count needs no settle of the roster's owner. (A settle makes the
//! roster save its row at once, which a daemon does each 512 journal rows;
//! the row settles after the count and asserts that this save is the only
//! commit that came after the answer.)
//!
//! The 4 commits that stay:
//!
//! 1. the admit: the journal row of the hook, its receipt and its retry row;
//! 2. the notification's effect receipt, prepared and marked `executing` in
//!    one commit, durable before the notification is posted;
//! 3. the notification and the agent report: the receipt's outcome, their 2
//!    journal records, the feed's rows and the agent's projection;
//! 4. the clear of the hook's retry row.
//!
//! What this row leaves out: the bytes of each commit (they change with the
//! page that a row falls on), `fullfsync`, the checkpoint, the save of the
//! agent history when its feed is on, and agents that report at the same
//! time.

use std::collections::BTreeMap;

use serde_json::json;

use super::*;

/// The most commits of the registry's file for one turn-end hook.
const MOST_COMMITS: u64 = 4;
const TERMINAL: &str = "00000000000040008000000000000001";
const INCARNATION: &str = "10000000000040008000000000000001";
const SESSION: &str = "turn-end";

/// One hook of the agent session on `terminal`, through the journal ingress
/// path, as its hook helper sends it.
fn send(mux: &Arc<Mux>, terminal: &TerminalPublicId, event: &str, mut native: Value) {
    native["session_id"] = json!(SESSION);
    native["cwd"] = json!("/srv/project");
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal.as_str()),
        native,
    )
    .unwrap();
    let key = format!("turn-end-commits-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap();
}

/// Journal rows after `sequence`, counted by kind.
fn kinds_after(mux: &Mux, mut sequence: u64) -> BTreeMap<String, usize> {
    let mut kinds = BTreeMap::new();
    loop {
        let page = mux.session_journal_after(sequence, 500).unwrap();
        let Some(last) = page.records.last() else { return kinds };
        sequence = last.sequence;
        for record in &page.records {
            *kinds.entry(record.kind.clone()).or_default() += 1;
        }
    }
}

#[test]
fn one_turn_end_hook_makes_at_most_4_registry_commits() {
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-turn-end-commits-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("agent-turn-end-commits", &root);
    // The maintenance worker checkpoints and seals on its own clock; the
    // count below must see only what the hook causes.
    mux.stop_journal_maintenance();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap().key;
    mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace).unwrap();
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    send(&mux, &terminal, "SessionStart", json!({}));
    send(&mux, &terminal, "UserPromptSubmit", json!({ "prompt": "go on" }));
    settled(&mux);

    let head = mux.session_journal_head().unwrap();
    let saves = mux.agent_roster_snapshot_saves_for_test();
    let before = mux.write_path_stats();
    send(&mux, &terminal, "Stop", json!({}));
    let at_answer = mux.write_path_stats();
    settled(&mux);
    let after = mux.write_path_stats();
    let rows = kinds_after(&mux, head);
    let roster_saves = mux.agent_roster_snapshot_saves_for_test() - saves;
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    let turn_end = BTreeMap::from([
        ("agent.report".to_owned(), 1),
        ("agent.turn.completed".to_owned(), 1),
        ("notification.create".to_owned(), 1),
    ]);
    assert_eq!(
        rows, turn_end,
        "setup: the hook is a turn end with its notification and its agent report"
    );
    let later = after.wal_commits - at_answer.wal_commits;
    assert_eq!(
        later,
        u64::try_from(roster_saves).unwrap(),
        "setup: after the hook's answer the only commits are the roster's saves that the row's \
         settle asked for, so the count at the answer is the hook's whole count"
    );
    let commits = at_answer.wal_commits - before.wal_commits;
    let frame_bytes = at_answer.registry_wal_frame_bytes - before.registry_wal_frame_bytes;
    assert!(
        commits <= MOST_COMMITS,
        "one turn-end hook of an agent made {commits} commits of the registry's file before its \
         answer ({frame_bytes} bytes of WAL frames; journal rows {rows:?}). The target is at most \
         {MOST_COMMITS}: the admit of the hook's journal row; the notification's effect receipt, \
         prepared and marked `executing`; the notification and the agent report; the clear of \
         the hook's retry row. After the answer the roster's owner made {later} commits for \
         {roster_saves} saves of its row, which the row's settle asked for."
    );
}
