//! Agents that work and change no durable state write nothing.
//!
//! Lawrence's daemon, 2026-11-10 (826 workspaces, 170 agents, nobody at the
//! keyboard): 64 % of the journal rows were `agent.state.changed`, about 3.3 a
//! second, 2,146 bytes each, 612 MB a day, each one a registry commit. A tool
//! call, a notification or a hook cmux has no name for moves no durable state:
//! the roster keeps its row and the history list keeps its session. They are
//! live state for clients (presence), not journal.
//!
//! This guard runs that stretch on a real on-disk registry: every agent is in
//! a turn and reports tool calls for some simulated minutes. It counts journal
//! rows, registry commits, WAL frame bytes and database pages; none may move.
//! Rows and bytes are counted, not timed, so the result does not depend on the
//! machine. The control proves that the counters see a real change: a turn's
//! start and end still append their rows.

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::*;

/// Agents of the session (Lawrence's daemon had 170).
const AGENTS: usize = 170;
/// Simulated minutes at rest.
const MINUTES: usize = 5;
/// Reports of one agent a minute (3.3 rows a second from 170 agents is about
/// 1.2 a minute each; a busy agent sends more, so the guard uses 3).
const REPORTS_PER_AGENT_PER_MINUTE: usize = 3;
const CWD: &str = "/work/project";

struct Agent {
    terminal: TerminalPublicId,
    surface: SurfaceId,
    session: String,
}

/// A session of `workspaces` workspaces with `AGENTS` terminals spread over
/// them, each terminal with an agent in a turn.
fn session_with_agents_in_a_turn(workspaces: usize, root: &Path) -> (Arc<Mux>, Vec<Agent>) {
    let mux = open_persistent_test_mux("agents-at-rest", root);
    // The maintenance worker checkpoints and seals on its own clock; the
    // counters below must see only what the hooks cause.
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
            Agent { terminal, surface, session: format!("session-{index}") }
        })
        .collect::<Vec<_>>();
    for agent in &agents {
        send(&mux, agent, "SessionStart", json!({}));
        send(&mux, agent, "UserPromptSubmit", json!({ "prompt": "go on" }));
    }
    for agent in &agents {
        assert_eq!(
            settled(&mux).agent_roster_state_now_for_test(agent.terminal.as_str()).as_deref(),
            Some("working"),
            "setup: every agent is in a turn"
        );
    }
    (mux, agents)
}

/// One hook of `agent` through the real journal ingress path, as its hook
/// helper sends it. Returns the answer the helper gets.
fn send(
    mux: &Arc<Mux>,
    agent: &Agent,
    event: &str,
    mut native: Value,
) -> crate::JournalAppendCommit {
    native["session_id"] = json!(agent.session);
    native["cwd"] = json!(CWD);
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(agent.terminal.as_str()),
        native,
    )
    .unwrap();
    let key = format!("at-rest-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap()
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

/// The next presence of `surface` on `events`, skipping every other event.
fn next_presence(events: &MuxEventReceiver, surface: SurfaceId) -> AgentPresence {
    loop {
        match events.recv_timeout(Duration::from_secs(5)) {
            Ok(MuxEvent::AgentPresenceChanged { surface: changed, presence: Some(presence) })
                if changed == surface =>
            {
                return presence.as_ref().clone();
            }
            Ok(_) => continue,
            Err(error) => panic!("no agent presence for the tool call: {error:?}"),
        }
    }
}

/// `MINUTES` at rest: each agent reports tool calls, notifications and a hook
/// cmux has no name for. Nothing durable changes, so nothing is written.
fn agents_at_rest_write_nothing(workspaces: usize) {
    let root = std::env::temp_dir()
        .join(format!("cmux-agents-at-rest-{}", crate::workspace_registry::new_uuid_v4()));
    let (mux, agents) = session_with_agents_in_a_turn(workspaces, &root);
    let before = written(&mux);

    let mut hooks = 0_usize;
    for report in 0..MINUTES * REPORTS_PER_AGENT_PER_MINUTE {
        for agent in &agents {
            let file = format!("{CWD}/src/file_{report}.rs");
            let answer = match report % 4 {
                0 => send(
                    &mux,
                    agent,
                    "PreToolUse",
                    json!({ "tool_name": "Read", "tool_input": { "file_path": file } }),
                ),
                1 => send(
                    &mux,
                    agent,
                    "PostToolUse",
                    json!({ "tool_name": "Read", "tool_input": { "file_path": file } }),
                ),
                2 => send(&mux, agent, "Notification", json!({ "message": "still at work" })),
                _ => send(&mux, agent, "PreCompact", json!({})),
            };
            // The hook helper reads a decimal sequence and an event id of 1
            // to 128 characters from the answer.
            assert!(
                answer.sequence > 0 && (1..=128).contains(&answer.event_id.len()),
                "the hook's caller gets a receipt: {answer:?}"
            );
            hooks += 1;
        }
    }
    // The live effect still reaches clients: a tool call shows its file.
    let events = mux.subscribe();
    let shown = &agents[AGENTS / 2];
    send(
        &mux,
        shown,
        "PreToolUse",
        json!({ "tool_name": "Edit", "tool_input": { "file_path": "/work/project/src/shown.rs" } }),
    );
    hooks += 1;
    let presence = next_presence(&events, shown.surface);
    assert_eq!(presence.path.as_deref(), Some("/work/project/src/shown.rs"));
    assert_eq!(presence.tool.as_deref(), Some("Edit"));
    drop(events);

    let after = written(&mux);
    let rows = kinds_after(&mux, before.journal_head);
    assert_eq!(
        after,
        before,
        "{MINUTES} minutes at rest, {AGENTS} agents in {workspaces} workspaces, {hooks} hooks that \
         change no durable state: {} journal rows {rows:?}, {} registry commits, {} WAL frame \
         bytes, {} bytes of database pages. A hook that changes no durable state must write nothing",
        after.journal_head - before.journal_head,
        after.commits - before.commits,
        after.wal_frame_bytes - before.wal_frame_bytes,
        after.database_bytes.saturating_sub(before.database_bytes),
    );
    for agent in &agents {
        assert_eq!(
            mux.agent_roster_state_now_for_test(agent.terminal.as_str()).as_deref(),
            Some("working"),
            "the roster keeps every agent in its turn"
        );
    }
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn agents_at_rest_write_nothing_in_a_light_session() {
    agents_at_rest_write_nothing(1);
}

#[test]
fn agents_at_rest_write_nothing_in_a_large_session() {
    agents_at_rest_write_nothing(60);
}

#[test]
fn agents_at_rest_write_nothing_in_a_real_session() {
    agents_at_rest_write_nothing(826);
}

/// The control: the same counters see a durable change. Each agent ends its
/// turn and starts the next one; each of the two hooks appends its row.
#[test]
fn agents_at_rest_control_a_turn_still_appends_its_rows() {
    let root = std::env::temp_dir()
        .join(format!("cmux-agents-at-rest-control-{}", crate::workspace_registry::new_uuid_v4()));
    let (mux, agents) = session_with_agents_in_a_turn(1, &root);
    let before = written(&mux);
    for agent in &agents {
        send(&mux, agent, "Stop", json!({}));
        send(&mux, agent, "UserPromptSubmit", json!({ "prompt": "next" }));
    }
    let after = written(&mux);
    let rows = kinds_after(&mux, before.journal_head);
    assert_eq!(
        (rows.get("agent.turn.completed"), rows.get("agent.turn.started")),
        (Some(&AGENTS), Some(&AGENTS)),
        "each turn end and each turn start appends exactly one row: {rows:?}"
    );
    assert!(
        after.commits >= before.commits + 2 * AGENTS as u64
            && after.wal_frame_bytes > before.wal_frame_bytes,
        "the counters see the turn rows: {before:?} -> {after:?}"
    );
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

fn one_agent(name: &str) -> (Arc<Mux>, Agent, std::path::PathBuf) {
    let root = std::env::temp_dir()
        .join(format!("cmux-agents-at-rest-{name}-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("agents-at-rest", &root);
    mux.stop_journal_maintenance();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap().key;
    let raw = "00000000000040008000000000000a01";
    let surface = mux
        .seed_running_terminal_for_test(raw, "10000000000040008000000000000a01", &workspace)
        .unwrap();
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(raw).unwrap().unwrap();
    let agent = Agent { terminal, surface, session: "session-one".into() };
    send(&mux, &agent, "SessionStart", json!({}));
    send(&mux, &agent, "UserPromptSubmit", json!({ "prompt": "go on" }));
    (mux, agent, root)
}

/// A completed tool call resumes a blocked agent: that is a durable change,
/// so its row is appended and the roster moves.
#[test]
fn agents_at_rest_a_tool_call_that_resumes_a_blocked_agent_appends_its_row() {
    let (mux, agent, root) = one_agent("resume");
    send(&mux, &agent, "PermissionRequest", json!({ "tool_name": "Bash" }));
    assert_eq!(
        settled(&mux).agent_roster_state_now_for_test(agent.terminal.as_str()).as_deref(),
        Some("blocked")
    );
    let before = written(&mux);
    let answer = send(&mux, &agent, "PostToolUse", json!({ "tool_name": "Bash" }));
    assert!(!answer.replayed, "the resume is a new row");
    let rows = kinds_after(&mux, before.journal_head);
    assert_eq!(rows.get("agent.state.changed"), Some(&1), "{rows:?}");
    assert_eq!(
        settled(&mux).agent_roster_state_now_for_test(agent.terminal.as_str()).as_deref(),
        Some("working")
    );
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// What the history list keeps of a session (its directory, its session id)
/// still reaches the journal: the first report with a new value is a row,
/// the next equal one is not.
#[test]
fn agents_at_rest_a_new_directory_or_session_appends_one_row() {
    let (mux, mut agent, root) = one_agent("facts");
    let tool = || json!({ "tool_name": "Read", "tool_input": { "file_path": "/a.rs" } });
    let rows_of = |mux: &Arc<Mux>, agent: &Agent, native: Value| {
        let before = written(mux);
        send(mux, agent, "PreToolUse", native);
        written(mux).journal_head - before.journal_head
    };
    assert_eq!(rows_of(&mux, &agent, tool()), 0, "an equal report");
    let mut moved = tool();
    moved["cwd"] = json!("/work/other");
    // `send` sets the directory; send this one by hand.
    let moved_rows = {
        let before = written(&mux);
        moved["session_id"] = json!(agent.session);
        let ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            "PreToolUse",
            Some(agent.terminal.as_str()),
            moved.clone(),
        )
        .unwrap();
        for key in ["moved-1", "moved-2"] {
            mux.append_journal_ingress(&ingress, "test", key).unwrap();
        }
        written(&mux).journal_head - before.journal_head
    };
    assert_eq!(moved_rows, 1, "a new directory is one row; the equal report after it is none");
    agent.session = "session-two".into();
    assert_eq!(rows_of(&mux, &agent, tool()), 1, "a new agent session is a row");
    assert_eq!(rows_of(&mux, &agent, tool()), 0, "the equal report after it is none");
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// A start folds the journal into the roster. The reports that got no row
/// changed nothing in it, so a fold of the journal alone gives the roster
/// the running daemon holds.
#[test]
fn agents_at_rest_a_fold_of_the_journal_gives_the_live_roster() {
    let (mux, agent, root) = one_agent("fold");
    for report in 0..6 {
        let event = if report % 2 == 0 { "PreToolUse" } else { "PostToolUse" };
        send(&mux, &agent, event, json!({ "tool_name": "Read" }));
    }
    send(&mux, &agent, "PermissionRequest", json!({ "tool_name": "Bash" }));
    send(&mux, &agent, "PostToolUse", json!({ "tool_name": "Bash" }));
    send(&mux, &agent, "Notification", json!({ "message": "still at work" }));
    let live = settled(&mux).agent_roster.lock().unwrap().roster.entries.clone();
    assert_eq!(
        live.get(agent.terminal.as_str()).map(|entry| entry.state.as_str()),
        Some("working")
    );

    let mut folded = crate::journal_reducers::AgentRoster::default();
    let mut sequence = 0;
    loop {
        let page = mux.session_journal_after(sequence, 500).unwrap();
        let Some(last) = page.records.last() else { break };
        sequence = last.sequence;
        for record in &page.records {
            folded.apply(&crate::journal_reducers::RosterEvent::from_record(record));
        }
    }
    assert_eq!(folded.entries, live, "the journal alone folds to the live roster");
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// A hook helper that got no answer sends the report again with the same
/// idempotency key. The retry gets the first answer and changes nothing:
/// the presence of a tool call that already ended does not come back.
#[test]
fn agents_at_rest_a_retried_report_has_no_second_effect() {
    let (mux, agent, root) = one_agent("retry");
    let report = |event: &str, file: &str, key: &str| {
        let native = json!({
            "session_id": agent.session,
            "cwd": CWD,
            "tool_name": "Read",
            "tool_input": { "file_path": file },
        });
        let ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(agent.terminal.as_str()),
            native,
        )
        .unwrap();
        mux.append_journal_ingress(&ingress, "test", key).unwrap()
    };
    let before = written(&mux);
    let first = report("PreToolUse", "/work/project/one.rs", "retry-1");
    report("PreToolUse", "/work/project/two.rs", "retry-2");
    let events = mux.subscribe();
    let again = report("PreToolUse", "/work/project/one.rs", "retry-1");
    assert_eq!(again, first, "the retry gets the first answer");
    let deadline = Instant::now() + Duration::from_millis(300);
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        match events.recv_timeout(remaining) {
            Ok(MuxEvent::AgentPresenceChanged { presence, .. }) => {
                panic!("a retried report changed presence: {presence:?}")
            }
            Ok(_) => continue,
            Err(_) => break,
        }
    }
    assert_eq!(written(&mux), before, "no report of the three wrote a row");
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// A journal hook is delivered every row its filter matches. While one that
/// matches `agent.state.changed` is installed, each report is a row again;
/// a hook for other kinds changes nothing.
#[test]
fn agents_at_rest_a_journal_hook_for_the_kind_keeps_every_row() {
    let (mux, agent, root) = one_agent("journal-hook");
    let hook = |id: &str, kind: &str| crate::JournalHookManifest {
        hook_id: id.into(),
        manifest_version: 1,
        filter: crate::JournalHookFilter { kinds: vec![kind.into()], ..Default::default() },
        exec: crate::JournalHookExec {
            argv: vec!["/usr/bin/true".into()],
            timeout_ms: 1000,
            max_parallel: 1,
        },
        delivery: crate::JournalHookDeliveryPolicy {
            start: "tail".into(),
            retry: crate::JournalHookRetry { max_attempts: 1, backoff_ms: 0 },
        },
        permissions: vec!["journal.read".into()],
    };
    let tool_call_rows = |mux: &Arc<Mux>| {
        let head = mux.session_journal_head().unwrap();
        for _ in 0..3 {
            send(mux, &agent, "PreToolUse", json!({ "tool_name": "Read" }));
        }
        kinds_after(mux, head).get("agent.state.changed").copied().unwrap_or(0)
    };
    assert_eq!(tool_call_rows(&mux), 0, "no journal hook: no row");
    mux.put_journal_hook(&hook("other_kinds", "terminal.*"), "test", "hook-1").unwrap();
    assert_eq!(tool_call_rows(&mux), 0, "a hook for other kinds: no row");
    mux.put_journal_hook(&hook("agent_kinds", "agent.*"), "test", "hook-2").unwrap();
    assert_eq!(tool_call_rows(&mux), 3, "a hook for the kind is delivered every report");
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// A row whose producer gave up (the writer was slow) can still commit. The
/// daemon then does not know what the journal holds of the terminal's agent
/// session, so the next report is appended: after a late `agent.session.ended`
/// the history fold opens the session again only from a row.
#[test]
fn agents_at_rest_a_report_after_a_row_with_an_unknown_result_is_appended() {
    let (mux, agent, root) = one_agent("unknown");
    let tool_rows = |mux: &Arc<Mux>| {
        let head = mux.session_journal_head().unwrap();
        send(mux, &agent, "PreToolUse", json!({ "tool_name": "Read" }));
        kinds_after(mux, head).get("agent.state.changed").copied().unwrap_or(0)
    };
    assert_eq!(tool_rows(&mux), 0, "setup: an equal report writes nothing");

    // The session's end is admitted by the writer and held there: its
    // producer gets an error, then the row commits. Settle first, so the
    // hold takes this row and not a late write of the roster's owner.
    settled(&mux);
    let (entered, entered_receiver) = std::sync::mpsc::sync_channel(1);
    let (release, release_receiver) = std::sync::mpsc::sync_channel(1);
    mux.install_journal_after_commit_admission_for_test(entered, release_receiver);
    let ended = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "SessionEnd",
        Some(agent.terminal.as_str()),
        json!({ "session_id": agent.session, "cwd": CWD }),
    )
    .unwrap();
    assert_eq!(ended.kind, "agent.session.ended");
    // Read now: the held writer keeps the registry connection.
    let before_end = mux.session_journal_head().unwrap();
    let producer_mux = mux.clone();
    let producer = std::thread::spawn(move || {
        producer_mux.append_journal_ingress(&ended, "test", "unknown-result-1")
    });
    entered_receiver.recv_timeout(Duration::from_secs(5)).unwrap();
    let error = producer.join().unwrap().expect_err("the producer gives up on a held commit");
    release.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !kinds_after(&mux, before_end).contains_key("agent.session.ended") {
        assert!(Instant::now() < deadline, "the held row did not commit after {error:#}");
        std::thread::sleep(Duration::from_millis(10));
    }

    assert_eq!(
        tool_rows(&mux),
        1,
        "the report after a row with an unknown result ({error:#}) must be appended"
    );
    assert_eq!(tool_rows(&mux), 0, "the equal report after it writes nothing again");
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// A hook can arrive after its terminal closed (a session end from a shell
/// that exits). It must leave nothing in the per-terminal table: nothing
/// would ever remove it.
#[test]
fn agents_at_rest_a_report_for_a_closed_terminal_keeps_no_table_entry() {
    let (mux, agent, root) = one_agent("closed");
    assert_eq!(mux.agent_hook_slots_for_test(), 1, "setup: the open terminal has its entry");
    mux.remove_terminal_catalog_for_test(&agent.terminal).expect("the terminal was in the catalog");
    mux.purge_terminal_side_tables(&agent.terminal);
    assert_eq!(mux.agent_hook_slots_for_test(), 0, "the close removes the entry");
    for (event, key) in [("PreToolUse", "closed-1"), ("SessionEnd", "closed-2")] {
        let ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(agent.terminal.as_str()),
            json!({ "session_id": agent.session, "cwd": CWD, "tool_name": "Read" }),
        )
        .unwrap();
        // The answer for a closed terminal is not this test's subject.
        let _ = mux.append_journal_ingress(&ingress, "test", key);
    }
    assert_eq!(
        mux.agent_hook_slots_for_test(),
        0,
        "a report for a closed terminal left an entry in the table"
    );
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// A hook row whose projection failed waits for a retry
/// (`enqueue_agent_hook_pending`). Before reports at rest, the next hook of
/// the terminal was a row, and its projection ran the retry first
/// (`reconcile_preceding_agent_hooks`). A report at rest is no row, so it
/// must run the retry itself: a failed turn start must not wait for the
/// turn's end.
#[test]
fn agents_at_rest_a_report_at_rest_retries_a_pending_projection() {
    let (mux, agent, root) = one_agent("pending");
    let projected = |mux: &Arc<Mux>| {
        mux.agent_records.lock().unwrap().get(&agent.terminal).map(|record| record.state)
    };
    let pending = |mux: &Arc<Mux>| {
        mux.workspace_registry.lock().unwrap().pending_agent_hook_projections().unwrap().len()
    };
    send(&mux, &agent, "Stop", json!({}));
    assert_eq!(projected(&mux), Some(AgentState::Idle), "setup: the turn ended");
    assert_eq!(pending(&mux), 0, "setup: no projection waits");

    // The next turn's start is a journal row whose projection fails.
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
    let started = send(&mux, &agent, "UserPromptSubmit", json!({ "prompt": "next" }));
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();
    assert!(!started.replayed, "setup: the turn's start is a row: {started:?}");
    assert_eq!(pending(&mux), 1, "setup: the projection of the turn's start waits");
    assert_eq!(projected(&mux), Some(AgentState::Idle), "setup: the start is not projected");

    // A report that changes nothing: no row of its own, and the retry runs.
    let head = settled(&mux).session_journal_head().unwrap();
    let answer = send(&mux, &agent, "PreToolUse", json!({ "tool_name": "Read" }));
    assert_eq!(
        pending(&mux),
        0,
        "the report after a failed projection must run its retry (answer {answer:?})"
    );
    assert_eq!(
        projected(&mux),
        Some(AgentState::Working),
        "the turn's start is projected with the next report, not with the turn's end"
    );
    // The report itself is no row: its receipt is the one of the turn's
    // start, and the journal holds no row of the tool call.
    assert!(answer.replayed && answer.sequence == started.sequence, "{answer:?} {started:?}");
    let page = mux.session_journal_after(head, 500).unwrap();
    assert!(
        page.records.iter().all(|record| record.payload["native_event"] != "PreToolUse"),
        "the report at rest got a journal row"
    );
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// One lifecycle hook of `agent`, as its helper builds it.
fn lifecycle_hook(agent: &Agent, event: &str) -> crate::JournalIngress {
    crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(agent.terminal.as_str()),
        json!({ "session_id": agent.session, "cwd": CWD }),
    )
    .unwrap()
}

/// Rows of one more equal tool call of `agent`.
fn tool_call_rows(mux: &Arc<Mux>, agent: &Agent) -> usize {
    let head = mux.session_journal_head().unwrap();
    send(mux, agent, "PreToolUse", json!({ "tool_name": "Read" }));
    kinds_after(mux, head).get("agent.state.changed").copied().unwrap_or(0)
}

/// A hook's retry that the registry answers (`replayed`) tells the table
/// nothing: nobody noted its first result here, so the table forgets what
/// the journal holds of the terminal and the next report is a row.
#[test]
fn agents_at_rest_a_report_after_a_retry_the_registry_answered_is_appended() {
    let (mux, agent, root) = one_agent("replayed");
    let stop = lifecycle_hook(&agent, "Stop");
    let first = mux.append_journal_ingress(&stop, "test", "replayed-1").unwrap();
    assert!(!first.replayed, "setup: the turn's end is a row: {first:?}");
    assert_eq!(tool_call_rows(&mux, &agent), 0, "setup: an equal report writes nothing");

    let again = mux.append_journal_ingress(&stop, "test", "replayed-1").unwrap();
    assert!(again.replayed, "setup: the registry answers the retry: {again:?}");
    assert_eq!(again.sequence, first.sequence);

    assert_eq!(
        tool_call_rows(&mux, &agent),
        1,
        "the report after a retry the registry answered must be appended"
    );
    assert_eq!(tool_call_rows(&mux, &agent), 0, "the equal report after it writes nothing again");
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// Two hooks of one terminal are on their way at once. The result of the
/// second is not known (its producer gave up; its row can still commit), then
/// the first, sent before it, commits. The first one's facts can be older
/// than the unknown row's, so the table must not note them: the next report
/// is a row. The table's own functions are driven in that order, as
/// `append_journal_ingress` calls them; the first hook's receipt stands for
/// its commit.
#[test]
fn agents_at_rest_a_hook_sent_before_an_unknown_result_does_not_note_its_facts() {
    let (mux, agent, root) = one_agent("unknown-order");
    assert_eq!(tool_call_rows(&mux, &agent), 0, "setup: an equal report writes nothing");

    let first = lifecycle_hook(&agent, "Stop");
    let on_its_way = mux.agent_hook_in_flight(&first);
    assert!(on_its_way.is_some(), "setup: the terminal has a table entry");
    let second = lifecycle_hook(&agent, "SessionEnd");
    mux.note_agent_hook_result(&second, None, None, "test", "unknown-order-2");
    let commit = crate::JournalAppendCommit {
        sequence: mux.session_journal_head().unwrap() + 1,
        event_id: "unknown-order-first".into(),
        replayed: false,
    };
    mux.note_agent_hook_result(
        &first,
        Some(&commit),
        on_its_way.as_ref(),
        "test",
        "unknown-order-1",
    );
    drop(on_its_way);

    assert_eq!(
        tool_call_rows(&mux, &agent),
        1,
        "a hook sent before a row with an unknown result must not note its facts"
    );
    assert_eq!(tool_call_rows(&mux, &agent), 0, "the equal report after it writes nothing again");
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}
