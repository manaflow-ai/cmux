//! The commits of the registry's file by the name of their writer
//! (`server-stats` `write_path.commits_by_writer`).
//!
//! `write_path.wal_commits` counts each commit of the registry's file, but
//! not who made it: the journal writer's batches have their own counter and
//! each other commit has none. The section's rows give each commit, and the
//! WAL frames that it appended, to one name of a fixed table.
//!
//! COUNT form (no clock): the registry is a file in a temporary directory and
//! its commits go through the journal writer thread, as in a daemon. The row
//! reads the section as a client does (its JSON) before one hook of a turn's
//! start, when the hook's caller has its answer, and after a settle of the
//! roster's owner. The hook makes 3 commits before its answer: the journal
//! writer admits its row, the request's thread commits the agent report, and
//! the journal writer clears the hook's retry row. The settle makes the
//! roster save its row at once (a daemon does that each 512 journal rows).
//!
//! What this row leaves out: the names of the other writers (each has one
//! line at its commit and no row here), and the bytes of a frame on a
//! registry whose page is not 4096 bytes.

use std::collections::BTreeMap;

use serde_json::json;

use super::*;

const TERMINAL: &str = "00000000000040008000000000000001";
const INCARNATION: &str = "10000000000040008000000000000001";
const SESSION: &str = "commits-by-writer";
/// One WAL frame of the registry: a 24-byte header and one 4096-byte page.
const FRAME_BYTES: u64 = 4120;

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
    let key = format!("commits-by-writer-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap();
}

/// The `write_path` section as a client reads it.
fn section(mux: &Mux) -> Value {
    serde_json::to_value(mux.write_path_stats()).unwrap()
}

/// The section's rows: writer -> (commits, WAL frames).
fn rows(section: &Value) -> BTreeMap<String, (u64, u64)> {
    section["commits_by_writer"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| {
            (
                row["writer"].as_str().unwrap_or_default().to_owned(),
                (row["commits"].as_u64().unwrap_or(0), row["wal_frames"].as_u64().unwrap_or(0)),
            )
        })
        .collect()
}

fn commits(section: &Value, writer: &str) -> u64 {
    rows(section).get(writer).map_or(0, |row| row.0)
}

/// The rows hold each commit and each frame of the section's own totals.
#[track_caller]
fn assert_rows_sum_to_the_totals(section: &Value, at: &str) {
    let rows = rows(section);
    let commits: u64 = rows.values().map(|row| row.0).sum();
    let frames: u64 = rows.values().map(|row| row.1).sum();
    assert_eq!(
        Some(commits),
        section["wal_commits"].as_u64(),
        "{at}: the rows' commits sum to `wal_commits`; the rows: {rows:?}"
    );
    assert_eq!(
        Some(frames * FRAME_BYTES),
        section["registry_wal_frame_bytes"].as_u64(),
        "{at}: the rows' WAL frames are the frames of `registry_wal_frame_bytes`; the rows: \
         {rows:?}"
    );
}

#[test]
fn each_registry_commit_counts_under_the_name_of_its_writer() {
    let root = std::env::temp_dir()
        .join(format!("cmux-commits-by-writer-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("commits-by-writer", &root);
    // The maintenance worker checkpoints and seals on its own clock; the
    // counts below must see only what the hook and the settle cause.
    mux.stop_journal_maintenance();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap().key;
    mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace).unwrap();
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    send(&mux, &terminal, "SessionStart", json!({}));
    settled(&mux);

    let saves = mux.agent_roster_snapshot_saves_for_test();
    let before = section(&mux);
    send(&mux, &terminal, "UserPromptSubmit", json!({ "prompt": "go on" }));
    let at_answer = section(&mux);
    settled(&mux);
    let after = section(&mux);
    let roster_saves = u64::try_from(mux.agent_roster_snapshot_saves_for_test() - saves).unwrap();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    assert_eq!(
        at_answer["wal_commits"].as_u64().unwrap() - before["wal_commits"].as_u64().unwrap(),
        3,
        "setup: one hook of a turn's start makes 3 commits of the registry's file before its \
         answer"
    );
    assert!(roster_saves >= 1, "setup: the settle makes the roster save its row");
    let by_hook = |writer: &str| commits(&at_answer, writer) - commits(&before, writer);
    assert_eq!(
        (by_hook("journal_writer"), by_hook("agent_report")),
        (2, 1),
        "(journal_writer, agent_report): of the hook's 3 commits the journal writer makes 2 (the \
         hook's row, the clear of its retry row) and the agent report's projection makes 1; the \
         rows before the hook: {:?}; at its answer: {:?}",
        rows(&before),
        rows(&at_answer)
    );
    assert_eq!(
        commits(&after, "agent_roster_save") - commits(&at_answer, "agent_roster_save"),
        roster_saves,
        "each save of the roster's row is a commit of `agent_roster_save`; the rows at the \
         hook's answer: {:?}; after the settle: {:?}",
        rows(&at_answer),
        rows(&after)
    );
    assert_rows_sum_to_the_totals(&before, "before the hook");
    assert_rows_sum_to_the_totals(&at_answer, "at the hook's answer");
    assert_rows_sum_to_the_totals(&after, "after the settle");
}
