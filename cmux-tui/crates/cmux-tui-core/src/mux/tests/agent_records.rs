//! AGENT RECORDS (2026-11-10): one agent record for each terminal that is still in the session.
//!
//! The registry kept the agent record of a terminal (`resource_agent_projections`, and the hook
//! fence beside it in `resource_agent_hook_state`) after the terminal closed: a close only
//! tombstones the terminal, and nothing deleted the two rows. The person's session had 214
//! records, 111 of them of closed terminals, and it gained one for each terminal that had an
//! agent. `agent.list`, the session snapshot (so each `session.events` open and each journal
//! checkpoint), each agent report and each daemon start read and decoded all of them under the
//! registry lock and the state lock.
//!
//! The rule (`spec/resource-api-v2.md`, "Agent"): the close ends the record in the transaction
//! that tombstones the terminal, and the start removes the old records of closed terminals one
//! time. A parked terminal (its shell ended, its tab kept) is not closed: its record stays.
//!
//! These tests count rows: the rows in the two tables and the agent rows a reader decodes. They
//! read no clock.

use serde_json::{Value, json};

use super::read_paths::resource;
use super::*;
use crate::workspace_registry::{
    agent_hook_fence_rows_read_on_this_thread as fences_read,
    agent_projection_rows_read_on_this_thread as rows_read,
};

/// A workspace with one terminal; the terminal's public id.
fn terminal(mux: &Arc<Mux>, name: &str) -> String {
    let created = public_request(
        mux,
        name,
        "workspace.create",
        json!({"machine":"current","session":"current","name":name,"initial_content":"terminal"}),
        Some(&format!("agent-records-create-{name}")),
    );
    assert_eq!(created["ok"], true, "workspace.create {name}: {created}");
    created["result"]["value"]["terminal_id"].as_str().expect("the new terminal's id").to_string()
}

/// One agent hook of the harness session `session` in `terminal`, through the journal ingress
/// path that the hook helper uses.
fn hook(
    mux: &Arc<Mux>,
    terminal: &str,
    event: &str,
    session: &str,
) -> anyhow::Result<crate::JournalAppendCommit> {
    let mut native = json!({"session_id": session, "cwd": "/work/project"});
    match event {
        "UserPromptSubmit" => native["prompt"] = json!("go on"),
        "PreToolUse" => native["tool_name"] = json!("Read"),
        _ => {}
    }
    let ingress =
        crate::agent_hooks::agent_hook_journal_ingress("claude", event, Some(terminal), native)?;
    let key = format!("agent-records-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key)
}

/// A hook agent in a turn in `terminal`: a record and a hook fence.
fn start_hook_agent(mux: &Arc<Mux>, terminal: &str) {
    let session = format!("session-of-{terminal}");
    hook(mux, terminal, "SessionStart", &session).unwrap();
    hook(mux, terminal, "UserPromptSubmit", &session).unwrap();
}

/// An agent that reports through `agent.report` in `terminal`: a record.
fn report_agent(mux: &Arc<Mux>, terminal: &str) {
    let reported = public_request(
        mux,
        "report",
        "agent.report",
        json!({"machine":"current","session":"current","terminal_id":terminal,
               "state":"working","source":"socket",
               "source_session":format!("worker-{terminal}")}),
        Some(&format!("agent-records-report-{terminal}")),
    );
    assert_eq!(reported["ok"], true, "agent.report: {reported}");
}

/// `terminal.close`: the request tombstones the terminal.
fn close(mux: &Arc<Mux>, terminal: &str) {
    let closed = public_request(
        mux,
        "close",
        "terminal.close",
        json!({"machine":"current","session":"current","terminal":terminal}),
        Some(&format!("agent-records-close-{terminal}")),
    );
    assert_eq!(closed["ok"], true, "terminal.close: {closed}");
    let tombstoned: bool = mux
        .registry_connection
        .get()
        .query_row(
            "SELECT deleted_revision IS NOT NULL FROM resource_terminals WHERE public_id = ?1",
            [terminal],
            |row| row.get(0),
        )
        .unwrap();
    assert!(tombstoned, "setup: terminal.close tombstones {terminal} in the request");
}

/// (agent records, hook fences) that the registry stores for `terminal`.
fn stored(mux: &Mux, terminal: &str) -> (i64, i64) {
    let db = mux.registry_connection.get();
    let records = db
        .query_row(
            "SELECT COUNT(*) FROM resource_agent_projections WHERE terminal_id = ?1",
            [terminal],
            |row| row.get(0),
        )
        .unwrap();
    let fences = db
        .query_row(
            "SELECT COUNT(*) FROM resource_agent_hook_state WHERE terminal_id = ?1",
            [terminal],
            |row| row.get(0),
        )
        .unwrap();
    (records, fences)
}

/// (agent records, hook fences) in the whole registry.
fn stored_in_all(mux: &Mux) -> (i64, i64) {
    let db = mux.registry_connection.get();
    let records = db
        .query_row("SELECT COUNT(*) FROM resource_agent_projections", [], |row| row.get(0))
        .unwrap();
    let fences = db
        .query_row("SELECT COUNT(*) FROM resource_agent_hook_state", [], |row| row.get(0))
        .unwrap();
    (records, fences)
}

/// The agents of `agents` (an `agent.list` result or a snapshot's `agents`) whose terminal is
/// one of `terminals`.
fn agents_of(agents: &Value, terminals: &[String]) -> usize {
    agents
        .as_array()
        .expect("an array of agents")
        .iter()
        .filter(|agent| {
            agent["terminal_id"].as_str().is_some_and(|id| terminals.iter().any(|t| t == id))
        })
        .count()
}

/// The stored record and hook fence of a terminal, as an older daemon left them in the file.
struct OldRecord {
    terminal: String,
    result_json: String,
    revision: i64,
    fence: Option<(String, i64, bool, i64, Option<i64>)>,
}

fn old_record(mux: &Mux, terminal: &str) -> OldRecord {
    let db = mux.registry_connection.get();
    let (result_json, revision): (String, i64) = db
        .query_row(
            "SELECT result_json, committed_revision FROM resource_agent_projections
             WHERE terminal_id = ?1",
            [terminal],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .expect("setup: the terminal has an agent record");
    let fence: Option<(String, i64, bool, i64, Option<i64>)> = db
        .prepare(
            "SELECT agent_session_id, applied_sequence, ended, committed_revision, ended_at_ms
             FROM resource_agent_hook_state WHERE terminal_id = ?1",
        )
        .unwrap()
        .query_map([terminal], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, bool>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, Option<i64>>(4)?,
            ))
        })
        .unwrap()
        .next()
        .map(Result::unwrap);
    OldRecord { terminal: terminal.to_string(), result_json, revision, fence }
}

/// Writes `record` into the file again: the state a daemon before this rule left behind, where
/// the terminal is tombstoned and its record and fence are still stored.
fn put_old_record(mux: &Mux, record: &OldRecord) {
    let db = mux.registry_connection.get();
    db.execute(
        "INSERT OR REPLACE INTO resource_agent_projections(
           terminal_id, result_json, committed_revision
         ) VALUES(?1, ?2, ?3)",
        rusqlite::params![record.terminal, record.result_json, record.revision],
    )
    .unwrap();
    if let Some((session, sequence, ended, revision, ended_at_ms)) = &record.fence {
        db.execute(
            "INSERT OR REPLACE INTO resource_agent_hook_state(
               terminal_id, agent_session_id, applied_sequence, ended, committed_revision,
               ended_at_ms
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![record.terminal, session, sequence, ended, revision, ended_at_ms],
        )
        .unwrap();
    }
}

/// Terminals with an agent that close in the count test.
const CLOSED: usize = 6;

/// The agent records that each reader decodes: `agent.list`, `session.snapshot`, and the snapshot
/// that a `session.events` open with no cursor sends (`server/resource_clients.rs`,
/// `resource_session_snapshot`). With each count, the agents that the reader gave.
fn readers(mux: &Arc<Mux>) -> [(&'static str, usize, Value); 3] {
    let before = rows_read();
    let listed = resource(mux, "agent.list", json!({}));
    let list_rows = rows_read() - before;
    let before = rows_read();
    let snapshot = resource(mux, "session.snapshot", json!({}));
    let snapshot_rows = rows_read() - before;
    let before = rows_read();
    let events_open = crate::resource_api::public_session_snapshot(mux).unwrap();
    let events_open_rows = rows_read() - before;
    [
        ("agent.list", list_rows, listed),
        ("session.snapshot", snapshot_rows, snapshot["agents"].clone()),
        ("a session.events open", events_open_rows, events_open["agents"].clone()),
    ]
}

/// After N terminals with an agent close, the registry stores no record and no hook fence of
/// them, and `agent.list`, the session snapshot and the snapshot of a `session.events` open
/// decode as many agent records as before those terminals were made: the one of the terminal
/// that is still open.
#[test]
fn closed_terminals_leave_no_agent_record_and_no_reader_reads_one() {
    let mux = test_mux();
    let open = terminal(&mux, "open");
    start_hook_agent(&mux, &open);
    settled(&mux);
    let alone = readers(&mux);
    for (reader, rows, agents) in &alone {
        assert_eq!(*rows, 1, "setup: {reader} decodes the one record on this thread");
        assert_eq!(agents_of(agents, std::slice::from_ref(&open)), 1, "setup: {reader}: {agents}");
    }

    let closed = (0..CLOSED)
        .map(|index| {
            let id = terminal(&mux, &format!("closed-{index}"));
            // Both kinds of record: a hook session (record and fence) and a report.
            if index % 2 == 0 {
                start_hook_agent(&mux, &id);
            } else {
                report_agent(&mux, &id);
            }
            id
        })
        .collect::<Vec<_>>();
    settled(&mux);
    let before_close = closed.iter().map(|id| stored(&mux, id)).collect::<Vec<_>>();
    let expected = (0..CLOSED).map(|index| (1, i64::from(index % 2 == 0))).collect::<Vec<_>>();
    assert_eq!(
        before_close, expected,
        "setup: (agent records, hook fences) of each terminal before its close"
    );

    for id in &closed {
        close(&mux, id);
    }
    settled(&mux);

    let mut problems = Vec::new();
    let left = closed
        .iter()
        .map(|id| stored(&mux, id))
        .fold((0, 0), |sum, (records, fences)| (sum.0 + records, sum.1 + fences));
    if left != (0, 0) {
        problems.push(format!(
            "the registry stores {} agent records and {} hook fences of {CLOSED} closed terminals",
            left.0, left.1
        ));
    }
    assert_eq!(stored(&mux, &open).0, 1, "the record of the open terminal stays");

    for ((reader, rows, agents), (_, rows_alone, _)) in readers(&mux).iter().zip(&alone) {
        if rows != rows_alone {
            problems.push(format!(
                "{reader} decoded {rows} agent records; it decoded {rows_alone} before the \
                 {CLOSED} terminals that are closed now were made"
            ));
        }
        let shown = agents_of(agents, &closed);
        if shown != 0 {
            problems.push(format!("{reader} lists {shown} agents of closed terminals"));
        }
        assert_eq!(
            agents_of(agents, std::slice::from_ref(&open)),
            1,
            "{reader} lists the agent of the open terminal: {agents}"
        );
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
    mux.shutdown();
}

/// A harness that is killed with its terminal sends its last hooks after the close (a tool call
/// in flight, then `SessionEnd`). They must not make a record or a fence again.
#[test]
fn a_late_hook_after_the_close_makes_no_agent_record() {
    let mux = test_mux();
    let id = terminal(&mux, "late");
    start_hook_agent(&mux, &id);
    settled(&mux);
    assert_eq!(stored(&mux, &id), (1, 1), "setup: the hook session has a record and a fence");

    close(&mux, &id);
    for event in ["PreToolUse", "SessionEnd"] {
        // The answer to a hook of a closed terminal is not this test's subject.
        let _ = hook(&mux, &id, event, &format!("session-of-{id}"));
    }
    settled(&mux);

    assert_eq!(
        stored(&mux, &id),
        (0, 0),
        "(agent records, hook fences) of a closed terminal after its late hooks"
    );
    mux.shutdown();
}

/// Old records of closed terminals in the start test.
const OLD: usize = 8;

/// A registry file that an older daemon wrote has the records of closed terminals. The start
/// removes them, keeps the record of a terminal that was open and of a parked terminal, and a
/// second start finds nothing to remove.
#[test]
fn the_start_removes_the_old_agent_records_of_closed_terminals() {
    let session = "agent-records-at-open";
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-records-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    let open = terminal(&mux, "open");
    let parked = terminal(&mux, "parked");
    let closed = (0..OLD).map(|index| terminal(&mux, &format!("old-{index}"))).collect::<Vec<_>>();
    for id in closed.iter().chain([&open, &parked]) {
        start_hook_agent(&mux, id);
    }
    settled(&mux);

    // The parked terminal: its shell ends, its tab stays (`park-tabs`).
    let parked_id = TerminalPublicId::parse(&parked).unwrap();
    let parked_surface = mux
        .with_state(|state| {
            state.resource_indexes.content_ids.iter().find_map(|(surface, content)| {
                (*content == ContentPublicId::Terminal(parked_id.clone())).then_some(*surface)
            })
        })
        .expect("setup: a tab shows the terminal");
    assert_eq!(
        mux.park_terminal_tabs(&[parked_surface]).unwrap(),
        [parked_surface],
        "setup: the terminal is parked"
    );

    let old = closed.iter().map(|id| old_record(&mux, id)).collect::<Vec<_>>();
    for id in &closed {
        close(&mux, id);
    }
    settled(&mux);
    for record in &old {
        put_old_record(&mux, record);
    }
    let in_file = closed.iter().map(|id| stored(&mux, id)).collect::<Vec<_>>();
    assert_eq!(in_file, vec![(1, 1); OLD], "setup: the file has the old records and fences");
    mux.shutdown();
    drop(mux);

    for start in ["the first start", "the second start"] {
        let reopened = open_persistent_test_mux(session, &root);
        // First the records that stay: a red run shows that the setup holds.
        assert_eq!(stored(&reopened, &open), (1, 1), "{start}: the open terminal keeps its record");
        assert_eq!(
            stored(&reopened, &parked),
            (1, 1),
            "{start}: the parked terminal keeps its record"
        );
        assert!(
            reopened.parked_terminal_ids([parked_id.clone()]).contains(&parked_id),
            "{start}: the parked terminal is still parked"
        );
        let left = closed.iter().map(|id| stored(&reopened, id)).collect::<Vec<_>>();
        assert_eq!(
            left,
            vec![(0, 0); OLD],
            "{start}: (agent records, hook fences) of the {OLD} closed terminals"
        );
        assert_eq!(stored_in_all(&reopened), (2, 2), "{start}: all that the registry stores");
        let listed = resource(&reopened, "agent.list", json!({}));
        assert_eq!(agents_of(&listed, &closed), 0, "{start}: agent.list: {listed}");
        reopened.shutdown();
        drop(reopened);
    }
    let _ = std::fs::remove_dir_all(&root);
}

/// The hook fences (`resource_agent_hook_state`) have the rule of the records. After N terminals
/// with a hook session close, the registry stores no fence of them, and the load of the public
/// projections (each daemon start reads every fence into memory with it) reads as many fences
/// as before those terminals were made: the one of the terminal that is still open.
#[test]
fn closed_terminals_leave_no_hook_fence_and_the_start_load_reads_none() {
    // (fence rows read, fences given) by one load of the public projections on this thread.
    let load = |mux: &Arc<Mux>| {
        let before = fences_read();
        let projections = mux.workspace_registry.lock().unwrap().public_projections().unwrap();
        (fences_read() - before, projections.agent_hook_states.len())
    };
    let mux = test_mux();
    let open = terminal(&mux, "open");
    start_hook_agent(&mux, &open);
    settled(&mux);
    assert_eq!(load(&mux), (1, 1), "setup: the load reads the one fence on this thread");

    let closed = (0..CLOSED)
        .map(|index| {
            let id = terminal(&mux, &format!("closed-{index}"));
            start_hook_agent(&mux, &id);
            id
        })
        .collect::<Vec<_>>();
    settled(&mux);
    assert_eq!(
        (stored_in_all(&mux).1, load(&mux)),
        (CLOSED as i64 + 1, (CLOSED + 1, CLOSED + 1)),
        "setup: one fence for each hook session before the closes"
    );

    for id in &closed {
        close(&mux, id);
    }
    settled(&mux);

    assert_eq!(stored(&mux, &open).1, 1, "the fence of the open terminal stays");
    assert_eq!(
        (stored_in_all(&mux).1, load(&mux)),
        (1, (1, 1)),
        "(fences stored, (fence rows read, fences given) by the load) after {CLOSED} terminals \
         with a hook session closed"
    );
    mux.shutdown();
}
