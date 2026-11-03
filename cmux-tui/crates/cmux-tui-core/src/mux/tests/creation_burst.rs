//! SPLIT BURST (STATUS 6602): four splits sent at once answered 12-20 ms
//! apart. Each split held a mux-wide lock for its whole creation, its
//! SQLite projection write included, so the next split waited for it.
//! Splits that wait at the same time now commit as one group: one
//! projection, one journal write, one public revision with changes.

use super::*;
use std::sync::mpsc;

/// Waits, bounded and with no sleep, until `ready` holds.
fn wait_until(what: &str, ready: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !ready() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::yield_now();
    }
}

#[test]
fn splits_that_wait_together_commit_in_one_projection_write() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let before = mux.with_state(|state| state.resource_revision);
    // The first split stops right before its effect, inside the creation
    // path, until the other three wait for it.
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    mux.set_creation_before_effect_hook_for_test(Box::new(move || {
        entered_tx.send(()).unwrap();
        release_rx.recv().unwrap();
    }));
    let split = |mux: &Arc<Mux>| {
        let mux = mux.clone();
        std::thread::spawn(move || mux.split(pane, SplitDir::Down, None).unwrap())
    };
    let leader = split(&mux);
    entered_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    let followers = (0..3).map(|_| split(&mux)).collect::<Vec<_>>();
    wait_until("the three other splits to wait", || mux.creations_waiting_for_test() == 3);
    release_tx.send(()).unwrap();
    let mut surfaces = vec![leader.join().unwrap()];
    surfaces.extend(followers.into_iter().map(|thread| thread.join().unwrap()));

    // Each split answered with its own new pane.
    let panes = mux.with_state(|state| {
        surfaces.iter().map(|surface| state.pane_of(surface.id).unwrap()).collect::<HashSet<_>>()
    });
    assert_eq!(panes.len(), 4, "the splits did not answer four new panes");
    assert!(!panes.contains(&pane));
    // The four new panes reached the store and its subscribers in one
    // projection commit, not one commit each.
    let registry = mux.workspace_registry.lock().unwrap();
    let batches = registry.resource_events_after(before).unwrap().batches;
    let with_changes =
        batches.iter().filter(|batch| batch.changes.as_array().is_some_and(|c| !c.is_empty()));
    let revisions = with_changes.map(|batch| batch.revision).collect::<Vec<_>>();
    assert_eq!(
        revisions.len(),
        1,
        "the burst of four splits wrote {} projections with changes (revisions {revisions:?})",
        revisions.len()
    );
    let stored = registry.resource_topology_snapshot().unwrap();
    drop(registry);
    let stored_panes =
        stored.panes.iter().map(|pane| pane.public_id.clone()).collect::<HashSet<_>>();
    mux.with_state(|state| {
        for pane in &panes {
            let public = state.resource_indexes.pane_ids.get(pane).unwrap();
            assert!(stored_panes.contains(public), "pane {public} is not stored");
        }
    });
    for surface in surfaces {
        surface.kill();
    }
    first.kill();
}

/// A group whose one projection commit fails settles each member as a lone
/// failed commit does: here the store takes each creation's own projection
/// next, so every split still answers its pane, and every pane is stored.
#[test]
fn a_failed_group_commit_settles_every_split() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    mux.set_creation_before_effect_hook_for_test(Box::new(move || {
        entered_tx.send(()).unwrap();
        release_rx.recv().unwrap();
    }));
    let split = |mux: &Arc<Mux>| {
        let mux = mux.clone();
        std::thread::spawn(move || mux.split(pane, SplitDir::Right, None))
    };
    let leader = split(&mux);
    entered_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    let follower = split(&mux);
    wait_until("the other split to wait", || mux.creations_waiting_for_test() == 1);
    // The next projection patch the store prepares fails once.
    mux.set_resource_patch_failures_remaining_for_test(1);
    release_tx.send(()).unwrap();
    let surfaces = [leader.join().unwrap().unwrap(), follower.join().unwrap().unwrap()];
    let registry = mux.workspace_registry.lock().unwrap();
    let stored = registry.resource_topology_snapshot().unwrap();
    drop(registry);
    let stored_panes =
        stored.panes.iter().map(|pane| pane.public_id.clone()).collect::<HashSet<_>>();
    mux.with_state(|state| {
        for surface in &surfaces {
            let pane = state.pane_of(surface.id).unwrap();
            let public = state.resource_indexes.pane_ids.get(&pane).unwrap();
            assert!(stored_panes.contains(public), "pane {public} is not stored");
        }
    });
    for surface in surfaces {
        surface.kill();
    }
    first.kill();
}

/// A split sent again with the same client ids while its original waits
/// for its group commit must get the original's replay. Joining the group,
/// it found its original executed but not committed and answered
/// `mutation.indeterminate`, which tells a client to retry with a new key:
/// a second pane (review of #32364).
#[test]
fn a_split_sent_again_during_its_group_gets_the_replay() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let keyed = || TerminalSpawnOptions {
        pane_id: Some(format!("pane_{:032x}", 0x5b11_u128)),
        tab_id: Some(format!("tab_{:032x}", 0x5b11_u128)),
        ..TerminalSpawnOptions::default()
    };
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    mux.set_creation_before_effect_hook_for_test(Box::new(move || {
        entered_tx.send(()).unwrap();
        release_rx.recv().unwrap();
    }));
    let split = |mux: &Arc<Mux>| {
        let (mux, spawn) = (mux.clone(), keyed());
        std::thread::spawn(move || {
            mux.split_with_options_as(&Actor::Daemon, pane, SplitDir::Down, spawn, None)
        })
    };
    let original = split(&mux);
    entered_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    let again = split(&mux);
    wait_until("the second send to wait", || mux.creations_waiting_for_test() == 1);
    release_tx.send(()).unwrap();
    let original = original.join().unwrap().unwrap();
    let again = again
        .join()
        .unwrap()
        .unwrap_or_else(|error| panic!("the split sent again did not get the replay: {error:#}"));
    assert!(!original.replayed);
    assert!(again.replayed, "the split sent again was not a replay");
    assert_eq!(again.surface.id, original.surface.id);
    original.surface.kill();
    first.kill();
}

/// Creation groups take the creation fence in the order they started
/// (third review of #32461): a leader that started later took the fence
/// as soon as it was free, so a later creation could commit before an
/// earlier group whose leader had not reached the fence yet.
#[test]
fn a_later_creation_group_commits_after_an_earlier_one() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let before = mux.with_state(|state| state.resource_revision);
    // The split's group leader stops after it joined and before the fence.
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    mux.set_creation_before_fence_hook_for_test(Box::new(move || {
        entered_tx.send(()).unwrap();
        release_rx.recv().unwrap();
    }));
    let split = {
        let mux = mux.clone();
        std::thread::spawn(move || mux.split(pane, SplitDir::Down, None).unwrap())
    };
    entered_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    // A workspace create starts the next group.
    let workspace = {
        let mux = mux.clone();
        std::thread::spawn(move || mux.new_workspace(None, Some((80, 24))).unwrap())
    };
    // It waits for the fence's turn, or (before the fix) it ran at once.
    wait_until("the workspace create to wait or end", || {
        mux.creations_waiting_for_test() == 1 || workspace.is_finished()
    });
    release_tx.send(()).unwrap();
    let split = split.join().unwrap();
    let workspace = workspace.join().unwrap();
    // The split's pane is stored at a lower revision than the new
    // workspace's pane.
    let (split_pane, workspace_pane) = mux.with_state(|state| {
        let public = |surface: &Arc<Surface>| {
            state
                .resource_indexes
                .pane_ids
                .get(&state.pane_of(surface.id).unwrap())
                .unwrap()
                .clone()
        };
        (public(&split), public(&workspace))
    });
    let batches = mux.workspace_registry.lock().unwrap().resource_events_after(before).unwrap();
    let stored_at = |pane: &str| {
        batches.batches.iter().find_map(|batch| {
            let changes = batch.changes.as_array()?;
            changes
                .iter()
                .any(|change| change["resource"] == "pane" && change["id"].as_str() == Some(pane))
                .then_some(batch.revision)
        })
    };
    let (split_at, workspace_at) =
        (stored_at(split_pane.as_str()), stored_at(workspace_pane.as_str()));
    assert!(
        split_at.is_some() && workspace_at.is_some() && split_at < workspace_at,
        "the later workspace create committed first: split at {split_at:?}, workspace at {workspace_at:?}"
    );
    split.kill();
    workspace.kill();
    first.kill();
}
