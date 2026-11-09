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

/// #39096 router review F1: a hook that commits and projects after the
/// replay's reconcile checked that the roster folded every agent record, and
/// before the reconcile writes. The reconcile's check and its writes hold the
/// hook projector's lock, so that hook projects after them and its row is the
/// one that stays; without that, the reconcile put the replay's plugin state
/// over the newer hook row, and the hook's later fold applied no delta.
#[test]
fn a_hook_after_the_replay_reconciles_check_keeps_its_public_row() {
    let mux = test_mux();
    put_plugin_manifest(&mux);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    let t0 = crate::workspace_registry::unix_epoch_ms().unwrap();
    screen(&mux, &terminal_id, "working", t0);
    assert_eq!(public_agents(&mux)[0]["source"], "plugin");

    // At the reconcile, a hook from another thread. It gets 2 s to project
    // before the reconcile goes on: all of it where nothing holds it back.
    let (projected_tx, projected) = std::sync::mpsc::channel();
    let thread = Arc::new(Mutex::new(None));
    let (hook_mux, hook_terminal, hook_thread) =
        (Arc::clone(&mux), terminal_id, Arc::clone(&thread));
    *mux.agent_roster_worker.reconcile_seam.lock().unwrap() = Some(Box::new(move || {
        tick();
        let handle = std::thread::spawn(move || {
            hook(&hook_mux, &hook_terminal, "live", "SessionStart", t0 + 1_000);
            hook(&hook_mux, &hook_terminal, "live", "UserPromptSubmit", t0 + 1_001);
            let _ = projected_tx.send(());
        });
        *hook_thread.lock().unwrap() = Some(handle);
        let _ = projected.recv_timeout(Duration::from_secs(2));
    }));
    // A replay from zero whose gate is open: one pass runs it to its end.
    let (entered_tx, entered) = std::sync::mpsc::sync_channel(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel(0);
    drop((entered, release));
    mux.restart_agent_roster_replay_for_test(1, (entered_tx, release_rx));
    for _ in 0..100 {
        if thread.lock().unwrap().is_some() {
            break;
        }
        assert!(mux.settle_agent_roster_for_test());
    }
    let handle = thread.lock().unwrap().take().expect("the reconcile ran its seam");
    handle.join().unwrap();
    let agents = public_agents(&mux);
    assert!(!mux.agent_roster_replaying(), "the replay finished");
    assert_eq!(agents.len(), 1, "{agents:?}");
    assert_eq!(agents[0]["source"], "hook", "the hook's row survives the reconcile: {agents:?}");
    assert_eq!(agents[0]["state"], "working", "{agents:?}");
}

/// #39096 follow-up F1: a direct hook report commits its projection and
/// releases the hook projector's lock before it appends its journal echo, the
/// record the roster folds. A replay reconcile in between saw no newer agent
/// record and put the replay's older plugin state over the report's row, and
/// the echo then moved only the roster. The reconcile leaves a row newer than
/// the roster's entry.
#[test]
fn a_direct_report_before_its_echo_keeps_its_row_through_the_replays_reconcile() {
    let mux = test_mux();
    put_plugin_manifest(&mux);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    let t0 = crate::workspace_registry::unix_epoch_ms().unwrap();
    screen(&mux, &terminal_id, "working", t0);
    assert_eq!(public_agents(&mux)[0]["source"], "plugin");

    // A replay from zero, held at its first slice's gate.
    let (entered_tx, entered) = std::sync::mpsc::sync_channel(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel(0);
    mux.restart_agent_roster_replay_for_test(1, (entered_tx, release_rx));
    entered.recv_timeout(Duration::from_secs(30)).expect("the replay waits at its gate");

    // A direct hook report that commits, then waits before its echo.
    let (committed_tx, committed) = std::sync::mpsc::channel();
    let (echo_tx, echo) = std::sync::mpsc::channel::<()>();
    *mux.agent_roster_worker.report_echo_seam.lock().unwrap() = Some(Box::new(move || {
        let _ = committed_tx.send(());
        let _ = echo.recv_timeout(Duration::from_secs(30));
    }));
    tick();
    let reporter = {
        let mux = Arc::clone(&mux);
        let surface = surface.id;
        std::thread::spawn(move || {
            mux.report_agent(surface, AgentState::Idle, AgentSource::Hook, None).unwrap();
        })
    };
    committed.recv_timeout(Duration::from_secs(30)).expect("the report committed");
    // The gate opens: the replay ends, and its reconcile gets its chance
    // while the echo waits.
    drop(release);
    drop(entered);
    for _ in 0..5 {
        assert!(mux.settle_agent_roster_for_test());
    }
    drop(echo_tx);
    reporter.join().unwrap();
    settle_the_replay(&mux);
    let agents = public_agents(&mux);
    assert_eq!(agents.len(), 1, "{agents:?}");
    assert_eq!(agents[0]["source"], "hook", "the report's row survives the reconcile: {agents:?}");
    assert_eq!(agents[0]["state"], "idle", "{agents:?}");
}

/// #39096 follow-up: the start's own reconcile (`reconcile_agent_roster_projections`)
/// waited for the background replay, but not for the reconcile the replay
/// owes once it is done. In that window the roster can still hold an older
/// plugin entry than a row written since, and the start's reconcile put the
/// entry over it. It waits for both now (`agent_roster_settling`).
#[test]
fn the_starts_reconcile_waits_for_the_reconcile_the_replay_owes() {
    let mux = test_mux();
    put_plugin_manifest(&mux);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    let t0 = crate::workspace_registry::unix_epoch_ms().unwrap();
    screen(&mux, &terminal_id, "working", t0);
    assert_eq!(public_agents(&mux)[0]["source"], "plugin");

    // A newer row whose echo the roster has not folded yet.
    let (committed_tx, committed) = std::sync::mpsc::channel();
    let (echo_tx, echo) = std::sync::mpsc::channel::<()>();
    *mux.agent_roster_worker.report_echo_seam.lock().unwrap() = Some(Box::new(move || {
        let _ = committed_tx.send(());
        let _ = echo.recv_timeout(Duration::from_secs(30));
    }));
    tick();
    let reporter = {
        let mux = Arc::clone(&mux);
        let surface = surface.id;
        std::thread::spawn(move || {
            mux.report_agent(surface, AgentState::Idle, AgentSource::Hook, None).unwrap();
        })
    };
    committed.recv_timeout(Duration::from_secs(30)).expect("the report committed");
    // The replay is done and its reconcile not yet run.
    mux.agent_roster_worker.reconcile_pending.store(true, Ordering::Release);
    mux.reconcile_agent_roster_projections();
    let row = mux
        .workspace_registry
        .lock()
        .unwrap()
        .public_agent_projections(Some(&terminal_id), None)
        .unwrap();
    assert_eq!(row[0].source, "hook", "the start's reconcile left the newer row: {row:?}");
    drop(echo_tx);
    reporter.join().unwrap();
    let agents = public_agents(&mux);
    assert_eq!(agents[0]["source"], "hook", "{agents:?}");
}

/// #39096 follow-up F1 (router-review): the reconcile a background replay
/// owes cleared its pending flag before its projection writes, so a guarded
/// `send` (`expect_agent`) saw the roster settled while the writes were still
/// to come, and could type into an agent a hook had just made busy. The flag
/// is cleared after the writes, under the same lock.
#[test]
fn a_guarded_send_waits_for_the_replays_reconcile_writes() {
    let mux = test_mux();
    put_plugin_manifest(&mux);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    screen(&mux, &terminal_id, "working", crate::workspace_registry::unix_epoch_ms().unwrap());
    let settling = Arc::new(Mutex::new(None));
    let (seam_mux, seen) = (Arc::clone(&mux), Arc::clone(&settling));
    *mux.agent_roster_worker.reconcile_seam.lock().unwrap() = Some(Box::new(move || {
        *seen.lock().unwrap() = Some(seam_mux.agent_roster_settling());
    }));
    let (entered_tx, entered) = std::sync::mpsc::sync_channel(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel(0);
    drop((entered, release));
    mux.restart_agent_roster_replay_for_test(1, (entered_tx, release_rx));
    for _ in 0..100 {
        if settling.lock().unwrap().is_some() {
            break;
        }
        assert!(mux.settle_agent_roster_for_test());
    }
    assert_eq!(
        *settling.lock().unwrap(),
        Some(true),
        "a guarded send saw the roster settled before the reconcile's writes"
    );
    assert!(mux.settle_agent_roster_for_test());
    assert!(!mux.agent_roster_settling(), "the reconcile finished");
}

/// #39096 follow-up F3 (router-review): a journal read that failed in the
/// reconcile a background replay owes returned with no retry, so the
/// reconcile stayed pending and guarded sends stayed refused until an
/// unrelated request. It is retried after the roster's read backoff.
#[test]
fn a_failed_reconcile_read_is_retried_without_another_request() {
    use crate::mux::agent_roster_fold::rebuild_faults;
    let mux = test_mux();
    put_plugin_manifest(&mux);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    screen(&mux, &terminal_id, "working", crate::workspace_registry::unix_epoch_ms().unwrap());
    rebuild_faults::fail_reconcile_reads(&mux.session, 1);
    let (entered_tx, entered) = std::sync::mpsc::sync_channel(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel(0);
    drop((entered, release));
    mux.restart_agent_roster_replay_for_test(1, (entered_tx, release_rx));
    let deadline = Instant::now() + Duration::from_secs(10);
    while mux.agent_roster_settling() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    let settled = !mux.agent_roster_settling();
    rebuild_faults::fail_reconcile_reads(&mux.session, 0);
    assert!(settled, "the reconcile stayed pending after its failed read");
}

/// Settles the roster until its replay and the reconcile it owes are done.
fn settle_the_replay(mux: &Mux) {
    for _ in 0..100 {
        assert!(mux.settle_agent_roster_for_test());
        if !mux.agent_roster_settling() {
            break;
        }
    }
    assert!(!mux.agent_roster_settling(), "the replay reconciled");
}

/// Sets the stored projection's `updated_at_ms`, in the type it is stored in.
fn set_projection_updated_at(mux: &Mux, terminal_id: &TerminalPublicId, at_ms: u64) {
    mux.workspace_registry.lock().unwrap().edit_agent_projection_for_test(terminal_id, |row| {
        let stamp = &mut row["updated_at_ms"];
        *stamp = if stamp.is_string() { Value::String(at_ms.to_string()) } else { at_ms.into() };
    });
}

/// A replay from zero held at its gate, and a direct report of `state` from
/// `source` that commits during it. `after_commit` runs right after the report's
/// projection commit; its journal echo waits until the replay ended and its
/// reconcile had its chance. Then everything settles.
fn direct_report_during_a_replay(
    mux: &Arc<Mux>,
    surface: SurfaceId,
    source: AgentSource,
    state: AgentState,
    after_commit: impl FnOnce() + Send + 'static,
) {
    let (entered_tx, entered) = std::sync::mpsc::sync_channel(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel(0);
    mux.restart_agent_roster_replay_for_test(1, (entered_tx, release_rx));
    entered.recv_timeout(Duration::from_secs(30)).expect("the replay waits at its gate");
    let (committed_tx, committed) = std::sync::mpsc::channel();
    let (echo_tx, echo) = std::sync::mpsc::channel::<()>();
    mux.hold_agent_report_echo_for_test(Box::new(move || {
        after_commit();
        let _ = committed_tx.send(());
        let _ = echo.recv_timeout(Duration::from_secs(30));
    }));
    tick();
    let reporter = {
        let mux = Arc::clone(mux);
        std::thread::spawn(move || {
            mux.report_agent(surface, state, source, None).unwrap();
        })
    };
    committed.recv_timeout(Duration::from_secs(30)).expect("the report committed");
    drop(release);
    drop(entered);
    for _ in 0..5 {
        assert!(mux.settle_agent_roster_for_test());
    }
    drop(echo_tx);
    reporter.join().unwrap();
    settle_the_replay(mux);
}

/// #39830 review (next-review F1): the replay's reconcile skipped a row whose
/// wall-clock stamp was newer than the roster's entry. Projections are
/// stamped when written and plugin entries keep their observation time, so a
/// stale row (here an `idle` written after the `working` observation whose
/// own write went missing) outranked the entry, and the repair the reconcile
/// owed never happened. Only a direct report during the replay keeps its row.
#[test]
fn the_replays_reconcile_repairs_a_stale_projection_stamped_later() {
    let mux = test_mux();
    put_plugin_manifest(&mux);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    let t0 = crate::workspace_registry::unix_epoch_ms().unwrap();
    screen(&mux, &terminal_id, "working", t0);
    assert_eq!(public_agents(&mux)[0]["state"], "working");
    mux.workspace_registry
        .lock()
        .unwrap()
        .edit_agent_projection_for_test(&terminal_id, |row| row["state"] = "idle".into());
    set_projection_updated_at(&mux, &terminal_id, t0 + 3_600_000);
    let (entered_tx, entered) = std::sync::mpsc::sync_channel(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel(0);
    drop((entered, release));
    mux.restart_agent_roster_replay_for_test(1, (entered_tx, release_rx));
    settle_the_replay(&mux);
    let agents = public_agents(&mux);
    assert_eq!(agents.len(), 1, "{agents:?}");
    assert_eq!(agents[0]["source"], "plugin", "{agents:?}");
    assert_eq!(agents[0]["state"], "working", "the reconcile repaired the stale row: {agents:?}");
}

/// #39830 review (router F1): a direct report stamped in the same
/// millisecond as the roster's entry, or before it after a clock step, lost
/// its row to the reconcile's strict `>`. Its row is kept because it was
/// written during the replay, whatever its stamp.
#[test]
fn a_direct_report_stamped_before_the_entry_keeps_its_row_through_the_reconcile() {
    let mux = test_mux();
    put_plugin_manifest(&mux);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    screen(&mux, &terminal_id, "working", crate::workspace_registry::unix_epoch_ms().unwrap());
    let (stamp_mux, stamp_terminal) = (Arc::clone(&mux), terminal_id);
    direct_report_during_a_replay(
        &mux,
        surface.id,
        AgentSource::Hook,
        AgentState::Idle,
        move || {
            set_projection_updated_at(&stamp_mux, &stamp_terminal, 1);
        },
    );
    let agents = public_agents(&mux);
    assert_eq!(agents.len(), 1, "{agents:?}");
    assert_eq!(agents[0]["source"], "hook", "the report's row survives the reconcile: {agents:?}");
    assert_eq!(agents[0]["state"], "idle", "{agents:?}");
}

/// #39830 review (router F2), and round 3: a direct completion during the
/// replay. The reconcile read the filtered public projection, where a hook's
/// `done` row is absent, and a fence that kept the report's row whatever the
/// roster folded hid what the reducer made of it. The public row now is the
/// roster's verdict on the completion's echo, as a reconcile with no replay
/// would leave it: never a state the roster does not hold.
#[test]
fn a_direct_completion_during_the_replay_leaves_the_row_the_roster_folded() {
    let mux = test_mux();
    put_plugin_manifest(&mux);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    screen(&mux, &terminal_id, "working", crate::workspace_registry::unix_epoch_ms().unwrap());
    direct_report_during_a_replay(&mux, surface.id, AgentSource::Hook, AgentState::Done, || {});
    let public = public_agents(&mux)
        .iter()
        .map(|agent| {
            (
                agent["state"].as_str().unwrap().to_owned(),
                agent["source"].as_str().unwrap().to_owned(),
            )
        })
        .collect::<Vec<_>>();
    let roster = mux
        .list_agents(None, None)
        .into_iter()
        .filter(|agent| agent.state != AgentState::Done)
        .map(|agent| (agent.state.as_str().to_owned(), agent.source.as_str().to_owned()))
        .collect::<Vec<_>>();
    assert_eq!(public, roster, "the public row is what the roster folded");
}

/// A direct report during the replay whose journal echo failed: the echo is
/// appended again, and the roster folds it before the reconcile, so the
/// report's row stays, stamp or no stamp.
#[test]
fn a_direct_report_whose_echo_failed_keeps_its_row_through_the_reconcile() {
    use crate::mux::agent_roster_fold::rebuild_faults;
    let mux = test_mux();
    put_plugin_manifest(&mux);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    screen(&mux, &terminal_id, "working", crate::workspace_registry::unix_epoch_ms().unwrap());
    rebuild_faults::fail_report_echoes(&mux.session, 1);
    let (stamp_mux, stamp_terminal) = (Arc::clone(&mux), terminal_id);
    direct_report_during_a_replay(
        &mux,
        surface.id,
        AgentSource::Hook,
        AgentState::Idle,
        move || {
            set_projection_updated_at(&stamp_mux, &stamp_terminal, 1);
        },
    );
    rebuild_faults::fail_report_echoes(&mux.session, 0);
    let agents = public_agents(&mux);
    assert_eq!(agents.len(), 1, "{agents:?}");
    assert_eq!(agents[0]["source"], "hook", "the report's row survives the reconcile: {agents:?}");
}

/// #39830 review round 3 (router F1): a stop left a plugin journal event with
/// no projection, so during the replay a weaker socket `idle` report commits
/// (neither the cache nor the projection holds the plugin row). The roster's
/// reducer refuses its echo and keeps the plugin `working`, but a fence kept
/// the socket row whatever the reducer folded. The reconcile now repairs the
/// row to what the roster folded, as it did before the fence.
#[test]
fn a_weaker_direct_report_during_the_replay_gets_the_replayed_plugin_row_back() {
    let mux = test_mux();
    put_plugin_manifest(&mux);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    screen(&mux, &terminal_id, "working", crate::workspace_registry::unix_epoch_ms().unwrap());
    assert_eq!(public_agents(&mux)[0]["source"], "plugin");
    mux.workspace_registry.lock().unwrap().delete_agent_projection_for_test(&terminal_id);
    mux.agent_records.lock().unwrap().remove(&terminal_id);
    direct_report_during_a_replay(&mux, surface.id, AgentSource::Socket, AgentState::Idle, || {});
    assert_eq!(
        mux.agent_roster_state_now_for_test(terminal_id.as_str()).as_deref(),
        Some("working")
    );
    let agents = public_agents(&mux);
    assert_eq!(agents.len(), 1, "{agents:?}");
    assert_eq!(agents[0]["source"], "plugin", "the reconcile repaired the socket row: {agents:?}");
    assert_eq!(agents[0]["state"], "working", "{agents:?}");
}
