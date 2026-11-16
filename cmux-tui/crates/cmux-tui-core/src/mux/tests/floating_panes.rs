//! Durability of floating panes (`floating-panes-v1`): the list survives a
//! daemon restart through `resource_floating_panes`, with its order and its
//! frames, and load applies the rules of the list to what the table holds.

use cmux_layout_reducer::floating_panes::{FloatFrame, FloatMode, Floating};

use super::*;
use std::path::PathBuf;

fn open_restart_mux(root: &Path, session: &str) -> Arc<Mux> {
    Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        WorkspaceRegistry::open(root, session).unwrap(),
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap()
}

/// Seeds the restore fixture with its first screen changed by `edit`.
fn seed(name: &str, edit: impl FnOnce(&mut RegistryScreen)) -> (PathBuf, String) {
    let root = std::env::temp_dir()
        .join(format!("cmux-floating-{name}-{}", WorkspacePublicId::random().unwrap()));
    let session = format!("floating-{name}");
    let (fixture_snapshot, mut fixture_topology) = resource_restore_fixture();
    let screen = fixture_topology
        .screens
        .iter_mut()
        .find(|screen| screen.public_id == restore_screen_id(1))
        .unwrap();
    edit(screen);
    let mut registry = WorkspaceRegistry::open(&root, &session).unwrap();
    registry
        .commit_resource_patch(
            &WorkspaceMutation::daemon(format!("seed-floating-{name}"), "test").unwrap(),
            "session.restore_fixture",
            &serde_json::json!({"fixture":"floating"}),
            None,
            Some(0),
            &resource_restore_patch(&fixture_snapshot, &fixture_topology),
            &serde_json::json!({"restored":true}),
            &serde_json::json!([{"event":"session.restored"}]),
        )
        .unwrap();
    (root, session)
}

/// The stored list of the fixture's first screen.
fn stored_list(root: &Path, session: &str) -> Vec<Floating<PanePublicId>> {
    let topology =
        WorkspaceRegistry::open(root, session).unwrap().resource_topology_snapshot().unwrap();
    topology
        .screens
        .into_iter()
        .find(|screen| screen.public_id == restore_screen_id(1))
        .unwrap()
        .floating
}

/// The live list of the first screen, by the public ids of its panes.
fn live_list(mux: &Mux) -> Vec<Floating<PanePublicId>> {
    mux.with_state(|state| {
        state.workspaces[0].screens[0]
            .floating
            .iter()
            .map(|entry| Floating {
                pane: state.panes[&entry.pane].public_id.clone(),
                frame: entry.frame,
            })
            .collect()
    })
}

fn live_pane(mux: &Mux, public_id: &PanePublicId) -> PaneId {
    mux.with_state(|state| {
        state.panes.values().find(|pane| pane.public_id == *public_id).map(|pane| pane.id).unwrap()
    })
}

#[test]
fn floating_panes_persist_across_restart() {
    let (root, session) = seed("restart", |_| {});
    // The fixture's first screen: a stack of panes 1 and 2 above pane 3 in one column, pane 4 in the next.
    let right = restore_pane_id(4);
    let low = restore_pane_id(3);
    let moved = FloatFrame { x: 100_000, y: 200_000, w: 400_000, h: 500_000 };
    let centered = FloatFrame { x: 200_000, y: 200_000, w: 600_000, h: 600_000 };
    let expected = vec![
        Floating { pane: right.clone(), frame: moved },
        Floating { pane: low.clone(), frame: centered },
    ];
    assert!(stored_list(&root, &session).is_empty(), "the fixture has no floating pane");

    let mux = open_restart_mux(&root, &session);
    assert!(live_list(&mux).is_empty());
    let outcome = mux
        .float_pane_as(
            &crate::Actor::Daemon,
            live_pane(&mux, &right),
            FloatMode::On,
            Some(moved),
            None,
        )
        .unwrap();
    assert_eq!(outcome.frame, Some(moved));
    assert!(outcome.changed);
    let outcome = mux
        .float_pane_as(&crate::Actor::Daemon, live_pane(&mux, &low), FloatMode::Toggle, None, None)
        .unwrap();
    assert_eq!(outcome.frame, Some(centered));
    assert_eq!(live_list(&mux), expected);
    mux.shutdown();
    drop(mux);

    assert_eq!(stored_list(&root, &session), expected, "the store keeps the order and the frames");

    let mux = open_restart_mux(&root, &session);
    assert_eq!(live_list(&mux), expected, "a restart keeps the order and the frames");
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.root.pane_ids_vec().len(), 4, "a floating pane stays a pane of the tree");
    });
    // Putting the front pane back is durable too.
    let outcome = mux
        .float_pane_as(&crate::Actor::Daemon, live_pane(&mux, &low), FloatMode::Off, None, None)
        .unwrap();
    assert_eq!(outcome.frame, None);
    mux.shutdown();
    drop(mux);

    assert_eq!(stored_list(&root, &session), expected[..1].to_vec());
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn floating_pane_records_load_by_the_rules() {
    let right = restore_pane_id(4);
    let low = restore_pane_id(3);
    let (root, session) = seed("rules", |screen| {
        screen.floating = vec![
            // A pane that is not a pane of this screen: an older build closed it.
            Floating { pane: restore_pane_id(77), frame: FloatFrame::centered(600_000, 600_000) },
            // A frame that reaches past the screen and is too small.
            Floating {
                pane: low.clone(),
                frame: FloatFrame { x: 950_000, y: 0, w: 10, h: 400_000 },
            },
            Floating { pane: right.clone(), frame: FloatFrame::centered(500_000, 500_000) },
        ];
    });
    let expected = vec![
        Floating { pane: low, frame: FloatFrame { x: 850_000, y: 0, w: 150_000, h: 400_000 } },
        Floating {
            pane: right,
            frame: FloatFrame { x: 250_000, y: 250_000, w: 500_000, h: 500_000 },
        },
    ];
    assert_eq!(stored_list(&root, &session), expected);

    let mux = open_restart_mux(&root, &session);
    assert_eq!(live_list(&mux), expected);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
