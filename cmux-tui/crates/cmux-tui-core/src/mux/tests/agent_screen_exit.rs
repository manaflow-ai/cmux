//! A hook session whose agent the screen saw exit with no `SessionEnd` (a
//! killed harness, manaflow-ai/cmux#20874): the public row goes and the next
//! session's hooks own the terminal, in the hook projector as in the roster.

use super::*;

const PLUGIN: &str = "screen_exit_test";

fn put_plugin_manifest(mux: &Mux) {
    let event = |name: &str| crate::JournalEventSchema {
        kind: format!("plugin.{PLUGIN}.agent.{name}"),
        schema_version: 1,
        class: crate::JournalClass::State,
        replay: crate::JournalReplayPolicy::Advisory,
        sensitivity: crate::JournalSensitivity::Metadata,
        payload_schema: serde_json::json!({"type":"object"}),
    };
    let manifest = crate::JournalProducerManifest {
        producer_id: PLUGIN.into(),
        namespace: format!("plugin.{PLUGIN}"),
        manifest_version: 1,
        max_sensitivity: crate::JournalSensitivity::Metadata,
        permissions: vec![format!("journal.append.plugin.{PLUGIN}")],
        events: vec![event("state.changed"), event("session.ended")],
    };
    mux.put_journal_producer(&manifest, "test", "screen-exit-manifest").unwrap();
}

/// A Claude Code hook of `session`, stamped as observed at `at_ms`.
fn hook(mux: &Mux, terminal_id: &TerminalPublicId, session: &str, event: &str, at_ms: u64) {
    let mut ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal_id.as_str()),
        serde_json::json!({"session_id": session}),
    )
    .unwrap();
    crate::agent_hooks::stamp_agent_hook_observed_at(&mut ingress, at_ms);
    mux.append_journal_ingress(&ingress, "test", &format!("hook-{session}-{event}-{at_ms}"))
        .unwrap();
}

/// The screen plugin's report about the agent process `pid:42`.
fn screen(mux: &Mux, terminal_id: &TerminalPublicId, state: &str, at_ms: u64) {
    let event = if state == "done" { "session.ended" } else { "state.changed" };
    let ingress = crate::JournalIngress {
        producer_id: PLUGIN.into(),
        manifest_version: 1,
        kind: format!("plugin.{PLUGIN}.agent.{event}"),
        schema_version: 1,
        occurred_at_ms: None,
        subjects: vec![crate::JournalSubject {
            kind: "terminal".into(),
            id: terminal_id.to_string(),
        }],
        sensitivity: None,
        payload: serde_json::json!({
            "format": crate::journal_reducers::AGENT_PLUGIN_FORMAT,
            "plugin": {"id": PLUGIN, "version": 1},
            "adapter": {"id": "claude", "version": 1},
            "event": event,
            "normalized": {
                "state": state,
                "source_session": "pid:42",
                "observed_at_ms": at_ms.to_string(),
            },
        }),
        causation_id: None,
        correlation_id: None,
    };
    mux.append_journal_ingress(&ingress, "screen", &format!("screen-{state}-{at_ms}")).unwrap();
}

/// Let the wall clock pass the last commit: the roster clamps a plugin's
/// observation to its commit time and orders it after a hook's report only
/// when it is later.
fn tick() {
    let start = crate::workspace_registry::unix_epoch_ms().unwrap();
    while crate::workspace_registry::unix_epoch_ms().unwrap() <= start {
        std::hint::spin_loop();
    }
}

fn public_agents(mux: &Mux) -> Vec<Value> {
    let snapshot = crate::resource_api::public_session_snapshot(settled(mux)).unwrap();
    snapshot["agents"].as_array().unwrap().clone()
}

#[test]
fn the_next_session_after_a_screen_proven_exit_owns_the_public_row() {
    let mux = test_mux();
    put_plugin_manifest(&mux);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    let t0 = crate::workspace_registry::unix_epoch_ms().unwrap();

    hook(&mux, &terminal_id, "old", "SessionStart", t0);
    hook(&mux, &terminal_id, "old", "UserPromptSubmit", t0 + 1);
    tick();
    screen(&mux, &terminal_id, "working", t0 + 3_000);
    assert_eq!(public_agents(&mux).len(), 1);
    // The harness is killed: no `SessionEnd`, the screen sees it gone.
    tick();
    screen(&mux, &terminal_id, "done", t0 + 5_000);
    assert!(public_agents(&mux).is_empty(), "the killed agent's row goes");
    assert_eq!(roster_agent_state(&mux, &terminal_id), None);
    let fence = mux.agent_hook_fences.lock().unwrap()[&terminal_id].clone();
    assert!(fence.ended && fence.session_id == "old", "{fence:?}");
    let exit_at = fence.ended_at_ms.expect("the exit's observation ends the session");

    // A `Stop` the old session sent before it died arrives late.
    hook(&mux, &terminal_id, "old", "Stop", exit_at - 1);
    assert!(public_agents(&mux).is_empty(), "a late hook of the killed session stays out");
    assert_eq!(roster_agent_state(&mux, &terminal_id), None);

    hook(&mux, &terminal_id, "new", "SessionStart", exit_at + 1);
    hook(&mux, &terminal_id, "new", "UserPromptSubmit", exit_at + 2);
    let agents = public_agents(&mux);
    assert_eq!(agents.len(), 1, "{agents:?}");
    assert_eq!(agents[0]["state"], "working");
    assert_eq!(agents[0]["source"], "hook");
    assert_eq!(roster_agent_state(&mux, &terminal_id).as_deref(), Some("working"));
    assert_eq!(mux.agent_hook_fences.lock().unwrap()[&terminal_id].session_id, "new");
}

/// Ctrl+Z puts the shell in front, so the screen reads the agent gone; after
/// `fg` the same session's hooks own the row again, here as in the roster.
#[test]
fn a_suspended_session_brought_back_with_fg_gets_its_public_row_back() {
    let mux = test_mux();
    put_plugin_manifest(&mux);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    let t0 = crate::workspace_registry::unix_epoch_ms().unwrap();

    hook(&mux, &terminal_id, "same", "SessionStart", t0);
    hook(&mux, &terminal_id, "same", "UserPromptSubmit", t0 + 1);
    tick();
    screen(&mux, &terminal_id, "working", t0 + 3_000);
    tick();
    screen(&mux, &terminal_id, "done", t0 + 5_000);
    assert!(public_agents(&mux).is_empty());
    let exit_at = mux.agent_hook_fences.lock().unwrap()[&terminal_id].ended_at_ms.unwrap();

    hook(&mux, &terminal_id, "same", "UserPromptSubmit", exit_at + 1);
    let agents = public_agents(&mux);
    assert_eq!(agents.len(), 1, "{agents:?}");
    assert_eq!(agents[0]["state"], "working");
    assert_eq!(roster_agent_state(&mux, &terminal_id).as_deref(), Some("working"));
}

/// #39096 review F1: a hook that commits while the background roster replay
/// runs its last slice. The pass that finishes the replay took its fold
/// target before the hook, and the reconcile at the replay's end writes the
/// roster's entries over the public projections. Unless that pass folds the
/// hook first, the reconcile puts the replay's older plugin state over the
/// row the hook projector wrote, and the later fold of the hook applies no
/// delta, so the row stays wrong.
#[test]
fn a_hook_during_the_last_replay_slice_keeps_its_public_row() {
    let mux = test_mux();
    put_plugin_manifest(&mux);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    let t0 = crate::workspace_registry::unix_epoch_ms().unwrap();
    screen(&mux, &terminal_id, "working", t0);
    let agents = public_agents(&mux);
    assert_eq!(agents.len(), 1);
    assert_eq!(agents[0]["source"], "plugin");

    // A replay from zero in the background, held at its first slice's gate.
    let (entered_tx, entered) = std::sync::mpsc::sync_channel(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel(0);
    mux.restart_agent_roster_replay_for_test(1, (entered_tx, release_rx));
    entered.recv_timeout(Duration::from_secs(30)).expect("the replay waits at its gate");
    tick();
    hook(&mux, &terminal_id, "live", "SessionStart", t0 + 1_000);
    hook(&mux, &terminal_id, "live", "UserPromptSubmit", t0 + 1_001);
    // The gate opens: this slice runs the replay to its end.
    drop(release);
    drop(entered);
    let agents = public_agents(&mux);
    assert!(!mux.agent_roster_replaying(), "the replay finished");
    assert_eq!(agents.len(), 1, "{agents:?}");
    assert_eq!(agents[0]["source"], "hook", "the hook's row survives the replay's end: {agents:?}");
    assert_eq!(agents[0]["state"], "working", "{agents:?}");
}
