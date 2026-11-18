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
//! The other rows: the reply's names and their order; one commit through a
//! site that takes the connection with its writer's name
//! (`RegistryConnection::get_as`); and 2 commits that are of a named writer
//! at a site of their own: the save at the end of a roster rebuild, and the
//! delete of a dead letter in the enqueue of a hook's retry row.
//!
//! What these rows leave out: the commits of 9 of the 14 writers (each has
//! one line at its commit and no row here), and the bytes of a frame on a
//! registry whose page is not 4096 bytes.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

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

/// The reply's `writer` values: each writer of the table, in its order.
const WRITERS: [&str; 14] = [
    "other",
    "journal_writer",
    "agent_report",
    "agent_roster_save",
    "agent_hook_retry",
    "effect_receipt",
    "notification",
    "resource_patch",
    "frontend_projection",
    "registry_intent",
    "terminal_relaunch",
    "state_mutation",
    "feed",
    "journal_maintenance",
];
/// The registry's cap on the dead letters of the hook retry table. The rows'
/// own copy: the registry does not export its cap.
const DEAD_LETTER_CAP: i64 = 1_024;

/// A daemon's registry in a temporary directory with one running terminal,
/// and with no maintenance worker (it checkpoints and seals on its own
/// clock).
fn mux_with_a_terminal(session: &str) -> (PathBuf, Arc<Mux>, TerminalPublicId) {
    let root = std::env::temp_dir()
        .join(format!("cmux-{session}-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    mux.stop_journal_maintenance();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap().key;
    mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace).unwrap();
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    (root, mux, terminal)
}

/// One row of the hook retry table through the registry, as a hook whose
/// projection failed leaves it. The enqueue has 2 statements, each its own
/// commit: the write of the row, and the delete of the oldest dead letters
/// over the table's cap, which is no commit when it deletes no row.
fn enqueue_retry_row(mux: &Mux, terminal: &TerminalPublicId, key: &str) {
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "UserPromptSubmit",
        Some(terminal.as_str()),
        json!({}),
    )
    .unwrap();
    mux.workspace_registry
        .lock()
        .unwrap()
        .enqueue_agent_hook_pending(
            &ingress.producer_id,
            "test",
            key,
            1,
            &ingress,
            AgentHookPendingFailure {
                error: AGENT_HOOK_RETRY_ERROR,
                retry_class: crate::workspace_registry::AgentHookRetryClass::Transient,
            },
        )
        .unwrap();
}

/// The dead letters of the hook retry table, by a second connection.
fn dead_letters(connection: &rusqlite::Connection) -> i64 {
    connection
        .query_row(
            "SELECT COUNT(*) FROM resource_agent_hook_pending WHERE attempt >= ?1",
            [crate::workspace_registry::AGENT_HOOK_MAX_ATTEMPTS],
            |row| row.get(0),
        )
        .unwrap()
}

/// A store whose roster snapshot is of the reducer's previous version, with
/// one agent working: the next start serves that roster and rebuilds it
/// from the journal in the background.
fn store_with_a_roster_of_the_previous_version(session: &str, root: &Path) {
    use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};
    let mux = open_persistent_test_mux(session, root);
    let terminal = mux.new_workspace(None, None).unwrap().terminal_public_id().cloned().unwrap();
    append_journal_hook(&mux, &terminal, "SessionStart", Some(SESSION));
    append_journal_hook(&mux, &terminal, "UserPromptSubmit", Some(SESSION));
    assert_eq!(roster_agent_state(&mux, &terminal).as_deref(), Some("working"));
    mux.shutdown();
    drop(mux);
    let registry = WorkspaceRegistry::open(root, session).unwrap();
    let (_, cursor, snapshot) =
        registry.journal_reducer_state(AGENT_ROSTER_REDUCER_ID).unwrap().unwrap();
    registry
        .put_journal_reducer_state(
            AGENT_ROSTER_REDUCER_ID,
            AGENT_ROSTER_REDUCER_VERSION - 1,
            cursor,
            &snapshot,
        )
        .unwrap();
}

/// A client reads the rows by their `writer` strings: the reply has one row
/// for each writer of the table, in the table's order, also for a writer
/// with no commit.
#[test]
fn the_reply_names_each_writer_of_the_table_in_its_order() {
    let (root, mux, _) = mux_with_a_terminal("commits-by-writer-names");
    let reply = section(&mux);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    let writers: Vec<&str> = reply["commits_by_writer"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| row["writer"].as_str().unwrap_or_default())
        .collect();
    assert_eq!(writers, WRITERS, "the `writer` of each row of the reply, in the reply's order");
}

/// One commit through a site that takes the connection with its writer's
/// name (`RegistryConnection::get_as`): the write of a hook's retry row. It
/// counts under that name, not under the name of its thread (`other`).
#[test]
fn a_commit_on_a_connection_taken_with_a_name_counts_under_that_name() {
    let (root, mux, terminal) = mux_with_a_terminal("commits-by-writer-named");
    settled(&mux);
    let before = section(&mux);
    enqueue_retry_row(&mux, &terminal, "named");
    let after = section(&mux);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    let by_enqueue = |writer: &str| commits(&after, writer) - commits(&before, writer);
    assert_eq!(
        (by_enqueue("agent_hook_retry"), by_enqueue("other")),
        (1, 0),
        "(agent_hook_retry, other): the write of the retry row is 1 commit of \
         `agent_hook_retry`; the rows before the enqueue: {:?}; after it: {:?}",
        rows(&before),
        rows(&after)
    );
    assert_rows_sum_to_the_totals(&after, "after the enqueue");
}

/// The enqueue's second statement deletes the oldest dead letters over the
/// table's cap. With one dead letter over the cap it deletes a row, and that
/// commit is of the same writer as the first.
#[test]
fn the_delete_of_a_dead_letter_over_the_cap_counts_as_agent_hook_retry() {
    let (root, mux, terminal) = mux_with_a_terminal("commits-by-writer-dead-letters");
    settled(&mux);
    let database = mux.workspace_registry.lock().unwrap().session_journal_database_path().unwrap();
    let connection = rusqlite::Connection::open(database).unwrap();
    connection
        .execute(
            "WITH RECURSIVE dead(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM dead WHERE n < ?2)
             INSERT INTO resource_agent_hook_pending(
               producer_id, origin, idempotency_key, terminal_id, event_sequence, ingress_json,
               error, attempt
             ) SELECT ?1, 'test', 'dead-' || n, NULL, n, '{}', 'dead', ?3 FROM dead",
            (
                crate::agent_hooks::AGENT_HOOK_PRODUCER_ID,
                DEAD_LETTER_CAP + 1,
                crate::workspace_registry::AGENT_HOOK_MAX_ATTEMPTS,
            ),
        )
        .unwrap();
    assert_eq!(dead_letters(&connection), DEAD_LETTER_CAP + 1, "setup: 1 dead letter over the cap");

    let before = section(&mux);
    enqueue_retry_row(&mux, &terminal, "over-the-cap");
    let after = section(&mux);
    let left = dead_letters(&connection);
    drop(connection);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    assert_eq!(left, DEAD_LETTER_CAP, "setup: the enqueue deleted the dead letter over the cap");
    let by_enqueue = |writer: &str| commits(&after, writer) - commits(&before, writer);
    assert_eq!(
        (by_enqueue("agent_hook_retry"), by_enqueue("other")),
        (2, 0),
        "(agent_hook_retry, other): the write of the retry row and the delete of the dead \
         letter are 2 commits of `agent_hook_retry`; the rows before the enqueue: {:?}; after \
         it: {:?}",
        rows(&before),
        rows(&after)
    );
}

/// The end of a roster rebuild saves the rebuilt roster's snapshot row. That
/// is a commit of `agent_roster_save`, one more than the saves of the
/// roster's owner in the same time.
#[test]
fn the_save_of_a_rebuilt_roster_counts_as_agent_roster_save() {
    use crate::journal_reducers::AGENT_ROSTER_REDUCER_ID;
    use crate::mux::agent_roster_fold::rebuild_faults;
    let session = "commits-by-writer-rebuild";
    let root = std::env::temp_dir()
        .join(format!("cmux-{session}-{}", crate::workspace_registry::new_uuid_v4()));
    store_with_a_roster_of_the_previous_version(session, &root);
    rebuild_faults::hold(session, true);
    let mux = open_persistent_test_mux(session, &root);
    mux.stop_journal_maintenance();
    settled(&mux);
    assert!(mux.agent_roster_rebuilding(), "setup: the start serves the old roster");
    let rebuild_pending = || {
        let registry = mux.workspace_registry.lock().unwrap();
        registry.journal_reducer_rebuild_pending(AGENT_ROSTER_REDUCER_ID).unwrap().is_some()
    };
    assert!(rebuild_pending(), "setup: the roster is marked for its rebuild");

    let saves = mux.agent_roster_snapshot_saves_for_test();
    let before = section(&mux);
    rebuild_faults::hold(session, false);
    mux.continue_agent_roster_rebuild_later();
    // The rebuild's save takes the mark away in its own transaction.
    let deadline = Instant::now() + Duration::from_secs(10);
    while rebuild_pending() {
        assert!(Instant::now() < deadline, "the rebuild did not save its roster");
        std::thread::sleep(Duration::from_millis(10));
    }
    settled(&mux);
    let after = section(&mux);
    let owner_saves = u64::try_from(mux.agent_roster_snapshot_saves_for_test() - saves).unwrap();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    assert_eq!(
        commits(&after, "agent_roster_save") - commits(&before, "agent_roster_save"),
        owner_saves + 1,
        "the save of the rebuilt roster is 1 commit of `agent_roster_save` beside the \
         {owner_saves} of the roster's owner; the rows before the rebuild: {:?}; after it: {:?}",
        rows(&before),
        rows(&after)
    );
}
