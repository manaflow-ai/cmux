//! A socket agent report that changes no durable state writes nothing.
//!
//! A socket reporter (`report-agent` with source `socket`, a poller) says a
//! terminal's state again and again. A report equal to the terminal's record
//! (the same state and session), or one that a stronger source's record
//! ignores, moves nothing a reader keeps. Each one was a registry commit (its
//! mutation key). This guard sends such reports on a real on-disk registry
//! and counts journal rows, registry commits, WAL frame bytes and database
//! pages; none may move. Rows and bytes are counted, not timed. The control
//! proves that the counters see a real change.
//!
//! A hook-source report equal to the record keeps its two rows: its roster
//! echo moves the entry's `updated_at_ms`, which `fresh_hook`
//! (`journal_reducers.rs`) reads to decide whether a screen observation may
//! take the hook's row.

use std::collections::BTreeMap;

use super::*;

/// Agents of the session (Lawrence's daemon had 170).
const AGENTS: usize = 170;
/// Agents that report again and again (20 agents, one report a minute, for 5
/// minutes: 100 reports, his 93 rounded up).
const REPORTERS: usize = 20;
/// Simulated minutes, one equal report of each reporter a minute.
const MINUTES: usize = 5;

pub(super) struct Agent {
    pub(super) terminal: TerminalPublicId,
    pub(super) surface: SurfaceId,
}

/// A session of `workspaces` workspaces with `AGENTS` terminals spread over
/// them.
pub(super) fn session_with_terminals(workspaces: usize, root: &Path) -> (Arc<Mux>, Vec<Agent>) {
    let mux = open_persistent_test_mux("reports-at-rest", root);
    // The maintenance worker checkpoints and seals on its own clock; the
    // counters below must see only what the reports cause.
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
            Agent { terminal, surface }
        })
        .collect::<Vec<_>>();
    (mux, agents)
}

/// What the registry holds and what was written to it so far.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Written {
    pub(super) journal_head: u64,
    pub(super) commits: u64,
    pub(super) wal_frame_bytes: u64,
    pub(super) database_bytes: u64,
    /// The registry's resource revision (one per projection commit).
    pub(super) resource_revision: u64,
}

pub(super) fn written(mux: &Arc<Mux>) -> Written {
    // The roster's owner saves its snapshot after the request answered.
    let mux = settled(mux);
    let stats = mux.write_path_stats();
    let path = mux.journal_kernel.database_path().expect("an on-disk registry");
    let reader = crate::workspace_registry::open_registry_database_read_only(path).unwrap();
    let pragma = |name: &str| -> u64 {
        let value: i64 = reader.query_row(&format!("PRAGMA {name}"), [], |row| row.get(0)).unwrap();
        u64::try_from(value).unwrap()
    };
    Written {
        journal_head: mux.session_journal_head().unwrap(),
        commits: stats.wal_commits,
        wal_frame_bytes: stats.registry_wal_frame_bytes,
        // The committed size, WAL frames included: it does not depend on
        // when a checkpoint moves them into the main file.
        database_bytes: pragma("page_count") * pragma("page_size"),
        resource_revision: reader
            .query_row("SELECT value FROM meta WHERE key = 'resource_revision'", [], |row| {
                row.get::<_, String>(0)
            })
            .unwrap()
            .parse()
            .unwrap(),
    }
}

/// Journal rows after `sequence`, counted by kind.
pub(super) fn kinds_after(mux: &Mux, mut sequence: u64) -> BTreeMap<String, usize> {
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

/// Let the wall clock pass the last report, as a minute does in the field:
/// the next equal report carries a later time.
pub(super) fn tick() {
    let start = crate::workspace_registry::unix_epoch_ms().unwrap();
    while crate::workspace_registry::unix_epoch_ms().unwrap() <= start {
        std::hint::spin_loop();
    }
}

fn report_session(index: usize) -> Option<String> {
    Some(format!("report-session-{index}"))
}

/// `MINUTES` of direct reports (`report-agent`, the resource `agent.report`)
/// that say again what each terminal's record holds. Nothing durable changes,
/// so nothing is written.
fn equal_agent_reports_write_nothing(workspaces: usize, source: AgentSource, hook_owned: bool) {
    let root = std::env::temp_dir()
        .join(format!("cmux-reports-at-rest-{}", crate::workspace_registry::new_uuid_v4()));
    let (mux, agents) = session_with_terminals(workspaces, &root);
    for (index, agent) in agents.iter().take(REPORTERS).enumerate() {
        let owner = if hook_owned { AgentSource::Hook } else { source };
        let record = mux
            .report_agent(agent.surface, AgentState::Working, owner, report_session(index))
            .unwrap();
        assert_eq!(record.state, AgentState::Working, "setup: the first report is the record");
    }
    let owner = if hook_owned { AgentSource::Hook } else { source };
    let before = written(&mux);

    let mut reports = 0_usize;
    for _minute in 0..MINUTES {
        tick();
        for (index, agent) in agents.iter().take(REPORTERS).enumerate() {
            let record = mux
                .report_agent(agent.surface, AgentState::Working, source, report_session(index))
                .unwrap();
            // The caller still gets the terminal's record.
            assert_eq!(record.terminal_id, agent.terminal);
            assert_eq!(record.state, AgentState::Working);
            assert_eq!(record.source, owner);
            reports += 1;
        }
    }

    let after = written(&mux);
    let rows = kinds_after(&mux, before.journal_head);
    assert_eq!(
        after,
        before,
        "{MINUTES} minutes, {REPORTERS} of {AGENTS} agents in {workspaces} workspaces, {reports} \
         `{}` reports equal to the stored record: {} journal rows {rows:?}, {} registry commits, \
         {} WAL frame bytes, {} bytes of database pages. A report that changes no durable state \
         must write nothing",
        source.as_str(),
        after.journal_head - before.journal_head,
        after.commits - before.commits,
        after.wal_frame_bytes - before.wal_frame_bytes,
        after.database_bytes.saturating_sub(before.database_bytes),
    );
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn equal_agent_reports_write_nothing_in_a_light_session() {
    equal_agent_reports_write_nothing(1, AgentSource::Socket, false);
}

#[test]
fn equal_agent_reports_write_nothing_in_a_large_session() {
    equal_agent_reports_write_nothing(60, AgentSource::Socket, false);
}

#[test]
fn equal_agent_reports_write_nothing_in_a_real_session() {
    equal_agent_reports_write_nothing(826, AgentSource::Socket, false);
}

/// A socket report for a terminal a hook-source record owns is ignored: the
/// record stays, and nothing is written.
#[test]
fn equal_agent_reports_ignored_by_a_hook_record_write_nothing() {
    equal_agent_reports_write_nothing(60, AgentSource::Socket, true);
}

/// The counters see a real change: a report with another state is one
/// projection row (`agent.report`) and its echo for the roster
/// (`agent.state.changed`), and the record moves.
#[test]
fn equal_agent_reports_control_a_new_state_appends_its_row() {
    let root = std::env::temp_dir()
        .join(format!("cmux-reports-at-rest-control-{}", crate::workspace_registry::new_uuid_v4()));
    let (mux, agents) = session_with_terminals(1, &root);
    let agent = &agents[0];
    mux.report_agent(agent.surface, AgentState::Working, AgentSource::Socket, report_session(0))
        .unwrap();
    let before = written(&mux);

    tick();
    let record = mux
        .report_agent(agent.surface, AgentState::Blocked, AgentSource::Socket, report_session(0))
        .unwrap();
    assert_eq!(record.state, AgentState::Blocked);

    let after = written(&mux);
    let rows = kinds_after(&mux, before.journal_head);
    assert_eq!(
        rows.get("agent.report"),
        Some(&1),
        "one real change is one projection row: {rows:?}"
    );
    assert_eq!(rows.get("agent.state.changed"), Some(&1), "and its echo for the roster: {rows:?}");
    assert_eq!(after.journal_head - before.journal_head, 2, "{rows:?}");
    assert!(after.commits > before.commits && after.wal_frame_bytes > before.wal_frame_bytes);
    assert_eq!(
        settled(&mux).agent_roster_state_now_for_test(agent.terminal.as_str()).as_deref(),
        Some("blocked")
    );
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}
