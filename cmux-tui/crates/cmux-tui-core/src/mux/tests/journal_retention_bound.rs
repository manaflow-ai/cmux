//! The journal's bookkeeping in the registry stays bounded in a running daemon.
//!
//! Lawrence's registry, 2026-11-10 (826 workspaces, 170 agents): 9.65 GB, of
//! which under 0.15 GB was state. The rest was the journal's own tables, and
//! no rule ever deleted a row of them: 3.41 GB of kept reducer records, 2.02
//! GB of sealed segments, 3.30 GB of subject index (12.1 rows a record), 0.33
//! GB of ingress receipts and 0.31 GB of event index.
//!
//! This guard writes the mix of that session (agent hooks, terminal program
//! status, `project.observe`) through the real ingress paths, on a real
//! on-disk registry, and runs the maintenance worker's own tick. It counts
//! rows and pages; it times nothing, so the result does not depend on the
//! machine. The bound is the same after N records and after 4N: the tables
//! follow the retained window, not the age of the session.
//!
//! The worker checkpoints each 4,096 records; this test asks for a checkpoint
//! each [`CHECKPOINT_EVERY`] records through the public checkpoint path, so
//! the same rule (the newest 16 checkpoints stay) is reached with thousands
//! of records, not hundreds of thousands. Seal, prune and vacuum are the
//! tick's own.
#![cfg(unix)]

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::*;
use crate::mux::agent_roster_restore::restore_agent_roster;

/// Agents of the session. The first [`ACTIVE_AGENTS`] work for the whole
/// test; the rest start a session and then stay idle, so every record of
/// theirs is soon older than the retained window.
const AGENTS: usize = 8;
const ACTIVE_AGENTS: usize = 4;
/// Journal records between two checkpoints of this test.
const CHECKPOINT_EVERY: u64 = 64;
/// N: journal records after the first measure. The second measure is at 4N.
const RECORDS: u64 = 2_000;
/// Ticks after each checkpoint: one seals, one prunes what the seal covered.
const TICKS_PER_CHECKPOINT: usize = 2;
/// Records the registry may keep bookkeeping for: the newest 16 checkpoints
/// (`JOURNAL_CHECKPOINTS_KEPT`) bound the window, each interval holds
/// `CHECKPOINT_EVERY` records plus the checkpoint and seal records of its
/// own, and 4 more intervals are the margin for the segment in flight.
const RETAINED_RECORDS_BOUND: u64 = 20 * (CHECKPOINT_EVERY + 8);
/// Subject index rows a record may have (Lawrence's file: 12.1 a record).
const SUBJECT_ROWS_PER_RECORD: u64 = 16;
/// Bytes a journal table may use per retained record (his file: 4.8 KB a
/// record over all five tables; no single table is over 2 KiB a record).
const TABLE_BYTES_PER_RECORD: u64 = 2 * 1024;
const TABLE_BYTES_BOUND: u64 = RETAINED_RECORDS_BOUND * TABLE_BYTES_PER_RECORD;
const CWD: &str = "/work/project";

/// The journal's own tables and the column that holds a record's sequence.
const JOURNAL_TABLES: [(&str, &str); 5] = [
    ("journal_segments", "start_sequence"),
    ("journal_segment_reducer_records", "sequence"),
    ("journal_subject_index", "sequence"),
    ("journal_event_index", "sequence"),
    ("journal_ingress_receipts", "journal_sequence"),
];

struct Agent {
    terminal: TerminalPublicId,
    surface: Arc<Surface>,
    session: String,
}

/// A session of `workspaces` workspaces with `AGENTS` terminals spread over
/// them, each with an agent session.
fn session(workspaces: usize, root: &Path) -> (Arc<Mux>, Vec<Agent>) {
    let mux = open_persistent_test_mux("journal-retention", root);
    // The worker ticks each 30 s; this test runs the same tick itself.
    mux.stop_journal_maintenance();
    let keys = (0..workspaces)
        .map(|_| mux.create_empty_workspace(None, None, None).unwrap().key)
        .collect::<Vec<_>>();
    let agents = (0..AGENTS)
        .map(|index| {
            let raw = format!("00000000000040008000{:012x}", index + 1);
            let incarnation = format!("10000000000040008000{:012x}", index + 1);
            let surface = mux
                .seed_running_terminal_for_test(&raw, &incarnation, &keys[index % workspaces])
                .unwrap();
            let terminal =
                mux.workspace_registry.lock().unwrap().terminal_resource_id(&raw).unwrap().unwrap();
            Agent {
                terminal,
                surface: mux.surface(surface).unwrap(),
                session: format!("session-{index}"),
            }
        })
        .collect::<Vec<_>>();
    for agent in &agents {
        send(&mux, agent, "SessionStart", json!({}));
    }
    (mux, agents)
}

/// One hook of `agent` through the real journal ingress path, as its hook
/// helper sends it.
fn send(mux: &Arc<Mux>, agent: &Agent, event: &str, mut native: Value) {
    native["session_id"] = json!(agent.session);
    native["cwd"] = json!(CWD);
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(agent.terminal.as_str()),
        native,
    )
    .unwrap();
    let key = format!("retention-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap();
}

/// One step of the session's mix: a turn's start, a turn's end, a program
/// status edge or a project observation with a newer time.
fn step(mux: &Arc<Mux>, agents: &[Agent], index: u64) {
    let agent = &agents[usize::try_from(index / 4).unwrap() % ACTIVE_AGENTS];
    match index % 4 {
        0 => send(mux, agent, "UserPromptSubmit", json!({ "prompt": format!("step {index}") })),
        1 => send(mux, agent, "Stop", json!({})),
        2 => {
            let state = if (index / 16) % 2 == 0 {
                ghostty_vt::ProgramStatusState::Working
            } else {
                ghostty_vt::ProgramStatusState::Idle
            };
            mux.record_program_status_evidence(&agent.surface, state);
        }
        _ => {
            let entries = json!([{
                "path": "/srv/cmux-retention/alpha",
                "last_used_ms": (1_000 + index).to_string(),
            }]);
            mux.state_project_observe(
                &WorkspaceMutation::daemon_local("retention-test"),
                "acpmux",
                &entries,
                true,
            )
            .unwrap();
        }
    }
}

fn head(mux: &Mux) -> u64 {
    mux.session_journal_head().unwrap()
}

/// Writes the mix until the journal head is at `target`, with a checkpoint
/// and the worker's ticks each `CHECKPOINT_EVERY` records.
fn write_through(mux: &Arc<Mux>, agents: &[Agent], next_step: &mut u64, target: u64) {
    while head(mux) < target {
        let stop = (head(mux) + CHECKPOINT_EVERY).min(target);
        while head(mux) < stop {
            step(mux, agents, *next_step);
            *next_step += 1;
        }
        settled(mux);
        mux.create_journal_checkpoint("retention-test", &format!("retention-{next_step}")).unwrap();
        for _ in 0..TICKS_PER_CHECKPOINT {
            mux.run_journal_maintenance_for_test();
        }
    }
}

fn reader(mux: &Mux) -> rusqlite::Connection {
    let path = mux.journal_kernel.database_path().expect("an on-disk registry");
    crate::workspace_registry::open_registry_database_read_only(path).unwrap()
}

/// One journal table at one moment.
#[derive(Debug, Clone, Copy)]
struct Table {
    rows: u64,
    /// The lowest record sequence it has a row for (0: no row).
    oldest: u64,
    /// The pages of the table and of its indexes (`dbstat`), in bytes.
    bytes: Option<u64>,
}

#[derive(Debug)]
struct Measure {
    head: u64,
    tables: BTreeMap<&'static str, Table>,
}

fn measure(mux: &Mux) -> Measure {
    let connection = reader(settled(mux));
    let number = |sql: &str| -> u64 {
        let value: i64 = connection.query_row(sql, [], |row| row.get(0)).unwrap();
        u64::try_from(value).unwrap()
    };
    let tables = JOURNAL_TABLES
        .iter()
        .map(|(table, column)| {
            let bytes = connection
                .query_row(
                    "SELECT COALESCE(SUM(pgsize), 0) FROM dbstat
                     WHERE name IN (SELECT name FROM sqlite_master WHERE tbl_name = ?1)",
                    [table],
                    |row| row.get::<_, i64>(0),
                )
                .ok()
                .map(|bytes| u64::try_from(bytes).unwrap());
            let measured = Table {
                rows: number(&format!("SELECT COUNT(*) FROM {table}")),
                oldest: number(&format!("SELECT COALESCE(MIN({column}), 0) FROM {table}")),
                bytes,
            };
            (*table, measured)
        })
        .collect();
    Measure { head: head(mux), tables }
}

/// What `measure` holds over the stated bounds.
fn over_bounds(label: &str, measure: &Measure, over: &mut Vec<String>) {
    let window_start = measure.head.saturating_sub(RETAINED_RECORDS_BOUND);
    for (table, measured) in &measure.tables {
        println!(
            "journal_retention_bound: {label} head={} table={table} rows={} oldest={} bytes={:?}",
            measure.head, measured.rows, measured.oldest, measured.bytes
        );
        if measured.rows > 0 && measured.oldest <= window_start {
            over.push(format!(
                "{label}: {table} keeps a row of record {}, {} records behind the head {} \
                 (bound {RETAINED_RECORDS_BOUND})",
                measured.oldest,
                measure.head - measured.oldest,
                measure.head
            ));
        }
        let rows_bound = match *table {
            "journal_subject_index" => SUBJECT_ROWS_PER_RECORD * RETAINED_RECORDS_BOUND,
            _ => RETAINED_RECORDS_BOUND,
        };
        if measured.rows > rows_bound {
            over.push(format!("{label}: {table} has {} rows, bound {rows_bound}", measured.rows));
        }
        match measured.bytes {
            Some(bytes) if bytes > TABLE_BYTES_BOUND => {
                over.push(format!("{label}: {table} uses {bytes} bytes, bound {TABLE_BYTES_BOUND}"))
            }
            Some(_) => {}
            // A SQLite without `dbstat`: the row bounds above still hold.
            None => println!("journal_retention_bound: {label} no dbstat for {table}"),
        }
    }
}

/// What every reader sees: no agent is lost, a start restores the roster
/// the daemon has, each kept checkpoint still gives a restore preview, and
/// a journal read from the first record returns the retained records with
/// no hole between them.
fn reader_problems(mux: &Arc<Mux>, agents: &[Agent], problems: &mut Vec<String>) {
    for agent in agents {
        if settled(mux).agent_roster_state_now_for_test(agent.terminal.as_str()).is_none() {
            problems.push(format!("the roster lost the agent of {}", agent.terminal));
        }
    }
    let live = settled(mux).agent_roster.lock().unwrap().roster.snapshot();
    let restored = {
        let registry = mux.workspace_registry.lock().unwrap();
        restore_agent_roster(&registry)
    };
    match restored {
        Ok(restored) => {
            if restored.host.roster.snapshot() != live {
                problems.push("a start restores a roster that is not the live roster".into());
            }
            if restored.rebuild {
                problems.push("a start would rebuild the roster from the journal".into());
            }
        }
        Err(error) => problems.push(format!("the roster does not restore: {error:#}")),
    }

    let checkpoints = mux.journal_checkpoints().unwrap();
    let selectors = ["latest".to_owned()]
        .into_iter()
        .chain(checkpoints.last().map(|oldest| oldest.checkpoint_id.clone()));
    for selector in selectors {
        if let Err(error) = mux.journal_restore_preview(&selector) {
            problems.push(format!("restore preview of checkpoint {selector}: {error:#}"));
        }
    }

    let head = head(mux);
    let mut cursor = 0;
    let mut previous = None;
    loop {
        let page = match mux.session_journal_after(cursor, 500) {
            Ok(page) => page,
            Err(error) => {
                problems.push(format!("journal read after {cursor}: {error:#}"));
                return;
            }
        };
        let Some(last) = page.records.last() else { break };
        cursor = last.sequence;
        for record in &page.records {
            if previous.is_some_and(|previous: u64| record.sequence != previous + 1) {
                problems.push(format!(
                    "journal read: record {} follows {previous:?}: a hole",
                    record.sequence
                ));
                return;
            }
            previous = Some(record.sequence);
        }
    }
    if previous != Some(head) {
        problems.push(format!("journal read ended at {previous:?}, the head is {head}"));
    }
}

fn journal_bookkeeping_is_bounded(workspaces: usize) {
    let root = std::env::temp_dir()
        .join(format!("cmux-journal-retention-{}", crate::workspace_registry::new_uuid_v4()));
    let (mux, agents) = session(workspaces, &root);
    let start = head(&mux);
    let mut next_step = 0;

    write_through(&mux, &agents, &mut next_step, start + RECORDS);
    let at_n = measure(&mux);
    write_through(&mux, &agents, &mut next_step, start + 4 * RECORDS);
    let at_4n = measure(&mux);

    let mut over = Vec::new();
    over_bounds(&format!("workspaces={workspaces} N={RECORDS}"), &at_n, &mut over);
    over_bounds(&format!("workspaces={workspaces} 4N={}", 4 * RECORDS), &at_4n, &mut over);
    let mut problems = Vec::new();
    reader_problems(&mux, &agents, &mut problems);

    mux.shutdown();
    drop(agents);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(problems.is_empty(), "a reader lost something: {problems:#?}");
    assert!(
        over.is_empty(),
        "the journal's tables grow with the age of the session, not with the retained window: \
         {over:#?}"
    );
}

#[test]
fn journal_bookkeeping_is_bounded_on_1_workspace() {
    journal_bookkeeping_is_bounded(1);
}

#[test]
fn journal_bookkeeping_is_bounded_on_60_workspaces() {
    journal_bookkeeping_is_bounded(60);
}

#[test]
fn journal_bookkeeping_is_bounded_on_826_workspaces() {
    journal_bookkeeping_is_bounded(826);
}

/// A journal hook that did not deliver yet holds every record after its
/// cursor: retention never deletes a row a hook has not seen.
#[test]
fn a_journal_hook_with_an_old_cursor_keeps_every_undelivered_record() {
    let root = std::env::temp_dir()
        .join(format!("cmux-journal-retention-hook-{}", crate::workspace_registry::new_uuid_v4()));
    let (mux, agents) = session(1, &root);
    // No dispatcher runs in this test, so the hook's cursor stays where the
    // hook was installed, as with a hook whose program hangs.
    assert!(mux.try_claim_journal_hook_dispatcher());
    let manifest: crate::JournalHookManifest = serde_json::from_value(json!({
        "hook_id": "retention_hook",
        "manifest_version": 1,
        "filter": {},
        "exec": { "argv": ["/usr/bin/true"], "timeout_ms": 1000, "max_parallel": 1 },
        "delivery": { "start": "tail", "retry": { "max_attempts": 1, "backoff_ms": 0 } },
        "permissions": ["journal.read"],
    }))
    .unwrap();
    mux.put_journal_hook(&manifest, "retention-test", "retention-hook-put").unwrap();
    let hook_cursor = mux.journal_hook_states().unwrap()[0].cursor_sequence;

    let mut next_step = 0;
    write_through(&mux, &agents, &mut next_step, hook_cursor + RECORDS);
    assert_eq!(mux.journal_hook_states().unwrap()[0].cursor_sequence, hook_cursor);

    let head = head(&mux);
    let mut expected = hook_cursor + 1;
    loop {
        let page = mux.session_journal_after(expected - 1, 500).unwrap();
        if page.records.is_empty() {
            break;
        }
        for record in &page.records {
            assert_eq!(record.sequence, expected, "a record the hook did not see is gone");
            expected += 1;
        }
    }
    assert_eq!(expected, head + 1, "the hook's records reach the head");

    mux.shutdown();
    drop(agents);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}
