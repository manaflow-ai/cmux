//! An agent report that changes no durable state writes nothing.
//!
//! Lawrence's daemon, 2026-11-10 (826 workspaces, 170 agents): 6 % of the
//! journal rows were `agent.report` and 6 % were the screen-detection plugin's
//! `plugin.<producer>.agent.state.changed`, about 0.3 a second each, so about
//! 93 of each in 5 minutes. A report that says again what the daemon already
//! holds (the same state, source and session) moves only a time. This guard
//! sends such reports on a real on-disk registry and counts journal rows,
//! registry commits, WAL frame bytes and database pages; none may move. Rows
//! and bytes are counted, not timed. The controls prove that the counters see
//! a real change.

use std::collections::BTreeMap;

use super::*;

/// Agents of the session (Lawrence's daemon had 170).
const AGENTS: usize = 170;
/// Agents that report again and again (20 agents, one report a minute, for 5
/// minutes: 100 reports, his 93 rounded up).
const REPORTERS: usize = 20;
/// Simulated minutes, one equal report of each reporter a minute.
const MINUTES: usize = 5;

struct Agent {
    terminal: TerminalPublicId,
    surface: SurfaceId,
}

/// A session of `workspaces` workspaces with `AGENTS` terminals spread over
/// them.
fn session_with_terminals(workspaces: usize, root: &Path) -> (Arc<Mux>, Vec<Agent>) {
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
struct Written {
    journal_head: u64,
    commits: u64,
    wal_frame_bytes: u64,
    database_bytes: u64,
}

fn written(mux: &Arc<Mux>) -> Written {
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
    }
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

/// Let the wall clock pass the last report, as a minute does in the field:
/// the next equal report carries a later time.
fn tick() {
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
fn equal_agent_reports_write_nothing(workspaces: usize, source: AgentSource) {
    let root = std::env::temp_dir()
        .join(format!("cmux-reports-at-rest-{}", crate::workspace_registry::new_uuid_v4()));
    let (mux, agents) = session_with_terminals(workspaces, &root);
    for (index, agent) in agents.iter().take(REPORTERS).enumerate() {
        let record = mux
            .report_agent(agent.surface, AgentState::Working, source, report_session(index))
            .unwrap();
        assert_eq!(record.state, AgentState::Working, "setup: the first report is the record");
    }
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
            assert_eq!(record.source, source);
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
    equal_agent_reports_write_nothing(1, AgentSource::Hook);
}

#[test]
fn equal_agent_reports_write_nothing_in_a_large_session() {
    equal_agent_reports_write_nothing(60, AgentSource::Hook);
}

#[test]
fn equal_agent_reports_write_nothing_in_a_real_session() {
    equal_agent_reports_write_nothing(826, AgentSource::Hook);
}

/// A socket reporter (a poller) that says the same state again.
#[test]
fn equal_agent_reports_of_a_socket_reporter_write_nothing() {
    equal_agent_reports_write_nothing(60, AgentSource::Socket);
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
    mux.report_agent(agent.surface, AgentState::Working, AgentSource::Hook, report_session(0))
        .unwrap();
    let before = written(&mux);

    tick();
    let record = mux
        .report_agent(agent.surface, AgentState::Blocked, AgentSource::Hook, report_session(0))
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
