//! `restart-tab` (`tab-restart-v1`): a dead tab restarts in place.

use super::*;
use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};

/// Pane public id -> tab public ids, over every workspace and screen.
fn placements(mux: &Mux) -> Vec<(String, Vec<String>)> {
    mux.with_state(|state| {
        let mut panes = Vec::new();
        for workspace in &state.workspaces {
            for screen in &workspace.screens {
                for pane in screen.root.pane_ids_vec() {
                    let tabs = state.panes[&pane]
                        .tabs
                        .iter()
                        .map(|tab| state.resource_indexes.tab_ids[tab].to_string())
                        .collect();
                    panes.push((state.resource_indexes.pane_ids[&pane].to_string(), tabs));
                }
            }
        }
        panes
    })
}

fn terminal_hex(prefix: &str, index: usize) -> String {
    format!("{prefix}000000000040008000{index:012x}")
}

fn content_of(mux: &Mux, surface: SurfaceId) -> ContentPublicId {
    mux.with_state(|state| state.resource_indexes.content_ids[&surface].clone())
}

fn lifecycle(mux: &Mux, host: &str) -> TerminalLifecycle {
    mux.workspace_registry.lock().unwrap().terminal_record(host).unwrap().unwrap().lifecycle
}

fn restart(mux: &Arc<Mux>, surface: SurfaceId, key: &str) -> anyhow::Result<TabRestartOutcome> {
    mux.restart_tab(
        TabRestartRequest {
            surface,
            idempotency_key: Some(key.to_string()),
            ..TabRestartRequest::default()
        },
        None,
    )
}

/// A seeded terminal whose host is then lost (no exit status): its tab
/// stays, dead (invariant 3).
fn host_lost_tab(mux: &Arc<Mux>, workspace_key: &str, index: usize) -> (SurfaceId, String) {
    let host = terminal_hex("00", index);
    let surface = mux
        .seed_running_terminal_with_on_exit_for_test(
            &host,
            &terminal_hex("10", index),
            workspace_key,
            TerminalOnExit::Close,
        )
        .unwrap();
    mux.surface_exited(surface);
    assert_eq!(lifecycle(mux, &host), TerminalLifecycle::Exited);
    (surface, host)
}

/// User decision 2026-10-02: restarting a host-lost tab keeps its id and
/// placement and gives it a live terminal; the dead terminal is tombstoned;
/// the same key replays without a second terminal; a live tab is a typed
/// reject.
#[test]
fn cmux_next_tab_restart_keeps_the_tab_and_gives_it_a_live_terminal() {
    let mux = Mux::new_for_test("tab-restart", SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let (surface, dead_host) = host_lost_tab(&mux, &workspace.key, 1);
    let before = placements(&mux);
    let dead_content = content_of(&mux, surface);

    // A host loss qualifies for the automatic restart (`only_lost`).
    let outcome = mux
        .restart_tab(
            TabRestartRequest {
                surface,
                idempotency_key: Some("restart-1".into()),
                only_lost: true,
                ..TabRestartRequest::default()
            },
            None,
        )
        .unwrap();
    assert!(!outcome.replayed);
    assert_eq!(placements(&mux), before, "a restart moved or replaced a tab");
    assert_eq!(outcome.result["surface"], serde_json::json!(surface));
    let ContentPublicId::Terminal(dead) = &dead_content else { panic!("terminal tab") };
    assert_eq!(outcome.result["replaced_terminal"], serde_json::json!(dead));
    let live_content = content_of(&mux, surface);
    assert_ne!(live_content, dead_content);
    let new_host = outcome.result["terminal_id"].as_str().unwrap().to_string();
    assert_eq!(lifecycle(&mux, &new_host), TerminalLifecycle::Running);
    assert_eq!(lifecycle(&mux, &dead_host), TerminalLifecycle::Tombstoned);
    assert!(!mux.surface(surface).unwrap().is_dead());
    // Durable: the tab row names the new terminal.
    let tab_id = mux.with_state(|state| state.resource_indexes.tab_ids[&surface].clone());
    let topology = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    let durable = topology.tabs.iter().find(|tab| tab.public_id == tab_id).unwrap();
    assert_eq!(durable.content_id, live_content);
    assert_eq!(layout_invariants::rejections_on_this_thread(), 0);

    // I5: the same key replays the first result and launches nothing.
    let terminals = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
    let replay = restart(&mux, surface, "restart-1").unwrap();
    assert!(replay.replayed);
    assert_eq!(replay.result["terminal_id"], outcome.result["terminal_id"]);
    assert_eq!(mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap(), terminals);
    assert_eq!(content_of(&mux, surface), live_content);

    // The tab is live now: another key is a typed reject.
    let error = restart(&mux, surface, "restart-2").unwrap_err();
    assert_eq!(error.downcast_ref::<TabRestartError>(), Some(&TabRestartError::NotDead(surface)));
    assert_eq!(placements(&mux), before);
}

/// Coordinator decision 2026-10-02: every dead tab restarts the same way,
/// including a process end kept by `keep_on_exit`; an unknown tab is a typed
/// reject.
#[test]
fn cmux_next_tab_restart_restarts_a_kept_process_end_and_rejects_unknown_tabs() {
    let mux = Mux::new_for_test("tab-restart-kept", SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let host = terminal_hex("00", 7);
    let surface = mux
        .seed_running_terminal_with_on_exit_for_test(
            &host,
            &terminal_hex("10", 7),
            &workspace.key,
            TerminalOnExit::Keep,
        )
        .unwrap();
    mux.surface(surface)
        .unwrap()
        .record_process_end_for_test(TerminalExit::now(TerminalExitOutcome::Exit { code: 0 }));
    mux.surface_exited(surface);
    let before = placements(&mux);
    assert!(before.iter().any(|(_, tabs)| !tabs.is_empty()), "keep_on_exit kept the tab");
    // The automatic restart takes only host losses; a process end stays.
    let only_lost = TabRestartRequest {
        surface,
        idempotency_key: Some("kept-auto".into()),
        only_lost: true,
        ..TabRestartRequest::default()
    };
    let error = mux.restart_tab(only_lost, None).unwrap_err();
    assert_eq!(error.downcast_ref::<TabRestartError>(), Some(&TabRestartError::NotLost(surface)));
    let outcome = restart(&mux, surface, "kept-1").unwrap();
    assert_eq!(placements(&mux), before);
    let new_host = outcome.result["terminal_id"].as_str().unwrap().to_string();
    assert_eq!(lifecycle(&mux, &new_host), TerminalLifecycle::Running);
    assert_eq!(lifecycle(&mux, &host), TerminalLifecycle::Tombstoned);
    // The restarted shell keeps the tab's exit policy.
    let record =
        mux.workspace_registry.lock().unwrap().terminal_record(&new_host).unwrap().unwrap();
    assert_eq!(record.on_exit, TerminalOnExit::Keep);

    let error = restart(&mux, 999_999, "unknown").unwrap_err();
    assert_eq!(
        error.downcast_ref::<TabRestartError>(),
        Some(&TabRestartError::UnknownTab(999_999))
    );
}

/// Property (seeded): over random host losses and restarts of several tabs,
/// a restart never changes the set of tabs or any placement, the layout
/// checker never rejects it (conservation holds), and only dead tabs
/// restart.
#[test]
fn cmux_next_tab_restart_conserves_tabs_over_random_losses_and_restarts() {
    let mux = Mux::new_for_test("tab-restart-property", SurfaceOptions::default());
    let mut tabs = Vec::new();
    for workspace_index in 0..2 {
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        for slot in 0..2 {
            let index = workspace_index * 2 + slot;
            let host = terminal_hex("00", index);
            let surface = mux
                .seed_running_terminal_with_on_exit_for_test(
                    &host,
                    &terminal_hex("10", index),
                    &workspace.key,
                    TerminalOnExit::Close,
                )
                .unwrap();
            tabs.push(surface);
        }
    }
    let before = placements(&mux);
    // Seeded placeholders can lose their host; a restarted tab runs an
    // in-process test terminal, which stays live here.
    let mut lost = HashSet::new();
    let mut live_again = HashSet::new();
    let mut seed = 0x9e37_79b9_7f4a_7c15_u64;
    let mut restarted = 0;
    for step in 0..24 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let surface = tabs[(seed % tabs.len() as u64) as usize];
        let dead = lost.contains(&surface) && !live_again.contains(&surface);
        // A bit the tab pick (the low bits) does not use.
        if (seed >> 32).is_multiple_of(2) {
            if !lost.contains(&surface) {
                mux.surface_exited(surface);
                lost.insert(surface);
            }
        } else {
            match restart(&mux, surface, &format!("step-{step}")) {
                Ok(_) => {
                    assert!(dead, "step {step}: a live tab restarted");
                    live_again.insert(surface);
                    restarted += 1;
                }
                Err(error) => {
                    assert!(!dead, "step {step}: a dead tab did not restart: {error:#}");
                    assert_eq!(
                        error.downcast_ref::<TabRestartError>(),
                        Some(&TabRestartError::NotDead(surface))
                    );
                }
            }
        }
        assert_eq!(placements(&mux), before, "step {step}: the topology changed");
        assert_eq!(layout_invariants::rejections_on_this_thread(), 0, "step {step}");
    }
    assert!(restarted > 0, "the seed restarted nothing");
}
