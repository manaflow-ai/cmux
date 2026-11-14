//! A plugin report that repeats what the roster holds from it writes nothing.
//!
//! The screen-detection plugin sends its `blocked` state again each 800 ms
//! while a dialog is visible (`STABLE_BLOCKER_REFRESH_MS`). On Lawrence's
//! daemon, 2026-11-10, 6 % of the journal rows were its
//! `plugin.<producer>.agent.state.changed` and 6 % were `agent.report`. While
//! the plugin owns the terminal's roster row, each refresh was one plugin row
//! and one projection commit (`agent.report`) that moved only a time.
//!
//! This guard holds a dialog on the screen for 5 simulated minutes (375
//! refreshes) through the journal ingress the plugin uses, on a real on-disk
//! registry, and counts journal rows, resource revisions, registry commits,
//! WAL frame bytes and database pages; none may move. Rows and bytes are
//! counted, not timed. The controls prove that the counters see a real
//! change: another state, or another plugin child, is a row.

use serde_json::{Value, json};

use super::agent_reports_at_rest::{Agent, kinds_after, session_with_terminals, tick, written};
use super::*;

const PLUGIN: &str = "screen_refresh_test";
/// 5 minutes at one refresh each 800 ms.
const REFRESHES: usize = 375;

fn plugin_kind() -> String {
    format!("plugin.{PLUGIN}.agent.state.changed")
}

fn put_plugin_manifest(mux: &Mux) {
    let event = |name: &str| crate::JournalEventSchema {
        kind: format!("plugin.{PLUGIN}.agent.{name}"),
        schema_version: 1,
        class: crate::JournalClass::State,
        replay: crate::JournalReplayPolicy::Advisory,
        sensitivity: crate::JournalSensitivity::Metadata,
        payload_schema: json!({"type":"object"}),
    };
    let manifest = crate::JournalProducerManifest {
        producer_id: PLUGIN.into(),
        namespace: format!("plugin.{PLUGIN}"),
        manifest_version: 1,
        max_sensitivity: crate::JournalSensitivity::Metadata,
        permissions: vec![format!("journal.append.plugin.{PLUGIN}")],
        events: vec![event("state.changed"), event("session.ended")],
    };
    mux.put_journal_producer(&manifest, "test", "screen-refresh-manifest").unwrap();
}

/// One report of the screen plugin's child `generation` about the agent
/// process `pid:42` on `agent`'s terminal, observed now, through the journal
/// ingress the plugin's `session.journal.append` reaches.
fn screen_with_key(
    mux: &Mux,
    agent: &Agent,
    state: &str,
    generation: u64,
    key: &str,
) -> crate::JournalAppendCommit {
    let ingress = crate::JournalIngress {
        producer_id: PLUGIN.into(),
        manifest_version: 1,
        kind: plugin_kind(),
        schema_version: 1,
        occurred_at_ms: None,
        subjects: vec![crate::JournalSubject {
            kind: "terminal".into(),
            id: agent.terminal.to_string(),
        }],
        sensitivity: None,
        payload: json!({
            "format": crate::journal_reducers::AGENT_PLUGIN_FORMAT,
            "plugin": {"id": PLUGIN, "version": 1},
            "adapter": {"id": "claude", "version": 1},
            "event": "state.changed",
            "normalized": {
                "state": state,
                "source_session": "pid:42",
                "observed_at_ms": crate::workspace_registry::unix_epoch_ms().unwrap().to_string(),
                "plugin_generation": generation.to_string(),
            },
            "native": {"visible": {"blocker": state == "blocked"}},
        }),
        causation_id: None,
        correlation_id: None,
    };
    mux.append_journal_ingress(&ingress, "screen", key).unwrap()
}

fn screen(mux: &Mux, agent: &Agent, state: &str, generation: u64) -> crate::JournalAppendCommit {
    let key = format!("screen-refresh-{}", crate::workspace_registry::new_uuid_v4());
    screen_with_key(mux, agent, state, generation, &key)
}

fn public_agents(mux: &Mux) -> Vec<Value> {
    let snapshot = crate::resource_api::public_session_snapshot(settled(mux)).unwrap();
    snapshot["agents"].as_array().unwrap().clone()
}

/// What a roster reader sees of the terminal: its state and source.
fn roster_row(mux: &Mux, agent: &Agent) -> Option<(String, String)> {
    let host = settled(mux).agent_roster.lock().unwrap();
    host.roster
        .entries
        .get(agent.terminal.as_str())
        .map(|entry| (entry.state.clone(), entry.source.clone()))
}

/// A session of `workspaces` workspaces where the plugin owns the roster row
/// of one terminal and sees a dialog on it.
fn session_with_a_visible_dialog(workspaces: usize, root: &Path) -> (Arc<Mux>, Vec<Agent>) {
    let (mux, agents) = session_with_terminals(workspaces, root);
    put_plugin_manifest(&mux);
    let agent = &agents[0];
    screen(&mux, agent, "working", 1);
    tick();
    screen(&mux, agent, "blocked", 1);
    assert_eq!(
        roster_row(&mux, agent),
        Some(("blocked".into(), "plugin".into())),
        "setup: the plugin owns the terminal's row"
    );
    (mux, agents)
}

/// A dialog stays on the screen: `REFRESHES` equal reports write nothing, and
/// every reader of the roster sees the row it saw before.
fn equal_plugin_refreshes_write_nothing(workspaces: usize) {
    let session = "reports-at-rest";
    let root = std::env::temp_dir()
        .join(format!("cmux-plugin-refresh-{}", crate::workspace_registry::new_uuid_v4()));
    let (mux, agents) = session_with_a_visible_dialog(workspaces, &root);
    let agent = &agents[0];
    let before = written(&mux);
    let public_before = public_agents(&mux);
    let listed_before = mux.list_agents(Some(agent.surface), None);
    assert_eq!(listed_before.len(), 1);

    for _refresh in 0..REFRESHES {
        tick();
        let answer = screen(&mux, agent, "blocked", 1);
        assert!(
            answer.sequence > 0 && (1..=128).contains(&answer.event_id.len()),
            "the plugin gets a receipt: {answer:?}"
        );
    }

    let after = written(&mux);
    let rows = kinds_after(&mux, before.journal_head);
    assert_eq!(
        after,
        before,
        "a dialog visible for 5 minutes in {workspaces} workspaces, {REFRESHES} equal refreshes: \
         {} journal rows {rows:?}, {} resource revisions, {} registry commits, {} WAL frame \
         bytes, {} bytes of database pages. A report that repeats the stored one must write nothing",
        after.journal_head - before.journal_head,
        after.resource_revision - before.resource_revision,
        after.commits - before.commits,
        after.wal_frame_bytes - before.wal_frame_bytes,
        after.database_bytes.saturating_sub(before.database_bytes),
    );
    // The roster's readers see the same row: the fold, a client's list, and
    // the public snapshot that `session.events` starts from.
    assert_eq!(roster_row(&mux, agent), Some(("blocked".into(), "plugin".into())));
    let listed = mux.list_agents(Some(agent.surface), None);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].state, AgentState::Blocked);
    assert_eq!(listed[0].source, AgentSource::Plugin);
    assert_eq!(public_agents(&mux), public_before);
    let entries_before = settled(&mux).agent_roster.lock().unwrap().roster.entries.clone();
    mux.shutdown();
    drop(mux);

    // A fold after a restart gives the same roster.
    let reopened = open_persistent_test_mux(session, &root);
    let entries_after = settled(&reopened).agent_roster.lock().unwrap().roster.entries.clone();
    assert_eq!(entries_after, entries_before, "the roster after the restart is the one before");
    reopened.shutdown();
    drop(reopened);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn equal_plugin_refreshes_write_nothing_in_a_light_session() {
    equal_plugin_refreshes_write_nothing(1);
}

#[test]
fn equal_plugin_refreshes_write_nothing_in_a_large_session() {
    equal_plugin_refreshes_write_nothing(60);
}

#[test]
fn equal_plugin_refreshes_write_nothing_in_a_real_session() {
    equal_plugin_refreshes_write_nothing(826);
}

/// The counters see a real change: a report with another state, and a report
/// of another plugin child (generation), are each exactly one plugin row.
#[test]
fn equal_plugin_refreshes_control_a_new_state_or_child_is_one_row() {
    let root = std::env::temp_dir()
        .join(format!("cmux-plugin-refresh-control-{}", crate::workspace_registry::new_uuid_v4()));
    let (mux, agents) = session_with_a_visible_dialog(1, &root);
    let agent = &agents[0];
    for _ in 0..3 {
        tick();
        screen(&mux, agent, "blocked", 1);
    }

    let before = written(&mux);
    tick();
    let changed = screen(&mux, agent, "working", 1);
    assert!(!changed.replayed, "{changed:?}");
    let after = written(&mux);
    let rows = kinds_after(&mux, before.journal_head);
    assert_eq!(rows.get(&plugin_kind()), Some(&1), "a new state is one plugin row: {rows:?}");
    assert_eq!(rows.get("agent.report"), Some(&1), "and one projection row: {rows:?}");
    assert_eq!(after.journal_head - before.journal_head, 2, "{rows:?}");
    assert_eq!(roster_row(&mux, agent), Some(("working".into(), "plugin".into())));

    let before = written(&mux);
    tick();
    let restarted = screen(&mux, agent, "working", 2);
    assert!(!restarted.replayed, "{restarted:?}");
    let rows = kinds_after(&mux, before.journal_head);
    assert_eq!(
        rows.get(&plugin_kind()),
        Some(&1),
        "a new plugin child is one plugin row: {rows:?}"
    );
    let generation = settled(&mux)
        .agent_roster
        .lock()
        .unwrap()
        .roster
        .entries
        .get(agent.terminal.as_str())
        .and_then(|entry| entry.producer_generation.clone());
    assert_eq!(generation.as_deref(), Some("2"));
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// A plugin that got no answer sends its report again with the same
/// idempotency key. The registry holds no receipt of a report answered at
/// rest, so a reader of the rows that came since must not make the retry a
/// second row: it gets its first answer.
#[test]
fn equal_plugin_refreshes_a_retry_gets_its_first_answer_after_a_follower_came() {
    let root = std::env::temp_dir()
        .join(format!("cmux-plugin-refresh-retry-{}", crate::workspace_registry::new_uuid_v4()));
    let (mux, agents) = session_with_a_visible_dialog(1, &root);
    let agent = &agents[0];
    tick();
    let first = screen_with_key(&mux, agent, "blocked", 1, "refresh-retried");
    assert!(first.replayed, "setup: the refresh is answered at rest: {first:?}");
    let follower = mux.follow_journal(
        JournalFollowerFilter {
            client: 0,
            stream_id: "stream_test".into(),
            remote: false,
            kinds: vec!["agent.report".into()],
            max_sensitivity: Some(crate::JournalSensitivity::Sensitive),
        },
        |kind, _| kind == "agent.report",
    );

    let before = written(&mux);
    let again = screen_with_key(&mux, agent, "blocked", 1, "refresh-retried");
    assert_eq!(
        (again.sequence, again.event_id.as_str(), again.replayed),
        (first.sequence, first.event_id.as_str(), true),
        "the retry of a refresh answered at rest must get its first answer"
    );
    assert_eq!(written(&mux), before, "the retry of a refresh answered at rest wrote a row");
    drop(follower);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// A live journal follower whose kind filter matches the plugin's kind or
/// `agent.report` reads the journal and nothing else: while it lives, and
/// for the grace after it left, each refresh is a plugin row and its
/// projection row, as for the hook rows (`agent_hooks_at_rest.rs`).
#[test]
fn equal_plugin_refreshes_are_rows_while_a_journal_follower_reads_them() {
    let root = std::env::temp_dir()
        .join(format!("cmux-plugin-refresh-follower-{}", crate::workspace_registry::new_uuid_v4()));
    let (mux, agents) = session_with_a_visible_dialog(1, &root);
    let agent = &agents[0];

    // A follower that is never sent the plugin's rows keeps none.
    let stream = |kinds: &[&str]| JournalFollowerFilter {
        client: 0,
        stream_id: "stream_test".into(),
        remote: false,
        kinds: kinds.iter().map(|kind| kind.to_string()).collect(),
        max_sensitivity: Some(crate::JournalSensitivity::Metadata),
    };
    let other =
        mux.follow_journal(stream(&["terminal.*"]), |kind, _| kind.starts_with("terminal."));
    let before = written(&mux);
    tick();
    let answer = screen(&mux, agent, "blocked", 1);
    assert!(answer.replayed, "a follower of terminal.* reads no plugin row: {answer:?}");
    assert_eq!(written(&mux), before);
    // `agent.report` is sensitive: a follower at the metadata limit is never
    // sent it, and it does not ask for the plugin's kind.
    let low = mux.follow_journal(stream(&["agent.report"]), |kind, sensitivity| {
        kind == "agent.report" && sensitivity != crate::JournalSensitivity::Sensitive
    });
    tick();
    let answer = screen(&mux, agent, "blocked", 1);
    assert!(answer.replayed, "agent.report at the metadata limit reads no row: {answer:?}");
    assert_eq!(written(&mux), before);
    drop((other, low));

    let follower = mux.follow_journal(stream(&["agent.report"]), |kind, _| kind == "agent.report");
    let before = written(&mux);
    for _ in 0..3 {
        tick();
        let answer = screen(&mux, agent, "blocked", 1);
        assert!(!answer.replayed, "a follower reads the row: {answer:?}");
        settled(&mux);
    }
    let rows = kinds_after(&mux, before.journal_head);
    assert_eq!(rows.get(&plugin_kind()), Some(&3), "{rows:?}");
    assert_eq!(rows.get("agent.report"), Some(&3), "{rows:?}");

    drop(follower);
    mux.pass_journal_follower_grace_for_test();
    let before = written(&mux);
    tick();
    let answer = screen(&mux, agent, "blocked", 1);
    assert!(answer.replayed, "no reader is left: {answer:?}");
    assert_eq!(written(&mux), before);
    assert_eq!(roster_row(&mux, agent), Some(("blocked".into(), "plugin".into())));
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}
